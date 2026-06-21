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
