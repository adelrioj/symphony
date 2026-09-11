defmodule SymphonyElixir.ExecutionEnvironment.Kubernetes do
  @moduledoc "Direct, permanently gated Agent Sandbox v1.0.1 environments. Qualification is operator-owned, never worker input."
  @behaviour SymphonyElixir.ExecutionEnvironment

  alias SymphonyElixir.ExecutionEnvironment.{Command, Config, Connection, Operations, Record}
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Client
  alias SymphonyElixir.SSH.Target

  @api "agents.x-k8s.io/v1beta1"
  @extensions "extensions.agents.x-k8s.io/v1beta1"
  @gate "symphony.dev/start-authorized"
  @finalizer "symphony.dev/environment-cleanup"
  @state "symphony.dev/record"
  @qualification "symphony.dev/qualification"
  @pv_finalizer "external-provisioner.volume.kubernetes.io/finalizer"
  @children ["pods", "persistentvolumeclaims", "services", "secrets"]

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

    with :ok <- validate_config(config.provider),
         {:ok, _} <- qualification(config, opts),
         {:ok, _} <- inventory(config, opts),
         do: {:error, {:unknown, :kubernetes_controller_cleanup_ordering_unproven}}
  end

  @spec discover(map(), keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  def discover(config, opts) do
    opts = with_deadline(opts)

    with {:ok, objects} <- inventory(config, opts) do
      (objects["sandboxes"] ++ Enum.flat_map(@children, &objects[&1]))
      |> Enum.filter(&(get_in(&1, ["metadata", "labels", "symphony.dev/deployment"]) == digest(config.deployment_id)))
      |> Enum.reduce_while({:ok, %{}}, &discover_object(&1, &2, objects, config))
      |> case do
        {:ok, records} -> {:ok, Map.values(records)}
        error -> error
      end
    end
  end

  defp discover_object(object, {:ok, records}, objects, config) do
    with {:ok, record} <- decode_record(object, config),
         {:ok, observed} <- discovered_parent(record, objects["sandboxes"]) do
      {:cont, {:ok, Map.put(records, record.key, observed)}}
    else
      {:error, {:unknown, :kubernetes_ownership_changed}} = error ->
        {:halt, error}

      _ ->
        resource_ids = Enum.filter([name(object), uid(object)], &is_binary/1)
        {:halt, {:error, {:unknown, {:kubernetes_invalid_owned_record, resource_ids}}}}
    end
  end

  defp discovered_parent(record, parents) do
    case Enum.find(parents, &(name(&1) == record.key)) do
      nil ->
        metadata = Map.put(record.metadata, "orphaned", true)
        {:ok, %{record | metadata: metadata, proof: :unknown, phase: :unknown}}

      parent ->
        with :ok <- ownership(parent, record), do: {:ok, observe(record, parent)}
    end
  end

  @spec ensure(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
  def ensure(config, record, opts) do
    opts = with_deadline(opts)

    result =
      with {:ok, q} <- qualification(config, opts),
           {:ok, existing} <- Client.lookup(config, collection(config, "sandboxes"), record.key, opts),
           {:ok, objects} <- inventory(config, opts) do
        ensure_observed(config, record, existing, objects, q, opts)
      end

    result(record, result)
  end

  defp ensure_observed(config, record, existing, objects, q, opts) do
    cond do
      existing != nil ->
        with :ok <- ownership(existing, record),
             observed = observe(record, existing),
             :ok <- template_identity(observed, q),
             do: {:ok, observed}

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
      {:ok, sandbox} -> inspect_parent(config, record, sandbox, objects, q, opts)
      {:error, {:unknown, :kubernetes_parent_missing}} -> inspect_denied_create(record, objects, q)
      error -> error
    end
  end

  defp inspect_parent(config, record, sandbox, objects, q, opts) do
    with :ok <- owned_pods(objects["pods"], record, sandbox),
         {:ok, record} <- capture_storage(observe(record, sandbox), sandbox, objects, q),
         {:ok, record} <- inspect_termination(config, record, q, opts),
         {:ok, record} <- save_observation(config, record, opts) do
      pods = children(objects["pods"], record, sandbox)
      evidence = Map.get(record.metadata, "termination_evidence", %{})
      {:ok, normalize(record, sandbox, pods, evidence)}
    end
  end

  @spec put_intent(map(), Record.t(), map(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
  def put_intent(config, record, intent, opts) do
    opts = with_deadline(opts)

    updated =
      Enum.reduce([:desired, :attempt_id, :issue_state, :terminal_observed_at], record, fn key, acc ->
        if Map.has_key?(intent, key), do: Map.put(acc, key, intent[key]), else: acc
      end)

    result =
      with {:ok, sandbox} <- fetch_parent(config, record, opts),
           true <- record.version == nil or record.version == rv(sandbox) do
        persist(config, updated, sandbox, [], opts)
      else
        false -> {:error, {:retryable, :kubernetes_cas_conflict}}
        {:error, {:unknown, :kubernetes_parent_missing}} -> inspect(config, updated, opts)
        error -> error
      end

    result(updated, result)
  end

  @spec start(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
  def start(config, record, opts) do
    opts = with_deadline(opts)

    result =
      with {:ok, q} <- qualification(config, opts),
           {:ok, sandbox} <- fetch_parent(config, record, opts),
           true <- observe(record, sandbox).desired == :running and get_in(sandbox, ["metadata", "deletionTimestamp"]) == nil,
           {:ok, objects} <- inventory(config, opts),
           {:ok, record} <- capture_storage(observe(record, sandbox), sandbox, objects, q),
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
    with {:ok, sandbox} <- fetch_parent(config, record, opts),
         true <- observe(record, sandbox).desired == :running and get_in(sandbox, ["metadata", "deletionTimestamp"]) == nil do
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
           :ok <- child_ownership(secret, current, sandbox),
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
            inspect(config, %{record | desired: :stopped}, opts)

          error ->
            error
        end
      end

    cleanup_client_key(record)
    result(record, result)
  end

  defp stop_parent(config, record, sandbox, q, opts) do
    stopping = %{observe(record, sandbox) | desired: :stopped, phase: :stopping, proof: :unknown}

    with {:ok, stopped} <- persist(config, stopping, sandbox, [], opts),
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
    patch = [%{"op" => "add", "path" => "/spec/operatingMode", "value" => "Suspended"}]
    persist(config, record, sandbox, patch, opts)
  end

  @spec destroy(map(), Record.t(), keyword()) :: SymphonyElixir.ExecutionEnvironment.result()
  def destroy(config, record, opts) do
    opts = with_deadline(opts)

    result =
      with {:ok, q} <- qualification(config, opts),
           {:ok, stopped} <- stop(config, record, opts) do
        destroy_stopped(config, stopped, q, opts)
      end

    result(record, result)
  end

  defp destroy_stopped(_config, %{absent?: true, proof: {:quiescent, _}} = stopped, _q, _opts),
    do: {:ok, %{stopped | desired: :absent}}

  defp destroy_stopped(config, stopped, q, opts) do
    with true <- match?({:quiescent, _}, stopped.proof),
         {:ok, objects} <- inventory(config, opts),
         {:ok, sandbox} <- parent(objects, stopped),
         {:ok, captured} <- capture_storage(stopped, sandbox, objects, q),
         {:ok, deleting} <- persist(config, %{captured | desired: :absent, phase: :deleting}, sandbox, [], opts),
         {:ok, current} <- fetch_parent(config, deleting, opts),
         :ok <- delete(config, "sandboxes", current, opts),
         {:ok, current} <- fetch_parent(config, deleting, opts),
         true <- get_in(current, ["metadata", "deletionTimestamp"]) != nil,
         {:ok, objects} <- inventory(config, opts),
         {:ok, deleting} <- capture_storage(deleting, current, objects, q),
         {:ok, deleting} <- persist(config, deleting, current, [], opts),
         {:ok, deleting} <- delete_children(config, deleting, current, objects, q, opts),
         {:ok, deleting} <- storage_deletion(config, deleting, q, opts),
         {:ok, current} <- fetch_parent(config, deleting, opts),
         {:ok, saved} <- persist(config, deleting, current, [], opts),
         {:ok, final_objects} <- inventory(config, opts) do
      remaining = Map.new(@children, &{&1, Enum.map(children(final_objects[&1], saved, current), fn child -> %{"name" => name(child), "uid" => uid(child)} end)})
      saved = %{saved | metadata: Map.put(saved.metadata, "cleanup_remaining", remaining)}
      # v1.0.1's deletionTimestamp branch has no acknowledged reconcile barrier.
      # Even zero current children plus CSI deletion is not proof against an old
      # create completing later. Keep the last discoverable ownership/finalizer.
      with {:ok, current} <- fetch_parent(config, saved, opts),
           {:ok, saved} <- persist(config, saved, current, [], opts) do
        {:error, {:unknown, :kubernetes_controller_cleanup_ordering_unproven}, saved}
      end
    else
      false -> {:error, {:unknown, :kubernetes_cleanup_pending}}
      other -> other
    end
  end

  @spec normalize(Record.t(), map(), [map()], map()) :: Record.t()
  def normalize(record, sandbox, pods, termination_evidence) do
    cond do
      stopped_sandbox?(record, sandbox, pods, termination_evidence) ->
        proof = %{sandbox_uid: uid(sandbox), generation: get_in(sandbox, ["metadata", "generation"])}
        %{record | phase: :stopped, pending: [], proof: {:quiescent, proof}}

      running_sandbox?(record, sandbox, pods) ->
        %{record | phase: :running, pending: [], proof: :unknown}

      true ->
        %{record | phase: :unknown, proof: :unknown}
    end
  end

  defp stopped_sandbox?(record, sandbox, pods, evidence) do
    authorized = Map.get(record.metadata, "authorized_pod_uids", [])
    accounted = Enum.all?(authorized, &termination_proof?(evidence[&1], &1, record))

    get_in(sandbox, ["spec", "operatingMode"]) == "Suspended" and condition?(sandbox, "Suspended") and
      blueprint_gated?(sandbox) and not unsafe_pod?(get_in(sandbox, ["spec", "podTemplate", "spec"]) || %{}) and
      accounted and Enum.all?(pods, &safely_gated?/1)
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
    with {:ok, %{status: 200, body: version}} <- Client.request(config, :get, "/version", nil, opts),
         true <- kubernetes_version?(version),
         {:ok, template} when is_map(template) <- Client.lookup(config, collection(config, "sandboxtemplates"), config.provider["template"], opts),
         qualification_name when is_binary(qualification_name) <- get_in(template, ["metadata", "annotations", @qualification]),
         {:ok, cm} when is_map(cm) <- Client.lookup(config, collection(config, "configmaps"), qualification_name, opts),
         true <- cm["immutable"] == true,
         {:ok, q} <- Jason.decode(get_in(cm, ["data", "contract.json"]) || ""),
         true <- q["release"] == "v1.0.1" and q["template_uid"] == uid(template) and q["template_digest"] == digest(template["spec"]),
         true <- is_binary(q["qualification_report"]) and String.trim(q["qualification_report"]) != "",
         true <- q["termination_contract"] == "qualified-kubelet-all-containers-v1",
         {:ok, crds} <- Client.list(config, "/apis/apiextensions.k8s.io/v1/customresourcedefinitions", opts),
         :ok <- schemas(crds),
         {:ok, deployments} <- Client.list(config, "/apis/apps/v1/namespaces/#{segment(q["controller_namespace"])}/deployments", opts),
         controller when is_map(controller) <- Enum.find(deployments, &(name(&1) == q["controller_name"])),
         true <- uid(controller) == q["controller_uid"] and controller_image?(controller, q),
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

  defp schemas(crds) do
    expected = [
      {"sandboxes.agents.x-k8s.io", "37f0b89594ba20ca4d37b93714c362bcd694369f"},
      {"sandboxtemplates.extensions.agents.x-k8s.io", "6c5c594b1a0cddda9b330bb094272e1c465d11c2"}
    ]

    valid = Enum.all?(expected, fn {name, hash} -> qualified_schema?(crds, name, hash) end)
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

  defp controller_image?(controller, q) do
    containers = get_in(controller, ["spec", "template", "spec", "containers"]) || []
    desired = get_in(controller, ["spec", "replicas"])
    available = get_in(controller, ["status", "availableReplicas"])

    is_integer(desired) and desired > 0 and is_integer(available) and available >= desired and
      q["controller_source_commit"] == "3e77ccbac4db8a12b0157eafcad0d1ad5872f32a" and
      Enum.any?(containers, &pinned_controller_image?(&1, q)) and
      get_in(controller, ["status", "observedGeneration"]) == get_in(controller, ["metadata", "generation"])
  end

  defp pinned_controller_image?(container, q) do
    prefix = "registry.k8s.io/agent-sandbox/agent-sandbox-controller@sha256:"
    container["image"] == q["controller_image"] and String.starts_with?(container["image"] || "", prefix)
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

  defp safe_template(template, config, q) do
    spec = get_in(template, ["spec", "podTemplate", "spec"]) || %{}
    volumes = spec["volumes"] || []
    containers = (spec["containers"] || []) ++ (spec["initContainers"] || [])
    auth = Enum.filter(volumes, &(&1["name"] == config.provider["ssh_auth_volume"]))
    unsafe = unsafe_pod?(spec)

    if not unsafe and length(auth) == 1 and q["runtime_handler"] != nil and
         Enum.any?(containers, &readonly_auth_mount?(&1, config.provider["ssh_auth_volume"])),
       do: :ok,
       else: {:error, {:invalid, :unsafe_kubernetes_template}}
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
    blueprint = Map.merge(blueprint, %{"podTemplate" => pod, "volumeClaimTemplates" => claims, "operatingMode" => "Suspended"})

    sandbox = %{
      "apiVersion" => @api,
      "kind" => "Sandbox",
      "metadata" => stamp(%{"name" => record.key, "namespace" => config.provider["namespace"], "finalizers" => [@finalizer]}, record),
      "spec" => blueprint
    }

    case api(config, :post, collection(config, "sandboxes"), sandbox, opts) do
      {:ok, created} ->
        {:ok, observe(%{record | pending: []}, created)}

      {:error, {:denied, _} = failure} ->
        failed = %{record | pending: failed_create(record)}
        {:error, failure, reconcile_denied_create(config, failed, q, opts)}

      {:error, _} ->
        case fetch_parent(config, record, opts) do
          {:ok, existing} ->
            {:ok, observe(%{record | pending: []}, existing)}

          _ ->
            pending = Enum.map(record.pending, &Map.put(&1, :outcome, :unknown))
            {:error, {:unknown, :kubernetes_create_outcome}, %{record | pending: pending}}
        end
    end
  end

  defp failed_create(record) do
    Enum.map(record.pending, fn operation ->
      if operation == %{verb: :create, id: record.key, outcome: :pending}, do: %{operation | outcome: :failed}, else: operation
    end)
  end

  defp reconcile_denied_create(config, record, q, opts) do
    with {:ok, objects} <- inventory(config, opts),
         {:ok, observed} <- inspect_denied_create(record, objects, q) do
      observed
    else
      {:error, _, observed} -> observed
      _ -> %{record | proof: :unknown, phase: :unknown, absent?: false}
    end
  end

  defp inspect_denied_create(record, objects, q) do
    remaining = denied_candidates(record, objects)
    captured = Map.get(record.metadata, "cleanup_remaining", %{})
    remaining = Map.merge(captured, remaining, fn _kind, prior, current -> Enum.uniq(prior ++ current) end)
    metadata = Map.put(record.metadata, "cleanup_remaining", remaining)
    observed = %{record | metadata: metadata, proof: :unknown, phase: :unknown, absent?: false}

    if denied_initial_create?(record) and Enum.all?(remaining, fn {_, items} -> items == [] end) do
      proof = %{qualification_uid: q["uid"], initial_create: :denied, inventory: :complete}
      {:ok, %{observed | proof: {:quiescent, proof}, phase: :stopped, absent?: true}}
    else
      {:error, {:unknown, :kubernetes_parent_missing}, observed}
    end
  end

  defp denied_initial_create?(record) do
    record.provider_ref == nil and record.metadata["orphaned"] != true and
      record.pending == [%{verb: :create, id: record.key, outcome: :failed}] and
      Map.get(record.metadata, "authorized_pod_uids", []) == [] and
      Map.get(record.metadata, "volumes", %{}) == %{}
  end

  defp unresolved_mutations?(record) do
    Enum.any?(record.pending, &(&1.outcome in [:unknown, :pending]))
  end

  defp denied_candidates(record, objects) do
    Map.new(["sandboxes" | @children] ++ ["persistentvolumes"], fn resource ->
      candidates = Enum.filter(objects[resource], &denied_candidate?(&1, resource, record))
      {resource, Enum.map(candidates, &%{"name" => name(&1), "uid" => uid(&1)})}
    end)
  end

  defp denied_candidate?(object, "sandboxes", record),
    do: name(object) == record.key or labeled_candidate?(object, record)

  defp denied_candidate?(object, "persistentvolumes", record) do
    claim = get_in(object, ["spec", "claimRef"]) || %{}

    labeled_candidate?(object, record) or
      (claim["namespace"] == record.scope["namespace"] and
         is_binary(claim["name"]) and String.ends_with?(claim["name"], "-" <> record.key))
  end

  defp denied_candidate?(object, _resource, record) do
    labeled_candidate?(object, record) or
      Enum.any?(get_in(object, ["metadata", "ownerReferences"]) || [], &(&1["name"] == record.key))
  end

  defp labeled_candidate?(object, record),
    do: get_in(object, ["metadata", "labels", "symphony.dev/environment"]) == record.key

  defp with_deadline(opts), do: Keyword.put_new_lazy(opts, :deadline, fn -> System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 20_000) end)

  defp command_options(opts), do: Keyword.put(opts, :timeout_ms, max(0, opts[:deadline] - System.monotonic_time(:millisecond)))

  defp wait_authorization(config, record, q, opts) do
    if opts[:deadline] <= System.monotonic_time(:millisecond) do
      {:error, {:unknown, :kubernetes_pod_creation_pending}, record}
    else
      with {:ok, sandbox} <- fetch_parent(config, record, opts),
           true <- observe(record, sandbox).desired == :running and get_in(sandbox, ["metadata", "deletionTimestamp"]) == nil,
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

  defp authorize_observed(config, record, sandbox, owned, q, opts),
    do: authorize(config, observe(record, sandbox), sandbox, owned, q, opts)

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

  defp owned_pods(pods, record, sandbox) do
    if Enum.all?(children(pods, record, sandbox), &(child_ownership(&1, record, sandbox) == :ok)), do: :ok, else: {:error, {:unknown, :kubernetes_child_ownership_changed}}
  end

  defp save_observation(config, record, opts) do
    with {:ok, sandbox} <- fetch_parent(config, record, opts) do
      current = observe(record, sandbox)

      if current.version != record.version or current.metadata == record.metadata do
        {:ok, current}
      else
        persist(config, record, sandbox, [], opts)
      end
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

    with {:ok, saved} <- persist(config, record, sandbox, [], opts),
         {:ok, current} <- fetch_parent(config, saved, opts),
         true <- rv(current) == saved.version and running_intent?(saved, current),
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
    get_in(sandbox, ["spec", "operatingMode"]) == "Running" and observe(record, sandbox).desired == :running
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
        gated?(fenced) -> "never_released"
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
    kubelet = Enum.any?(get_in(pod, ["metadata", "managedFields"]) || [], &(&1["manager"] == "kubelet" and &1["subresource"] == "status"))

    kubelet and status["phase"] in ["Succeeded", "Failed"] and containers != [] and
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
      with true <- child_stopped?(child, resource, record),
           :ok <- child_ownership(child, record, sandbox),
           :ok <- delete(config, resource, child, opts) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, {:unknown, :kubernetes_child_termination_unresolved}}}
        error -> {:halt, error}
      end
    end)
  end

  defp child_stopped?(child, "pods", record) do
    evidence = get_in(record.metadata, ["termination_evidence", uid(child)])
    gated?(child) or termination_proof?(evidence, uid(child), record)
  end

  defp child_stopped?(_child, _resource, _record), do: true

  defp storage_deletion(config, record, q, opts) do
    volumes = Map.get(record.metadata, "volumes", %{})

    Enum.reduce_while(volumes, {:ok, record}, fn {key, volume}, {:ok, current} ->
      cond do
        volume["deleted"] == true ->
          {:cont, {:ok, current}}

        volume["pv_uid"] == nil ->
          {:halt, {:error, {:unknown, :unbound_pvc_provisioning_unresolved}, current}}

        true ->
          {:cont, {:ok, observe_volume_deletion(config, current, key, volume, q, opts)}}
      end
    end)
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

  defp existing_secret_ownership(nil, _record, _sandbox), do: :ok
  defp existing_secret_ownership(secret, record, sandbox), do: child_ownership(secret, record, sandbox)

  defp ensure_credentials(config, record, sandbox, _q, opts) do
    with {:ok, secret} <- Client.lookup(config, collection(config, "secrets"), secret_name(record), opts),
         :ok <- existing_secret_ownership(secret, record, sandbox) do
      case client_key_path(record, secret) do
        {:ok, _} ->
          {:ok, record}

        _ ->
          rotate_after_stop(config, record, sandbox, secret, opts)
      end
    end
  end

  defp rotate_after_stop(config, record, sandbox, secret, opts) do
    case wait_credential_stop(config, record, sandbox, opts) do
      {:ok, observed, current} -> stage_credentials(config, observed, current, secret, opts)
      _ -> {:error, {:unknown, :client_key_rotation_requires_stop}}
    end
  end

  defp wait_credential_stop(config, record, sandbox, opts) do
    with {:ok, pods} <- Client.list(config, collection(config, "pods"), opts),
         :ok <- owned_pods(pods, record, sandbox) do
      observed = normalize(record, sandbox, children(pods, record, sandbox), Map.get(record.metadata, "termination_evidence", %{}))

      cond do
        observed.phase == :stopped ->
          {:ok, observed, sandbox}

        get_in(sandbox, ["spec", "operatingMode"]) != "Suspended" or opts[:deadline] <= System.monotonic_time(:millisecond) ->
          {:error, {:unknown, :client_key_rotation_requires_stop}}

        true ->
          wait_next_credential_stop(config, record, opts)
      end
    end
  end

  defp wait_next_credential_stop(config, record, opts) do
    pause(opts)

    with {:ok, current} <- fetch_parent(config, record, opts),
         do: wait_credential_stop(config, record, current, opts)
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
    api(config, :post, collection(config, "secrets"), body, opts)
  end

  defp save_credentials(config, record, sandbox, secret, data, opts) do
    patch = cas(secret) ++ [%{"op" => "add", "path" => "/data", "value" => data}]

    with :ok <- child_ownership(secret, record, sandbox),
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
    Enum.reduce_while(["sandboxes" | @children] ++ ["persistentvolumes"], {:ok, %{}}, fn resource, {:ok, objects} ->
      case Client.list(config, collection(config, resource), opts) do
        {:ok, items} -> {:cont, {:ok, Map.put(objects, resource, items)}}
        error -> {:halt, error}
      end
    end)
  end

  defp fetch_parent(config, record, opts) do
    with {:ok, sandbox} when is_map(sandbox) <- Client.lookup(config, collection(config, "sandboxes"), record.key, opts),
         :ok <- ownership(sandbox, record),
         do: {:ok, sandbox},
         else: (
           {:ok, nil} -> {:error, {:unknown, :kubernetes_parent_missing}}
           error -> error
         )
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
    annotations = Map.put(get_in(sandbox, ["metadata", "annotations"]) || %{}, @state, encode_record(record))

    patch = cas(sandbox) ++ [%{"op" => "add", "path" => "/metadata/annotations", "value" => annotations}] ++ extra

    with {:ok, updated} <- api(config, :patch, object_path(config, "sandboxes", sandbox), patch, opts),
         do: {:ok, observe(record, updated)}
  end

  defp durable_metadata(metadata), do: Map.drop(metadata, ["client_key_directory", "client_key_lease"])

  defp observe(record, sandbox) do
    case decode_annotation(sandbox) do
      {:ok, fields, lifecycle} ->
        metadata = Map.merge(lifecycle.metadata, Map.take(record.metadata, ["client_key_directory", "client_key_lease"]))
        struct!(record, Map.merge(lifecycle, %{provider_ref: uid(sandbox), version: rv(sandbox), template_identity: fields["template_identity"], metadata: metadata}))

      {:error, _} ->
        %{record | phase: :unknown, proof: :unknown, pending: [%{verb: :update, id: nil, outcome: :unknown}]}
    end
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
