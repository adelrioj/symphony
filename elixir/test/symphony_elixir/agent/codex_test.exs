defmodule SymphonyElixir.Agent.CodexTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Codex
  alias SymphonyElixir.Agent.Result

  test "to_result/1 maps a codex turn map with usage to a done Result" do
    turn = %{
      result: %{"usage" => %{"input_tokens" => 4, "output_tokens" => 6, "total_tokens" => 10}, "summary" => "did the thing"},
      session_id: "thread-1-turn-1",
      thread_id: "thread-1",
      turn_id: "turn-1"
    }

    assert {:ok, %Result{} = result} = Codex.to_result(turn)
    assert result.status == :done
    assert result.session_id == "thread-1-turn-1"
    assert result.tokens == %{input: 4, output: 6, total: 10}
    assert result.summary == "did the thing"
  end

  test "to_result/1 maps the current codex turn completion shape to a done Result" do
    turn = %{
      result: :turn_completed,
      session_id: "thread-1-turn-1",
      thread_id: "thread-1",
      turn_id: "turn-1"
    }

    assert {:ok, %Result{} = result} = Codex.to_result(turn)
    assert result.status == :done
    assert result.session_id == "thread-1-turn-1"
    assert result.tokens == %{input: 0, output: 0, total: 0}
    assert result.summary == nil
  end

  test "to_result/1 defaults tokens to zero when usage is absent" do
    assert {:ok, %Result{tokens: %{input: 0, output: 0, total: 0}}} =
             Codex.to_result(%{result: %{}, session_id: "s", thread_id: "t", turn_id: "u"})
  end

  test "run_turn/4 returns app-server errors unchanged" do
    tmp = Path.join(System.tmp_dir!(), "symphony-codex-error-test-#{System.unique_integer([:positive])}")
    script = Path.join(tmp, "fake_app_server")
    File.mkdir_p!(tmp)

    File.write!(script, """
    #!/bin/sh
    read _request
    printf '%s\\n' '{"id":3,"error":{"message":"turn failed"}}'
    """)

    File.chmod!(script, 0o700)

    on_exit(fn -> File.rm_rf(tmp) end)

    port =
      Port.open({:spawn_executable, String.to_charlist(script)}, [
        :binary,
        :exit_status,
        line: 1_048_576
      ])

    session = %{
      port: port,
      metadata: %{},
      approval_policy: "never",
      auto_approve_requests: true,
      turn_sandbox_policy: %{"type" => "workspaceWrite"},
      thread_id: "thread-1",
      workspace: tmp
    }

    issue = %{id: "issue-id", identifier: "ISS-1", title: "Broken turn"}

    assert Codex.run_turn(session, "prompt", issue, []) ==
             {:error, {:response_error, %{"message" => "turn failed"}}}
  end
end
