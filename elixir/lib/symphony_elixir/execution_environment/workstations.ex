defmodule SymphonyElixir.ExecutionEnvironment.Workstations do
  @moduledoc "Google Cloud Workstations lifecycle. Unknown requests and billable leftovers fail closed."
  @behaviour SymphonyElixir.ExecutionEnvironment

  alias SymphonyElixir.ExecutionEnvironment
  alias SymphonyElixir.ExecutionEnvironment.{Command, Config, Operations, Record}
  alias SymphonyElixir.ExecutionEnvironment.Workstations.Client
  alias SymphonyElixir.SSH.Target

  @required ~w(project location cluster config credential_configuration impersonate_service_account ssh_user)
  @annotation "symphony.dev/record"
  @verbs [:create, :start, :stop, :delete, :update]
  @outcomes [:pending, :unknown, :succeeded, :failed]
  @runtime_fields ~w(host container persistentDirectories idleTimeout idleAction runningTimeout allowedPorts disableTcpConnections encryptionKey replicaZones)

  @impl true
  @spec validate_config(term()) :: :ok | {:error, term()}
  def validate_config(provider) do
    if is_map(provider) and Enum.all?(@required, &(is_binary(provider[&1]) and String.trim(provider[&1]) != "")), do: :ok, else: {:error, {:invalid, :workstations_config}}
  end

  @impl true
  @spec preflight(map(), keyword()) :: :ok | {:error, term()}
  def preflight(config, opts) do
    opts = Client.options(config, opts)

    with :ok <- validate_config(config.provider),
         {:ok, template} <- get(config, parent(config), opts),
         :ok <- compatible(template),
         {:ok, _} <- discover(config, opts) do
      :ok
    end
  end

  @impl true
  @spec discover(map(), keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  def discover(config, opts) do
    opts = Client.options(config, opts)

    with {:ok, templates} <- pages(config, cluster(config) <> "/workstationConfigs", "workstationConfigs", opts),
         {:ok, operations} <- operation_inventory(config, opts),
         {:ok, workstations} <- list_templates(config, templates, opts),
         {:ok, records} <- decode_owned(config, workstations, operations),
         {:ok, backing} <- backing_inventory(config, opts) do
      keys = MapSet.new(records, & &1.key)
      owned_backing = Enum.filter(backing, &(get_in(&1, ["labels", "symphony-deployment"]) == deployment_hash(config.deployment_id)))
      orphans = Enum.reject(owned_backing, &MapSet.member?(keys, get_in(&1, ["labels", "symphony-ticket"])))
      if orphans == [], do: {:ok, Enum.map(records, &capture_backing(&1, backing))}, else: {:error, {:unknown, {:orphan_backing_resources, safe_ids(orphans)}}}
    end
  end

  @impl true
  @spec ensure(map(), Record.t(), keyword()) :: ExecutionEnvironment.result()
  def ensure(config, record, opts) do
    opts = Client.options(config, opts)

    with :ok <- identity(config, record),
         {:ok, workstation} <- get(config, resource_name(config, record), opts) do
      ensure_existing(config, record, workstation, opts)
    else
      {:error, :not_found} -> ensure_missing(config, record, opts)
      {:error, failure} -> fail(record, failure)
    end
  end

  @impl true
  @spec inspect(map(), Record.t(), keyword()) :: ExecutionEnvironment.result()
  def inspect(config, record, opts) do
    opts = Client.options(config, opts)

    with :ok <- identity(config, record),
         {:ok, workstation} <- get(config, resource_name(config, record), opts),
         {:ok, owned} <- observe_owned(config, record, workstation),
         {:ok, operations} <- operation_inventory(config, opts) do
      {:ok, normalize(owned, workstation, operations)}
    else
      {:error, :not_found} -> inspect_absence(config, record, opts)
      {:error, failure} -> fail(record, failure)
    end
  end

  @impl true
  @spec put_intent(map(), Record.t(), map(), keyword()) :: ExecutionEnvironment.result()
  def put_intent(config, record, intent, opts) do
    opts = Client.options(config, opts)

    updated =
      Enum.reduce([:desired, :attempt_id, :terminal_observed_at, :issue_state, :issue_identifier], record, fn field, acc ->
        if Map.has_key?(intent, field), do: Map.put(acc, field, intent[field]), else: acc
      end)

    if updated.desired in [:running, :stopped, :absent] do
      with :ok <- identity(config, updated),
           {:ok, settled} <- settle(config, updated, opts) do
        persist(config, settled, opts)
      else
        {:error, _, _} = error -> error
        {:error, failure} -> fail(record, failure)
      end
    else
      fail(record, {:invalid, :workstations_intent})
    end
  end

  @impl true
  @spec start(map(), Record.t(), keyword()) :: ExecutionEnvironment.result()
  def start(config, record, opts) do
    opts = Client.options(config, opts)

    with {:ok, observed} <- ensure(config, record, opts),
         {:ok, settled} <- settle(config, observed, opts) do
      cond do
        settled.phase == :running -> qualify_running(config, settled, opts)
        settled.desired != :running -> fail(settled, {:invalid, :workstations_intent})
        true -> mutate(config, settled, :start, opts)
      end
    end
  end

  @impl true
  @spec stop(map(), Record.t(), keyword()) :: ExecutionEnvironment.result()
  def stop(config, record, opts) do
    opts = Client.options(config, opts)

    with {:ok, observed} <- inspect(config, record, opts),
         {:ok, settled} <- settle(config, observed, opts) do
      if match?({:quiescent, _}, settled.proof) do
        {:ok, settled}
      else
        mutate(config, %{settled | desired: :stopped}, :stop, opts)
      end
    end
  end

  @impl true
  @spec destroy(map(), Record.t(), keyword()) :: ExecutionEnvironment.result()
  def destroy(config, record, opts) do
    opts = Client.options(config, opts)

    with :ok <- identity(config, record),
         {:ok, workstation} <- get(config, resource_name(config, record), opts),
         {:ok, owned} <- observe_owned(config, record, workstation) do
      destroy_owned(config, owned, opts)
    else
      {:error, :not_found} -> inspect_absence(config, record, opts)
      {:error, failure} -> fail(record, failure)
    end
  end

  @impl true
  @spec connect(map(), Record.t(), keyword()) :: {:ok, ExecutionEnvironment.Connection.t()} | {:error, term()}
  def connect(config, record, opts) do
    opts = Client.options(config, opts)

    with {:ok, observed} <- inspect(config, record, opts),
         true <- observed.phase == :running,
         supervisor when not is_nil(supervisor) <- opts[:task_supervisor],
         authority when is_pid(authority) <- opts[:authority] do
      connect_tunnel(config, observed, supervisor, authority, opts)
    else
      {:error, failure, _} -> {:error, failure}
      _ -> {:error, {:unknown, :workstations_connection_not_ready}}
    end
  end

  @doc "Normalizes provider observations without erasing uncorrelated mutation evidence."
  @spec normalize(Record.t(), map(), [map()]) :: Record.t()
  def normalize(record, workstation, operations) do
    pending = observed_pending(record.pending, operations, ref_name(record))
    settled = same_workstation?(record, workstation) and not unresolved?(record.scope, pending)
    reconciling = Map.get(workstation, "reconciling", false)
    stop = successful_stop(record.scope, pending)
    phase = observed_phase(settled and reconciling == false, workstation["state"], stop)
    proof = if phase == :stopped, do: {:quiescent, %{uid: workstation["uid"], operation: stop.id}}, else: :unknown
    %{record | pending: pending, version: workstation["etag"], phase: phase, proof: proof, absent?: false}
  end

  defp ensure_existing(config, record, workstation, opts) do
    with {:ok, owned} <- observe_owned(config, record, workstation),
         {:ok, template} <- get(config, config_name(config, owned), opts),
         :ok <- retained_config(owned, template),
         {:ok, operations} <- operation_inventory(config, opts) do
      {:ok, normalize(owned, workstation, operations)}
    else
      {:error, failure} -> fail(record, failure)
    end
  end

  defp ensure_missing(config, record, opts) do
    cond do
      record.pending == [] and is_nil(record.provider_ref) ->
        create(config, record, opts)

      never_created?(record) ->
        with {:ok, absent} <- inspect_absence(config, record, opts), do: create(config, absent, opts)

      true ->
        fail(record, {:unknown, :unresolved_create})
    end
  end

  defp destroy_owned(config, record, opts) do
    with {:ok, stopped} <- stop(config, record, opts),
         {:ok, backing} <- backing_inventory(config, opts) do
      if stopped.metadata["disk_reclaim_policy"] == "DELETE" and stopped.metadata["disk_archive_timeout"] == "0s" do
        mutate(config, capture_backing(%{stopped | desired: :absent}, backing), :delete, opts)
      else
        fail(stopped, {:unknown, :uncaptured_disk_policy})
      end
    else
      {:error, _, _} = error -> error
      {:error, failure} -> fail(record, failure)
    end
  end

  defp same_workstation?(record, workstation),
    do: nonblank?(workstation["uid"]) and ref_uid(record) == workstation["uid"]

  defp unresolved?(scope, pending),
    do: Enum.any?(pending, &(&1.outcome in [:pending, :unknown] or not valid_pending_evidence?(scope, &1)))

  defp successful_stop(scope, pending) do
    case Enum.find(Enum.reverse(pending), &(&1.verb in [:create, :start, :stop, :delete])) do
      %{verb: :stop, outcome: :succeeded, id: id} = entry ->
        if operation_name_in_scope?(scope, id), do: entry

      _ ->
        nil
    end
  end

  defp observed_phase(false, _state, _stop), do: :unknown
  defp observed_phase(true, "STATE_RUNNING", _stop), do: :running
  defp observed_phase(true, "STATE_STOPPED", stop) when not is_nil(stop), do: :stopped
  defp observed_phase(true, "STATE_STARTING", _stop), do: :preparing
  defp observed_phase(true, "STATE_STOPPING", _stop), do: :stopping
  defp observed_phase(true, _state, _stop), do: :unknown

  defp create(config, record, opts) do
    with {:ok, template} <- get(config, parent(config), opts),
         :ok <- compatible(template) do
      captured = %{
        record
        | template_identity: template["uid"],
          metadata: Map.merge(record.metadata, %{"config_name" => parent(config), "config_fingerprint" => fingerprint(template), "disk_reclaim_policy" => "DELETE", "disk_archive_timeout" => "0s"})
      }

      pending = marker(:create, opts)
      journal = captured.pending ++ [pending]
      creating = %{captured | pending: journal, phase: :preparing, proof: :unknown, absent?: false}
      body = Map.merge(metadata(creating), %{"name" => resource_name(config, creating)})

      case api(config, :post, parent(config) <> "/workstations", [workstationId: record.key], body, opts) do
        {:ok, operation} ->
          finish_mutation(config, creating, :create, operation, opts)

        {:error, {:retryable, {:conflict, _}}} ->
          rejected = replace_last(creating, :create, %{outcome: :failed})
          adopt_conflict(config, rejected, opts)

        {:error, {:denied, _} = failure} ->
          fail(replace_last(creating, :create, %{outcome: :failed}), failure)

        {:error, failure} ->
          fail(creating, failure)
      end
    else
      {:error, failure} -> fail(record, failure)
    end
  end

  defp adopt_conflict(config, record, opts) do
    case get(config, resource_name(config, record), opts) do
      {:ok, workstation} -> ensure_existing(config, record, workstation, opts)
      {:error, failure} -> fail(record, failure)
    end
  end

  defp mutate(config, record, verb, opts) do
    pending = marker(verb, opts)
    phase = if verb == :delete, do: :deleting, else: :unknown
    candidate = %{record | pending: record.pending ++ [pending], proof: :unknown, phase: phase}

    with {:ok, durable} <- persist(config, candidate, opts),
         {:ok, workstation} <- get(config, resource_name(config, durable), opts),
         {:ok, fresh} <- observe_owned(config, durable, workstation) do
      {method, suffix, query, body} =
        if verb == :delete,
          do: {:delete, "", [etag: fresh.version], nil},
          else: {:post, ":" <> Atom.to_string(verb), [], %{"etag" => fresh.version}}

      case api(config, method, resource_name(config, fresh) <> suffix, query, body, opts) do
        {:ok, operation} -> finish_mutation(config, fresh, verb, operation, opts)
        {:error, failure} -> mutation_failure(config, fresh, verb, failure, opts)
      end
    else
      {:error, _, _} = error -> error
      {:error, failure} -> fail(candidate, failure)
    end
  end

  defp finish_mutation(config, record, verb, operation, opts) do
    if valid_operation?(config, operation, resource_name(config, record), verb) do
      known = replace_last(record, verb, %{id: operation["name"], outcome: :pending})
      await_mutation(config, known, verb, operation, opts)
    else
      fail(record, {:unknown, :invalid_operation_evidence})
    end
  end

  defp await_mutation(config, record, verb, operation, opts) do
    case await_operation(config, operation, opts) do
      {:ok, terminal} ->
        resolved = replace_last(record, verb, operation_result(terminal))
        finish_terminal(config, resolved, verb, terminal, opts)

      {:error, failure} ->
        fail(record, failure)
    end
  end

  defp finish_terminal(_config, record, verb, %{"error" => error}, _opts),
    do: fail(record, {:unknown, {:operation_failed, verb, error["code"]}})

  defp finish_terminal(config, record, :delete, _terminal, opts) do
    case get(config, resource_name(config, record), opts) do
      {:error, :not_found} -> inspect_absence(config, record, opts)
      {:error, failure} -> fail(record, failure)
      {:ok, _} -> fail(record, {:unknown, :delete_not_absent})
    end
  end

  defp finish_terminal(config, record, verb, _terminal, opts) do
    with {:ok, durable} <- persist(config, record, opts),
         {:ok, observed} <- inspect(config, durable, opts) do
      confirm_mutation(config, observed, verb, opts)
    end
  end

  defp confirm_mutation(config, observed, verb, opts) do
    cond do
      verb == :stop and not match?({:quiescent, _}, observed.proof) ->
        fail(observed, {:unknown, :stop_not_confirmed})

      verb == :start and observed.phase != :running ->
        fail(observed, {:unknown, :start_not_confirmed})

      verb == :start ->
        qualify_running(config, observed, opts)

      true ->
        {:ok, observed}
    end
  end

  defp persist(config, record, opts) do
    with :ok <- identity(config, record),
         {:ok, workstation} <- get(config, resource_name(config, record), opts),
         {:ok, owned} <- observe_owned(config, record, workstation) do
      patch_metadata(config, record, owned, workstation, opts)
    else
      {:error, :not_found} -> inspect_absence(config, record, opts)
      {:error, failure} -> fail(record, failure)
    end
  end

  defp patch_metadata(config, record, owned, workstation, opts) do
    candidate = %{record | provider_ref: owned.provider_ref, pending: owned.pending ++ [marker(:update, opts)]}
    expected = metadata(candidate)
    annotation = expected["annotations"][@annotation]
    candidate = replace_last(candidate, :update, %{annotation_hash: annotation_hash(annotation)})

    body = %{
      "name" => resource_name(config, owned),
      "etag" => owned.version,
      "annotations" => Map.merge(Map.get(workstation, "annotations", %{}), expected["annotations"]),
      "labels" => Map.merge(Map.get(workstation, "labels", %{}), expected["labels"])
    }

    case api(config, :patch, resource_name(config, owned), [updateMask: "annotations,labels"], body, opts) do
      {:ok, operation} -> finish_metadata(config, candidate, operation, annotation, opts)
      {:error, failure} -> mutation_failure(config, candidate, :update, failure, opts)
    end
  end

  defp finish_metadata(config, record, operation, annotation, opts) do
    if valid_operation?(config, operation, resource_name(config, record), :update) do
      known = replace_last(record, :update, %{id: operation["name"], outcome: :pending})
      verify_metadata(config, known, operation, annotation, opts)
    else
      fail(record, {:unknown, :invalid_operation_evidence})
    end
  end

  defp verify_metadata(config, record, operation, annotation, opts) do
    with {:ok, terminal} <- await_operation(config, operation, opts),
         false <- Map.has_key?(terminal, "error"),
         {:ok, readback} <- get(config, resource_name(config, record), opts),
         true <- get_in(readback, ["annotations", @annotation]) == annotation,
         {:ok, verified} <- observe_owned(config, record, readback) do
      {:ok, verified}
    else
      {:error, failure} -> fail(record, failure)
      _ -> fail(record, {:unknown, :metadata_not_durable})
    end
  end

  defp settle(config, record, opts) do
    with {:ok, refreshed} <- refresh_metadata(config, record, opts),
         {:ok, operations} <- operation_inventory(config, opts) do
      pending = observed_pending(refreshed.pending, operations, resource_name(config, refreshed))
      current = %{refreshed | pending: pending}
      Enum.reduce_while(pending, {:ok, current}, &settle_entry(config, &1, &2, opts))
    else
      {:error, failure} -> fail(record, failure)
    end
  end

  defp settle_entry(config, entry, {:ok, current}, opts) do
    cond do
      not valid_pending_evidence?(current.scope, entry) ->
        {:halt, fail(current, {:invalid, :workstations_operation_evidence})}

      entry.outcome in [:succeeded, :failed] ->
        {:cont, {:ok, current}}

      unconfirmed_metadata?(entry) ->
        {:halt, fail(current, {:unknown, :metadata_not_durable})}

      is_nil(entry.id) ->
        {:halt, fail(current, {:unknown, :uncorrelated_mutation})}

      true ->
        settle_operation(config, current, entry, opts)
    end
  end

  defp settle_operation(config, record, entry, opts) do
    with true <- operation_name?(config, entry.id),
         {:ok, operation} <- get(config, entry.id, opts),
         true <- valid_operation?(config, operation, resource_name(config, record), entry.verb),
         {:ok, terminal} <- await_operation(config, operation, opts) do
      pending = Enum.map(record.pending, &resolve_entry(&1, entry, terminal))
      {:cont, {:ok, %{record | pending: pending}}}
    else
      {:error, failure} -> {:halt, fail(record, failure)}
      _ -> {:halt, fail(record, {:unknown, :invalid_operation_evidence})}
    end
  end

  defp resolve_entry(entry, entry, terminal), do: Map.merge(entry, operation_result(terminal))
  defp resolve_entry(other, _entry, _terminal), do: other

  defp refresh_metadata(config, record, opts) do
    if Enum.any?(record.pending, &unconfirmed_metadata?/1) do
      with {:ok, workstation} <- get(config, resource_name(config, record), opts) do
        observe_owned(config, record, workstation)
      end
    else
      {:ok, record}
    end
  end

  defp unconfirmed_metadata?(entry),
    do: entry.outcome in [:pending, :unknown] and Map.has_key?(entry, :annotation_hash)

  defp await_operation(config, operation, opts) do
    cond do
      operation["done"] == true ->
        {:ok, operation}

      Client.remaining(opts) <= 0 ->
        {:error, {:unknown, :operation_deadline}}

      true ->
        Process.sleep(min(Keyword.get(opts, :poll_interval_ms, 250), Client.remaining(opts)))

        with {:ok, next} <- get(config, operation["name"], opts),
             true <- same_operation?(next, operation) do
          await_operation(config, next, opts)
        else
          {:error, failure} -> {:error, failure}
          _ -> {:error, {:unknown, :invalid_operation_evidence}}
        end
    end
  end

  defp same_operation?(left, right) do
    left["name"] == right["name"] and
      get_in(left, ["metadata", "target"]) == get_in(right, ["metadata", "target"]) and
      get_in(left, ["metadata", "verb"]) == get_in(right, ["metadata", "verb"])
  end

  defp mutation_failure(config, record, verb, {:retryable, {:conflict, _}} = failure, opts) do
    rejected = replace_last(record, verb, %{outcome: :failed})

    with {:ok, workstation} <- get(config, resource_name(config, record), opts),
         {:ok, observed} <- observe_owned(config, rejected, workstation) do
      fail(observed, failure)
    else
      {:error, reason} -> fail(rejected, reason)
    end
  end

  defp mutation_failure(_config, record, verb, {:denied, _} = failure, _opts), do: fail(replace_last(record, verb, %{outcome: :failed}), failure)
  defp mutation_failure(_config, record, _verb, failure, _opts), do: fail(record, failure)

  defp observed_pending(pending, operations, target) do
    resolved = Enum.map(pending, &resolve(&1, operations, target))

    Enum.reduce(operations, resolved, fn operation, acc ->
      if operation["done"] != true and get_in(operation, ["metadata", "target"]) == target and not Enum.any?(acc, &(&1.id == operation["name"])) do
        acc ++ [unlisted_operation(operation)]
      else
        acc
      end
    end)
  end

  defp unlisted_operation(operation) do
    case enum(get_in(operation, ["metadata", "verb"]), @verbs) do
      {:ok, verb} -> %{verb: verb, id: operation["name"], outcome: :pending}
      _ -> %{verb: :update, id: nil, outcome: :unknown}
    end
  end

  defp resolve(%{outcome: outcome} = entry, _operations, _target) when outcome in [:succeeded, :failed], do: entry
  defp resolve(%{verb: :update, annotation_hash: _} = entry, _operations, _target), do: entry

  defp resolve(entry, operations, target) do
    matches =
      Enum.filter(operations, fn op ->
        get_in(op, ["metadata", "target"]) == target and get_in(op, ["metadata", "verb"]) == Atom.to_string(entry.verb) and
          if(is_binary(entry.id), do: op["name"] == entry.id, else: in_window?(op, entry))
      end)

    case matches do
      [operation] -> Map.merge(entry, operation_result(operation))
      _ -> entry
    end
  end

  defp in_window?(operation, entry) do
    with {:ok, created, _} <- DateTime.from_iso8601(get_in(operation, ["metadata", "createTime"]) || ""),
         {:ok, first, _} <- DateTime.from_iso8601(Map.get(entry, :from, "")),
         {:ok, last, _} <- DateTime.from_iso8601(Map.get(entry, :until, "")) do
      DateTime.compare(created, first) != :lt and DateTime.compare(created, last) != :gt
    else
      _ -> false
    end
  end

  defp operation_result(operation) do
    outcome =
      cond do
        operation["done"] != true -> :pending
        Map.has_key?(operation, "error") -> :failed
        true -> :succeeded
      end

    %{id: operation["name"], outcome: outcome}
  end

  defp valid_operation?(config, operation, target, verb) do
    operation_name?(config, operation["name"]) and
      get_in(operation, ["metadata", "target"]) == target and get_in(operation, ["metadata", "verb"]) == Atom.to_string(verb)
  end

  defp operation_name?(config, name), do: operation_name_in_scope?(config.provider, name)

  defp operation_name_in_scope?(%{"project" => project, "location" => location}, name)
       when is_binary(project) and is_binary(location) and is_binary(name) do
    case String.split(name, "/") do
      ["projects", named_project, "locations", named_location, "operations", id] ->
        named_project == segment(project) and named_location == segment(location) and nonblank?(id) and
          id not in [".", ".."] and URI.encode(id, &URI.char_unreserved?/1) == id

      _ ->
        false
    end
  end

  defp operation_name_in_scope?(_, _), do: false

  defp valid_pending_evidence?(_scope, %{id: nil, outcome: outcome}), do: outcome in [:unknown, :failed]
  defp valid_pending_evidence?(scope, %{id: id}), do: operation_name_in_scope?(scope, id)

  defp marker(verb, opts),
    do: %{
      verb: verb,
      id: nil,
      outcome: :unknown,
      from: DateTime.to_iso8601(DateTime.utc_now()),
      until: DateTime.utc_now() |> DateTime.add(Client.remaining(opts), :millisecond) |> DateTime.to_iso8601()
    }

  defp replace_last(record, verb, attrs) do
    index = Enum.find_index(Enum.reverse(record.pending), &(&1.verb == verb))
    pending = List.update_at(record.pending, length(record.pending) - 1 - index, &Map.merge(&1, attrs))
    %{record | pending: pending}
  end

  defp inspect_absence(config, record, opts) do
    with {:ok, settled} <- settle(config, record, opts),
         {:ok, backing} <- backing_inventory(config, opts) do
      captured = capture_backing(settled, backing)
      leftovers = related_backing(record, backing)

      cond do
        leftovers != [] -> fail(captured, {:unknown, {:backing_resources_remaining, safe_ids(leftovers)}})
        deleted?(settled) -> absent(captured, %{deleted_uid: ref_uid(record), backing_absent: true})
        never_created?(settled) -> absent(captured, %{create_rejected: true, backing_absent: true})
        true -> fail(captured, {:unknown, :absence_without_delete_evidence})
      end
    else
      {:error, _, _} = error -> error
      {:error, failure} -> fail(record, failure)
    end
  end

  defp deleted?(record), do: Enum.any?(record.pending, &(&1.verb == :delete and &1.outcome == :succeeded))

  defp never_created?(record) do
    is_nil(record.provider_ref) and record.pending != [] and
      Enum.all?(record.pending, &(&1.verb == :create and &1.outcome == :failed)) and
      Map.get(record.metadata, "backing_resources", []) == []
  end

  defp absent(record, evidence),
    do: {:ok, %{record | absent?: true, phase: :stopped, proof: {:quiescent, evidence}}}

  defp observe_owned(config, record, workstation) do
    with :ok <- identity(config, record),
         {:ok, durable} <- decode(config, workstation),
         true <- durable.key == record.key and durable.issue_id == record.issue_id and durable.tracker_kind == record.tracker_kind and durable.workspace_path == record.workspace_path,
         true <- is_nil(record.provider_ref) or ref_uid(record) == workstation["uid"],
         true <- nonblank?(record.template_identity) and record.template_identity == durable.template_identity,
         true <- workstation["name"] == resource_name(config, record),
         true <- nonblank?(workstation["uid"]) and nonblank?(workstation["etag"]) do
      local = confirmed_metadata(record.pending, workstation)
      pending = merge_pending(durable.pending, local)

      {:ok,
       %{
         record
         | provider_ref: %{name: workstation["name"], uid: workstation["uid"]},
           version: workstation["etag"],
           template_identity: durable.template_identity,
           metadata: Map.merge(durable.metadata, record.metadata),
           pending: pending
       }}
    else
      _ -> {:error, {:invalid, :workstations_ownership}}
    end
  end

  defp merge_pending(durable, local) do
    Enum.reduce(durable, local, fn item, acc ->
      if Enum.any?(acc, &same_pending?(&1, item)), do: acc, else: acc ++ [item]
    end)
  end

  defp same_pending?(left, right),
    do: left.verb == right.verb and Map.get(left, :from) == Map.get(right, :from)

  defp confirmed_metadata(pending, workstation) do
    hash = annotation_hash(get_in(workstation, ["annotations", @annotation]))
    Enum.reject(pending, &confirmed_metadata?(&1, hash))
  end

  defp confirmed_metadata?(%{verb: :update, annotation_hash: hash}, hash), do: true
  defp confirmed_metadata?(_entry, _hash), do: false

  defp annotation_hash(annotation), do: :crypto.hash(:sha256, annotation) |> Base.encode16(case: :lower)

  # The proof type is shared across adapters, but an operator loss declaration is specific to
  # the Kubernetes host model. Reaching Workstations means a record was routed to the wrong
  # adapter; fail loudly rather than fall through as merely "not quiescent".
  defp identity(_config, %Record{proof: {:operator_declared_lost, _}}), do: {:error, {:invalid, :workstations_proof_unsupported}}

  defp identity(config, record) do
    valid =
      record.kind == "google_workstations" and record.deployment_id == config.deployment_id and record.scope == Config.scope(config) and
        record.key == ExecutionEnvironment.resource_key(record.deployment_id, record.tracker_kind, record.issue_id) and valid_config_name?(config, config_name(config, record))

    if valid, do: :ok, else: {:error, {:invalid, :workstations_ownership}}
  end

  defp valid_config_name?(config, name),
    do: is_binary(name) and String.starts_with?(name, cluster(config) <> "/workstationConfigs/") and length(String.split(name, "/")) == 8 and not String.contains?(name, ["?", "#", ".."])

  defp metadata(record) do
    data =
      Map.take(Map.from_struct(record), [
        :key,
        :deployment_id,
        :tracker_kind,
        :issue_id,
        :kind,
        :scope,
        :workspace_path,
        :template_identity,
        :attempt_id,
        :issue_identifier,
        :issue_state,
        :desired,
        :terminal_observed_at,
        :pending,
        :metadata
      ])

    data = Map.put(data, :provider_uid, ref_uid(record))
    %{"labels" => labels(record.deployment_id, record.key), "annotations" => %{@annotation => Jason.encode!(data)}}
  end

  defp decode(config, workstation) do
    with encoded when is_binary(encoded) <- get_in(workstation, ["annotations", @annotation]),
         {:ok, data} when is_map(data) <- Jason.decode(encoded),
         true <- Enum.all?(~w(key deployment_id tracker_kind issue_id kind workspace_path template_identity), &nonblank?(data[&1])),
         true <- data["deployment_id"] == config.deployment_id and data["scope"] == Config.scope(config),
         true <- is_nil(data["provider_uid"]) or data["provider_uid"] == workstation["uid"],
         true <- labels(data["deployment_id"], data["key"]) |> Enum.all?(fn {key, value} -> get_in(workstation, ["labels", key]) == value end),
         {:ok, desired} <- enum(data["desired"], [:running, :stopped, :absent]),
         {:ok, pending} <- decode_pending(config.provider, data["pending"]),
         true <- is_map(data["metadata"]),
         true <- nonblank?(data["metadata"]["config_name"]) and nonblank?(data["metadata"]["config_fingerprint"]),
         true <- valid_config_name?(config, data["metadata"]["config_name"]) do
      record = %Record{
        key: data["key"],
        deployment_id: data["deployment_id"],
        tracker_kind: data["tracker_kind"],
        issue_id: data["issue_id"],
        kind: data["kind"],
        scope: data["scope"],
        workspace_path: data["workspace_path"],
        template_identity: data["template_identity"],
        desired: desired,
        pending: durable_pending(pending),
        metadata: data["metadata"],
        attempt_id: data["attempt_id"],
        issue_identifier: data["issue_identifier"],
        issue_state: data["issue_state"],
        terminal_observed_at: data["terminal_observed_at"],
        provider_ref: %{name: workstation["name"], uid: workstation["uid"]},
        version: workstation["etag"]
      }

      with :ok <- identity(config, record),
           true <- workstation["name"] == resource_name(config, record),
           true <- is_binary(workstation["uid"]) and workstation["uid"] != "" do
        {:ok, record}
      else
        _ -> {:error, {:invalid, :workstations_ownership}}
      end
    else
      _ -> {:error, {:invalid, :workstations_ownership}}
    end
  end

  # The final marker is contained in the very metadata write it journals. Reading
  # that owned annotation proves this metadata-only write landed, not any earlier
  # compute mutation or any other outstanding metadata write.
  defp durable_pending(pending) do
    case List.last(pending) do
      %{verb: :update, id: nil, outcome: :unknown, from: first, until: last}
      when is_binary(first) and is_binary(last) ->
        Enum.drop(pending, -1)

      _ ->
        pending
    end
  end

  defp decode_pending(scope, entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn item, {:ok, acc} ->
      with true <- is_map(item),
           {:ok, verb} <- enum(item["verb"], @verbs),
           {:ok, outcome} <- enum(item["outcome"], @outcomes),
           true <- valid_pending_evidence?(scope, %{id: item["id"], outcome: outcome}) do
        entry = %{verb: verb, outcome: outcome, id: item["id"]}
        entry = Enum.reduce([:from, :until], entry, &decode_window(&1, &2, item))
        {:cont, {:ok, acc ++ [entry]}}
      else
        _ -> {:halt, {:error, {:invalid, :workstations_metadata}}}
      end
    end)
  end

  defp decode_pending(_scope, _entries), do: {:error, {:invalid, :workstations_metadata}}

  defp decode_window(key, entry, item) do
    case item[Atom.to_string(key)] do
      value when is_binary(value) -> Map.put(entry, key, value)
      _ -> entry
    end
  end

  defp enum(value, allowed) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_enum}
      atom -> {:ok, atom}
    end
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp compatible(template) do
    valid = nonblank?(template["uid"]) and template["reconciling"] != true
    safe = compatible_storage?(template) and compatible_runtime?(template) and compatible_network?(template)
    if valid and safe, do: :ok, else: {:error, {:invalid, :workstations_profile}}
  end

  defp compatible_storage?(template) do
    case Map.get(template, "persistentDirectories", []) do
      [%{"mountPath" => "/home", "gcePd" => %{"reclaimPolicy" => "DELETE", "archiveTimeout" => "0s"}}] -> true
      _ -> false
    end
  end

  defp compatible_runtime?(template) do
    host = get_in(template, ["host", "gceInstance"]) || %{}

    Map.get(host, "poolSize", 0) == 0 and
      Enum.all?(Map.get(host, "boostConfigs", []), &(Map.get(&1, "poolSize", 0) == 0)) and
      Map.get(template, "idleTimeout", "1200s") == "0s" and
      Map.get(template, "runningTimeout", "43200s") == "0s" and
      Map.get(template, "idleAction", "STOP") in ["STOP", "IDLE_ACTION_UNSPECIFIED"]
  end

  defp compatible_network?(template) do
    ports = Map.get(template, "allowedPorts", [%{"first" => 22, "last" => 22}])

    Map.get(template, "disableTcpConnections", false) == false and
      Enum.any?(ports, &(Map.get(&1, "first", 0) <= 22 and Map.get(&1, "last", 0) >= 22))
  end

  defp retained_config(record, template) do
    with :ok <- compatible(template),
         true <- template["uid"] == record.template_identity and fingerprint(template) == record.metadata["config_fingerprint"] do
      :ok
    else
      _ -> {:error, {:invalid, :workstations_config_changed}}
    end
  end

  defp fingerprint(template),
    do:
      template |> Map.put_new("disableTcpConnections", false) |> Map.take(@runtime_fields) |> canonical() |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp canonical(map) when is_map(map), do: map |> Enum.map(fn {key, value} -> {key, canonical(value)} end) |> Enum.sort()
  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp list_templates(config, templates, opts) do
    Enum.reduce_while(templates, {:ok, []}, &list_template(config, &1, &2, opts))
  end

  defp list_template(config, template, {:ok, acc}, opts) do
    if is_binary(template["name"]) and String.starts_with?(template["name"], cluster(config) <> "/workstationConfigs/") do
      case pages(config, template["name"] <> "/workstations", "workstations", opts) do
        {:ok, items} -> {:cont, {:ok, acc ++ items}}
        error -> {:halt, error}
      end
    else
      {:halt, {:error, {:unknown, :invalid_inventory}}}
    end
  end

  defp decode_owned(config, workstations, operations) do
    workstations
    |> Enum.filter(&(get_in(&1, ["labels", "symphony-deployment"]) == deployment_hash(config.deployment_id)))
    |> Enum.reduce_while({:ok, []}, fn workstation, {:ok, acc} ->
      case decode(config, workstation) do
        {:ok, record} -> {:cont, {:ok, acc ++ [normalize(record, workstation, operations)]}}
        error -> {:halt, error}
      end
    end)
  end

  defp operation_inventory(config, opts), do: pages(config, region(config) <> "/operations", "operations", opts)

  defp pages(config, path, field, opts, token \\ nil, seen \\ %{}, acc \\ []) do
    query = [pageSize: 100] ++ if(token, do: [pageToken: token], else: [])

    with {:ok, body} <- api(config, :get, path, query, nil, opts),
         :ok <- complete(body),
         items when is_list(items) <- Map.get(body, field, []) do
      next = body["nextPageToken"]

      cond do
        next in [nil, ""] -> {:ok, acc ++ items}
        not is_binary(next) or Map.has_key?(seen, next) -> {:error, {:unknown, :invalid_pagination}}
        true -> pages(config, path, field, opts, next, Map.put(seen, next, true), acc ++ items)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, {:unknown, :invalid_inventory}}
    end
  end

  defp backing_inventory(config, opts) do
    with {:ok, instances} <- compute_pages(config, "instances", opts),
         {:ok, disks} <- compute_pages(config, "disks", opts) do
      {:ok, instances ++ disks}
    end
  end

  defp compute_pages(config, kind, opts, token \\ nil, seen \\ %{}, acc \\ []) do
    path = "/compute/v1/projects/" <> segment(config.provider["project"]) <> "/aggregated/" <> kind
    query = [maxResults: 100, returnPartialSuccess: false, includeAllScopes: true]
    query = if token, do: Keyword.put(query, :pageToken, token), else: query

    with {:ok, body} <- api(config, :get, path, query, nil, opts),
         :ok <- complete(body),
         scopes when is_map(scopes) <- Map.get(body, "items", %{}),
         true <- Enum.all?(scopes, fn {_, scope} -> complete(scope) == :ok and is_list(Map.get(scope, kind, [])) end) do
      items = Enum.flat_map(scopes, fn {_, scope} -> Map.get(scope, kind, []) end)
      next = body["nextPageToken"]

      cond do
        next in [nil, ""] -> {:ok, acc ++ items}
        not is_binary(next) or Map.has_key?(seen, next) -> {:error, {:unknown, :invalid_pagination}}
        true -> compute_pages(config, kind, opts, next, Map.put(seen, next, true), acc ++ items)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, {:unknown, :partial_inventory}}
    end
  end

  defp complete(body) when is_map(body) do
    if Map.get(body, "unreachable", []) == [] and Map.get(body, "unreachables", []) == [] and not Map.has_key?(body, "error") and
         get_in(body, ["warning", "code"]) in [nil, "NO_RESULTS_ON_PAGE"], do: :ok, else: {:error, {:unknown, :partial_inventory}}
  end

  defp complete(_), do: {:error, {:unknown, :invalid_inventory}}

  defp related_backing(record, resources) do
    captured = Map.get(record.metadata, "backing_resources", [])

    Enum.filter(resources, fn resource ->
      owned = labels(record.deployment_id, record.key) |> Enum.all?(fn {key, value} -> get_in(resource, ["labels", key]) == value end)
      owned or Enum.any?(captured, &(&1["id"] == resource["id"] and &1["selfLink"] == resource["selfLink"]))
    end)
  end

  defp capture_backing(record, resources) do
    observed = safe_ids(related_backing(record, resources))
    retained = Enum.uniq(Map.get(record.metadata, "backing_resources", []) ++ observed)
    %{record | metadata: Map.put(record.metadata, "backing_resources", retained)}
  end

  defp safe_ids(resources), do: Enum.map(resources, &Map.take(&1, ["id", "name", "selfLink", "zone", "region"]))

  defp qualify_running(config, record, opts) do
    case backing_inventory(config, opts) do
      {:ok, resources} -> qualify_backing(config, record, resources, opts)
      {:error, failure} -> fail(record, failure)
    end
  end

  defp qualify_backing(config, record, resources, opts) do
    related = related_backing(record, resources)
    owned = Enum.filter(related, &owned_backing?(record, &1))
    qualified = length(owned) == length(related) and Enum.all?(["/instances/", "/disks/"], &has_backing?(owned, &1))
    captured = capture_backing(record, resources)

    if qualified do
      persist(config, %{captured | metadata: Map.put(captured.metadata, "backing_qualified", true)}, opts)
    else
      fail(captured, {:unknown, :backing_ownership_unqualified})
    end
  end

  defp owned_backing?(record, resource),
    do: Enum.all?(labels(record.deployment_id, record.key), fn {key, value} -> get_in(resource, ["labels", key]) == value end)

  defp has_backing?(owned, kind),
    do: Enum.any?(owned, &(is_binary(&1["id"]) and is_binary(&1["selfLink"]) and String.contains?(&1["selfLink"], kind)))

  defp get(config, path, opts), do: api(config, :get, path, [], nil, opts)

  defp api(config, method, path, query, body, opts) do
    path = if String.starts_with?(path, "/compute/"), do: path, else: "/v1/" <> path

    case Client.request(config, method, path, query, body, opts) do
      {:ok, %{status: status, body: response}} when status in 200..299 and is_map(response) -> {:ok, response}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} when status in [401, 403] -> {:error, {:denied, :workstations_authorization}}
      {:ok, %{status: status}} when status in [409, 412] -> {:error, {:retryable, {:conflict, status}}}
      {:ok, %{status: status}} -> {:error, {:unknown, {:workstations_http, status}}}
      {:error, _} = error -> error
    end
  end

  defp labels(deployment, key), do: %{"symphony-managed" => "true", "symphony-deployment" => deployment_hash(deployment), "symphony-ticket" => key}
  defp deployment_hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp region(config), do: "projects/" <> segment(config.provider["project"]) <> "/locations/" <> segment(config.provider["location"])
  defp cluster(config), do: region(config) <> "/workstationClusters/" <> segment(config.provider["cluster"])
  defp parent(config), do: cluster(config) <> "/workstationConfigs/" <> segment(config.provider["config"])
  defp config_name(config, record), do: Map.get(record.metadata, "config_name", parent(config))
  defp resource_name(config, record), do: config_name(config, record) <> "/workstations/" <> segment(record.key)
  defp ref_name(%{provider_ref: %{name: name}}), do: name
  defp ref_name(_), do: nil
  defp ref_uid(%{provider_ref: %{uid: uid}}), do: uid
  defp ref_uid(_), do: nil
  defp fail(record, :not_found), do: fail(record, {:unknown, :resource_not_found})
  defp fail(record, failure), do: {:error, failure, %{record | phase: :unknown, proof: :unknown, absent?: false}}

  defp connect_tunnel(config, record, supervisor, authority, opts) do
    with gcloud when is_binary(gcloud) <- executable(opts, :gcloud_executable, "gcloud"),
         ssh when is_binary(ssh) <- Keyword.get_lazy(opts, :ssh_executable, fn -> System.find_executable("ssh") end) do
      directory = private_directory_path()
      connect_directory(config, record, gcloud, ssh, directory, supervisor, authority, opts)
    else
      _ -> {:error, {:invalid, :workstations_connection_prerequisite}}
    end
  end

  defp executable(opts, key, name), do: Keyword.get_lazy(opts, key, fn -> System.find_executable(name) end)

  defp connect_directory(config, record, gcloud, ssh, directory, supervisor, authority, opts) do
    case Operations.stage_private_paths(supervisor, authority, self(), [directory]) do
      {:ok, stage} ->
        staged_opts = Keyword.put(opts, :staged_paths, stage)
        result = create_connection(config, record, gcloud, ssh, directory, supervisor, authority, staged_opts)
        release_failed_stage(result, stage)

      error ->
        error
    end
  end

  defp create_connection(config, record, gcloud, ssh, directory, supervisor, authority, opts) do
    with :ok <- Operations.create_staged_directory(Keyword.fetch!(opts, :staged_paths), directory) do
      connect_staged(config, record, gcloud, ssh, directory, supervisor, authority, opts)
    end
  end

  defp release_failed_stage({:ok, _} = connection, _stage), do: connection

  defp release_failed_stage(error, stage) do
    Operations.release_staged_paths(stage)
    error
  end

  defp connect_staged(config, record, gcloud, ssh, directory, supervisor, authority, opts) do
    args =
      [
        "workstations",
        "start-tcp-tunnel",
        record.key,
        "22",
        "--project=" <> config.provider["project"],
        "--region=" <> config.provider["location"],
        "--cluster=" <> config.provider["cluster"],
        "--config=" <> List.last(String.split(config_name(config, record), "/")),
        "--local-host-port=127.0.0.1:0"
      ] ++ Client.auth_args(config)

    case Operations.start_staged_port(Keyword.fetch!(opts, :staged_paths), gcloud, args, env: [{"CLOUDSDK_CORE_DISABLE_PROMPTS", "1"}]) do
      {:ok, port} -> establish_tunnel(config, port, ssh, directory, supervisor, authority, opts)
      error -> error
    end
  rescue
    _ -> {:error, {:unknown, :workstations_tunnel_failed}}
  end

  defp establish_tunnel(config, port, ssh, directory, supervisor, authority, opts) do
    timeout = max(Client.remaining(opts), 1)

    result =
      with {:ok, local_port} <- tunnel_ready(port, opts, ""),
           {:ok, socket} <- :gen_tcp.connect({127, 0, 0, 1}, local_port, [:binary, active: false], timeout) do
        :gen_tcp.close(socket)
        known_hosts = Path.join(directory, "known_hosts")

        prefix = [
          "-F",
          "/dev/null",
          "-T",
          "-o",
          "BatchMode=yes",
          "-o",
          "ForwardAgent=no",
          "-o",
          "IdentityAgent=none",
          "-o",
          "PubkeyAuthentication=no",
          "-o",
          "PreferredAuthentications=none",
          "-o",
          "PasswordAuthentication=no",
          "-o",
          "KbdInteractiveAuthentication=no",
          "-o",
          "GlobalKnownHostsFile=/dev/null",
          "-o",
          "UserKnownHostsFile=" <> known_hosts,
          "-o",
          "StrictHostKeyChecking=accept-new",
          "-p",
          Integer.to_string(local_port),
          "-l",
          config.provider["ssh_user"],
          "127.0.0.1"
        ]

        with {:ok, %{status: 0}} <- Command.run(ssh, prefix ++ ["true"], Keyword.put(opts, :timeout_ms, max(Client.remaining(opts), 1))),
             {:ok, stat} <- File.stat(known_hosts),
             true <- stat.size > 0,
             :ok <- File.chmod(known_hosts, 0o600) do
          target = %Target{
            executable: ssh,
            prefix: Enum.map(prefix, fn value -> if value == "StrictHostKeyChecking=accept-new", do: "StrictHostKeyChecking=yes", else: value end),
            label: "managed-workstation"
          }

          Operations.open_connection(supervisor, authority, target, ports: [port], private_paths: [directory], staged_paths: Keyword.fetch!(opts, :staged_paths))
        else
          _ -> {:error, {:unknown, :workstations_ssh_not_ready}}
        end
      else
        _ -> {:error, {:unknown, :workstations_tunnel_not_ready}}
      end

    result
  rescue
    _ -> {:error, {:unknown, :workstations_tunnel_failed}}
  end

  defp private_directory_path do
    Path.join(System.tmp_dir!(), "symphony-ws-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))
  end

  defp tunnel_ready(port, opts, output) do
    receive do
      {^port, {:data, bytes}} ->
        combined = output <> bytes

        case Regex.run(~r/Listening on port \[(\d+)\]/, combined) do
          [_, number] ->
            value = String.to_integer(number)
            if value in 1..65_535, do: {:ok, value}, else: {:error, :invalid_port}

          _ ->
            continue_tunnel(port, opts, combined)
        end

      {^port, {:exit_status, _}} ->
        {:error, :tunnel_exit}
    after
      Client.remaining(opts) -> {:error, :tunnel_deadline}
    end
  end

  defp continue_tunnel(port, opts, output) when byte_size(output) <= 65_536,
    do: tunnel_ready(port, opts, output)

  defp continue_tunnel(_port, _opts, _output), do: {:error, :tunnel_output_limit}
end
