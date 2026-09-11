defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when `WORKFLOW.md` changes.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [:path, :stamp, :workflow, :settings, :environment_guard]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        call_store(pid, :current)

      _ ->
        Workflow.load()
    end
  end

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        call_store(pid, :settings)

      _ ->
        load_settings()
    end
  end

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        call_store(pid, :force_reload)

      _ ->
        load_reload_result()
    end
  end

  defp call_store(pid, operation) do
    GenServer.call(pid, operation)
  catch
    :exit, reason ->
      # A timeout from a live authority must not bypass its publication guard.
      if Process.alive?(pid), do: exit(reason), else: load_without_store(operation)
  end

  defp load_without_store(:current), do: Workflow.load()
  defp load_without_store(:settings), do: load_settings()
  defp load_without_store(:force_reload), do: load_reload_result()

  defp load_settings do
    case load_state(Workflow.workflow_file_path()) do
      {:ok, %State{settings: settings}} -> {:ok, settings}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_reload_result do
    case load_state(Workflow.workflow_file_path()) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec protect_environment(binary() | nil) :: {:ok, reference()} | {:error, term()}
  def protect_environment(identity) do
    GenServer.call(__MODULE__, {:protect_environment, identity})
  end

  @doc "Checks that a captured authority token still protects the published identity."
  @spec protect_environment(binary(), reference()) :: {:ok, reference()} | {:error, term()}
  def protect_environment(identity, token) when is_binary(identity) and is_reference(token) do
    GenServer.call(__MODULE__, {:protect_environment, identity, token})
  end

  @spec release_environment(reference(), :empty_inventory) :: :ok | {:error, term()}
  def release_environment(token, :empty_inventory) when is_reference(token) do
    GenServer.call(__MODULE__, {:release_environment, token, :empty_inventory})
  end

  @impl true
  def init(_opts) do
    case load_state(Workflow.workflow_file_path()) do
      {:ok, state} ->
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:settings, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}
    end
  end

  def handle_call({:protect_environment, identity, token}, _from, %State{environment_guard: %{identity: identity, token: token}} = state) do
    {:reply, {:ok, token}, state}
  end

  def handle_call({:protect_environment, _identity, _token}, _from, state) do
    {:reply, {:error, :invalid_environment_guard}, state}
  end

  def handle_call({:protect_environment, identity}, _from, %State{} = state) do
    current_identity = SymphonyElixir.ExecutionEnvironment.Config.identity(state.settings)

    compatible_guard? = is_nil(state.environment_guard) or state.environment_guard.identity == identity

    if identity == current_identity and compatible_guard? do
      token = make_ref()
      {:reply, {:ok, token}, %{state | environment_guard: %{identity: identity, token: token}}}
    else
      {:reply, {:error, :environment_identity_in_use}, state}
    end
  end

  def handle_call({:release_environment, token, :empty_inventory}, _from, %State{environment_guard: %{token: token}} = state) do
    {:reply, :ok, %{state | environment_guard: nil}}
  end

  def handle_call({:release_environment, _token, :empty_inventory}, _from, %State{} = state) do
    {:reply, {:error, :invalid_environment_guard}, state}
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    path = Workflow.workflow_file_path()

    if path != state.path do
      reload_path(path, state)
    else
      reload_current_path(path, state)
    end
  end

  defp reload_path(path, state) do
    case load_state(path) do
      {:ok, new_state} ->
        publish_candidate(state, new_state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp publish_candidate(%State{environment_guard: nil}, new_state), do: {:ok, new_state}

  defp publish_candidate(%State{environment_guard: guard} = state, new_state) do
    if SymphonyElixir.ExecutionEnvironment.Config.identity(new_state.settings) == guard.identity do
      {:ok, %{new_state | environment_guard: guard}}
    else
      log_reload_error(new_state.path, :environment_identity_in_use)
      {:error, :environment_identity_in_use, state}
    end
  end

  defp reload_current_path(path, state) do
    case current_stamp(path) do
      {:ok, stamp} when stamp == state.stamp ->
        {:ok, state}

      {:ok, _stamp} ->
        reload_path(path, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp load_state(path) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(settings),
         {:ok, stamp} <- current_stamp(path) do
      identity = SymphonyElixir.ExecutionEnvironment.Config.identity(settings)
      guard = if is_nil(identity), do: nil, else: %{identity: identity, token: make_ref()}
      {:ok, %State{path: path, stamp: stamp, workflow: workflow, settings: settings, environment_guard: guard}}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_stamp(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end
end
