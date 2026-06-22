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
      write_workflow!("""
      ---
      tracker: {kind: memory}
      agent: {backend: codex}
      codex: {command: ""}
      ---
      body
      """)

      assert {:error, {:invalid_workflow_config, message}} = SymphonyElixir.Config.validate!()
      assert message =~ "codex.command"
      assert message =~ "can't be blank"
    end

    test "rejects blank codex.command when a state override selects Codex" do
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

      assert {:error, {:invalid_workflow_config, message}} = SymphonyElixir.Config.validate!()
      assert message =~ "codex.command"
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
      write_workflow!("""
      ---
      tracker: {kind: memory}
      agent: {backend: claude}
      claude: {command: ""}
      ---
      body
      """)

      assert {:error, {:invalid_workflow_config, message}} = SymphonyElixir.Config.validate!()
      assert message =~ "claude.command"
      assert message =~ "can't be blank"
    end

    test "rejects blank claude.command when a state override selects Claude" do
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

      assert {:error, {:invalid_workflow_config, message}} = SymphonyElixir.Config.validate!()
      assert message =~ "claude.command"
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

  defp write_workflow!(content) do
    File.write!(Workflow.workflow_file_path(), content)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end
end
