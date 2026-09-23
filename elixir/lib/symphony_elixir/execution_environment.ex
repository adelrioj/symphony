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

  defmodule Credentials do
    @moduledoc "Credential lifecycle evidence. Cloud authority selects ownership; resource metadata records completed disposition."
    alias SymphonyElixir.CodexCredentials
    alias SymphonyElixir.CodexCredentials.Record, as: Authority
    alias SymphonyElixir.ExecutionEnvironment.Record

    @assignment_keys ~w(schema credential_id epoch claim_id owner secret_version)
    @stages ~w(claimed bound ready checkpointed committed recovery_required)
    @reasons ~w(cloud_authority worker_readiness checkpoint_failed disposition_unconfirmed identity_mismatch)

    @spec enabled?(map()) :: boolean()
    def enabled?(config), do: not is_nil(Map.get(config, :codex_credentials))

    @spec tracked?(Record.t()) :: boolean()
    def tracked?(record), do: Map.has_key?(record.metadata, "codex_credentials")

    @spec unallocated?(Record.t()) :: boolean()
    def unallocated?(record), do: is_nil(record.provider_ref) and record.pending == [] and not tracked?(record) and record.metadata["backing_resources"] in [nil, []]

    @spec data(Record.t()) :: map()
    def data(record) do
      case record.metadata["codex_credentials"] do
        value when is_map(value) -> value
        _ -> %{}
      end
    end

    @spec put(Record.t(), map()) :: Record.t()
    def put(record, attributes), do: %{record | metadata: Map.put(record.metadata, "codex_credentials", Map.merge(data(record), attributes))}

    @spec assignment(Record.t()) :: map() | nil
    def assignment(record), do: data(record)["assignment"]

    @spec resolved?(Record.t()) :: boolean()
    def resolved?(record) do
      not tracked?(record) or valid_disposition?(record, true)
    end

    @spec disposition(Record.t()) :: map() | nil
    def disposition(record), do: if(valid_disposition?(record, false), do: data(record)["disposition"], else: nil)

    @spec ready?(Record.t()) :: boolean()
    def ready?(record) do
      not tracked?(record) or
        (data(record)["stage"] == "ready" and data(record)["mode"] == "execute" and assignment_matches?(assignment(record), record))
    end

    @spec status(Record.t()) :: map() | nil
    def status(record) do
      if tracked?(record) do
        value = data(record)
        %{stage: if(value["stage"] in @stages, do: value["stage"], else: "recovery_required"), reason: if(value["reason"] in @reasons, do: value["reason"], else: nil)}
      end
    end

    @spec failure(Record.t(), String.t()) :: {:error, {:unknown, :credential_outcome_unknown}, Record.t()}
    def failure(record, reason) do
      {:error, {:unknown, :credential_outcome_unknown}, put(record, %{"stage" => "recovery_required", "reason" => reason})}
    end

    @spec reconcile(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
    def reconcile(config, record, opts) do
      if enabled?(config) do
        case CodexCredentials.read(config, opts) do
          {:ok, %{record: authority}} -> reconcile_authority(config, record, authority)
          {:error, _} -> failure(record, "cloud_authority")
        end
      else
        if tracked?(record), do: failure(record, "cloud_authority"), else: {:ok, record}
      end
    end

    @spec claim(map(), Record.t(), :agent | :cleanup, keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
    def claim(config, record, purpose, opts) do
      if enabled?(config) do
        with {:ok, %{record: authority}} <- CodexCredentials.read(config, opts) do
          cond do
            purpose == :cleanup ->
              reconcile_authority(config, record, authority)

            data(record)["mode"] == "recover" and authority["state"] != "AVAILABLE" ->
              failure(record, "identity_mismatch")

            authority["state"] == "OWNED" and owner_matches?(authority["owner"], record, false) and authority["owner"]["attempt_id"] == record.attempt_id ->
              {:ok, capture(record, authority)}

            authority["state"] == "AVAILABLE" and (not tracked?(record) or resolved?(record)) ->
              owner = %{"deployment_id" => record.deployment_id, "lane" => "features", "workstation_name" => resource_name(config, record), "workstation_uid" => nil, "attempt_id" => record.attempt_id}

              case CodexCredentials.claim(config, owner, opts) do
                {:ok, %{record: claimed}} -> {:ok, capture(record, claimed)}
                {:error, :credential_busy} -> {:error, {:retryable, :credential_busy}, record}
                {:error, _} -> failure(record, "cloud_authority")
              end

            true ->
              failure(record, "cloud_authority")
          end
        else
          {:error, _} -> failure(record, "cloud_authority")
        end
      else
        {:ok, record}
      end
    end

    @spec bind(map(), Record.t(), :agent | :cleanup, keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
    def bind(config, record, purpose, opts) do
      if enabled?(config) do
        mode = if purpose == :cleanup, do: "recover", else: "execute"
        assigned = assignment(record)
        uid = provider_uid(record)

        cond do
          not is_map(assigned) or not is_binary(uid) ->
            failure(record, "identity_mismatch")

          assigned["owner"]["workstation_uid"] == uid ->
            {:ok, put(record, %{"mode" => mode})}

          is_nil(assigned["owner"]["workstation_uid"]) ->
            case CodexCredentials.transition(config, assigned["claim_id"], {:bind_uid, assigned["claim_id"], uid}, opts) do
              {:ok, %{record: authority}} -> {:ok, capture(record, authority) |> put(%{"mode" => mode})}
              {:error, _} -> failure(record, "cloud_authority")
            end

          true ->
            failure(record, "identity_mismatch")
        end
      else
        {:ok, record}
      end
    end

    @spec authorize_start(map(), Record.t(), keyword()) :: :ok | {:error, atom()}
    def authorize_start(config, record, opts) do
      if enabled?(config) do
        with true <- assignment_matches?(assignment(record), record),
             {:ok, %{record: authority}} <- CodexCredentials.read(config, opts) do
          assigned = assignment(record)
          active = authority["state"] in ["OWNED", "CHECKPOINTED", "RECOVERY_REQUIRED"] and authority_assignment(authority) == assigned
          executable = data(record)["mode"] == "execute" and authority["state"] == "OWNED" and active
          recoverable = data(record)["mode"] == "recover" and (active or committed_current?(record, authority))
          if executable or recoverable, do: :ok, else: {:error, :credential_outcome_unknown}
        else
          _ -> {:error, :credential_outcome_unknown}
        end
      else
        if tracked?(record), do: {:error, :credential_outcome_unknown}, else: :ok
      end
    end

    @spec authorize_destroy(map(), Record.t(), keyword()) :: :ok | {:error, atom()}
    def authorize_destroy(config, record, opts) do
      if enabled?(config) or tracked?(record) do
        with true <- enabled?(config) and valid_disposition?(record, true),
             {:ok, %{record: authority}} <- CodexCredentials.read(config, opts),
             true <- committed_current?(record, authority) do
          :ok
        else
          _ -> {:error, :credential_outcome_unknown}
        end
      else
        :ok
      end
    end

    @spec acknowledge(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
    def acknowledge(config, record, opts) do
      disposition = data(record)["disposition"]

      if is_map(disposition) and disposition["resource_acknowledged"] == false do
        claim = disposition["claim_id"]

        case CodexCredentials.transition(config, claim, {:acknowledge_handoff, claim}, opts) do
          {:ok, %{record: authority}} -> reconcile_authority(config, record, authority)
          {:error, _} -> failure(record, "disposition_unconfirmed")
        end
      else
        {:ok, record}
      end
    end

    @spec checkpoint(map(), Record.t(), map(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
    def checkpoint(config, record, receipt, opts) do
      case CodexCredentials.transition(config, assignment(record)["claim_id"], {:checkpoint, receipt}, opts) do
        {:ok, %{record: authority}} -> {:ok, capture(record, authority)}
        {:error, _} -> failure(record, "checkpoint_failed")
      end
    end

    @spec release(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
    def release(config, record, opts) do
      assigned = assignment(record)

      with true <- assignment_matches?(assigned, record),
           {:quiescent, %{uid: uid, operation: operation}} <- record.proof,
           true <- uid == assigned["owner"]["workstation_uid"],
           proof = %{"uid" => uid, "operation" => operation, "attempt_id" => assigned["owner"]["attempt_id"]},
           {:ok, _} <- CodexCredentials.transition(config, assigned["claim_id"], {:stopped, assigned["claim_id"], proof}, opts),
           {:ok, %{record: authority}} <- CodexCredentials.transition(config, assigned["claim_id"], {:release, assigned["claim_id"]}, opts) do
        reconcile_authority(config, record, authority)
      else
        _ -> failure(record, "cloud_authority")
      end
    end

    @spec quarantine(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
    def quarantine(config, record, opts) do
      case assignment(record) do
        %{"claim_id" => claim} -> CodexCredentials.transition(config, claim, {:quarantine, claim, "checkpoint_failed"}, opts)
        _ -> :unassigned
      end

      failure(record, "checkpoint_failed")
    end

    @spec resource_name(map(), Record.t()) :: String.t()
    def resource_name(config, record) do
      case record.provider_ref do
        %{name: name} ->
          name

        _ ->
          (record.metadata["config_name"] ||
             "projects/#{config.provider["project"]}/locations/#{config.provider["location"]}/workstationClusters/#{config.provider["cluster"]}/workstationConfigs/#{config.provider["config"]}") <>
            "/workstations/" <> record.key
      end
    end

    @spec merge_metadata(map(), map()) :: map()
    def merge_metadata(durable, local) do
      merged = Map.merge(durable, local)
      if Map.has_key?(durable, "codex_credentials"), do: Map.put(merged, "codex_credentials", durable["codex_credentials"]), else: merged
    end

    defp reconcile_authority(config, record, authority) do
      handoff = authority["last_handoff"]

      cond do
        authority["state"] != "AVAILABLE" and recoverable_owner?(authority, record) ->
          {:ok, capture(record, authority)}

        is_map(handoff) and owner_matches?(handoff["owner"], record, true) ->
          reconcile_handoff(record, authority, handoff)
        historical_disposition?(record, authority) ->
          disposition = Map.put(data(record)["disposition"], "resource_acknowledged", true)
          {:ok, put(record, %{"stage" => "committed", "disposition" => disposition, "reason" => nil})}

        not tracked?(record) and is_nil(record.provider_ref) and authority["state"] == "AVAILABLE" ->
          {:ok, record}

        unallocated?(record) and is_map(authority["owner"]) and authority["owner"]["workstation_name"] != resource_name(config, record) ->
          {:error, {:retryable, :credential_busy}, record}

        true ->
          failure(record, if(authority["credential_id"] == config.codex_credentials["credential_id"], do: "cloud_authority", else: "identity_mismatch"))
      end
    end

    defp reconcile_handoff(record, authority, handoff) do
      assigned = assignment(record)
      matching = valid_assignment?(assigned) and assigned["claim_id"] == handoff["claim_id"] and assigned["owner"] == handoff["owner"] and
        assigned["credential_id"] == authority["credential_id"]
      same_epoch = matching and assigned["epoch"] == authority["epoch"]
      reseeded = matching and assigned["epoch"] + 1 == authority["epoch"] and stopped_handoff?(record, handoff)

      cond do
        same_epoch or reseeded ->
          disposition = Map.merge(Map.take(assigned, ~w(schema credential_id epoch)), handoff)
          disposition = if reseeded, do: Map.put(disposition, "resolved_epoch", authority["epoch"]), else: disposition
          {:ok, put(record, %{"assignment" => assigned, "disposition" => disposition, "stage" => "committed", "reason" => nil})}
        true ->
          failure(record, "disposition_unconfirmed")
      end
    end

    defp stopped_handoff?(%Record{phase: :stopped, proof: {:quiescent, %{uid: uid, operation: operation}}} = record, handoff) do
      proof = %{"uid" => uid, "operation" => operation, "attempt_id" => handoff["owner"]["attempt_id"]}
      handoff["stop_proof"] == proof and not Enum.any?(record.pending, &(&1.outcome in [:pending, :unknown]))
    end
    defp stopped_handoff?(_, _), do: false

    defp recoverable_owner?(authority, record) do
      owner = authority["owner"]

      owner_matches?(owner, record, true) or
        (is_map(owner) and is_nil(owner["workstation_uid"]) and owner_matches?(owner, record, false) and
           assignment(record) == authority_assignment(authority))
    end

    defp historical_disposition?(record, authority) do
      disposition = data(record)["disposition"]
      handoff = authority["last_handoff"]
      valid_disposition?(record, false) and consistent_epoch?(disposition, authority) and disposition["credential_id"] == authority["credential_id"] and
        ((is_map(handoff) and handoff["claim_id"] != disposition["claim_id"]) or
          (disposition["resource_acknowledged"] == true and (disposition["resolved_epoch"] || disposition["epoch"]) < authority["epoch"])) and
        (not is_map(authority["owner"]) or authority["owner"]["workstation_name"] != disposition["owner"]["workstation_name"])
    end

    defp consistent_epoch?(disposition, authority) do
      resolved = disposition["resolved_epoch"] || disposition["epoch"]
      resolved == authority["epoch"] or (disposition["resource_acknowledged"] == true and resolved < authority["epoch"])
    end

    defp capture(record, authority) do
      stage =
        case authority["state"] do
          "CHECKPOINTED" -> "checkpointed"
          "RECOVERY_REQUIRED" -> "recovery_required"
          _ -> if(is_nil(authority["owner"]["workstation_uid"]), do: "claimed", else: "bound")
        end

      put(record, %{"assignment" => authority_assignment(authority), "stage" => stage, "reason" => if(stage == "recovery_required", do: "checkpoint_failed", else: nil), "disposition" => nil})
    end

    defp authority_assignment(authority), do: Map.take(authority, ~w(schema credential_id epoch claim_id owner)) |> Map.put("secret_version", authority["head_version"])
    defp provider_uid(%{provider_ref: %{uid: uid}}), do: uid
    defp provider_uid(_record), do: nil
    defp provider_name(%{provider_ref: %{name: name}}), do: name
    defp provider_name(record), do: get_in(data(record), ["assignment", "owner", "workstation_name"])

    defp owner_matches?(owner, record, require_uid) when is_map(owner) do
      owner["deployment_id"] == record.deployment_id and owner["lane"] == "features" and
        owner["workstation_name"] == provider_name(record) and
        (not require_uid or owner["workstation_uid"] == provider_uid(record))
    end

    defp owner_matches?(_, _, _), do: false

    defp assignment_matches?(assigned, record), do: valid_assignment?(assigned) and owner_matches?(assigned["owner"], record, true)

    defp valid_assignment?(assigned) when is_map(assigned) do
      MapSet.new(Map.keys(assigned)) == MapSet.new(@assignment_keys) and
        Authority.validate(%{
          "schema" => assigned["schema"],
          "credential_id" => assigned["credential_id"],
          "epoch" => assigned["epoch"],
          "state" => "OWNED",
          "head_version" => assigned["secret_version"],
          "claim_id" => assigned["claim_id"],
          "owner" => assigned["owner"],
          "candidate" => nil,
          "stop_proof" => nil,
          "last_handoff" => nil,
          "reason" => nil,
          "transition_id" => "validated-resource-evidence"
        }) == :ok and
        is_binary(assigned["owner"]["workstation_uid"])
    end

    defp valid_assignment?(_assigned), do: false

    defp valid_disposition?(record, acknowledged) do
      assigned = assignment(record)
      disposition = data(record)["disposition"]
      handoff_keys = ~w(claim_id secret_version owner stop_proof resource_acknowledged)
      fields = ~w(schema credential_id epoch) ++ handoff_keys
      resolved_epoch = if is_map(disposition), do: disposition["resolved_epoch"], else: nil
      fields = if is_nil(resolved_epoch), do: fields, else: ["resolved_epoch" | fields]
      is_map(disposition) and assignment_matches?(assigned, record) and data(record)["stage"] == "committed" and
        MapSet.new(Map.keys(disposition)) == MapSet.new(fields) and
        (is_nil(resolved_epoch) or (is_integer(resolved_epoch) and resolved_epoch == assigned["epoch"] + 1)) and
        Map.take(disposition, ~w(schema credential_id epoch claim_id owner)) == Map.take(assigned, ~w(schema credential_id epoch claim_id owner)) and
        (not acknowledged or disposition["resource_acknowledged"] == true) and
        Authority.validate(%{
          "schema" => disposition["schema"],
          "credential_id" => disposition["credential_id"],
          "epoch" => disposition["epoch"],
          "state" => "AVAILABLE",
          "head_version" => disposition["secret_version"],
          "claim_id" => nil,
          "owner" => nil,
          "candidate" => nil,
          "stop_proof" => nil,
          "last_handoff" => Map.take(disposition, handoff_keys),
          "reason" => nil,
          "transition_id" => "validated-resource-evidence"
        }) == :ok
    end

    defp committed_current?(record, authority) do
      disposition = data(record)["disposition"]
      valid_disposition?(record, true) and consistent_epoch?(disposition, authority) and disposition["credential_id"] == authority["credential_id"] and
        (not is_map(authority["owner"]) or authority["owner"]["workstation_name"] != disposition["owner"]["workstation_name"]) and
        (not is_map(authority["last_handoff"]) or authority["last_handoff"]["claim_id"] != disposition["claim_id"] or authority["last_handoff"]["resource_acknowledged"] == true)
    end
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
    # Workstations limits the complete ID, including the prefix, to 56 characters.
    "se-" <> binary_part(digest, 0, 53)
  end

  @spec adapter(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter("google_workstations"), do: {:ok, __MODULE__.Workstations}
  def adapter("kubernetes"), do: {:ok, __MODULE__.Kubernetes}
  def adapter(_kind), do: {:error, {:invalid, :unknown_environment_kind}}
end
