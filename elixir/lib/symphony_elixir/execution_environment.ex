defmodule SymphonyElixir.ExecutionEnvironment do
  @moduledoc """
  Provider boundary for per-ticket managed execution environments.

  Callbacks receive captured runtime configuration; only `validate_config/1` receives
  the provider submap. Transport teardown is never evidence that execution stopped.
  """

  defmodule Record do
    @moduledoc """
    Durable identity and lifecycle observations for one managed environment.

    Pending operations retain their `verb`, correlation `id` (when known), and
    `outcome` (`:pending`, `:unknown`, `:succeeded`, or `:failed`). A missing resource
    cannot clear an unresolved create.
    Only adapters establish quiescence proof; agent-writable metadata is not evidence.
    `{:compute_unknown, evidence}` identifies unresolved physical obligations and
    invalidates any earlier quiescence proof. Bare `:unknown` may instead describe
    cleanup-only uncertainty without contradicting previously established physical stop.
    `absent?` is true only after both owned compute and disk absence are established.
    """

    @enforce_keys [:key, :deployment_id, :tracker_kind, :issue_id, :kind, :scope, :workspace_path, :template_identity]
    @derive {Inspect, only: [:key, :kind, :phase, :desired, :absent?]}
    defstruct @enforce_keys ++
                [
                  :provider_ref,
                  :version,
                  :attempt_id,
                  :issue_identifier,
                  :issue_state,
                  :terminal_observed_at,
                  phase: :unknown,
                  desired: :stopped,
                  pending: [],
                  proof: :unknown,
                  absent?: false,
                  metadata: %{}
                ]

    @type pending_operation :: %{
            required(:verb) => atom(),
            required(:id) => String.t() | nil,
            required(:outcome) => :pending | :unknown | :succeeded | :failed,
            optional(atom()) => term()
          }
    @type t :: %__MODULE__{
            key: String.t(),
            deployment_id: String.t(),
            tracker_kind: String.t(),
            issue_id: String.t(),
            kind: String.t(),
            scope: map(),
            workspace_path: String.t(),
            template_identity: term(),
            provider_ref: term() | nil,
            version: term() | nil,
            attempt_id: String.t() | nil,
            issue_identifier: String.t() | nil,
            issue_state: String.t() | nil,
            terminal_observed_at: term() | nil,
            phase: SymphonyElixir.ExecutionEnvironment.phase(),
            desired: :running | :stopped | :absent,
            pending: [pending_operation()],
            proof: :unknown | {:quiescent, term()} | {:compute_unknown, map()} | {:operator_declared_lost, map()},
            absent?: boolean(),
            metadata: map()
          }
  end

  defmodule Connection do
    @moduledoc """
    Runtime-only transport lease. Never serialize this into provider metadata.

    Before managed execution, the holder must acknowledge the exact lease ID and
    target with `:ok` in response to
    `GenServer.call(owner, {:validate_connection, id, target}, 1_000)`.
    This establishes ready lease consistency, not an authorization boundary between
    trusted BEAM callers or proof that remote execution has stopped.
    """
    @enforce_keys [:target, :owner, :id]
    @derive {Inspect, only: [:owner, :id]}
    defstruct @enforce_keys

    @type t :: %__MODULE__{target: SymphonyElixir.SSH.Target.t(), owner: pid(), id: reference()}
  end

  @type phase :: :preparing | :running | :stopping | :stopped | :deleting | :unknown
  @type failure :: {:invalid, atom()} | {:denied, atom()} | {:retryable, term()} | {:unknown, term()}
  @type result :: {:ok, Record.t()} | {:error, failure(), Record.t()}

  @callback validate_config(map()) :: :ok | {:error, term()}
  @callback preflight(map(), keyword()) :: :ok | {:error, failure()}
  @callback discover(map(), keyword()) :: {:ok, [Record.t()]} | {:error, failure()}
  @callback ensure(map(), Record.t(), keyword()) :: result()
  @callback inspect(map(), Record.t(), keyword()) :: result()
  @callback put_intent(map(), Record.t(), map(), keyword()) :: result()
  @callback start(map(), Record.t(), keyword()) :: result()
  @callback connect(map(), Record.t(), keyword()) :: {:ok, Connection.t()} | {:error, failure()}
  @callback stop(map(), Record.t(), keyword()) :: result()
  @callback destroy(map(), Record.t(), keyword()) :: result()

  # Optional: only a provider whose hosts can be physically lost, and whose obligations are
  # bound to a machine, has anything to declare. Callable while allocation preflight fails.
  @callback declare_lost(map(), term(), keyword()) :: {:ok, [Record.t()]} | {:error, failure()}
  @optional_callbacks declare_lost: 3

  @spec resource_key(String.t(), String.t(), String.t()) :: String.t()
  def resource_key(deployment_id, tracker_kind, issue_id) do
    encoded = :erlang.term_to_binary({deployment_id, tracker_kind, issue_id})
    digest = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
    "se-" <> binary_part(digest, 0, 56)
  end

  @spec adapter(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter("google_workstations"), do: {:ok, __MODULE__.Workstations}
  def adapter("kubernetes"), do: {:ok, __MODULE__.Kubernetes}
  def adapter(_kind), do: {:error, {:invalid, :unknown_environment_kind}}
end
