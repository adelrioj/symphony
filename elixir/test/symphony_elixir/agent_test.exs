defmodule SymphonyElixir.AgentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent

  test "module_for/1 resolves supported backends" do
    assert Agent.module_for("codex") == {:ok, SymphonyElixir.Agent.Codex}
    assert Agent.module_for("claude") == {:ok, SymphonyElixir.Agent.Claude}
  end

  test "module_for/1 rejects unsupported backends" do
    assert Agent.module_for("gemini") == {:error, {:invalid_agent_backend, "gemini"}}
  end
end
