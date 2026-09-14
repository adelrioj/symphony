defmodule SymphonyElixir.ExecutionEnvironment.Kubernetes do
  @moduledoc "Direct, permanently gated Agent Sandbox v1.0.1 environments. Qualification is operator-owned, never worker input."
  @behaviour SymphonyElixir.ExecutionEnvironment

  alias SymphonyElixir.ExecutionEnvironment.{Command, Config, Connection, Operations, Record}
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.{Client, Guard}
  alias SymphonyElixir.SSH.Target

  @api "agents.x-k8s.io/v1beta1"
  @extensions "extensions.agents.x-k8s.io/v1beta1"
  @gate "symphony.dev/start-authorized"
  @finalizer "symphony.dev/environment-cleanup"
  @state "symphony.dev/record"
  @qualification "symphony.dev/qualification"
  @pv_finalizer "external-provisioner.volume.kubernetes.io/finalizer"
  @children ["pods", "persistentvolumeclaims", "services", "secrets"]
  @protocol "symphony-create-drain-v1"

  @stock_baseline %{
    release: "v1.0.1",
    termination_contract: "qualified-kubelet-all-containers-v1",
    controller_source_commit: "3e77ccbac4db8a12b0157eafcad0d1ad5872f32a",
    controller_image_prefix: "registry.k8s.io/agent-sandbox/agent-sandbox-controller@sha256:",
    schemas: [
      {"sandboxes.agents.x-k8s.io", "37f0b89594ba20ca4d37b93714c362bcd694369f"},
      {"sandboxtemplates.extensions.agents.x-k8s.io", "6c5c594b1a0cddda9b330bb094272e1c465d11c2"}
    ]
  }

  # The release artifact has neither this entrypoint nor the candidate validator.
  if Mix.env() == :test do
    @spec candidate_preflight(map(), map(), keyword()) :: :ok | {:error, term()}
    def candidate_preflight(config, pins, opts \\ []) do
      opts = opts |> Keyword.put(:candidate_baseline, pins) |> with_deadline()

      with {:ok, _} <- qualification(config, opts),
           :ok <- validate_config(config.provider),
           {:ok, _} <- inventory(config, opts),
           do: :ok
    end

    defp baseline(config, opts) do
      case Keyword.fetch(opts, :candidate_baseline) do
        {:ok, pins} -> SymphonyElixir.ExecutionEnvironment.Kubernetes.Candidate.validate(config, pins)
        :error -> {:ok, @stock_baseline}
      end
    end

    defp candidate_contract(config, q, template, baseline, opts) do
      case baseline do
        %{candidate: pins} -> SymphonyElixir.ExecutionEnvironment.Kubernetes.Candidate.contract(config, q, template, pins, opts)
        _ -> :ok
      end
    end
  else
    defp baseline(_config, opts) do
      with :ok <- ordinary_options(opts), do: {:ok, @stock_baseline}
    end

    defp candidate_contract(_config, _q, _template, _baseline, _opts), do: :ok
  end

  defp ordinary_options(opts) do
    if Keyword.has_key?(opts, :candidate_baseline),
      do: {:error, {:invalid, :kubernetes_candidate_options_forbidden}},
      else: :ok
  end

  defp candidate_operation(config, opts) do
    if Keyword.has_key?(opts, :candidate_baseline) do
      with {:ok, _} <- qualification(config, opts), do: :ok
    else
      :ok
    end
  end

  @verbs [:create, :start, :stop, :delete, :update]
  @outcomes [:pending, :unknown, :succeeded, :failed]
  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(provider) when is_map(provider) do
    required = ["kubeconfig", "context", "namespace", "template", "ssh_user", "ssh_auth_volume"]

    if Enum.all?(required, &(is_binary(provider[&1]) and String.trim(provider[&1]) != "")) and
         is_integer(provider["ssh_port"]) and provider["ssh_port"] in 1..65_535 and File.regular?(provider["kubeconfig"]) and
         Regex.match?(~r/^[a-z_][a-z0-9_-]*[$]?$/, provider["ssh_user"]) do
      :ok
    else
      {:error, {:invalid, :kubernetes_configuration}}
    end
  end

  def validate_config(_), do: {:error, {:invalid, :kubernetes_configuration}}

  @spec preflight(map(), keyword()) :: :ok | {:error, term()}
  def preflight(config, opts) do
    opts = with_deadline(opts)

    with :ok <- ordinary_options(opts),
         :ok <- validate_config(config.provider),
         {:ok, _} <- qualification(config, opts),
         {:ok, _} <- inventory(config, opts),
         do: {:error, {:unknown, :kubernetes_controller_cleanup_ordering_unproven}}
  end

  @spec discover(map(), keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  def discover(config, opts) do
    opts = with_deadline(opts)

    with :ok <- candidate_operation(config, opts),
         {:ok, objects} <- inventory(config, opts),
         {:ok, records} <- discover_guards(config, objects, opts),
         :ok <- inventory_guard_ownership(config, objects, records) do
      {:ok, records |> Map.values() |> Enum.reject(& &1.absent?)}
    end
  end

  defp discover_guards(config, objects, opts) do
    guards = Enum.filter(objects["configmaps"], &guard_candidate?/1)

    Enum.reduce_while(guards, {:ok, %{}}, fn object, {:ok, records} ->
      case discovered_guard(config, object, objects, opts) do
        {:ok, record} -> store_discovered_guard(records, record)
        error -> {:halt, error}
      end
    end)
  end

  defp guard_candidate?(object) do
    String.starts_with?(name(object) || "", "symphony-guard-") or
      get_in(object, ["metadata", "labels", "symphony.dev/create-guard"]) == "true"
  end

  defp discovered_guard(config, object, objects, opts) do
    with {:ok, data} <- Jason.decode(get_in(object, ["data", "guard.json"]) || ""),
         true <- is_map(data) and is_map(data["identity"]) do
      if data["identity"]["deploymentID"] == config.deployment_id,
        do: resolve_discovered_guard(config, object, data, objects, opts),
        else: {:ok, nil}
    else
      _ -> {:error, {:unknown, :kubernetes_guard_invalid}}
    end
  end

  defp resolve_discovered_guard(config, object, data, objects, opts) do
    with {:ok, record} <- decode_guard_record(data, config),
         {:ok, guard} <- Guard.decode(object, record),
         {:ok, guard} <- Guard.settle(config, record, guard, opts),
         {:ok, record} <- guard_observation(config, record, guard, objects) do
      {:ok, record}
    else
      _ -> {:error, {:unknown, :kubernetes_guard_discovery_conflict}}
    end
  end

  defp store_discovered_guard(records, nil), do: {:cont, {:ok, records}}

  defp store_discovered_guard(records, record) do
    if Map.has_key?(records, record.key),
      do: {:halt, {:error, {:unknown, :kubernetes_guard_discovery_conflict}}},
      else: {:cont, {:ok, Map.put(records, record.key, record)}}
  end

  defp decode_guard_record(data, config) do
    object = %{"metadata" => %{"annotations" => %{@state => Jason.encode!(data["record"])}}}

    with {:ok, record} <- decode_record(object, config),
         do: {:ok, %{record | provider_ref: data["parentUID"]}}
  end

  defp guard_observation(config, record, guard, objects) do
    with {:ok, saved} <- decode_guard_record(guard.data, config) do
      sandbox = Enum.find(objects["sandboxes"], &(name(&1) == record.key))
      observe_guard_parent(saved, guard, sandbox, objects)
    end
  end

  defp observe_guard_parent(saved, guard, nil, objects) do
    if guard.data["phase"] == "Complete" and complete_evidence?(guard, saved) and
         not remaining_backing?(objects, saved) and guard_children_absent?(objects, saved) do
      {:ok, completed_record(saved, guard)}
    else
      {:ok, %{saved | metadata: Map.put(saved.metadata, "orphaned", true), proof: :unknown, phase: :unknown}}
    end
  end

  defp observe_guard_parent(saved, guard, sandbox, _objects) do
    with :ok <- ownership(sandbox, saved),
         :ok <- guarded_parent(guard, sandbox),
         true <- guard.data["phase"] != "Complete" do
      {:ok, %{saved | version: rv(sandbox)}}
    else
      _ -> {:error, {:unknown, :kubernetes_ownership_changed}}
    end
  end

  defp guard_children_absent?(objects, record) do
    Enum.all?(@children, fn resource ->
      not Enum.any?(objects[resource], &denied_candidate_for_guard?(&1, record))
    end)
  end

  defp inventory_guard_ownership(config, objects, records) do
    unresolved =
      ["sandboxes" | @children]
      |> Enum.flat_map(&objects[&1])
      |> Enum.filter(&unguarded_owned?(&1, config, records))

    if unresolved == [] do
      :ok
    else
      resources = Enum.flat_map(unresolved, &unguarded_resources(&1, config))
      {:error, {:unknown, {:kubernetes_invalid_owned_record, resources}}}
    end
  end

  defp unguarded_owned?(object, config, records) do
    labels = get_in(object, ["metadata", "labels"]) || %{}
    record = records[labels["symphony.dev/environment"]]
    labels["symphony.dev/deployment"] == digest(config.deployment_id) and (record == nil or record.absent?)
  end

  defp unguarded_resources(object, config) do
    identifiers = Enum.filter([name(object), uid(object)], &is_binary/1)

    case decode_record(object, config) do
      {:ok, record} -> identifiers ++ orphan_volume_resources(record.metadata["volumes"])
      _ -> identifiers
    end
  end

  defp orphan_volume_resources(volumes) when is_map(volumes) do
    Enum.flat_map(volumes, fn
      {_, volume} when is_map(volume) ->
        [
          %{"name" => volume["pvc_name"], "uid" => volume["pvc_uid"]},
          %{"name" => volume["pv_name"], "uid" => volume["pv_uid"], "volume_handle" => volume["volume_handle"]}
        ]

      _ ->
        []
    end)
  end

  defp orphan_volume_resources(_), do: []

  @spec ensure(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
  def ensure(config, record, opts) do
    opts = with_deadline(opts)

    result =
      with {:ok, q} <- qualification(config, opts),
           record = bind_template_identity(record, q),
           {:ok, existing} <- Client.lookup(config, collection(config, "sandboxes"), record.key, opts),
           {:ok, objects} <- inventory(config, opts) do
        ensure_observed(config, record, existing, objects, q, opts)
      end

    result(record, result)
  end

  # The scheduler creates records with no template identity and each adapter binds its own; the
  # Kubernetes adapter only ever validated it. Without a binding, ExecutionContext.managed/3
  # raises and preparation dies as {:invalid, :managed_execution_context}, so an environment is
  # allocated and then never usable. Bind on entry so the durable copy written to the guard and
  # every later identity comparison see the same value.
  defp bind_template_identity(%Record{template_identity: nil} = record, q), do: %{record | template_identity: q["template_uid"]}
  defp bind_template_identity(record, _q), do: record

  defp ensure_observed(config, record, existing, objects, q, opts) do
    cond do
      existing != nil ->
        with :ok <- ownership(existing, record),
             {:ok, guard} <- Guard.fetch(config, record, opts),
             {:ok, guard} <- Guard.settle(config, record, guard, opts),
             :ok <- guarded_parent(guard, existing),
             true <- guard.data["phase"] == "Open",
             {:ok, observed} <- guard_record(config, record, guard, existing),
             :ok <- template_identity(observed, q) do
          {:ok, observed}
        else
          false -> {:error, {:unknown, :kubernetes_issuance_closed}}
          error -> error
        end

      record.provider_ref != nil or record.metadata["orphaned"] == true ->
        {:error, {:unknown, :retained_kubernetes_parent_missing}}

      unresolved_mutations?(record) ->
        {:error, {:unknown, :kubernetes_create_outcome}}

      Enum.any?(@children, &Enum.any?(objects[&1], fn child -> labeled_candidate?(child, record) end)) ->
        {:error, {:unknown, :retained_kubernetes_children_without_parent}}

      true ->
        materialize(config, record, q, opts)
    end
  end

  @spec inspect(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
  def inspect(config, record, opts) do
    opts = with_deadline(opts)

    result =
      with {:ok, q} <- qualification(config, opts),
           {:ok, objects} <- inventory(config, opts),
           :ok <- template_identity(record, q) do
        inspect_inventory(config, record, objects, q, opts)
      end

    result(record, result)
  end

  defp inspect_inventory(config, record, objects, q, opts) do
    case parent(objects, record) do
      {:ok, sandbox} ->
        with {:ok, guard} <- Guard.fetch(config, record, opts),
             {:ok, guard} <- Guard.settle(config, record, guard, opts),
             :ok <- guarded_parent(guard, sandbox),
             {:ok, current} <- guard_record(config, record, guard, sandbox),
             {:ok, current} <- accept_observed_drain(current, sandbox, guard) do
          inspect_parent(config, current, sandbox, objects, q, opts)
        end

      {:error, {:unknown, :kubernetes_parent_missing}} ->
        recover_missing(config, record, objects, opts)

      error ->
        error
    end
  end

  defp inspect_parent(config, record, sandbox, objects, q, opts) do
    with_pod_obligations(record, sandbox, objects["pods"], q, fn record ->
      with :ok <- owned_pods(objects["pods"], record, sandbox),
           {:ok, record} <- capture_storage(record, sandbox, objects, q),
           {:ok, record} <- inspect_termination(config, record, q, opts),
           {:ok, record} <- save_observation(config, record, opts),
           {:ok, sandbox} <- fetch_parent(config, record, opts),
           {:ok, record} <- observe_guard(config, record, sandbox, opts) do
        pods = children(objects["pods"], record, sandbox)
        evidence = Map.get(record.metadata, "termination_evidence", %{})
        {:ok, normalize(record, sandbox, pods, evidence)}
      end
    end)
  end

  @spec put_intent(map(), Record.t(), map(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
  def put_intent(config, record, intent, opts) do
    opts = with_deadline(opts)

    updated =
      Enum.reduce([:desired, :attempt_id, :issue_state, :terminal_observed_at], record, fn key, acc ->
        if Map.has_key?(intent, key), do: Map.put(acc, key, intent[key]), else: acc
      end)

    result =
      with :ok <- candidate_operation(config, opts),
           {:ok, guard} <- Guard.fetch(config, record, opts) do
        write_intent(config, record, updated, guard, opts)
      end

    result(updated, result)
  end

  defp write_intent(config, _record, updated, %{data: %{"phase" => phase}} = guard, opts)
       when phase in ["ReadyToFinalize", "Complete"],
       do: immutable_intent(config, updated, guard, opts)

  defp write_intent(config, record, updated, _guard, opts) do
    with :ok <- intent_guard(config, updated, opts),
         {:ok, sandbox} <- fetch_parent(config, record, opts) do
      write_parent_intent(config, record, updated, sandbox, opts)
    else
      {:error, {:unknown, :kubernetes_parent_missing}} -> inspect(config, updated, opts)
      error -> error
    end
  end

  defp write_parent_intent(config, record, updated, sandbox, opts) do
    result =
      if record.version == nil or record.version == rv(sandbox),
        do: persist(config, updated, sandbox, [], opts),
        else: {:error, {:retryable, :kubernetes_cas_conflict}}

    case result do
      {:error, reason} -> physical_error_result(reason, updated, sandbox)
      other -> other
    end
  end

  @spec start(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
  def start(config, record, opts) do
    opts = with_deadline(opts)

    result =
      with {:ok, q} <- qualification(config, opts),
           :ok <- Guard.open(config, record, opts),
           {:ok, sandbox} <- fetch_parent(config, record, opts),
           {:ok, record} <- observe_guard(config, record, sandbox, opts),
           true <- record.desired == :running and get_in(sandbox, ["metadata", "deletionTimestamp"]) == nil,
           {:ok, objects} <- inventory(config, opts),
           {:ok, record} <- capture_storage(record, sandbox, objects, q),
           :ok <- replacement_safe(record, children(objects["pods"], record, sandbox)),
           {:ok, record} <- ensure_credentials(config, record, sandbox, q, opts) do
        case start_running(config, record, opts) do
          {:ok, running} -> result(running, wait_authorization(config, running, q, with_deadline(opts)))
          {:error, failure} -> {:error, failure, record}
        end
      else
        false -> {:error, {:unknown, :kubernetes_start_cancelled}}
        error -> error
      end

    finish_start(result(record, result), record)
  end

  defp start_running(config, record, opts) do
    with :ok <- Guard.open(config, record, opts),
         {:ok, sandbox} <- fetch_parent(config, record, opts),
         {:ok, record} <- observe_guard(config, record, sandbox, opts),
         true <- record.desired == :running and get_in(sandbox, ["metadata", "deletionTimestamp"]) == nil do
      updated = %{record | desired: :running, proof: :unknown, phase: :preparing}
      patch = [%{"op" => "add", "path" => "/spec/operatingMode", "value" => "Running"}]
      persist(config, updated, sandbox, patch, opts)
    else
      false -> {:error, {:unknown, :kubernetes_start_cancelled}}
      error -> error
    end
  end

  defp finish_start({:ok, _} = result, _record), do: result

  defp finish_start({:error, failure, %Record{} = record}, _fallback) do
    cleanup_client_key(record)
    {:error, failure, %{record | metadata: durable_metadata(record.metadata)}}
  end

  @spec connect(map(), Record.t(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def connect(config, record, opts) do
    opts = with_deadline(opts)

    result =
      with {:ok, current} <- inspect(config, record, opts),
           true <- current.phase == :running,
           {:ok, sandbox} <- fetch_parent(config, current, opts),
           {:ok, pods} <- Client.list(config, collection(config, "pods"), opts),
           [pod] <- Enum.filter(children(pods, current, sandbox), &(uid(&1) in Map.get(current.metadata, "authorized_pod_uids", []) and ready_pod?(&1))),
           {:ok, secret} <- Client.lookup(config, collection(config, "secrets"), secret_name(current), opts),
           :ok <- guarded_secret(config, secret, current, sandbox, opts),
           {:ok, host_public} <- secret_value(secret, "ssh_host_ed25519_key.pub"),
           {:ok, key_path} <- client_key_path(current, secret),
           directory when is_binary(directory) <- current.metadata["client_key_directory"],
           {:staged_paths, owner, id} when is_pid(owner) and is_reference(id) <- current.metadata["client_key_lease"] do
        connect_private(config, current, pod, host_public, key_path, directory, opts)
      else
        {:error, _} = error -> error
        _ -> {:error, {:unknown, :kubernetes_ssh_not_ready}}
      end

    if not match?({:ok, _}, result), do: cleanup_client_key(record)
    result
  end

  @spec stop(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
  def stop(config, record, opts) do
    opts = with_deadline(opts)

    result =
      with {:ok, q} <- qualification(config, opts) do
        case fetch_parent(config, record, opts) do
          {:ok, sandbox} ->
            stop_parent(config, record, sandbox, q, opts)

          {:error, {:unknown, :kubernetes_parent_missing}} ->
            inspect(config, %{record | desired: stop_desired(record)}, opts)

          error ->
            error
        end
      end

    cleanup_client_key(record)
    result(record, result)
  end

  defp stop_parent(config, record, sandbox, q, opts) do
    with {:ok, guard} <- Guard.fetch(config, record, opts),
         {:ok, observed} <- decode_guard_record(guard.data, config),
         desired = if(guard.data["phase"] == "Open", do: stop_desired(record), else: :absent),
         stopping = %{observed | version: rv(sandbox), desired: desired, phase: :stopping, proof: :unknown},
         {:ok, stopped} <- persist(config, stopping, sandbox, [], opts),
         {:ok, pods} <- Client.list(config, collection(config, "pods"), opts),
         {:ok, fenced} <- stop_fences(config, stopped, children(pods, stopped, sandbox), q, opts),
         {:ok, current} <- fetch_parent(config, fenced, opts),
         {:ok, suspended} <- suspend(config, fenced, current, opts),
         {:ok, proved} <- collect_termination(config, suspended, q, opts),
         {:ok, current} <- fetch_parent(config, proved, opts),
         {:ok, saved} <- persist(config, proved, current, [], opts) do
      inspect(config, %{saved | metadata: durable_metadata(saved.metadata)}, opts)
    end
  end

  defp suspend(config, record, sandbox, opts) do
    if get_in(sandbox, ["spec", "creationControl", "closeRequestId"]) == nil do
      patch = [%{"op" => "add", "path" => "/spec/operatingMode", "value" => "Suspended"}]
      persist(config, record, sandbox, patch, opts)
    else
      # A closed controller no longer reconciles operatingMode or its conditions.
      # Physical stop is established from the frozen journal and UID evidence.
      {:ok, record}
    end
  end

  @spec destroy(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
  def destroy(config, record, opts) do
    opts = with_deadline(opts)

    result =
      with {:ok, q} <- qualification(config, opts),
           {:ok, guard} <- Guard.close(config, %{record | desired: :absent}, encode_record(%{record | desired: :absent}), opts),
           {:ok, guard} <- Guard.settle(config, record, guard, opts),
           :ok <- Guard.drained(guard),
           {:ok, current} <- decode_guard_record(guard.data, config) do
        destroy_guarded(config, current, guard, q, opts)
      end

    result(%{record | desired: :absent}, result)
  end

  defp destroy_guarded(config, record, %{data: %{"phase" => "ReadyToFinalize"}} = guard, _q, opts) do
    with {:ok, objects} <- inventory(config, opts) do
      case parent(objects, record) do
        {:ok, _} -> finalize_ready(config, record, guard, opts)
        {:error, {:unknown, :kubernetes_parent_missing}} -> recover_missing(config, record, objects, opts)
        error -> error
      end
    end
  end

  defp destroy_guarded(config, record, %{data: %{"phase" => "Complete"}}, _q, opts) do
    with {:ok, objects} <- inventory(config, opts), do: recover_missing(config, record, objects, opts)
  end

  defp destroy_guarded(config, record, guard, q, opts) do
    with {:ok, objects} <- inventory(config, opts) do
      destroy_guard_inventory(config, record, guard, objects, q, opts)
    end
  end

  defp destroy_guard_inventory(config, record, guard, objects, q, opts) do
    case parent(objects, record) do
      {:ok, sandbox} -> close_and_destroy(config, record, guard, sandbox, objects, q, opts)
      {:error, {:unknown, :kubernetes_parent_missing}} -> recover_missing(config, record, objects, opts)
      error -> error
    end
  end

  defp close_and_destroy(config, record, guard, sandbox, objects, q, opts) do
    with :ok <- guarded_parent(guard, sandbox),
         {:ok, sandbox, journal} <- close_controller(config, record, sandbox, guard, opts) do
      with_pod_obligations(record, sandbox, objects["pods"], q, fn record ->
        destroy_closed(config, record, sandbox, journal, guard, q, opts)
      end)
    end
  end

  defp destroy_closed(config, record, sandbox, journal, guard, q, opts) do
    with {:ok, objects} <- inventory(config, opts),
         {:ok, captured} <- capture_storage(record, sandbox, objects, q),
         {:ok, classified} <- classify_journal(captured, sandbox, journal, guard, objects, q),
         {:ok, saved} <- persist(config, classified, sandbox, [], opts),
         {:ok, stopped} <- stop(config, saved, opts) do
      destroy_stopped(config, stopped, journal, guard, q, opts)
    end
  end

  defp destroy_stopped(config, stopped, journal, guard, q, opts) do
    with true <- match?({:quiescent, _}, stopped.proof),
         {:ok, objects} <- inventory(config, opts),
         {:ok, sandbox} <- parent(objects, stopped) do
      with_pod_obligations(stopped, sandbox, objects["pods"], q, fn stopped ->
        destroy_inventory(config, stopped, sandbox, objects, journal, guard, q, opts)
      end)
    else
      false -> {:error, {:unknown, :kubernetes_cleanup_pending}, stopped}
      {:error, reason} -> {:error, reason, stopped}
    end
  end

  defp destroy_inventory(config, stopped, sandbox, objects, journal, guard, q, opts) do
    with :ok <- unchanged_journal(sandbox, journal, guard),
         {:ok, captured} <- capture_storage(stopped, sandbox, objects, q),
         {:ok, classified} <- classify_journal(captured, sandbox, journal, guard, objects, q),
         {:ok, deleting} <- persist(config, %{classified | desired: :absent, phase: :deleting}, sandbox, [], opts),
         {:ok, deleting} <- delete_children(config, deleting, sandbox, objects, q, opts),
         {:ok, deleting} <- storage_deletion(config, deleting, q, opts),
         {:ok, current} <- fetch_parent(config, deleting, opts),
         {:ok, deleting} <- persist(config, deleting, current, [], opts),
         {:ok, final_objects} <- inventory(config, opts),
         true <- Enum.all?(@children, &(children(final_objects[&1], deleting, current) == [])),
         true <- not remaining_backing?(final_objects, deleting),
         true <- Enum.all?(deleting.metadata["volumes"] || %{}, fn {_, volume} -> volume["deleted"] == true end),
         {:ok, guard} <- Guard.fetch(config, deleting, opts),
         evidence = cleanup_evidence(deleting, journal, guard),
         true <- complete_evidence?(%{guard | data: Map.put(guard.data, "evidence", evidence)}, deleting),
         {:ok, ready} <- Guard.transition(config, deleting, guard, "ReadyToFinalize", encode_record(deleting), evidence, opts) do
      finalize_ready(config, deleting, ready, opts)
    else
      false -> {:error, {:unknown, :kubernetes_cleanup_pending}, stopped}
      other -> other
    end
  end

  defp cleanup_evidence(record, journal, guard) do
    %{
      "controllerJournal" => journal,
      "physical" => record.metadata["pod_safety"] || %{},
      "termination" => record.metadata["termination_evidence"] || %{},
      "volumes" => record.metadata["volumes"] || %{},
      "childrenAbsent" => true,
      "parentUID" => record.provider_ref,
      "closeRequestId" => guard.data["closeRequestId"]
    }
  end

  defp stop_desired(%{desired: :absent}), do: :absent
  defp stop_desired(_), do: :stopped

  defp intent_guard(config, %{desired: :absent} = record, opts) do
    with {:ok, _} <- Guard.close(config, record, encode_record(record), opts), do: :ok
  end

  defp intent_guard(config, record, opts), do: Guard.open(config, record, opts)

  defp immutable_intent(config, requested, guard, opts) do
    with true <- requested.desired == :absent,
         {:ok, record} <- decode_guard_record(guard.data, config),
         true <- complete_evidence?(guard, record),
         {:ok, guard} <- Guard.confirm(config, record, guard, opts),
         {:ok, objects} <- inventory(config, opts),
         true <- not remaining_backing?(objects, record),
         true <- guard_children_absent?(objects, record) do
      immutable_parent_intent(record, guard, parent(objects, record))
    else
      _ -> {:error, {:unknown, :kubernetes_finalization_unconfirmed}}
    end
  end

  defp immutable_parent_intent(record, guard, {:ok, sandbox}) do
    with true <- guard.data["phase"] == "ReadyToFinalize",
         :ok <- guarded_parent(guard, sandbox),
         :ok <- unchanged_journal(sandbox, guard.data["evidence"]["controllerJournal"], guard) do
      {:ok, bind_parent(record, sandbox)}
    else
      _ -> {:error, {:unknown, :kubernetes_finalization_unconfirmed}}
    end
  end

  defp immutable_parent_intent(record, _guard, {:error, {:unknown, :kubernetes_parent_missing}}), do: {:ok, record}
  defp immutable_parent_intent(_record, _guard, _parent), do: {:error, {:unknown, :kubernetes_ownership_changed}}

  defp physical_failure(reason, record, sandbox) do
    evidence = record.metadata["termination_evidence"] || %{}
    authorized_stopped? = Enum.all?(record.metadata["authorized_pod_uids"] || [], &termination_proof?(evidence[&1], &1, record))

    if authorized_stopped? and committed_pods_accounted?(record, sandbox, evidence),
      do: {:error, reason},
      else: {:error, reason, compute_unknown(record, sandbox)}
  end

  defp accept_observed_drain(record, sandbox, guard) do
    if get_in(sandbox, ["spec", "creationControl", "closeRequestId"]) == nil do
      {:ok, record}
    else
      journal = get_in(sandbox, ["status", "creationJournal"])

      with :ok <- unchanged_journal(sandbox, journal, guard),
           true <- record.metadata["creation_journal"] in [nil, journal] do
        {:ok, %{record | metadata: Map.put(record.metadata, "creation_journal", journal)}}
      else
        false -> physical_failure({:unknown, :kubernetes_controller_journal_changed}, record, sandbox)
        {:error, reason} -> physical_failure(reason, record, sandbox)
      end
    end
  end

  defp guarded_parent(guard, sandbox) do
    operation = Enum.find(guard.data["operations"], &(&1["resource"] == "sandboxes" and &1["state"] == "Committed"))

    if operation != nil and Guard.matches?(sandbox, operation) and guard.data["parentUID"] == uid(sandbox) and
         get_in(sandbox, ["spec", "creationControl", "protocol"]) == @protocol and
         @finalizer in (get_in(sandbox, ["metadata", "finalizers"]) || []) do
      :ok
    else
      {:error, {:unknown, :kubernetes_create_attribution_conflict}}
    end
  end

  defp close_controller(config, record, sandbox, guard, opts) do
    control = get_in(sandbox, ["spec", "creationControl"]) || %{}
    close_id = guard.data["closeRequestId"]

    with true <- control["protocol"] == @protocol and control["closeRequestId"] in [nil, close_id],
         true <- @finalizer in (get_in(sandbox, ["metadata", "finalizers"]) || []) do
      if control["closeRequestId"] == nil do
        patch = cas(sandbox) ++ [%{"op" => "add", "path" => "/spec/creationControl/closeRequestId", "value" => close_id}]
        api(config, :patch, object_path(config, "sandboxes", sandbox), patch, opts)
      end

      read_drained_controller(config, record, guard, opts)
    else
      _ -> {:error, {:unknown, :kubernetes_controller_acknowledgement_invalid}}
    end
  end

  defp read_drained_controller(config, record, guard, opts) do
    with {:ok, current} <- fetch_parent(config, record, opts) do
      journal = get_in(current, ["status", "creationJournal"])

      case unchanged_journal(current, journal, guard) do
        :ok -> {:ok, current, journal}
        {:error, reason} -> physical_failure(reason, record, current)
      end
    end
  end

  defp unchanged_journal(sandbox, journal, guard) do
    control = get_in(sandbox, ["spec", "creationControl"]) || %{}

    if control == %{"protocol" => @protocol, "closeRequestId" => guard.data["closeRequestId"]} and
         get_in(sandbox, ["status", "creationJournal"]) == journal and
         valid_journal?(journal, uid(sandbox), guard.data["closeRequestId"], get_in(sandbox, ["metadata", "namespace"])),
       do: :ok,
       else: {:error, {:unknown, :kubernetes_controller_acknowledgement_invalid}}
  end

  defp valid_journal?(journal, parent_uid, close_id, namespace) when is_map(journal) do
    journal_identity?(journal, parent_uid, close_id) and
      committed_members?(journal["operations"], parent_uid, namespace) and
      matching_acknowledgement?(journal, parent_uid, close_id)
  end

  defp valid_journal?(_, _, _, _), do: false

  defp journal_identity?(journal, parent_uid, close_id) do
    is_binary(parent_uid) and parent_uid != "" and is_binary(close_id) and close_id != "" and
      journal["parentUID"] == parent_uid and journal["phase"] == "Drained" and
      is_integer(journal["revision"]) and journal["revision"] >= 1
  end

  defp committed_members?(operations, parent_uid, namespace) when is_list(operations) do
    Enum.all?(operations, &valid_controller_operation?(&1, parent_uid, namespace)) and
      length(Enum.uniq_by(operations, & &1["id"])) == length(operations) and
      length(Enum.uniq_by(operations, &{&1["resource"], &1["objectUID"]})) == length(operations)
  end

  defp committed_members?(_, _, _), do: false

  defp matching_acknowledgement?(journal, parent_uid, close_id) do
    expected = %{
      "protocol" => @protocol,
      "parentUID" => parent_uid,
      "closeRequestId" => close_id,
      "revision" => journal["revision"],
      "operationCount" => length(journal["operations"])
    }

    journal["acknowledgement"] == expected
  end

  defp valid_controller_operation?(operation, parent_uid, namespace) when is_map(operation) do
    valid_operation_identity?(operation, parent_uid, namespace) and operation["state"] == "Committed" and
      is_binary(operation["objectUID"]) and operation["objectUID"] != ""
  end

  defp valid_controller_operation?(_, _, _), do: false

  defp valid_operation_identity?(operation, parent_uid, namespace) do
    Enum.all?(~w(id issuerId name), &(is_binary(operation[&1]) and operation[&1] != "")) and
      operation["group"] == "" and operation["resource"] in ["pods", "persistentvolumeclaims", "services"] and
      operation["namespace"] == namespace and operation["parentUID"] == parent_uid
  end

  defp controller_attribution?(object, operation) do
    annotations = get_in(object, ["metadata", "annotations"]) || %{}
    kinds = %{"pods" => "Pod", "persistentvolumeclaims" => "PersistentVolumeClaim", "services" => "Service"}

    uid(object) == operation["objectUID"] and name(object) == operation["name"] and object["kind"] == kinds[operation["resource"]] and
      get_in(object, ["metadata", "namespace"]) == operation["namespace"] and
      annotations["agents.x-k8s.io/create-protocol"] == @protocol and
      annotations["agents.x-k8s.io/create-parent-uid"] == operation["parentUID"] and
      annotations["agents.x-k8s.io/create-attempt-id"] == operation["id"]
  end

  defp classify_journal(record, sandbox, journal, guard, objects, q) do
    operations = journal["operations"]

    with true <- record.metadata["creation_journal"] in [nil, journal],
         :ok <- authenticated_inventory(record, sandbox, operations, guard, objects) do
      record = %{record | metadata: Map.put(record.metadata, "creation_journal", journal)}

      classify_operations(record, operations, objects, q)
    else
      false -> {:error, {:unknown, :kubernetes_controller_journal_changed}}
      error -> error
    end
  end

  defp classify_operations(record, operations, objects, q) do
    Enum.reduce_while(operations, {:ok, record}, fn operation, {:ok, current} ->
      object = Enum.find(objects[operation["resource"]], &(uid(&1) == operation["objectUID"]))

      case classify_operation(current, object, operation, q) do
        {:ok, classified} -> {:cont, {:ok, classified}}
        error -> {:halt, error}
      end
    end)
  end

  defp authenticated_inventory(record, sandbox, operations, guard, objects) do
    valid = Enum.all?(@children, &authenticated_children?(&1, record, sandbox, operations, guard, objects))
    if valid, do: :ok, else: {:error, {:unknown, :kubernetes_unjournaled_child}}
  end

  defp authenticated_children?(resource, record, sandbox, operations, guard, objects) do
    Enum.all?(children(objects[resource], record, sandbox), fn child ->
      child_ownership(child, record, sandbox) == :ok and authenticated_child?(resource, child, operations, guard)
    end)
  end

  defp authenticated_child?("secrets", child, _operations, guard) do
    Enum.any?(guard.data["operations"], fn operation ->
      operation["resource"] == "secrets" and operation["state"] == "Committed" and Guard.matches?(child, operation)
    end)
  end

  defp authenticated_child?(resource, child, operations, _guard) do
    Enum.any?(operations, &(&1["resource"] == resource and controller_attribution?(child, &1)))
  end

  defp classify_operation(record, pod, %{"resource" => "pods"} = operation, q) do
    pod_uid = operation["objectUID"]
    prior = get_in(record.metadata, ["pod_safety", pod_uid])
    termination = get_in(record.metadata, ["termination_evidence", pod_uid])
    authorized = pod_uid in Map.get(record.metadata, "authorized_pod_uids", [])

    cond do
      termination_proof?(termination, pod_uid, record) ->
        safety = Map.put(termination, "kind", "terminated")
        {:ok, put_pod_safety(record, pod_uid, safety)}

      retained_pod_safety?(prior, pod, pod_uid, record, q) ->
        {:ok, record}

      pod == nil ->
        unresolved_pod(record, operation)

      not authorized and gated?(pod) and safe_live_pod(pod, q) == :ok ->
        {:ok, put_pod_safety(record, pod_uid, pod_evidence(pod, "never_executable", q))}

      authorized ->
        {:ok, record}

      true ->
        unresolved_pod(record, operation)
    end
  end

  defp classify_operation(record, _pvc, %{"resource" => "persistentvolumeclaims"} = operation, _q) do
    if Enum.any?(record.metadata["volumes"] || %{}, fn {_, volume} -> volume["pvc_uid"] == operation["objectUID"] end),
      do: {:ok, record},
      else: {:error, {:unknown, {:kubernetes_storage_obligation_missing, operation["objectUID"]}}}
  end

  defp classify_operation(record, _, _, _), do: {:ok, record}

  defp retained_pod_safety?(prior, pod, pod_uid, record, q) do
    valid_safety?(prior, pod_uid, record) and
      (pod == nil or prior["kind"] == "terminated" or (gated?(pod) and safe_live_pod(pod, q) == :ok))
  end

  defp unresolved_pod(record, operation) do
    evidence = %{parent_uid: operation["parentUID"], pod_uid: operation["objectUID"], attempt_id: operation["id"]}
    unresolved = %{record | phase: :unknown, proof: {:compute_unknown, evidence}, absent?: false}
    {:error, {:unknown, {:kubernetes_pod_safety_unresolved, operation["objectUID"]}}, unresolved}
  end

  defp put_pod_safety(record, pod_uid, safety),
    do: %{record | metadata: Map.update(record.metadata, "pod_safety", %{pod_uid => safety}, &Map.put(&1, pod_uid, safety))}

  defp valid_safety?(proof, pod_uid, record) when is_map(proof) do
    proof["kind"] in ["never_executable", "terminated"] and proof["uid"] == pod_uid and
      is_binary(proof["resourceVersion"]) and proof["resourceVersion"] != "" and
      proof["qualification_uid"] != nil and proof["qualification_uid"] == record.metadata["qualification_uid"]
  end

  defp valid_safety?(_, _, _), do: false

  defp complete_evidence?(guard, record) do
    evidence = guard.data["evidence"]
    journal = evidence["controllerJournal"]

    valid_journal?(journal, record.provider_ref, guard.data["closeRequestId"], record.scope["namespace"]) and
      journal == record.metadata["creation_journal"] and Guard.drained(guard) == :ok and
      receipt_binding?(evidence, guard, record) and receipt_payload?(evidence, record) and
      Enum.all?(journal["operations"], &complete_member?(&1, evidence, record)) and
      authorized_pods_terminated?(record, evidence["termination"]) and
      Enum.all?(evidence["volumes"], fn {_, volume} -> deleted_volume?(volume) end)
  end

  defp receipt_binding?(evidence, guard, record) do
    evidence["parentUID"] == record.provider_ref and evidence["closeRequestId"] == guard.data["closeRequestId"] and
      evidence["childrenAbsent"] == true
  end

  defp receipt_payload?(evidence, record) do
    evidence["physical"] == (record.metadata["pod_safety"] || %{}) and
      evidence["termination"] == (record.metadata["termination_evidence"] || %{}) and
      evidence["volumes"] == (record.metadata["volumes"] || %{})
  end

  defp complete_member?(%{"resource" => "pods", "objectUID" => uid}, evidence, record),
    do: valid_safety?(evidence["physical"][uid], uid, record)

  defp complete_member?(%{"resource" => "persistentvolumeclaims", "objectUID" => uid}, evidence, _record) do
    Enum.any?(evidence["volumes"], fn {_, volume} -> volume["pvc_uid"] == uid and deleted_volume?(volume) end)
  end

  defp complete_member?(%{"resource" => "services"}, _evidence, _record), do: true
  # Either the provisioned volume's deletion was observed, or the claim provably never bound and
  # no volume was ever provisioned for it. Only discharge_unbound/5 sets the latter, and only
  # after an authoritative read shows the claim absent with no PersistentVolume claiming its UID.
  defp deleted_volume?(volume), do: volume["deleted"] == true and (is_binary(volume["pv_uid"]) or volume["unbound"] == true)

  defp authorized_pods_terminated?(record, evidence) do
    Enum.all?(record.metadata["authorized_pod_uids"] || [], &termination_proof?(evidence[&1], &1, record))
  end

  defp recover_missing(config, record, objects, opts) do
    with {:ok, guard} <- Guard.fetch(config, record, opts),
         {:ok, saved} <- decode_guard_record(guard.data, config),
         true <- guard.data["phase"] in ["ReadyToFinalize", "Complete"] and complete_evidence?(guard, saved),
         true <- guard_children_absent?(objects, saved),
         true <- not remaining_backing?(objects, saved),
         {:ok, nil} <- Client.lookup(config, collection(config, "sandboxes"), saved.key, opts) do
      finish_absent_guard(config, saved, guard, opts)
    else
      _ ->
        unresolved = %{record | proof: :unknown, absent?: false, phase: :unknown}
        {:error, {:unknown, :kubernetes_parent_missing}, unresolved}
    end
  end

  defp finish_absent_guard(config, record, %{data: %{"phase" => "Complete"}} = guard, opts) do
    with {:ok, confirmed} <- Guard.confirm(config, record, guard, opts) do
      {:ok, completed_record(record, confirmed)}
    end
  end

  defp finish_absent_guard(config, record, guard, opts), do: complete_guard(config, record, guard, opts)

  defp denied_candidate_for_guard?(object, record) do
    labeled_candidate?(object, record) or
      Enum.any?(get_in(object, ["metadata", "ownerReferences"]) || [], &(&1["uid"] == record.provider_ref or &1["name"] == record.key))
  end

  defp finalize_ready(config, record, ready, opts) do
    with true <- complete_evidence?(ready, record),
         {:ok, ready} <- Guard.confirm(config, record, ready, opts),
         {:ok, current} <- fetch_parent(config, record, opts),
         :ok <- unchanged_journal(current, ready.data["evidence"]["controllerJournal"], ready),
         :ok <- delete(config, "sandboxes", current, opts),
         {:ok, current} <- fetch_parent(config, record, opts),
         :ok <- unchanged_journal(current, ready.data["evidence"]["controllerJournal"], ready),
         {:ok, _} <- Guard.confirm(config, record, ready, opts),
         true <- get_in(current, ["metadata", "deletionTimestamp"]) != nil do
      finalizers = Enum.reject(get_in(current, ["metadata", "finalizers"]) || [], &(&1 == @finalizer))
      patch = cas(current) ++ [%{"op" => "add", "path" => "/metadata/finalizers", "value" => finalizers}]
      api(config, :patch, object_path(config, "sandboxes", current), patch, opts)

      case Client.lookup(config, collection(config, "sandboxes"), record.key, opts) do
        {:ok, nil} -> complete_guard(config, record, ready, opts)
        _ -> {:error, {:unknown, :kubernetes_parent_deletion_pending}, record}
      end
    else
      _ -> {:error, {:unknown, :kubernetes_finalization_unconfirmed}, record}
    end
  end

  defp complete_guard(config, record, ready, opts) do
    with {:ok, complete} <- Guard.transition(config, record, ready, "Complete", encode_record(record), ready.data["evidence"], opts),
         {:ok, confirmed} <- Guard.confirm(config, record, complete, opts) do
      {:ok, completed_record(record, confirmed)}
    end
  end

  defp completed_record(record, guard),
    do: %{record | desired: :absent, absent?: true, phase: :stopped, pending: [], proof: {:quiescent, %{parent_uid: guard.data["parentUID"], guard_uid: uid(guard.object), protocol: @protocol}}}

  @spec normalize(Record.t(), map(), [map()], map()) :: Record.t()
  def normalize(record, sandbox, pods, termination_evidence) do
    cond do
      stopped_sandbox?(record, sandbox, pods, termination_evidence) ->
        proof = %{sandbox_uid: uid(sandbox), generation: get_in(sandbox, ["metadata", "generation"])}
        %{record | phase: :stopped, pending: [], proof: {:quiescent, proof}}

      record.desired == :running and running_sandbox?(record, sandbox, pods) ->
        %{record | phase: :running, pending: [], proof: :unknown}

      get_in(sandbox, ["spec", "creationControl", "protocol"]) == @protocol ->
        compute_unknown(record, sandbox)

      true ->
        %{record | phase: :unknown, proof: :unknown}
    end
  end

  defp stopped_sandbox?(record, sandbox, pods, evidence) do
    suspension_acknowledged?(record, sandbox) and blueprint_gated?(sandbox) and
      not unsafe_pod?(get_in(sandbox, ["spec", "podTemplate", "spec"]) || %{}) and
      authorized_pods_terminated?(record, evidence) and committed_pods_accounted?(record, sandbox, evidence) and
      Enum.all?(pods, &(safely_gated?(&1) or termination_proof?(evidence[uid(&1)], uid(&1), record)))
  end

  defp suspension_acknowledged?(record, sandbox) do
    close_id = get_in(sandbox, ["spec", "creationControl", "closeRequestId"])
    journal = get_in(sandbox, ["status", "creationJournal"])

    if close_id == nil do
      get_in(sandbox, ["spec", "operatingMode"]) == "Suspended" and condition?(sandbox, "Suspended")
    else
      record.desired == :absent and journal == record.metadata["creation_journal"] and
        valid_journal?(journal, uid(sandbox), close_id, get_in(sandbox, ["metadata", "namespace"]))
    end
  end

  defp pod_operations(sandbox) do
    journal = get_in(sandbox, ["status", "creationJournal"]) || %{}
    operations = journal["operations"]

    if get_in(sandbox, ["spec", "creationControl", "protocol"]) == @protocol and journal_membership_valid?(journal, sandbox) do
      {:ok, Enum.filter(operations, &(&1["resource"] == "pods"))}
    else
      {:error, {:unknown, :kubernetes_controller_journal_invalid}}
    end
  end

  defp journal_membership_valid?(journal, sandbox) do
    journal["parentUID"] == uid(sandbox) and journal["phase"] in ["Open", "Closed", "Drained"] and
      is_integer(journal["revision"]) and journal["revision"] > 0 and
      journal_members_valid?(journal["operations"], sandbox)
  end

  defp journal_members_valid?(operations, sandbox) when is_list(operations) do
    Enum.all?(operations, &valid_journal_member?(&1, uid(sandbox), get_in(sandbox, ["metadata", "namespace"]))) and
      length(Enum.uniq_by(operations, & &1["id"])) == length(operations)
  end

  defp journal_members_valid?(_, _), do: false

  defp valid_journal_member?(%{"state" => "Issued"} = operation, parent_uid, namespace) do
    not Map.has_key?(operation, "objectUID") and
      valid_operation_identity?(operation, parent_uid, namespace)
  end

  defp valid_journal_member?(operation, parent_uid, namespace), do: valid_controller_operation?(operation, parent_uid, namespace)

  defp with_pod_obligations(record, sandbox, pods, q, callback) do
    with {:ok, observed} <- capture_pod_obligations(record, sandbox, pods, q) do
      case callback.(observed) do
        {:error, reason} -> physical_error_result(reason, observed, sandbox)
        {:error, reason, %Record{} = failed} -> physical_error_result(reason, failed, sandbox)
        other -> other
      end
    end
  end

  defp physical_error_result(reason, record, sandbox) do
    case physical_failure(reason, record, sandbox) do
      {:error, ^reason} -> {:error, reason, record}
      failure -> failure
    end
  end

  defp capture_pod_obligations(record, sandbox, pods, q) do
    with {:ok, operations} <- pod_operations(sandbox),
         true <- prior_pod_operations_preserved?(record, operations) do
      record = %{record | metadata: Map.put(record.metadata, "controller_pod_operations", Map.new(operations, &{&1["id"], &1}))}

      observed =
        Enum.reduce(operations, record, fn operation, current ->
          capture_pod_operation(current, operation, sandbox, pods, q)
        end)

      {:ok, observed}
    else
      _ -> {:error, {:unknown, :kubernetes_controller_journal_invalid}, compute_unknown(record, sandbox)}
    end
  end

  defp capture_pod_operation(record, %{"state" => "Committed"} = operation, sandbox, pods, q) do
    pod = Enum.find(pods, &(controller_attribution?(&1, operation) and child_ownership(&1, record, sandbox) == :ok))

    case classify_operation(record, pod, operation, q) do
      {:ok, classified} -> classified
      {:error, _reason, unresolved} -> unresolved
    end
  end

  defp capture_pod_operation(record, _operation, _sandbox, _pods, _q), do: record

  defp prior_pod_operations_preserved?(record, operations) do
    Enum.all?(record.metadata["controller_pod_operations"] || %{}, fn {id, prior} ->
      case Enum.find(operations, &(&1["id"] == id)) do
        nil ->
          false

        current ->
          current == prior or (prior["state"] == "Issued" and current["state"] == "Committed" and Map.drop(current, ["state", "objectUID"]) == Map.delete(prior, "state"))
      end
    end)
  end

  defp committed_pods_accounted?(record, sandbox, evidence) do
    if get_in(sandbox, ["spec", "creationControl", "protocol"]) == nil do
      true
    else
      journal_pods_accounted?(record, sandbox, evidence)
    end
  end

  defp journal_pods_accounted?(record, sandbox, evidence) do
    case pod_operations(sandbox) do
      {:ok, operations} ->
        prior_pod_operations_preserved?(record, operations) and
          Enum.all?(operations, &pod_operation_accounted?(&1, record, evidence))

      _ ->
        false
    end
  end

  defp pod_operation_accounted?(operation, record, evidence) do
    pod_uid = operation["objectUID"]

    operation["state"] == "Committed" and
      (termination_proof?(evidence[pod_uid], pod_uid, record) or
         (pod_uid not in (record.metadata["authorized_pod_uids"] || []) and
            valid_safety?(get_in(record.metadata, ["pod_safety", pod_uid]), pod_uid, record)))
  end

  defp compute_unknown(record, sandbox) do
    evidence = %{
      parent_uid: uid(sandbox),
      authorized_pod_uids: record.metadata["authorized_pod_uids"] || [],
      controller_pod_operations: record.metadata["controller_pod_operations"] || %{}
    }

    %{record | phase: :unknown, proof: {:compute_unknown, evidence}, absent?: false}
  end

  defp safely_gated?(pod) do
    gated?(pod) and not unsafe_pod?(pod["spec"] || %{}) and get_in(pod, ["metadata", "deletionTimestamp"]) == nil
  end

  defp running_sandbox?(record, sandbox, pods) do
    authorized = Map.get(record.metadata, "authorized_pod_uids", [])

    get_in(sandbox, ["spec", "operatingMode"]) == "Running" and condition?(sandbox, "Ready") and
      Enum.any?(pods, &(uid(&1) in authorized and ready_pod?(&1)))
  end

  defp qualification(config, opts) do
    with {:ok, baseline} <- baseline(config, opts),
         {:ok, %{status: 200, body: version}} <- Client.request(config, :get, "/version", nil, opts),
         true <- kubernetes_version?(version),
         {:ok, template} when is_map(template) <- Client.lookup(config, collection(config, "sandboxtemplates"), config.provider["template"], opts),
         qualification_name when is_binary(qualification_name) <- get_in(template, ["metadata", "annotations", @qualification]),
         {:ok, cm} when is_map(cm) <- Client.lookup(config, collection(config, "configmaps"), qualification_name, opts),
         true <- cm["immutable"] == true,
         {:ok, q} <- Jason.decode(get_in(cm, ["data", "contract.json"]) || ""),
         true <- q["release"] == baseline.release and q["template_uid"] == uid(template) and q["template_digest"] == digest(template["spec"]),
         true <- is_binary(q["qualification_report"]) and String.trim(q["qualification_report"]) != "",
         true <- q["termination_contract"] == baseline.termination_contract,
         :ok <- candidate_contract(config, q, template, baseline, opts),
         {:ok, crds} <- Client.list(config, "/apis/apiextensions.k8s.io/v1/customresourcedefinitions", opts),
         :ok <- schemas(crds, baseline),
         {:ok, deployments} <- Client.list(config, "/apis/apps/v1/namespaces/#{segment(q["controller_namespace"])}/deployments", opts),
         controller when is_map(controller) <- Enum.find(deployments, &(name(&1) == q["controller_name"])),
         true <- uid(controller) == q["controller_uid"] and controller_image?(controller, q, baseline),
         {:ok, runtimes} <- Client.list(config, "/apis/node.k8s.io/v1/runtimeclasses", opts),
         runtime when is_map(runtime) <- Enum.find(runtimes, &(name(&1) == get_in(template, ["spec", "podTemplate", "spec", "runtimeClassName"]))),
         true <- uid(runtime) == q["runtime_class_uid"] and runtime["handler"] == q["runtime_handler"],
         {:ok, classes} <- Client.list(config, "/apis/storage.k8s.io/v1/storageclasses", opts),
         :ok <- storage_classes(template, classes, q),
         {:ok, policies} <- Client.list(config, "/apis/networking.k8s.io/v1/namespaces/#{segment(config.provider["namespace"])}/networkpolicies", opts),
         true <- network_policy?(template, policies, q),
         :ok <- safe_template(template, config, q) do
      {:ok, Map.merge(q, %{"uid" => uid(cm), "template" => template})}
    else
      {:error, _} = error -> error
      _ -> {:error, {:invalid, :kubernetes_profile_not_qualified}}
    end
  rescue
    _ -> {:error, {:invalid, :kubernetes_profile_not_qualified}}
  end

  defp schemas(crds, baseline) do
    valid = Enum.all?(baseline.schemas, fn {name, hash} -> qualified_schema?(crds, name, hash) end)
    if valid, do: :ok, else: {:error, {:invalid, :kubernetes_schema_mismatch}}
  end

  defp qualified_schema?(crds, expected_name, hash) do
    crd = Enum.find(crds, &(name(&1) == expected_name))
    versions = get_in(crd || %{}, ["spec", "versions"]) || []
    version = Enum.find(versions, &served_storage_version?/1)
    schema = get_in(version || %{}, ["schema", "openAPIV3Schema"])

    schema != nil and Enum.count(versions, &(&1["served"] == true)) == 1 and
      digest(schema) == hash and get_in(crd, ["spec", "scope"]) == "Namespaced"
  end

  defp served_storage_version?(version),
    do: version["name"] == "v1beta1" and version["served"] == true and version["storage"] == true

  defp kubernetes_version?(%{"major" => "1", "minor" => minor}) do
    case Integer.parse(minor) do
      {number, _} -> number >= 30
      _ -> false
    end
  end

  defp kubernetes_version?(_), do: false

  defp controller_image?(controller, q, baseline) do
    containers = get_in(controller, ["spec", "template", "spec", "containers"]) || []
    desired = get_in(controller, ["spec", "replicas"])
    available = get_in(controller, ["status", "availableReplicas"])

    is_integer(desired) and desired > 0 and is_integer(available) and available >= desired and
      q["controller_source_commit"] == baseline.controller_source_commit and
      Enum.any?(containers, &pinned_controller_image?(&1, q, baseline)) and
      get_in(controller, ["status", "observedGeneration"]) == get_in(controller, ["metadata", "generation"])
  end

  defp pinned_controller_image?(container, q, baseline) do
    container["image"] == q["controller_image"] and
      case baseline do
        %{controller_image: image} -> container["image"] == image
        %{controller_image_prefix: prefix} -> String.starts_with?(container["image"] || "", prefix)
      end
  end

  defp storage_classes(template, classes, q) do
    claims = get_in(template, ["spec", "volumeClaimTemplates"]) || []

    valid =
      claims != [] and
        Enum.all?(claims, fn claim ->
          class = Enum.find(classes, &(name(&1) == get_in(claim, ["spec", "storageClassName"])))
          class != nil and class["reclaimPolicy"] == "Delete" and class["provisioner"] == q["csi_driver"] and uid(class) in Map.get(q, "storage_class_uids", [])
        end)

    if valid, do: :ok, else: {:error, {:invalid, :kubernetes_storage_not_qualified}}
  end

  defp network_policy?(template, policies, q) do
    labels = get_in(template, ["spec", "podTemplate", "metadata", "labels"]) || %{}
    policy = Enum.find(policies, &(uid(&1) == q["network_policy_uid"]))
    profile = q["network_profile_label"]

    is_binary(profile) and not String.starts_with?(profile, "agents.x-k8s.io/") and labels[profile] != nil and
      get_in(template, ["spec", "networkPolicyManagement"]) == "Unmanaged" and
      qualified_policy?(policy, profile, labels)
  end

  defp qualified_policy?(nil, _profile, _labels), do: false

  defp qualified_policy?(policy, profile, labels) do
    get_in(policy, ["spec", "podSelector", "matchLabels", profile]) == labels[profile] and
      selector_matches?(get_in(policy, ["spec", "podSelector"]) || %{}, labels) and
      Enum.sort(get_in(policy, ["spec", "policyTypes"]) || []) == ["Egress", "Ingress"]
  end

  defp selector_matches?(selector, labels) do
    Enum.all?(selector["matchLabels"] || %{}, fn {key, value} -> labels[key] == value end) and
      Enum.all?(selector["matchExpressions"] || [], &expression_matches?(&1, labels))
  end

  defp expression_matches?(expression, labels) do
    key = expression["key"]
    values = expression["values"] || []

    case expression["operator"] do
      "In" -> labels[key] in values
      "NotIn" -> labels[key] not in values
      "Exists" -> Map.has_key?(labels, key)
      "DoesNotExist" -> not Map.has_key?(labels, key)
      _ -> false
    end
  end

  defp remaining_backing?(objects, record) do
    pvc_uids = Enum.map(record.metadata["volumes"] || %{}, fn {_, volume} -> volume["pvc_uid"] end)

    Enum.any?(objects["persistentvolumes"], fn pv ->
      claim = get_in(pv, ["spec", "claimRef"]) || %{}

      labeled_candidate?(pv, record) or (claim["uid"] != nil and claim["uid"] in pvc_uids) or
        (claim["namespace"] == record.scope["namespace"] and is_binary(claim["name"]) and String.ends_with?(claim["name"], "-" <> record.key))
    end)
  end

  defp reserved_template_attribution?(template) do
    metadata = [
      get_in(template, ["spec", "podTemplate", "metadata"]) || %{}
      | Enum.map(get_in(template, ["spec", "volumeClaimTemplates"]) || [], &(&1["metadata"] || %{}))
    ]

    Enum.any?(metadata, fn item ->
      Enum.any?(Map.keys(item["annotations"] || %{}), &(String.starts_with?(&1, "agents.x-k8s.io/create-") or String.starts_with?(&1, "symphony.dev/create-")))
    end)
  end

  defp safe_template(template, config, q) do
    spec = get_in(template, ["spec", "podTemplate", "spec"]) || %{}

    if not unsafe_pod?(spec) and not reserved_template_attribution?(template) and
         q["runtime_handler"] != nil and template_auth_available?(spec, config),
       do: :ok,
       else: {:error, {:invalid, :unsafe_kubernetes_template}}
  end

  defp template_auth_available?(spec, config) do
    volumes = spec["volumes"] || []
    containers = (spec["containers"] || []) ++ (spec["initContainers"] || [])
    auth = Enum.filter(volumes, &(&1["name"] == config.provider["ssh_auth_volume"]))
    length(auth) == 1 and Enum.any?(containers, &readonly_auth_mount?(&1, config.provider["ssh_auth_volume"]))
  end

  defp readonly_auth_mount?(container, volume) do
    Enum.any?(container["volumeMounts"] || [], &(&1["name"] == volume and &1["readOnly"] == true))
  end

  defp unsafe_pod?(spec) do
    volumes = spec["volumes"] || []
    containers = (spec["containers"] || []) ++ (spec["initContainers"] || [])

    Enum.any?(["hostNetwork", "hostPID", "hostIPC"], &(spec[&1] == true)) or spec["nodeName"] not in [nil, ""] or
      spec["schedulerName"] not in [nil, "default-scheduler"] or spec["ephemeralContainers"] not in [nil, []] or
      Enum.any?(volumes, &unsafe_volume?/1) or Enum.any?(containers, &unsafe_container?/1)
  end

  defp unsafe_volume?(volume) do
    Map.has_key?(volume, "hostPath") or
      Enum.any?(get_in(volume, ["projected", "sources"]) || [], &Map.has_key?(&1, "serviceAccountToken"))
  end

  defp unsafe_container?(container) do
    Map.has_key?(container, "restartPolicy") or Enum.any?(container["ports"] || [], &(&1["hostPort"] not in [nil, 0]))
  end

  defp materialize(config, record, q, opts) do
    metadata =
      Map.merge(record.metadata, %{
        "template_uid" => q["template_uid"],
        "template_digest" => q["template_digest"],
        "qualification_uid" => q["uid"],
        "authorized_pod_uids" => [],
        "termination_evidence" => %{},
        "volumes" => %{}
      })

    retained = Enum.reject(record.pending, &(&1 == %{verb: :create, id: record.key, outcome: :failed}))
    pending = retained ++ [%{verb: :create, id: record.key, outcome: :pending}]
    record = %{record | metadata: metadata, pending: pending, absent?: false, proof: :unknown}
    blueprint = Map.take(q["template"]["spec"], ["podTemplate", "volumeClaimTemplates", "service"])
    pod = blueprint["podTemplate"]
    spec = pod["spec"]
    gates = [%{"name" => @gate} | Enum.reject(spec["schedulingGates"] || [], &(&1["name"] == @gate))]

    volumes =
      Enum.map(spec["volumes"] || [], fn volume ->
        if volume["name"] == config.provider["ssh_auth_volume"] do
          %{"name" => volume["name"], "secret" => %{"secretName" => secret_name(record), "defaultMode" => 0o400}}
        else
          volume
        end
      end)

    spec =
      Map.merge(spec, %{
        "schedulingGates" => gates,
        "schedulerName" => "default-scheduler",
        "automountServiceAccountToken" => false,
        "enableServiceLinks" => false,
        "restartPolicy" => "Never",
        "volumes" => volumes
      })

    pod = %{pod | "spec" => spec} |> Map.put("metadata", stamp(Map.get(pod, "metadata", %{}), record))
    claims = Enum.map(blueprint["volumeClaimTemplates"], &Map.update!(&1, "metadata", fn metadata -> stamp(metadata, record) end))
    blueprint = Map.merge(blueprint, %{"podTemplate" => pod, "volumeClaimTemplates" => claims, "operatingMode" => "Suspended", "creationControl" => %{"protocol" => @protocol}})

    sandbox = %{
      "apiVersion" => @api,
      "kind" => "Sandbox",
      "metadata" => stamp(%{"name" => record.key, "namespace" => config.provider["namespace"], "finalizers" => [@finalizer]}, record),
      "spec" => blueprint
    }

    with {:ok, _} <- Guard.establish(config, record, encode_record(record), opts),
         {:ok, created} <- Guard.create(config, record, "sandboxes", sandbox, opts),
         :ok <- ownership(created, record) do
      {:ok, bind_parent(%{record | pending: []}, created)}
    else
      {:error, failure} ->
        pending = Enum.map(record.pending, &Map.put(&1, :outcome, :unknown))
        {:error, failure, %{record | pending: pending, proof: :unknown, absent?: false}}
    end
  end

  defp unresolved_mutations?(record) do
    Enum.any?(record.pending, &(&1.outcome in [:unknown, :pending]))
  end

  defp labeled_candidate?(object, record),
    do: get_in(object, ["metadata", "labels", "symphony.dev/environment"]) == record.key

  defp with_deadline(opts), do: Keyword.put_new_lazy(opts, :deadline, fn -> System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 20_000) end)

  defp command_options(opts), do: Keyword.put(opts, :timeout_ms, max(0, opts[:deadline] - System.monotonic_time(:millisecond)))

  defp wait_authorization(config, record, q, opts) do
    if opts[:deadline] <= System.monotonic_time(:millisecond) do
      {:error, {:unknown, :kubernetes_pod_creation_pending}, record}
    else
      with :ok <- Guard.open(config, record, opts),
           {:ok, sandbox} <- fetch_parent(config, record, opts),
           {:ok, record} <- observe_guard(config, record, sandbox, opts),
           true <- record.desired == :running and get_in(sandbox, ["metadata", "deletionTimestamp"]) == nil,
           {:ok, pods} <- Client.list(config, collection(config, "pods"), opts) do
        authorize_observed(config, record, sandbox, children(pods, record, sandbox), q, opts)
      else
        false -> {:error, {:unknown, :kubernetes_start_cancelled}, record}
        error -> error
      end
    end
  end

  defp authorize_observed(config, record, _sandbox, [], q, opts) do
    pause(opts)
    wait_authorization(config, record, q, opts)
  end

  defp authorize_observed(config, record, sandbox, owned, q, opts) do
    with {:ok, current} <- observe_guard(config, record, sandbox, opts),
         do: authorize(config, current, sandbox, owned, q, opts)
  end

  defp pause(opts) do
    delay = min(250, max(0, opts[:deadline] - System.monotonic_time(:millisecond)))
    Keyword.get(opts, :sleep_fun, &Process.sleep/1).(delay)
  end

  defp inspect_termination(config, %{desired: desired} = record, q, opts) when desired in [:stopped, :absent] do
    with {:ok, observed} <- collect_termination(config, record, q, opts) do
      if observed.metadata == record.metadata do
        {:ok, observed}
      else
        persist_current(config, observed, opts)
      end
    end
  end

  defp inspect_termination(_config, record, _q, _opts), do: {:ok, record}

  defp persist_current(config, record, opts) do
    with {:ok, sandbox} <- fetch_parent(config, record, opts), do: persist(config, record, sandbox, [], opts)
  end

  defp authorize(config, record, sandbox, pods, q, opts) do
    cond do
      record.desired != :running or get_in(sandbox, ["spec", "operatingMode"]) != "Running" ->
        {:error, {:unknown, :kubernetes_start_cancelled}}

      length(pods) != 1 ->
        {:error, {:retryable, :kubernetes_waiting_for_gated_pod}, record}

      true ->
        authorize_pod(config, record, sandbox, hd(pods), q, opts)
    end
  end

  defp authorize_pod(config, record, sandbox, pod, q, opts) do
    authorized = Map.get(record.metadata, "authorized_pod_uids", [])
    evidence = Map.get(record.metadata, "termination_evidence", %{})

    cond do
      child_ownership(pod, record, sandbox) != :ok ->
        {:error, {:unknown, :kubernetes_child_ownership_changed}}

      not journaled_pod?(sandbox, pod) ->
        reread_journaled_pod(config, record, sandbox, pod, q, opts)

      uid(pod) in authorized and not gated?(pod) ->
        {:ok, normalize(record, sandbox, [pod], evidence)}

      uid(pod) in authorized ->
        {:error, {:unknown, :kubernetes_release_already_recorded}, record}

      not gated?(pod) or not blueprint_gated?(sandbox) ->
        {:error, {:unknown, :kubernetes_gate_missing}}

      true ->
        release(config, record, sandbox, pod, q, opts)
    end
  end

  # Authorization runs against a parent snapshot taken before the Pod was observed, so a Pod
  # issued between the two reads looks unjournaled. Aborting on that deletes the Pod, the
  # controller recreates it, and the environment churns through its bounded journal without ever
  # starting — observed live as 59 Pod operations for one environment. Re-read the parent
  # authoritatively once: the protocol commits the entry before the POST, so a genuinely issued
  # Pod appears. A Pod still missing from the fresh journal is denied exactly as before, which
  # keeps forged and uncommitted attribution decisively rejected rather than merely delayed.
  defp reread_journaled_pod(config, record, _sandbox, pod, q, opts) do
    with {:ok, current} <- fetch_parent(config, record, opts),
         true <- journaled_pod?(current, pod) do
      authorize_pod(config, record, current, pod, q, opts)
    else
      false -> {:error, {:unknown, :kubernetes_unjournaled_child}}
      error -> error
    end
  end

  defp owned_pods(pods, record, sandbox) do
    if Enum.all?(children(pods, record, sandbox), &(child_ownership(&1, record, sandbox) == :ok)), do: :ok, else: {:error, {:unknown, :kubernetes_child_ownership_changed}}
  end

  defp save_observation(config, record, opts) do
    with {:ok, sandbox} <- fetch_parent(config, record, opts),
         {:ok, current} <- observe_guard(config, record, sandbox, opts) do
      updated = %{current | metadata: Map.merge(current.metadata, record.metadata)}
      if updated.metadata == current.metadata, do: {:ok, current}, else: persist(config, updated, sandbox, [], opts)
    end
  end

  defp release(config, record, sandbox, pod, q, opts) do
    with {:ok, objects} <- inventory(config, opts),
         {:ok, record} <- capture_storage(record, sandbox, objects, q),
         true <-
           Enum.all?(get_in(q, ["template", "spec", "volumeClaimTemplates"]) || [], fn claim ->
             Enum.any?(objects["persistentvolumeclaims"], &(name(&1) == get_in(claim, ["metadata", "name"]) <> "-" <> name(sandbox)))
           end) do
      record_release(config, record, sandbox, pod, q, opts)
    else
      false -> {:error, {:retryable, :kubernetes_waiting_for_qualified_claims}}
      error -> error
    end
  end

  defp record_release(config, record, sandbox, pod, q, opts) do
    pod_uid = uid(pod)
    reference = %{"name" => name(pod), "uid" => pod_uid, "resourceVersion" => rv(pod)}
    metadata = record.metadata |> Map.update("authorized_pod_uids", [pod_uid], &Enum.uniq([pod_uid | &1])) |> Map.update("authorized_pods", %{pod_uid => reference}, &Map.put(&1, pod_uid, reference))
    record = %{record | metadata: metadata, pending: [%{verb: :start, id: pod_uid, outcome: :pending}]}

    with :ok <- Guard.open(config, record, opts),
         {:ok, saved} <- persist(config, record, sandbox, [], opts),
         {:ok, current} <- fetch_parent(config, saved, opts),
         {:ok, observed} <- observe_guard(config, saved, current, opts),
         true <- rv(current) == saved.version and running_intent?(observed, current),
         :ok <- Guard.open(config, saved, opts),
         :ok <- safe_live_pod(pod, q),
         index when is_integer(index) <- Enum.find_index(get_in(pod, ["spec", "schedulingGates"]) || [], &(&1["name"] == @gate)),
         {:ok, _} <-
           api(
             config,
             :patch,
             object_path(config, "pods", pod),
             cas(pod) ++ [%{"op" => "test", "path" => "/spec/schedulingGates/#{index}/name", "value" => @gate}, %{"op" => "remove", "path" => "/spec/schedulingGates/#{index}"}],
             opts
           ) do
      {:ok, %{saved | pending: [%{verb: :start, id: pod_uid, outcome: :succeeded}]}}
    else
      _ ->
        pending = [%{verb: :start, id: pod_uid, outcome: :unknown}]
        {:error, {:unknown, :kubernetes_release_outcome}, %{record | pending: pending}}
    end
  end

  defp running_intent?(record, sandbox) do
    get_in(sandbox, ["spec", "operatingMode"]) == "Running" and record.desired == :running and
      get_in(sandbox, ["spec", "creationControl", "closeRequestId"]) == nil
  end

  defp safe_live_pod(pod, q) do
    spec = pod["spec"] || %{}

    valid =
      admitted_profile?(pod, q) and spec["schedulerName"] == "default-scheduler" and
        spec["nodeName"] in [nil, ""] and spec["automountServiceAccountToken"] == false and
        spec["enableServiceLinks"] == false and spec["restartPolicy"] == "Never" and not unsafe_pod?(spec)

    if valid, do: :ok, else: {:error, {:invalid, :unsafe_admitted_pod}}
  end

  defp admitted_profile?(pod, q) do
    blueprint = get_in(q, ["template", "spec", "podTemplate"])

    get_in(pod, ["metadata", "labels", q["network_profile_label"]]) ==
      get_in(blueprint, ["metadata", "labels", q["network_profile_label"]]) and
      get_in(pod, ["spec", "runtimeClassName"]) == get_in(blueprint, ["spec", "runtimeClassName"])
  end

  defp replacement_safe(record, pods) do
    evidence = Map.get(record.metadata, "termination_evidence", %{})
    unresolved = Enum.reject(Map.get(record.metadata, "authorized_pod_uids", []), &termination_proof?(evidence[&1], &1, record))

    if unresolved == [] or (length(pods) == 1 and unresolved == [uid(hd(pods))]) do
      :ok
    else
      {:error, {:unknown, :previous_pod_termination_unresolved}}
    end
  end

  defp stop_fences(config, record, pods, q, opts) do
    Enum.reduce_while(pods, {:ok, record}, fn pod, {:ok, current} ->
      case stop_fence(config, current, pod, q, opts) do
        {:ok, saved} -> {:cont, {:ok, saved}}
        error -> {:halt, error}
      end
    end)
  end

  defp stop_fence(config, record, pod, q, opts) do
    annotations = get_in(pod, ["metadata", "annotations"]) || %{}
    annotations = Map.put(annotations, "symphony.dev/stop-fence", rv_from_record(record))
    patch = cas(pod) ++ [%{"op" => "add", "path" => "/metadata/annotations", "value" => annotations}]

    with {:ok, sandbox} <- fetch_parent(config, record, opts),
         :ok <- child_ownership(pod, record, sandbox),
         {:ok, fenced} <- api(config, :patch, object_path(config, "pods", pod), patch, opts),
         current = record_fence(record, fenced, q),
         {:ok, saved} <- persist(config, current, sandbox, [], opts),
         :ok <- delete(config, "pods", fenced, opts),
         do: {:ok, saved}
  end

  defp record_fence(record, fenced, q) do
    kind =
      cond do
        gated?(fenced) and safe_live_pod(fenced, q) == :ok -> "never_released"
        kubelet_terminated?(fenced) -> "kubelet_terminated"
        true -> nil
      end

    record = if kind, do: save_evidence(record, uid(fenced), pod_evidence(fenced, kind, q)), else: record
    ref = %{"name" => name(fenced), "uid" => uid(fenced), "resourceVersion" => rv(fenced)}
    refs = Map.put(Map.get(record.metadata, "authorized_pods", %{}), uid(fenced), ref)
    metadata = record.metadata |> Map.put("authorized_pods", refs)
    metadata = Map.update(metadata, "authorized_pod_uids", [uid(fenced)], &Enum.uniq([uid(fenced) | &1]))
    %{record | metadata: metadata}
  end

  defp pod_evidence(pod, kind, q),
    do: %{"kind" => kind, "uid" => uid(pod), "resourceVersion" => rv(pod), "qualification_uid" => q["uid"]}

  defp collect_termination(config, record, q, opts) do
    Enum.reduce_while(Map.get(record.metadata, "authorized_pods", %{}), {:ok, record}, fn ref, {:ok, current} ->
      {:cont, {:ok, collect_pod_termination(config, current, ref, q, opts)}}
    end)
  end

  defp collect_pod_termination(config, record, {pod_uid, ref}, q, opts) do
    if termination_proof?(get_in(record.metadata, ["termination_evidence", pod_uid]), pod_uid, record) do
      record
    else
      case Client.watch(config, collection(config, "pods"), ref["name"], ref["resourceVersion"], opts) do
        {:ok, events} -> observe_termination(record, events, pod_uid, q)
        {:error, _} -> record
      end
    end
  end

  defp observe_termination(record, events, pod_uid, q) do
    proof =
      Enum.find_value(events, fn event ->
        pod = event["object"]
        if uid(pod) == pod_uid and kubelet_terminated?(pod), do: pod_evidence(pod, "kubelet_terminated", q)
      end)

    if proof, do: save_evidence(record, pod_uid, proof), else: record
  end

  defp kubelet_terminated?(pod) when is_map(pod) do
    status = pod["status"] || %{}
    spec = pod["spec"] || %{}
    containers = all_containers(spec, ["containers", "initContainers", "ephemeralContainers"])
    states = all_containers(status, ["containerStatuses", "initContainerStatuses", "ephemeralContainerStatuses"])

    # Attribution is the status subresource itself, not the field manager's name: the
    # manager string is chosen by the writer, while admission restricts pods/status to
    # the assigned node. Distributions name it differently (k3s embeds the kubelet and
    # writes "k3s"), so pinning the name only makes terminal status unprovable there.
    reported = Enum.any?(get_in(pod, ["metadata", "managedFields"]) || [], &(&1["subresource"] == "status"))

    reported and status["phase"] in ["Succeeded", "Failed"] and containers != [] and
      Enum.all?(containers, &container_terminated?(&1, states))
  end

  defp all_containers(object, keys), do: Enum.flat_map(keys, &(object[&1] || []))

  defp container_terminated?(container, states) do
    state = Enum.find(states, &(&1["name"] == container["name"]))
    terminated = get_in(state || %{}, ["state", "terminated"]) || %{}

    is_binary(terminated["finishedAt"]) and is_binary(terminated["containerID"]) and
      terminated["containerID"] != "" and terminated["reason"] != "ContainerStatusUnknown"
  end

  defp capture_storage(record, sandbox, objects, q) do
    claims = Map.new(get_in(q, ["template", "spec", "volumeClaimTemplates"]) || [], &{get_in(&1, ["metadata", "name"]) <> "-" <> name(sandbox), &1})
    pvcs = Enum.filter(objects["persistentvolumeclaims"], &(Map.has_key?(claims, name(&1)) or child_candidate?(&1, record, sandbox)))
    known = Map.get(record.metadata, "volumes", %{})

    Enum.reduce_while(pvcs, {:ok, known}, fn pvc, {:ok, acc} ->
      pv = Enum.find(objects["persistentvolumes"], &(name(&1) == get_in(pvc, ["spec", "volumeName"])))

      with :ok <- child_ownership(pvc, record, sandbox),
           :ok <- validate_claim(pvc, claims[name(pvc)], acc[name(pvc)]),
           {:ok, volume} <- capture_volume(pvc, pv, acc[name(pvc)], q) do
        {:cont, {:ok, Map.put(acc, name(pvc), volume)}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, volumes} -> {:ok, %{record | metadata: Map.put(record.metadata, "volumes", volumes)}}
      error -> error
    end
  end

  defp validate_claim(pvc, claim, old) do
    cond do
      claim == nil or get_in(pvc, ["spec", "storageClassName"]) != get_in(claim, ["spec", "storageClassName"]) ->
        {:error, {:invalid, :unqualified_kubernetes_pvc}}

      old != nil and old["pvc_uid"] != uid(pvc) ->
        {:error, {:unknown, :retained_pvc_replaced}}

      true ->
        :ok
    end
  end

  defp capture_volume(pvc, nil, _old, _q) do
    if get_in(pvc, ["spec", "volumeName"]) in [nil, ""] do
      {:ok, %{"pvc_uid" => uid(pvc), "pvc_name" => name(pvc), "pvc_version" => rv(pvc), "unbound" => true}}
    else
      {:error, {:unknown, :bound_pv_missing}}
    end
  end

  defp capture_volume(pvc, pv, old, q) do
    cond do
      not qualified_volume?(pvc, pv, q) ->
        {:error, {:unknown, :csi_deletion_evidence_unavailable}}

      old != nil and old["pv_uid"] != nil and old["pv_uid"] != uid(pv) ->
        {:error, {:unknown, :retained_pv_replaced}}

      true ->
        volume = %{
          "pvc_uid" => uid(pvc),
          "pvc_name" => name(pvc),
          "pvc_version" => rv(pvc),
          "pv_uid" => uid(pv),
          "pv_name" => name(pv),
          "pv_version" => rv(pv),
          "claim_ref" => get_in(pv, ["spec", "claimRef"]),
          "volume_handle" => get_in(pv, ["spec", "csi", "volumeHandle"]),
          "csi_finalizer_observed" => true
        }

        {:ok, Map.merge(old || %{}, volume)}
    end
  end

  defp qualified_volume?(pvc, pv, q) do
    handle = get_in(pv, ["spec", "csi", "volumeHandle"])

    get_in(pv, ["spec", "claimRef", "uid"]) == uid(pvc) and
      get_in(pv, ["spec", "claimRef", "namespace"]) == get_in(pvc, ["metadata", "namespace"]) and
      get_in(pv, ["spec", "persistentVolumeReclaimPolicy"]) == "Delete" and
      get_in(pv, ["spec", "csi", "driver"]) == q["csi_driver"] and
      is_binary(handle) and handle != "" and @pv_finalizer in (get_in(pv, ["metadata", "finalizers"]) || [])
  end

  defp delete_children(config, record, sandbox, objects, _q, opts) do
    Enum.reduce_while(@children, {:ok, record}, fn resource, {:ok, current} ->
      delete_owned_children(config, current, sandbox, resource, objects[resource], opts)
      |> case do
        :ok -> {:cont, {:ok, current}}
        error -> {:halt, error}
      end
    end)
  end

  defp delete_owned_children(config, record, sandbox, resource, items, opts) do
    Enum.reduce_while(children(items, record, sandbox), :ok, fn child, :ok ->
      with :ok <- child_ownership(child, record, sandbox),
           :ok <- delete(config, resource, child, opts) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp storage_deletion(config, record, q, opts) do
    volumes = Map.get(record.metadata, "volumes", %{})

    Enum.reduce_while(volumes, {:ok, record}, fn {key, volume}, {:ok, current} ->
      cond do
        volume["deleted"] == true ->
          {:cont, {:ok, current}}

        volume["pv_uid"] == nil ->
          case discharge_unbound(config, current, key, volume, opts) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            :unresolved -> {:halt, {:error, {:unknown, :unbound_pvc_provisioning_unresolved}, current}}
            error -> {:halt, error}
          end

        true ->
          {:cont, {:ok, observe_volume_deletion(config, current, key, volume, q, opts)}}
      end
    end)
  end

  # A claim that never bound has no backing volume whose deletion could ever be proven, so the
  # evidence path below can never discharge it and cleanup would retain the identity forever.
  # Prove the negative instead: the claim is authoritatively absent and no PersistentVolume
  # references its UID. A claim that bound after capture, or any read failure, stays unresolved.
  defp discharge_unbound(config, record, key, volume, opts) do
    with {:ok, claim} <- Client.lookup(config, collection(config, "persistentvolumeclaims"), volume["pvc_name"], opts),
         {:ok, provisioned} <- Client.list(config, collection(config, "persistentvolumes"), opts) do
      claimed? = Enum.any?(provisioned, &(get_in(&1, ["spec", "claimRef", "uid"]) == volume["pvc_uid"]))

      if is_nil(claim) and not claimed? do
        {:ok, %{record | metadata: put_in(record.metadata, ["volumes", key, "deleted"], true)}}
      else
        :unresolved
      end
    end
  end

  defp observe_volume_deletion(config, record, key, volume, q, opts) do
    case Client.watch(config, "/api/v1/persistentvolumes", volume["pv_name"], volume["pv_version"], opts) do
      {:ok, events} ->
        if Enum.any?(events, &volume_deleted?(&1, volume, q)) do
          metadata = put_in(record.metadata, ["volumes", key, "deleted"], true)
          %{record | metadata: metadata}
        else
          record
        end

      _ ->
        record
    end
  end

  defp volume_deleted?(event, volume, q) do
    pv = event["object"]

    event["type"] == "DELETED" and uid(pv) == volume["pv_uid"] and volume["csi_finalizer_observed"] == true and
      @pv_finalizer not in (get_in(pv, ["metadata", "finalizers"]) || []) and
      get_in(pv, ["spec", "csi", "volumeHandle"]) == volume["volume_handle"] and
      get_in(pv, ["spec", "csi", "driver"]) == q["csi_driver"] and
      get_in(pv, ["spec", "claimRef", "uid"]) == volume["pvc_uid"]
  end

  defp existing_secret_ownership(_config, nil, _record, _sandbox, _opts), do: :ok
  defp existing_secret_ownership(config, secret, record, sandbox, opts), do: guarded_secret(config, secret, record, sandbox, opts)

  defp guarded_secret(config, secret, record, sandbox, opts) do
    with :ok <- child_ownership(secret, record, sandbox),
         {:ok, guard} <- Guard.fetch(config, record, opts),
         {:ok, guard} <- Guard.settle(config, record, guard, opts),
         true <- Enum.any?(guard.data["operations"], &(&1["resource"] == "secrets" and &1["state"] == "Committed" and Guard.matches?(secret, &1))) do
      :ok
    else
      false -> {:error, {:unknown, :kubernetes_create_attribution_conflict}}
      error -> error
    end
  end

  defp journaled_pod?(sandbox, pod) do
    journal = get_in(sandbox, ["status", "creationJournal"]) || %{}

    journal["parentUID"] == uid(sandbox) and is_list(journal["operations"]) and
      Enum.any?(
        journal["operations"],
        &(valid_controller_operation?(&1, uid(sandbox), get_in(sandbox, ["metadata", "namespace"])) and
            &1["resource"] == "pods" and controller_attribution?(pod, &1))
      )
  end

  defp ensure_credentials(config, record, sandbox, q, opts) do
    with :ok <- Guard.open(config, record, opts),
         {:ok, secret} <- Client.lookup(config, collection(config, "secrets"), secret_name(record), opts),
         :ok <- existing_secret_ownership(config, secret, record, sandbox, opts) do
      case client_key_path(record, secret) do
        {:ok, _} ->
          {:ok, record}

        _ ->
          rotate_after_stop(config, record, sandbox, secret, q, opts)
      end
    end
  end

  defp rotate_after_stop(config, record, sandbox, secret, q, opts) do
    case wait_credential_stop(config, record, sandbox, q, opts) do
      {:ok, observed, current} -> stage_credentials(config, observed, current, secret, opts)
      _ -> {:error, {:unknown, :client_key_rotation_requires_stop}}
    end
  end

  defp wait_credential_stop(config, record, sandbox, q, opts) do
    with {:ok, record} <- observe_guard(config, record, sandbox, opts),
         {:ok, pods} <- Client.list(config, collection(config, "pods"), opts),
         :ok <- owned_pods(pods, record, sandbox),
         {:ok, record} <- capture_pod_obligations(record, sandbox, pods, q),
         {:ok, record} <- save_observation(config, record, opts),
         {:ok, sandbox} <- fetch_parent(config, record, opts) do
      observed = normalize(record, sandbox, children(pods, record, sandbox), Map.get(record.metadata, "termination_evidence", %{}))

      cond do
        observed.phase == :stopped ->
          {:ok, observed, sandbox}

        get_in(sandbox, ["spec", "operatingMode"]) != "Suspended" or opts[:deadline] <= System.monotonic_time(:millisecond) ->
          {:error, {:unknown, :client_key_rotation_requires_stop}}

        true ->
          wait_next_credential_stop(config, record, q, opts)
      end
    end
  end

  defp wait_next_credential_stop(config, record, q, opts) do
    pause(opts)

    with {:ok, current} <- fetch_parent(config, record, opts),
         do: wait_credential_stop(config, record, current, q, opts)
  end

  defp stage_credentials(config, record, sandbox, secret, opts) do
    with {:ok, directory, lease} <- Client.private_directory(opts) do
      metadata = Map.merge(record.metadata, %{"client_key_directory" => directory, "client_key_lease" => lease})
      rotate_credentials(config, %{record | metadata: metadata}, sandbox, secret, directory, opts)
    end
  end

  defp rotate_credentials(config, record, sandbox, secret, directory, opts) do
    command = Keyword.get(opts, :command_fun, &Command.run/3)
    client = Path.join(directory, "client")
    host = Path.join(directory, "host")

    result =
      with {:ok, %{status: 0}} <- generate_key(command, client, opts),
           {:ok, public} <- File.read(client <> ".pub"),
           {:ok, data} <- host_data(secret, host, command, opts) do
        data = Map.put(data, "authorized_keys", Base.encode64(public))

        with {:ok, _} <- save_credentials(config, record, sandbox, secret, data, opts),
             do: {:ok, %{record | metadata: Map.put(record.metadata, "client_key_directory", directory)}}
      end

    File.rm(host)
    File.rm(host <> ".pub")

    case result do
      {:ok, _} ->
        result

      _ ->
        cleanup_client_key(record)
        {:error, {:unknown, :kubernetes_credentials_outcome}}
    end
  end

  defp generate_key(command, path, opts) do
    args = ["-q", "-t", "ed25519", "-N", "", "-f", path]
    command.(System.find_executable("ssh-keygen") || "ssh-keygen", args, command_options(opts))
  end

  defp save_credentials(config, record, sandbox, nil, data, opts) do
    metadata = %{
      "name" => secret_name(record),
      "namespace" => config.provider["namespace"],
      "ownerReferences" => [owner_reference(sandbox)]
    }

    body = %{"apiVersion" => "v1", "kind" => "Secret", "metadata" => stamp(metadata, record)}
    body = Map.merge(body, %{"type" => "Opaque", "data" => data})
    Guard.create(config, record, "secrets", body, opts)
  end

  defp save_credentials(config, record, sandbox, secret, data, opts) do
    patch = cas(secret) ++ [%{"op" => "add", "path" => "/data", "value" => data}]

    with :ok <- Guard.open(config, record, opts),
         :ok <- guarded_secret(config, secret, record, sandbox, opts),
         do: api(config, :patch, object_path(config, "secrets", secret), patch, opts)
  end

  defp host_data(nil, path, command, opts) do
    with {:ok, %{status: 0}} <- generate_key(command, path, opts),
         {:ok, private} <- File.read(path),
         {:ok, public} <- File.read(path <> ".pub") do
      {:ok, %{"ssh_host_ed25519_key" => Base.encode64(private), "ssh_host_ed25519_key.pub" => Base.encode64(public)}}
    end
  end

  defp host_data(secret, _path, _command, _opts) do
    with {:ok, _} <- secret_value(secret, "ssh_host_ed25519_key.pub"), {:ok, _} <- secret_value(secret, "ssh_host_ed25519_key"), do: {:ok, secret["data"]}
  end

  defp secret_value(secret, key) do
    case get_in(secret || %{}, ["data", key]) do
      value when is_binary(value) -> Base.decode64(value)
      _ -> {:error, {:unknown, :kubernetes_ssh_secret_missing}}
    end
  end

  defp client_key_path(record, secret) do
    with path when is_binary(path) <- record.metadata["client_key_directory"],
         {:ok, public} <- File.read(Path.join(path, "client.pub")),
         {:ok, authorized} <- secret_value(secret, "authorized_keys"),
         true <- public == authorized,
         key = Path.join(path, "client"),
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(key),
         true <- Bitwise.band(mode, 0o777) == 0o600 do
      {:ok, key}
    else
      _ -> {:error, {:unknown, :kubernetes_client_key_missing}}
    end
  end

  defp connect_private(config, record, pod, host_public, key, directory, opts) do
    alias_name = "symphony-" <> digest(record.provider_ref)
    hosts = Path.join(directory, "known_hosts")
    address = get_in(pod, ["status", "podIP"])
    public = host_public |> String.split() |> Enum.take(2) |> Enum.join(" ")

    result =
      with true <- private_address?(address),
           true <- String.starts_with?(public, "ssh-ed25519 "),
           :ok <- Client.write_private(hosts, alias_name <> " " <> public <> "\n") do
        prefix = [
          "-F",
          "/dev/null",
          "-T",
          "-o",
          "BatchMode=yes",
          "-o",
          "StrictHostKeyChecking=yes",
          "-o",
          "IdentitiesOnly=yes",
          "-o",
          "ForwardAgent=no",
          "-o",
          "GlobalKnownHostsFile=/dev/null",
          "-o",
          "UserKnownHostsFile=" <> hosts,
          "-o",
          "HostKeyAlias=" <> alias_name,
          "-o",
          "ConnectTimeout=10",
          "-i",
          key,
          "-p",
          to_string(config.provider["ssh_port"]),
          "-l",
          config.provider["ssh_user"],
          address
        ]

        target = %Target{executable: System.find_executable("ssh") || "ssh", prefix: prefix, label: record.key}
        command = Keyword.get(opts, :command_fun, &Command.run/3)
        paths = [private_paths: [directory], staged_paths: record.metadata["client_key_lease"]]

        with {:ok, %{status: 0}} <- command.(target.executable, prefix ++ ["true"], command_options(opts)),
             {:ok, connection} <- Operations.open_connection(opts[:task_supervisor], opts[:authority], target, paths) do
          {:ok, connection}
        else
          _ -> {:error, {:unknown, :kubernetes_ssh_authentication_failed}}
        end
      end

    case result do
      {:ok, _} ->
        result

      _ ->
        {:error, {:unknown, :kubernetes_ssh_authentication_failed}}
    end
  end

  defp private_address?(address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, second, _, _}} when second in 16..31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {first, _, _, _, _, _, _, _}} when first in 0xFC00..0xFDFF -> true
      _ -> false
    end
  end

  defp private_address?(_), do: false

  defp cleanup_client_key(record) do
    case record.metadata["client_key_lease"] do
      nil -> :ok
      lease -> Operations.release_staged_paths(lease)
    end

    case record.metadata["client_key_directory"] do
      directory when is_binary(directory) -> File.rm_rf(directory)
      _ -> :ok
    end
  end

  defp inventory(config, opts) do
    Enum.reduce_while(["sandboxes" | @children] ++ ["persistentvolumes", "configmaps"], {:ok, %{}}, fn resource, {:ok, objects} ->
      case Client.list(config, collection(config, resource), opts) do
        {:ok, items} -> {:cont, {:ok, Map.put(objects, resource, items)}}
        error -> {:halt, error}
      end
    end)
  end

  defp fetch_parent(config, record, opts) do
    with {:ok, sandbox} when is_map(sandbox) <- Client.lookup(config, collection(config, "sandboxes"), record.key, opts),
         :ok <- ownership(sandbox, record) do
      confirm_parent_guard(config, record, sandbox, opts)
    else
      {:ok, nil} -> {:error, {:unknown, :kubernetes_parent_missing}}
      error -> error
    end
  end

  defp confirm_parent_guard(config, record, sandbox, opts) do
    with {:ok, guard} <- Guard.fetch(config, record, opts),
         {:ok, guard} <- Guard.settle(config, record, guard, opts),
         :ok <- guarded_parent(guard, sandbox) do
      {:ok, sandbox}
    else
      {:error, reason} -> physical_error_result(reason, record, sandbox)
    end
  end

  defp parent(objects, record) do
    case Enum.find(objects["sandboxes"], &(name(&1) == record.key)) do
      nil -> {:error, {:unknown, :kubernetes_parent_missing}}
      sandbox -> with :ok <- ownership(sandbox, record), do: {:ok, sandbox}
    end
  end

  defp ownership(object, record), do: if(owned?(object, record), do: :ok, else: {:error, {:unknown, :kubernetes_ownership_changed}})

  defp owned?(object, record) do
    labels = get_in(object || %{}, ["metadata", "labels"]) || %{}

    case decode_annotation(object) do
      {:ok, fields, _lifecycle} ->
        identity = [:key, :deployment_id, :tracker_kind, :issue_id, :kind, :scope, :workspace_path, :template_identity]
        same_uid = record.provider_ref == nil or uid(object) == record.provider_ref

        labels == Map.merge(labels, identity_labels(record)) and same_uid and
          Enum.all?(identity, &(fields[Atom.to_string(&1)] == Map.fetch!(record, &1)))

      _ ->
        false
    end
  end

  defp children(items, record, sandbox), do: Enum.filter(items, &child_candidate?(&1, record, sandbox))

  defp child_candidate?(item, record, sandbox) do
    labels = get_in(item, ["metadata", "labels"]) || %{}
    labels["symphony.dev/environment"] == record.key or Enum.any?(get_in(item, ["metadata", "ownerReferences"]) || [], &(&1["uid"] == uid(sandbox)))
  end

  defp child_ownership(child, record, sandbox) when is_map(child) do
    refs = get_in(child, ["metadata", "ownerReferences"]) || []

    if Enum.any?(refs, &(&1["uid"] == uid(sandbox) and &1["kind"] == "Sandbox")) and
         get_in(child, ["metadata", "labels", "symphony.dev/environment"]) in [nil, record.key], do: :ok, else: {:error, {:unknown, :kubernetes_child_ownership_changed}}
  end

  defp child_ownership(_, _, _), do: {:error, {:unknown, :kubernetes_child_missing}}

  defp template_identity(record, q) do
    identity = [
      {"template_uid", "template_uid"},
      {"template_digest", "template_digest"},
      {"qualification_uid", "uid"}
    ]

    if Enum.all?(identity, fn {saved, qualified} -> record.metadata[saved] in [nil, q[qualified]] end), do: :ok, else: {:error, {:invalid, :retained_template_changed}}
  end

  defp persist(config, record, sandbox, extra, opts) do
    with {:ok, guard} <- Guard.save(config, record, encode_record(record), opts),
         {:ok, durable} <- decode_guard_record(guard.data, config) do
      durable = %{durable | metadata: Map.merge(durable.metadata, Map.take(record.metadata, ["client_key_directory", "client_key_lease"]))}
      annotations = Map.put(get_in(sandbox, ["metadata", "annotations"]) || %{}, @state, encode_record(durable))
      patch = cas(sandbox) ++ [%{"op" => "add", "path" => "/metadata/annotations", "value" => annotations}] ++ extra

      case api(config, :patch, object_path(config, "sandboxes", sandbox), patch, opts) do
        {:ok, updated} -> {:ok, bind_parent(durable, updated)}
        error -> confirm_persist(config, durable, sandbox, annotations, extra, error, opts)
      end
    end
  end

  # kubectl reports a failed JSON-Patch precondition as 422 prose with an empty body, so the
  # transport cannot classify it and conservatively returns unknown. Read back before believing
  # that: our own exact state annotation proves a lost response, and a parent that moved without
  # it proves the atomic patch never applied. Anything less certain stays unknown.
  defp confirm_persist(config, durable, sandbox, annotations, extra, error, opts) do
    case Client.lookup(config, collection(config, "sandboxes"), name(sandbox), opts) do
      {:ok, observed} when is_map(observed) ->
        cond do
          uid(observed) != uid(sandbox) -> error
          persisted_intent?(observed, annotations, extra) -> {:ok, bind_parent(durable, observed)}
          rv(observed) != rv(sandbox) -> {:error, {:retryable, :kubernetes_cas_conflict}}
          true -> error
        end

      _ ->
        error
    end
  end

  defp persisted_intent?(observed, annotations, extra) do
    get_in(observed, ["metadata", "annotations", @state]) == annotations[@state] and
      Enum.all?(extra, fn
        %{"op" => "add", "path" => path, "value" => value} -> get_in(observed, String.split(path, "/", trim: true)) == value
        _ -> false
      end)
  end

  defp durable_metadata(metadata), do: Map.drop(metadata, ["client_key_directory", "client_key_lease"])

  defp bind_parent(record, sandbox), do: %{record | provider_ref: uid(sandbox), version: rv(sandbox)}

  defp guard_record(config, record, guard, sandbox) do
    with {:ok, saved} <- decode_guard_record(guard.data, config) do
      saved = %{saved | metadata: Map.merge(saved.metadata, Map.take(record.metadata, ["client_key_directory", "client_key_lease"]))}
      {:ok, bind_parent(saved, sandbox)}
    end
  end

  defp observe_guard(config, record, sandbox, opts) do
    with {:ok, guard} <- Guard.fetch(config, record, opts),
         {:ok, guard} <- Guard.settle(config, record, guard, opts),
         :ok <- guarded_parent(guard, sandbox),
         do: guard_record(config, record, guard, sandbox)
  end

  defp encode_record(record) do
    record
    |> Map.from_struct()
    |> Map.take([
      :key,
      :deployment_id,
      :tracker_kind,
      :issue_id,
      :kind,
      :scope,
      :workspace_path,
      :template_identity,
      :desired,
      :pending,
      :attempt_id,
      :issue_identifier,
      :issue_state,
      :terminal_observed_at,
      :metadata
    ])
    |> Map.update!(:metadata, &durable_metadata/1)
    |> Jason.encode!()
  end

  defp decode_record(object, config) do
    with {:ok, fields, lifecycle} <- decode_annotation(object),
         true <- fields["deployment_id"] == config.deployment_id and fields["scope"] == Config.scope(config) and fields["kind"] == "kubernetes",
         true <- Enum.all?(["key", "tracker_kind", "issue_id", "workspace_path"], &is_binary(fields[&1])) do
      record = %Record{
        key: fields["key"],
        deployment_id: fields["deployment_id"],
        tracker_kind: fields["tracker_kind"],
        issue_id: fields["issue_id"],
        kind: "kubernetes",
        scope: fields["scope"],
        workspace_path: fields["workspace_path"],
        template_identity: fields["template_identity"]
      }

      {:ok, struct!(record, lifecycle)}
    else
      _ -> {:error, {:unknown, :kubernetes_record_invalid}}
    end
  end

  defp decode_annotation(object) do
    with {:ok, fields} when is_map(fields) <- Jason.decode(get_in(object || %{}, ["metadata", "annotations", @state]) || ""),
         {:ok, desired} <- enum(fields["desired"], [:running, :stopped, :absent]),
         {:ok, pending} <- decode_pending(fields["pending"]),
         true <- is_map(fields["metadata"]),
         true <- Enum.all?(~w(attempt_id issue_identifier issue_state), &(is_nil(fields[&1]) or is_binary(fields[&1]))),
         true <- is_nil(fields["terminal_observed_at"]) or is_integer(fields["terminal_observed_at"]) do
      lifecycle = %{
        desired: desired,
        pending: pending,
        metadata: durable_metadata(fields["metadata"]),
        attempt_id: fields["attempt_id"],
        issue_identifier: fields["issue_identifier"],
        issue_state: fields["issue_state"],
        terminal_observed_at: fields["terminal_observed_at"]
      }

      {:ok, fields, lifecycle}
    else
      _ -> {:error, {:unknown, :kubernetes_record_invalid}}
    end
  end

  defp decode_pending(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn item, {:ok, acc} ->
      with true <- is_map(item) and map_size(item) == 3 and Map.has_key?(item, "id"),
           {:ok, verb} <- enum(item["verb"], @verbs),
           {:ok, outcome} <- enum(item["outcome"], @outcomes),
           true <- is_nil(item["id"]) or is_binary(item["id"]) do
        {:cont, {:ok, [%{verb: verb, id: item["id"], outcome: outcome} | acc]}}
      else
        _ -> {:halt, {:error, {:unknown, :kubernetes_record_invalid}}}
      end
    end)
    |> case do
      {:ok, pending} -> {:ok, Enum.reverse(pending)}
      error -> error
    end
  end

  defp decode_pending(_), do: {:error, {:unknown, :kubernetes_record_invalid}}

  defp enum(value, allowed) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_enum}
      atom -> {:ok, atom}
    end
  end

  defp stamp(metadata, record),
    do:
      metadata
      |> Map.update("labels", identity_labels(record), &Map.merge(&1, identity_labels(record)))
      |> Map.update("annotations", %{@state => encode_record(record)}, &Map.put(&1, @state, encode_record(record)))

  defp identity_labels(record),
    do: %{
      "symphony.dev/deployment" => digest(record.deployment_id),
      "symphony.dev/environment" => record.key,
      "symphony.dev/issue" => digest(record.issue_id),
      "symphony.dev/tracker" => record.tracker_kind
    }

  defp owner_reference(sandbox), do: %{"apiVersion" => @api, "kind" => "Sandbox", "name" => name(sandbox), "uid" => uid(sandbox), "controller" => true, "blockOwnerDeletion" => true}
  defp cas(object), do: [%{"op" => "test", "path" => "/metadata/uid", "value" => uid(object)}, %{"op" => "test", "path" => "/metadata/resourceVersion", "value" => rv(object)}]

  defp delete(config, resource, object, opts) do
    body = %{"apiVersion" => "v1", "kind" => "DeleteOptions", "preconditions" => %{"uid" => uid(object), "resourceVersion" => rv(object)}, "propagationPolicy" => "Foreground"}
    with {:ok, _} <- api(config, :delete, object_path(config, resource, object), body, opts), do: :ok
  end

  defp api(config, method, path, body, opts) do
    case Client.request(config, method, path, body, opts) do
      {:ok, %{status: status, body: value}} when status in 200..299 -> {:ok, value}
      {:ok, %{status: status}} when status in [401, 403] -> {:error, {:denied, :kubernetes_api}}
      {:ok, %{status: 409}} -> {:error, {:retryable, :kubernetes_cas_conflict}}
      {:ok, _} -> {:error, {:unknown, :kubernetes_api_outcome}}
      error -> error
    end
  end

  defp collection(config, "sandboxes"), do: "/apis/#{@api}/namespaces/#{segment(config.provider["namespace"])}/sandboxes"
  defp collection(config, "sandboxtemplates"), do: "/apis/#{@extensions}/namespaces/#{segment(config.provider["namespace"])}/sandboxtemplates"
  defp collection(_config, "persistentvolumes"), do: "/api/v1/persistentvolumes"
  defp collection(config, resource), do: "/api/v1/namespaces/#{segment(config.provider["namespace"])}/#{resource}"
  defp object_path(config, resource, object), do: collection(config, resource) <> "/" <> segment(name(object))
  defp segment(value) when is_binary(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp uid(object), do: get_in(object || %{}, ["metadata", "uid"])
  defp rv(object), do: get_in(object || %{}, ["metadata", "resourceVersion"])
  defp name(object), do: get_in(object || %{}, ["metadata", "name"])
  defp rv_from_record(record), do: to_string(record.version)
  defp secret_name(record), do: record.key <> "-ssh"
  defp digest(value), do: :crypto.hash(:sha256, Jason.encode!(canonical(value))) |> Base.encode16(case: :lower) |> binary_part(0, 40)
  defp canonical(map) when is_map(map), do: map |> Enum.map(fn {key, value} -> [key, canonical(value)] end) |> Enum.sort()
  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
  defp gated?(pod), do: get_in(pod, ["spec", "nodeName"]) in [nil, ""] and Enum.any?(get_in(pod, ["spec", "schedulingGates"]) || [], &(&1["name"] == @gate))
  defp blueprint_gated?(sandbox), do: Enum.any?(get_in(sandbox, ["spec", "podTemplate", "spec", "schedulingGates"]) || [], &(&1["name"] == @gate))

  defp condition?(sandbox, type),
    do: Enum.any?(get_in(sandbox, ["status", "conditions"]) || [], &(&1["type"] == type and &1["status"] == "True" and &1["observedGeneration"] == get_in(sandbox, ["metadata", "generation"])))

  defp ready_pod?(pod),
    do:
      get_in(pod, ["status", "phase"]) == "Running" and get_in(pod, ["metadata", "deletionTimestamp"]) == nil and
        Enum.any?(get_in(pod, ["status", "conditions"]) || [], &(&1["type"] == "Ready" and &1["status"] == "True"))

  defp save_evidence(record, pod_uid, proof), do: %{record | metadata: Map.update(record.metadata, "termination_evidence", %{pod_uid => proof}, &Map.put(&1, pod_uid, proof))}

  defp termination_proof?(proof, pod_uid, record) when is_map(proof),
    do:
      proof["kind"] in ["kubelet_terminated", "never_released"] and proof["uid"] == pod_uid and is_binary(proof["resourceVersion"]) and proof["qualification_uid"] != nil and
        proof["qualification_uid"] == record.metadata["qualification_uid"]

  defp termination_proof?(_, _, _), do: false
  defp result(_record, {:ok, _} = result), do: result
  defp result(_record, {:error, _, %Record{}} = result), do: result

  defp result(record, {:error, failure}),
    do: {:error, failure, %{record | proof: :unknown, phase: :unknown, absent?: false}}
end
