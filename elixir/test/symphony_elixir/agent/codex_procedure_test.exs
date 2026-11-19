defmodule SymphonyElixir.Agent.CodexProcedureTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Codex
  alias SymphonyElixir.{ExecutionContext, Repo}

  for {transport, slug, route, live_state, labels} <- [
        {:local, "bonbons-delivery", "bug", "In Progress", ["groomed", "Bug"]},
        {:ssh, "chorus-delivery", "qa", "In Review", ["groomed"]}
      ] do
    @tag :tmp_dir
    test "#{transport} Codex starts with Common and reads only its selected pinned procedure", %{tmp_dir: root} do
      previous_path = System.get_env("PATH")
      on_exit(fn -> restore_env("PATH", previous_path) end)
      trace = Path.join(root, "ssh.trace")
      write_fake_ssh!(root, trace)

      route = unquote(route)

      issue = %Issue{
        id: "codex-procedure-issue",
        identifier: "TEST-2",
        state: unquote(live_state),
        dispatchable: true,
        labels: unquote(labels)
      }

      procedures = %{"qa" => "PINNED_QA", "bug" => "PINNED_BUG", "deliver" => "PINNED_DELIVER"}

      procedures =
        if unquote(slug) == "bonbons-delivery",
          do: Map.put(procedures, "error-reporting", "PINNED_ERROR_REPORTING"),
          else: procedures

      run_log = Path.join(root, "model-boundary.jsonl")
      codex = write_procedure_codex!(root, run_log, route)

      {:ok, lane} =
        create_lane_from_front_matter(%{
          slug: unquote(slug),
          procedures: procedures,
          prompt: "PINNED_COMMON",
          front_matter: """
          tracker:
            kind: memory
            active_states: ["Todo", "In Progress", "In Review"]
          workspace:
            root: #{Jason.encode!(Path.join(root, "workspaces"))}
          agent: {backend: codex}
          codex:
            command: #{Jason.encode!(codex)}
            turn_timeout_ms: 15000
            stall_timeout_ms: 15000
          """
        })

      {:ok, pinned} = LaneStore.lookup(lane.id)
      LaneContext.install(pinned)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      context =
        case unquote(transport) do
          :local ->
            ExecutionContext.local(pinned.settings.workspace.root)

          :ssh ->
            target = %SymphonyElixir.SSH.Target{
              executable: Path.join([root, "bin", "ssh"]),
              prefix: [],
              label: "fixture",
              env: [{"BASH_ENV", Path.join(root, "fixture-bash-env")}]
            }

            ExecutionContext.ssh(pinned.settings.workspace.root, target)
        end

      current_procedures = Map.replace!(procedures, route, "CURRENT_REPLACEMENT")

      # Publish a new lane version between turns: the continuation must stay on the pinned one.
      fetch_issue = fn [id] ->
        assert id == issue.id

        if LaneStore.lookup(lane.id) == {:ok, pinned} do
          assert {:ok, _updated} = Lanes.update(lane, %{prompt: "CURRENT_COMMON", procedures: current_procedures})
        end

        {:ok, [issue]}
      end

      opts = [execution_context: context, backend_module: Codex]
      assert :ok = AgentRunner.run(issue, self(), opts ++ [max_turns: 2, issue_state_fetcher: fetch_issue])

      [first, continuation] = read_boundary(run_log)
      assert first["prompt"] =~ "PINNED_COMMON"
      assert continuation["prompt"] =~ "Continuation guidance"
      assert continuation["calls"] == []

      assert [%{"name" => "read_procedure", "description" => description}] =
               Enum.filter(first["tools"], &(&1["name"] == "read_procedure"))

      [denied, selected, secondary] = first["calls"]
      assert %{"section" => "error-reporting", "success" => false} = denied
      assert %{"section" => ^route, "success" => true, "text" => text} = selected
      assert text == Map.fetch!(procedures, route)

      if unquote(slug) == "bonbons-delivery",
        do: assert(%{"success" => true, "text" => "PINNED_ERROR_REPORTING"} = secondary),
        else: assert(%{"success" => false} = secondary)

      for capture <- [first, continuation],
          marker <- Map.values(procedures) ++ ["CURRENT_REPLACEMENT", "CURRENT_COMMON"] do
        refute capture["prompt"] =~ marker
        refute description =~ marker
      end

      if unquote(transport) == :ssh do
        ssh_args = File.read!(trace)
        for marker <- ["PINNED_COMMON" | Map.values(procedures)], do: refute(ssh_args =~ marker)
      end

      # A completed turn that never read its selected procedure is rejected.
      mode = Path.join(root, "fixture-mode")
      File.write!(mode, "unread")

      assert_raise RuntimeError, ~r/procedure_not_read/, fn ->
        AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
      end

      # No live route: nothing needs a procedure, so an unread turn is accepted.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | labels: ["human"]}])
      assert :ok = AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
      refute_received {:codex_worker_update, _, _, %{event: :attempt_blocked}}
      File.rm!(mode)

      # The selected section is missing from the new version: preflight blocks before Codex runs.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      captures = read_boundary(run_log)
      updated = Lanes.get!(lane.id)
      version = Lanes.current_version(updated)
      Repo.update!(Ecto.Changeset.change(version, procedures: Map.delete(current_procedures, route)))
      assert :ok = LaneStore.refresh(lane.id)
      {:ok, damaged} = LaneStore.lookup(lane.id)
      LaneContext.install(damaged)

      assert :ok = AgentRunner.run(issue, self(), opts ++ [max_turns: 1])
      assert_received {:codex_worker_update, _, _, %{event: :attempt_blocked, payload: detail}}
      assert detail =~ route

      assert Tracker.Memory.calls() == [
               {:create_comment, issue.id},
               {:update_issue_state, issue.id, damaged.settings.agent.blocked_state}
             ]

      assert read_boundary(run_log) == captures
    end
  end

  defp read_boundary(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  # A fake app-server that behaves like a Codex thread: the first turn reads Error Reporting
  # (expecting denial), its selected section, then Error Reporting again; continuations read nothing.
  defp write_procedure_codex!(root, run_log, section) do
    path = Path.join(root, "fixture-codex")

    File.write!(path, """
    #!/usr/bin/env python3
    import json, sys
    from pathlib import Path

    mode_file = Path(#{Jason.encode!(Path.join(root, "fixture-mode"))})

    def send(message):
        sys.stdout.write(json.dumps(message) + "\\n")
        sys.stdout.flush()

    def recv():
        line = sys.stdin.readline()
        if not line:
            sys.exit(0)
        return json.loads(line)

    tools, turns = None, 0
    while True:
        message = recv()
        method = message.get("method")
        if method == "initialize":
            send({"id": message["id"], "result": {}})
        elif method == "thread/start":
            tools = message["params"]["dynamicTools"]
            send({"id": message["id"], "result": {"thread": {"id": "thread-procedure"}}})
        elif method == "turn/start":
            turns += 1
            mode = mode_file.read_text() if mode_file.exists() else ""
            send({"id": message["id"], "result": {"turn": {"id": "turn-%d" % turns}}})
            sections = []
            if turns == 1 and mode != "unread":
                sections = ["error-reporting", #{Jason.encode!(section)}, "error-reporting"]
            calls = []
            for index, wanted in enumerate(sections):
                send({"id": 100 + index, "method": "item/tool/call",
                      "params": {"name": "read_procedure", "arguments": {"section": wanted}}})
                reply = recv()["result"]
                calls.append({"section": wanted, "success": reply["success"], "text": reply["output"]})
            with open(#{Jason.encode!(run_log)}, "a") as log:
                log.write(json.dumps({"prompt": message["params"]["input"][0]["text"], "tools": tools, "calls": calls}) + "\\n")
            send({"method": "turn/completed", "params": {}})
    """)

    File.chmod!(path, 0o700)
    path
  end

  defp write_fake_ssh!(test_root, trace_file) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)
    escaped_bin = "'" <> String.replace(fake_bin_dir, "'", "'\"'\"'") <> "'"
    File.write!(Path.join(test_root, "fixture-bash-env"), "export PATH=#{escaped_bin}:\"$PATH\"\n")

    File.write!(fake_ssh, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    last_arg=
    for arg in "$@"; do
      last_arg=$arg
    done
    /bin/sh -c "$last_arg"
    """)

    File.chmod!(fake_ssh, 0o755)

    fake_realpath = Path.join(fake_bin_dir, "realpath")

    File.write!(
      fake_realpath,
      "#!/bin/sh\n[ \"$1\" = -m ] && shift\n[ \"$1\" = -- ] && shift\nexec python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \"$1\"\n"
    )

    File.chmod!(fake_realpath, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end
end
