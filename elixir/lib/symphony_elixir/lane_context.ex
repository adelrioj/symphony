defmodule SymphonyElixir.LaneContext do
  @moduledoc """
  Names the lane a process works for.

  Resolution checks the process's own tag first, then the nearest live tagged
  process in `$callers`, which Task and Task.Supervisor children inherit. Tags
  belong to individual processes; tagging a child does not change its ancestors.
  Ordinary spawned processes must be tagged explicitly.
  """

  @key :symphony_lane_id

  defmodule NoLaneContext do
    @moduledoc "Raised when neither a process nor its live task callers have a lane tag."
    defexception [:message]
  end

  @doc "Tags the current process with its lane, replacing any previous tag."
  @spec put(term()) :: :ok
  def put(lane_id) do
    Process.put(@key, lane_id)
    :ok
  end

  @doc "Resolves the current lane from this process or its live task callers."
  @spec current() :: {:ok, term()} | :error
  def current do
    case Process.get(@key) do
      nil ->
        if @key in Process.get_keys(nil) do
          {:ok, nil}
        else
          from_callers(Process.get(:"$callers", []))
        end

      lane_id ->
        {:ok, lane_id}
    end
  end

  @doc "Resolves the current lane, raising with caller information when no tag exists."
  @spec current!() :: term()
  def current! do
    case current() do
      {:ok, lane_id} ->
        lane_id

      :error ->
        {module, function, arity} = caller()

        raise NoLaneContext,
          message:
            "no lane context in #{inspect(self())} for #{inspect(module)}.#{function}/#{arity}: " <>
              "call SymphonyElixir.LaneContext.put/1 in this process or start it from a lane's Task.Supervisor"
    end
  end

  defp from_callers([]), do: :error

  defp from_callers([pid | rest]) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, @key, 0) do
          {@key, lane_id} -> {:ok, lane_id}
          nil -> from_callers(rest)
        end

      nil ->
        from_callers(rest)
    end
  end

  defp caller do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

    stack
    |> Enum.drop_while(fn {module, _function, _arity, _location} ->
      module in [__MODULE__, Process, SymphonyElixir.Config, SymphonyElixir.LaneStore]
    end)
    |> List.first()
    |> case do
      {module, function, arity, _location} -> {module, function, arity}
      nil -> {:unknown, :unknown, 0}
    end
  end
end
