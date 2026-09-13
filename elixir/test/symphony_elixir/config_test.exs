defmodule SymphonyElixir.ConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  describe "agent_backend_for_state/1" do
    test "returns the global default when no per-state override" do
      write_workflow!("""
      ---
      tracker: {kind: memory}
      agent: {backend: codex}
      ---
      body
      """)

      assert SymphonyElixir.Config.agent_backend_for_state("Implemented") == {:ok, "codex"}
    end

    test "per-state override wins and is case/space-insensitive" do
      write_workflow!("""
      ---
      tracker: {kind: memory}
      agent:
        backend: codex
        backend_by_state: {"implemented": claude}
      ---
      body
      """)

      assert SymphonyElixir.Config.agent_backend_for_state("  Implemented ") == {:ok, "claude"}
    end

    test "unknown backend value returns an invalid_agent_backend error" do
      write_workflow!("""
      ---
      tracker: {kind: memory}
      agent:
        backend: codex
        backend_by_state: {"implemented": gemini}
      ---
      body
      """)

      assert SymphonyElixir.Config.agent_backend_for_state("Implemented") ==
               {:error, {:invalid_agent_backend, "Implemented", "gemini"}}
    end

    test "unknown global backend value returns an invalid_agent_backend error" do
      write_workflow!("""
      ---
      tracker: {kind: memory}
      agent: {backend: gemini, backend_by_state: {}}
      ---
      body
      """)

      assert SymphonyElixir.Config.agent_backend_for_state("Implemented") ==
               {:error, {:invalid_agent_backend, "Implemented", "gemini"}}
    end
  end

  test "normalize_state_backends/1 handles nil" do
    assert Schema.normalize_state_backends(nil) == %{}
  end

  describe "selected backend command validation" do
    test "rejects blank codex.command when global backend selects Codex" do
      assert {:error, [%{path: "codex.command"}]} =
               write_workflow!("""
               ---
               tracker: {kind: memory}
               agent: {backend: codex}
               codex: {command: ""}
               ---
               body
               """)

      assert :ok = Config.validate!()
    end

    test "rejects blank codex.command when a state override selects Codex" do
      assert {:error, [%{path: "codex.command"}]} =
               write_workflow!("""
               ---
               tracker: {kind: memory}
               agent:
                 backend: claude
                 backend_by_state: {"implemented": codex}
               codex: {command: ""}
               claude: {command: "/bin/true"}
               ---
               body
               """)

      assert :ok = Config.validate!()
    end

    test "allows blank codex.command when Codex cannot be selected" do
      write_workflow!("""
      ---
      tracker: {kind: memory}
      agent: {backend: claude, backend_by_state: {}}
      codex: {command: ""}
      claude: {command: "/bin/true"}
      ---
      body
      """)

      assert :ok = SymphonyElixir.Config.validate!()
    end

    test "rejects blank claude.command when global backend selects Claude" do
      assert {:error, [%{path: "claude.command"}]} =
               write_workflow!("""
               ---
               tracker: {kind: memory}
               agent: {backend: claude}
               claude: {command: ""}
               ---
               body
               """)

      assert :ok = Config.validate!()
    end

    test "rejects blank claude.command when a state override selects Claude" do
      assert {:error, [%{path: "claude.command"}]} =
               write_workflow!("""
               ---
               tracker: {kind: memory}
               agent:
                 backend: codex
                 backend_by_state: {"implemented": claude}
               claude: {command: ""}
               ---
               body
               """)

      assert :ok = Config.validate!()
    end

    test "allows blank claude.command when Claude cannot be selected" do
      write_workflow!("""
      ---
      tracker: {kind: memory}
      agent: {backend: codex, backend_by_state: {}}
      claude: {command: ""}
      ---
      body
      """)

      assert :ok = SymphonyElixir.Config.validate!()
    end
  end

  test "schema errors identify invalid fields in changesets and early worker validation" do
    cases = [
      {%{"polling" => %{"interval_ms" => "nope"}, "server" => %{"port" => "nope"}}, ["polling.interval_ms", "server.port"]},
      {%{"worker" => %{"environment" => %{}, "ssh_hosts" => []}}, ["worker"]},
      {%{"worker" => %{"environment" => nil}}, ["worker.environment"]},
      {%{"worker" => %{"environment" => %{}}}, ["worker.environment"]},
      {%{"worker" => %{"environment" => %{"kind" => "unsupported"}}}, ["worker.environment"]}
    ]

    for {config, paths} <- cases do
      config = Map.put(config, "tracker", %{"kind" => "memory"})

      assert {:error, {:invalid_workflow_config, errors}} = Schema.parse(config, errors: :list)
      assert Enum.sort(Enum.map(errors, &elem(&1, 0))) == paths
      assert Enum.all?(errors, fn {_path, message} -> is_binary(message) end)
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
      assert is_binary(message)
      assert Schema.parse(config, errors: :string) == Schema.parse(config)
    end
  end

  test "operator token rotation invalidates the installation signing key" do
    Application.put_env(:symphony_elixir, :operator_token, "first-operator-token")
    key = Config.operator_session_secret()
    assert byte_size(key) >= 64
    assert key == Config.operator_session_secret()
    Application.put_env(:symphony_elixir, :operator_token, "rotated-operator-token")
    refute Config.operator_session_secret() == key
    Application.delete_env(:symphony_elixir, :operator_token)
    assert Config.operator_session_secret() == nil
  end

  defp write_workflow!(content) do
    File.write!(Workflow.workflow_file_path(), content)

    reload_workflow!()
  end
end
