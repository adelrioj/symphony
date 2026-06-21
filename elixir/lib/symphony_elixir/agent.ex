defmodule SymphonyElixir.Agent do
  @moduledoc """
  Behaviour for a coding-agent backend. Session-aware to match the existing
  `Codex.AppServer` shape; `AgentRunner` owns the multi-turn continuation loop.
  """

  alias SymphonyElixir.Agent.Result

  @type session :: term()
  @type on_message :: (map() -> any())

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(session :: session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, Result.t()} | {:error, term()}

  @callback stop_session(session :: session()) :: :ok

  @doc """
  Resolve a backend module name to its adapter module.
  """
  @spec module_for(String.t()) :: {:ok, module()} | {:error, {:invalid_agent_backend, String.t()}}
  def module_for("codex"), do: {:ok, SymphonyElixir.Agent.Codex}
  def module_for("claude"), do: {:ok, SymphonyElixir.Agent.Claude}
  def module_for(other), do: {:error, {:invalid_agent_backend, other}}
end
