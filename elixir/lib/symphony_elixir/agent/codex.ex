defmodule SymphonyElixir.Agent.Codex do
  @moduledoc """
  Agent backend that drives the Codex app-server.

  This is a thin wrapper over `Codex.AppServer` that normalizes turn results to
  `Agent.Result`. Codex still emits its native worker-update maps through
  `opts[:on_message]`, preserving the existing Codex path behavior.
  """

  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.Codex.AppServer

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, SymphonyElixir.Agent.session()} | {:error, term()}
  def start_session(workspace, opts) do
    AppServer.start_session(workspace, Keyword.take(opts, [:worker_host]))
  end

  @impl true
  @spec run_turn(SymphonyElixir.Agent.session(), String.t(), map(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_turn(session, prompt, issue, opts) do
    run_opts = Keyword.take(opts, [:on_message, :tool_executor])

    case AppServer.run_turn(session, prompt, issue, run_opts) do
      {:ok, turn} -> to_result(turn)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec stop_session(SymphonyElixir.Agent.session()) :: :ok
  def stop_session(session) do
    AppServer.stop_session(session)
  end

  @doc false
  @spec to_result(map()) :: {:ok, Result.t()}
  def to_result(turn) do
    result = Map.get(turn, :result, %{})
    usage = usage_from_result(result)

    {:ok,
     Result.new(
       status: :done,
       session_id: Map.get(turn, :session_id),
       tokens: %{
         input: Map.get(usage, "input_tokens", 0),
         output: Map.get(usage, "output_tokens", 0),
         total: Map.get(usage, "total_tokens", 0)
       },
       summary: summary_from_result(result)
     )}
  end

  defp usage_from_result(%{} = result), do: Map.get(result, "usage", %{})
  defp usage_from_result(_result), do: %{}

  defp summary_from_result(%{} = result), do: Map.get(result, "summary")
  defp summary_from_result(_result), do: nil
end
