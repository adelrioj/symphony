defmodule SymphonyElixir.ExecutionEnvironment.Lifecycle do
  @moduledoc "Pure lifecycle transitions; only qualified provider evidence releases execution capacity."
  alias SymphonyElixir.ExecutionEnvironment.Record

  defmodule Entry do
    @moduledoc false
    @enforce_keys [:record, :attempt_id, :purpose]
    @derive {Inspect, only: [:record, :attempt_id, :operation_id, :purpose, :phase]}
    defstruct [:record, :context, :attempt_id, :operation_id, :purpose, :completion, :last_error, :issue, :backend_module, :agent_executable, :retry_attempt, :metadata_intent, :terminal_observation, :cleanup_retry_at, phase: :reserved, operation_seq: 0]
    @type t :: %__MODULE__{record: Record.t(), context: SymphonyElixir.ExecutionContext.t() | nil, attempt_id: String.t(), operation_id: {String.t(), non_neg_integer()} | nil, purpose: :agent | :cleanup, phase: atom(), completion: term(), last_error: term(), issue: term(), backend_module: module() | nil, agent_executable: String.t() | nil, retry_attempt: term(), metadata_intent: map() | nil, terminal_observation: integer() | nil, cleanup_retry_at: integer() | nil, operation_seq: non_neg_integer()}
  end

  @spec new(Record.t(), String.t(), :agent | :cleanup) :: Entry.t()
  def new(%Record{} = record, attempt_id, purpose) when purpose in [:agent, :cleanup] do
    %Entry{record: record, attempt_id: attempt_id, purpose: purpose}
  end

  @spec step(Entry.t(), term(), integer()) :: {Entry.t(), [term()]}
  def step(%Entry{phase: :reserved} = entry, :prepare, _now), do: operation(entry, :prepare, :preparing)

  def step(%Entry{} = entry, {:reconcile, operation}, _now) when operation in [:stop, :destroy, :inspect, :metadata, :cleanup_hook] do
    phase = case operation do
      :stop -> :stopping
      :destroy -> :deleting
      _ -> entry.phase
    end
    operation(entry, operation, phase)
  end

  def step(%Entry{operation_id: id} = entry, {:updated, id, %Record{} = record}, _now) when not is_nil(id) do
    {%{entry | record: record, operation_id: nil, last_error: nil}, []}
  end

  def step(%Entry{phase: :stopped} = entry, {:reserve, attempt_id, purpose}, _now) do
    {%{entry | attempt_id: attempt_id, purpose: purpose, phase: :reserved, completion: nil, context: nil, last_error: nil}, []}
  end

  def step(%Entry{phase: :preparing, operation_id: id} = entry, {:prepared, id, %Record{phase: :running} = record}, _now) when not is_nil(id) do
    {%{entry | record: record, operation_id: nil}, []}
  end

  def step(%Entry{phase: :preparing, operation_id: nil, operation_seq: seq, record: %Record{phase: :running}} = entry, :launch, _now) when seq > 0 do
    {%{entry | phase: :running}, [{:launch_agent, entry.attempt_id}]}
  end

  def step(%Entry{phase: :running, attempt_id: id} = entry, {:agent_exited, id, completion}, _now) do
    operation(%{entry | completion: completion}, :stop, :stopping)
  end

  def step(%Entry{phase: phase} = entry, {:cancel, completion}, _now) when phase in [:reserved, :preparing, :running] do
    operation(%{entry | completion: completion}, :stop, :stopping)
  end

  def step(%Entry{phase: :unknown, record: %Record{desired: :absent}} = entry, {:stopped, _id, _record}, _now), do: {entry, []}

  def step(%Entry{phase: phase, operation_id: id} = entry, {:stopped, id, %Record{} = record}, _now) when phase in [:stopping, :unknown] and not is_nil(id) do
    record = invalidate_start_proof(record)

    if quiescent?(record) and not unresolved?(record) do
      {%{entry | record: record, phase: :stopped, context: nil, operation_id: nil}, [{:release, entry.completion}]}
    else
      {%{entry | record: record, phase: :unknown}, []}
    end
  end

  def step(%Entry{operation_id: id} = entry, {:failed, id, failure, %Record{} = record}, _now) when not is_nil(id) do
    record = retain_delete_proof(entry, record) |> invalidate_start_proof()
    {%{entry | record: record, phase: :unknown, last_error: failure}, []}
  end

  def step(%Entry{phase: :stopped} = entry, :destroy, _now) do
    if quiescent?(entry.record) and not unresolved?(entry.record), do: operation(entry, :destroy, :deleting), else: {entry, []}
  end

  def step(%Entry{phase: phase, operation_id: id} = entry, {:destroyed, id, %Record{absent?: true} = record}, _now) when phase in [:deleting, :unknown] and not is_nil(id) do
    if not unresolved?(record) do
      {%{entry | record: record, phase: :absent, context: nil, operation_id: nil}, [:forget]}
    else
      {entry, []}
    end
  end

  def step(%Entry{} = entry, _event, _now), do: {entry, []}

  @spec occupied?(Entry.t()) :: boolean()
  def occupied?(%Entry{phase: :absent}), do: false

  def occupied?(%Entry{phase: phase, record: record}) when phase in [:stopped, :deleting] do
    not quiescent?(record) or unresolved_start?(record)
  end

  def occupied?(%Entry{phase: :unknown, record: %Record{desired: :absent} = record}) do
    not quiescent?(record) or unresolved_start?(record)
  end

  def occupied?(%Entry{}), do: true

  @spec deletion_due?(Record.t(), :terminal | :nonterminal | :missing | :error, non_neg_integer(), integer()) :: boolean()
  def deletion_due?(%Record{terminal_observed_at: timestamp}, :terminal, retention_ms, now) when is_integer(timestamp) and is_integer(retention_ms) and retention_ms >= 0 do
    now >= timestamp and now - timestamp >= retention_ms
  end

  def deletion_due?(%Record{}, _observation, _retention_ms, _now), do: false

  defp operation(entry, operation, phase) do
    seq = entry.operation_seq + 1
    id = {entry.attempt_id, seq}
    {%{entry | phase: phase, operation_seq: seq, operation_id: id}, [{:provider, operation, id}]}
  end

  defp quiescent?(%Record{proof: {:quiescent, evidence}}), do: is_map(evidence) and map_size(evidence) > 0
  defp quiescent?(_record), do: false
  defp unresolved?(record), do: Enum.any?(record.pending, &(&1.outcome in [:pending, :unknown]))
  defp unresolved_start?(record), do: Enum.any?(record.pending, &(&1.verb in [:create, :start] and &1.outcome in [:pending, :unknown]))
  defp invalidate_start_proof(record), do: if(unresolved_start?(record), do: %{record | proof: :unknown}, else: record)

  defp retain_delete_proof(%Entry{phase: phase, record: old}, record) when phase in [:deleting, :unknown] do
    if old.desired == :absent or phase == :deleting do
      %{record | proof: if(quiescent?(old), do: old.proof, else: record.proof), desired: :absent}
    else
      record
    end
  end

  defp retain_delete_proof(_entry, record), do: record
end
