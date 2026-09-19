defmodule SymphonyElixir.ExecutionEnvironment.Kubernetes.LossAlarm do
  @moduledoc """
  Durable record of a contradiction to a host-loss declaration.

  Finalization is irreversible, so a declared-lost host that is observed again cannot be
  undone — by then its identities may already have been reused. All that is left is to say so,
  permanently and exactly once. These records are never pruned; run retention does not touch
  this table.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.Repo

  @type t :: %__MODULE__{}

  schema "host_loss_alarms" do
    field(:kind, :string)
    field(:dedup_key, :string)
    field(:declaration, :string)
    field(:node_uid, :string)
    field(:machine_id, :string)
    field(:observed_at, :utc_datetime_usec)
    field(:detail, :map, default: %{})
  end

  @doc """
  Records an alarm, or reports that this exact contradiction is already on record.

  The reconciler re-reads every predicate on every pass, so without the deduplication key the
  first observation would be buried under one copy per tick. The stored record keeps the
  earliest observation rather than the latest.
  """
  @spec raise(map()) :: {:ok, :raised | :duplicate}
  def raise(attrs) when is_map(attrs) do
    record = %__MODULE__{
      kind: attrs[:kind],
      dedup_key: attrs[:dedup_key],
      declaration: attrs[:declaration],
      node_uid: attrs[:node_uid],
      machine_id: attrs[:machine_id],
      observed_at: attrs[:observed_at] || DateTime.utc_now(),
      detail: attrs[:detail] || %{}
    }

    # A plain struct insert has no validations to fail; a database error raises, which is the
    # right outcome for a sink whose whole job is not to lose a record quietly.
    case Repo.insert(record, on_conflict: :nothing, conflict_target: :dedup_key) do
      {:ok, %__MODULE__{id: nil}} -> {:ok, :duplicate}
      {:ok, _} -> {:ok, :raised}
    end
  end

  @spec all() :: [t()]
  def all, do: Repo.all(from(a in __MODULE__, order_by: [asc: a.id]))
end
