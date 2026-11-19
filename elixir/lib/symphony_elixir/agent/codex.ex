defmodule SymphonyElixir.Agent.Codex do
  @moduledoc """
  Agent backend that drives the Codex app-server.

  This is a thin wrapper over `Codex.AppServer` that normalizes turn results to
  `Agent.Result`. Codex still emits its native worker-update maps through
  `opts[:on_message]`, preserving the existing Codex path behavior.
  """

  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.{CliHarness, Result}
  alias SymphonyElixir.Codex.{AppServer, DynamicTool}
  alias SymphonyElixir.MCP.ProcedureSession

  @procedure_tool "read_procedure"

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, SymphonyElixir.Agent.session()} | {:error, term()}
  def start_session(workspace, opts) do
    app_opts = Keyword.take(opts, [:execution_context])

    case ProcedureSession.payload(Keyword.get(opts, :issue_id)) do
      {:ok, nil, _preflight?} -> AppServer.start_session(workspace, app_opts)
      {:ok, payload, preflight?} -> start_procedure_session(workspace, app_opts, payload, preflight?)
      {:error, _reason} = error -> error
    end
  end

  # Codex calls dynamic tools back over the app-server's stdio, so the pinned bundle and its
  # outcome stay in a private controller directory even when the app-server runs over SSH.
  # One Codex thread serves every continuation turn, so the outcome is reset once per session and
  # each turn's recorded read is rechecked against the live route when the turn ends.
  defp start_procedure_session(workspace, app_opts, payload, preflight?) do
    with {:ok, dir, monitor} <- CliHarness.create_session_dir("symphony-codex-procedures", workspace) do
      path = Path.join(dir, "procedures.json")
      binding = DynamicTool.bind()
      binding = %{binding | tool_specs: binding.tool_specs ++ [ProcedureSession.tool_spec()]}

      with :ok <- CliHarness.write_private_file(path, payload),
           :ok <- ProcedureSession.reset_outcome(path),
           {:ok, session} <- AppServer.start_session(workspace, [dynamic_tool_binding: binding] ++ app_opts) do
        {:ok,
         Map.merge(session, %{
           procedure_path: path,
           procedure_preflight?: preflight?,
           procedure_dir: dir,
           cleanup_monitor: monitor
         })}
      else
        error ->
          CliHarness.remove_session_dir(dir, monitor)
          error
      end
    end
  end

  @impl true
  @spec run_turn(SymphonyElixir.Agent.session(), String.t(), map(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_turn(%{procedure_path: path} = session, prompt, issue, opts) when is_binary(path) do
    case preflight(session) do
      :ok ->
        fallback =
          Keyword.get(opts, :tool_executor, &DynamicTool.execute(&1, &2, session.dynamic_tool_binding, issue: issue))

        executor = fn
          @procedure_tool, arguments -> read_procedure(path, arguments)
          tool, arguments -> fallback.(tool, arguments)
        end

        result = run_app_server_turn(session, prompt, issue, Keyword.put(opts, :tool_executor, executor))
        ProcedureSession.finish_local_turn(path, result, recheck_read?: true)

      {:blocked, detail} ->
        ProcedureSession.blocked_result(detail)

      {:error, _reason} = error ->
        error
    end
  end

  def run_turn(session, prompt, issue, opts), do: run_app_server_turn(session, prompt, issue, opts)

  defp run_app_server_turn(session, prompt, issue, opts) do
    run_opts = Keyword.take(opts, [:on_message, :tool_executor])

    case AppServer.run_turn(session, prompt, issue, run_opts) do
      {:ok, turn} -> to_result(turn)
      {:error, reason} -> {:error, reason}
    end
  end

  defp preflight(%{procedure_preflight?: true, procedure_path: path}) do
    with {:ok, procedure} <- ProcedureSession.load(path), do: ProcedureSession.preflight(procedure)
  end

  defp preflight(_session), do: :ok

  defp read_procedure(path, arguments) do
    case with({:ok, procedure} <- ProcedureSession.load(path), do: ProcedureSession.read(procedure, arguments)) do
      {:ok, text} -> %{"success" => true, "output" => text}
      {:error, text} when is_binary(text) -> %{"success" => false, "output" => text}
      {:error, _reason} -> %{"success" => false, "output" => "This run's procedure context is unavailable."}
    end
  end

  @impl true
  @spec stop_session(SymphonyElixir.Agent.session()) :: :ok
  def stop_session(session) do
    AppServer.stop_session(session)

    case session do
      %{procedure_dir: dir} -> CliHarness.remove_session_dir(dir, session[:cleanup_monitor])
      _ -> :ok
    end
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
