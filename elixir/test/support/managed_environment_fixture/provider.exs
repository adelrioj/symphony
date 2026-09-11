defmodule SymphonyElixir.ManagedEnvironmentFixture.Provider do
  @moduledoc false

  alias SymphonyElixir.ExecutionEnvironment.{Command, Config, Kubernetes, Workstations}
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Client, as: KubernetesClient
  alias SymphonyElixir.ExecutionEnvironment.Workstations.Client, as: WorkstationsClient

  @gate "symphony.dev/start-authorized"
  @pv_finalizer "external-provisioner.volume.kubernetes.io/finalizer"
  @quota_fields ~w(concurrent_workers retained_environments persistent_disk_gib)
  @compute_states ~w(PROVISIONING STAGING RUNNING STOPPING SUSPENDING REPAIRING TERMINATED SUSPENDED)

  # Only this opt-in helper consumes provider.qualification. No production profile
  # can turn the known v1.0.1 cleanup-ordering defect into a successful preflight.
  def preflight(config, profile, opts) do
    safely(:provider_prerequisites_unavailable, fn ->
      with {:ok, quota} <- quota_evidence(profile),
           :ok <- validate_driver(profile),
           true <- profile["storage_fault_authorized"] == true,
           true <- pinned_image?(profile["worker_image"]) do
        provider_preflight(config, profile, quota, bounded(opts))
      else
        {:error, code} when is_atom(code) -> {:error, code}
        _ -> {:error, :provider_prerequisites_unavailable}
      end
    end)
  end

  def fault_options(config, entry, operation, opts, callbacks) do
    opts = bounded(opts)
    id = if entry, do: entry.record.issue_id

    case config.kind do
      "google_workstations" ->
        Keyword.put(opts, :request_fun, fn request ->
          workstation_fault(request, operation, id, callbacks)
        end)

      "kubernetes" ->
        Keyword.put(opts, :command_fun, fn executable, args, command_opts ->
          kubernetes_fault(config, entry, operation, callbacks, executable, args, bounded(command_opts, opts[:deadline]))
        end)
    end
  end

  # Bodies are internal input to evidence extraction, never public evidence. In
  # particular, callers must not serialize an API body or an exception wholesale.
  def request(config, method, path, opts) do
    safely(:provider_evidence_request_failed, fn ->
      result =
        case config.kind do
          "google_workstations" -> WorkstationsClient.request(config, method, path, [], nil, bounded(opts))
          "kubernetes" -> KubernetesClient.request(config, method, path, nil, bounded(opts))
        end

      case result do
        {:ok, %{status: status, body: body}} when is_integer(status) and is_map(body) -> {:ok, %{status: status, body: body}}
        _ -> {:error, :provider_evidence_request_failed}
      end
    end)
  end

  def runtime_targets(config, record, opts) do
    safely(:runtime_identity_unresolved, fn ->
      with :ok <- record_scope(config, record) do
        runtime(config, record, bounded(opts))
      end
    end)
  end

  # Presence is an observation only. Neither false nor a parent 404 certifies
  # physical deletion; the adapter must still discharge its durable barrier.
  def storage_present(config, record, opts) do
    safely(:storage_identity_unresolved, fn ->
      with :ok <- record_scope(config, record) do
        storage(config, record, bounded(opts))
      end
    end)
  end

  def inventory(config, opts) do
    safely(:complete_owned_inventory_unavailable, fn ->
      opts = bounded(opts)
      adapter = if config.kind == "google_workstations", do: Workstations, else: Kubernetes

      with {:ok, records} <- adapter.discover(config, opts),
           true <- Enum.all?(records, &(record_scope(config, &1) == :ok and &1.metadata["orphaned"] != true)),
           true <- unique?(records, & &1.key),
           true <- unique?(records, & &1.issue_id),
           {:ok, workers} <- current_workers(config, records, opts) do
        counts = Map.new(records, &{&1.key, 0})

        counts =
          Enum.reduce(workers, counts, fn {key, worker}, acc ->
            if potentially_runnable?(config.kind, worker), do: Map.update!(acc, key, &(&1 + 1)), else: acc
          end)

        {:ok, %{records: records, live_worker_counts: counts}}
      else
        _ -> {:error, :complete_owned_inventory_unavailable}
      end
    end)
  end

  def unrelated_snapshot(config, paths, opts) do
    safely(:negative_control_identity_unavailable, fn ->
      if is_list(paths) and paths != [] and Enum.uniq(paths) == paths do
        collect(paths, fn path ->
          with true <- negative_control_path?(config, path),
               {:ok, body} <- get(config, path, opts),
               {:ok, identity} <- negative_identity(config, body),
               true <- not owned_deployment?(config, body) do
            {:ok, %{path: path, uid: identity}}
          else
            _ -> {:error, :negative_control_identity_unavailable}
          end
        end)
      else
        {:error, :negative_control_paths_required}
      end
    end)
  end

  def physical_fault(config, profile, scenario, phase, record, opts) do
    safely(:operator_fault_driver_failed, fn ->
      opts = bounded(opts)

      with :ok <- validate_driver(profile),
           :ok <- fault_scope(config),
           :ok <- fault_permission(config, profile, scenario, phase, record),
           {:ok, resource} <- fault_resource(config, profile, scenario, phase, record, opts),
           {:ok, bytes} <- driver_bytes(profile["fault_driver"]),
           true <- sha256(bytes) == profile["fault_driver_sha256"] do
        input = %{
          scenario: scenario,
          phase: phase,
          deployment_id: config.deployment_id,
          scope: safe_scope(config),
          resource: resource,
          credential_references: credential_references(config)
        }

        # Execute a private snapshot of precisely the audited bytes, not a path
        # that can be replaced between hashing and exec. Drivers are self-contained.
        result =
          Command.with_json_file(
            input,
            fn request_path ->
              executable = Path.join(Path.dirname(request_path), "fault-driver")

              with :ok <- write_executable(executable, bytes) do
                Command.run(executable, ["--request", request_path], Keyword.put(opts, :max_output_bytes, 16_384))
              end
            end,
            opts
          )

        case result do
          {:ok, %{status: 0, output: output}} ->
            case Jason.decode(output) do
              {:ok, %{"applied" => true} = acknowledgment} when map_size(acknowledgment) == 1 -> :ok
              _ -> {:error, :operator_fault_driver_did_not_acknowledge}
            end

          _ ->
            {:error, :operator_fault_driver_failed}
        end
      else
        {:error, code} when is_atom(code) -> {:error, code}
        _ -> {:error, :operator_fault_driver_authorization_mismatch}
      end
    end)
  end

  def gate_observation(%{kind: "kubernetes"} = config, record, opts) do
    safely(:kubernetes_gate_identity_unresolved, fn ->
      with :ok <- record_scope(config, record),
           {:ok, pod} <- exact_pod(config, record, bounded(opts)),
           true <- nonblank?(uid(pod)) do
        held = own_gate?(pod)

        if not held or never_scheduled?(pod) do
          {:ok, %{held?: held, pod_uid: uid(pod)}}
        else
          {:error, :kubernetes_gate_did_not_prevent_execution}
        end
      else
        _ -> {:error, :kubernetes_gate_identity_unresolved}
      end
    end)
  end

  def gate_observation(_, _, _), do: {:error, :gate_requires_kubernetes}

  def node_observation(%{kind: "kubernetes"} = config, record, profile, opts) do
    safely(:kubernetes_node_identity_unresolved, fn ->
      with true <- profile["node_fault_authorized"] == true,
           authorized when is_list(authorized) and authorized != [] <- profile["authorized_node_uids"],
           :ok <- record_scope(config, record),
           true <- Enum.all?(authorized, &nonblank?/1),
           {:ok, node} <- observed_node(config, record, opts),
           true <- is_map(node) and node.uid in authorized,
           {:ok, pods} <- KubernetesClient.list(config, "/api/v1/pods", bounded(opts)),
           true <- unique?(pods, &uid/1),
           true <-
             Enum.all?(pods, fn other ->
               get_in(other, ["spec", "nodeName"]) != node.name or
                 (namespace(other) == config.provider["namespace"] and pod_owned?(other, record))
             end),
           {:ok, object} <- get(config, "/api/v1/nodes/" <> segment(node.name), opts),
           true <- uid(object) == node.uid,
           [ready] <- Enum.filter(get_in(object, ["status", "conditions"]) || [], &(&1["type"] == "Ready")),
           true <- ready["status"] in ["True", "False", "Unknown"] do
        {:ok, %{node: node, ready?: ready["status"] == "True"}}
      else
        _ -> {:error, :kubernetes_dedicated_authorized_node_required}
      end
    end)
  end

  def node_observation(_, _, _, _), do: {:error, :node_fault_requires_kubernetes}

  defp provider_preflight(%{kind: "google_workstations"} = config, profile, quota, opts) do
    with :ok <- Workstations.preflight(config, opts),
         {:ok, template} <- get(config, workstation_parent(config), opts),
         true <- get_in(template, ["container", "image"]) == profile["worker_image"],
         {:ok, cluster} <- get(config, workstation_cluster(config), opts),
         true <- nonblank?(cluster["uid"]) and nonblank?(template["uid"]),
         {:ok, region} <- get(config, compute_root(config) <> "/regions/" <> segment(config.provider["location"]), opts),
         {:ok, compute_quota} <- region_quotas(region),
         executable when is_binary(executable) <- System.find_executable("gcloud"),
         {:ok, %{status: 0, output: output}} <- Command.run(executable, ["version", "--format=json"], Keyword.put(opts, :max_output_bytes, 65_536)),
         {:ok, versions} <- Jason.decode(output),
         version when is_binary(version) <- versions["Google Cloud SDK"] do
      {:ok,
       %{
         scope: safe_scope(config),
         image_digest: profile["worker_image"],
         template_uid: template["uid"],
         cluster_uid: cluster["uid"],
         client_version: safe_report_reference(version),
         runtime_version: safe_report_reference(profile["runtime_version"]),
         runtime_version_source: :operator_report,
         quota_evidence: quota,
         quota_evidence_source: :operator_report,
         provider_quota_evidence: compute_quota,
         provider_quota_evidence_source: :regional_disk_quota_lower_bound,
         qualification_report: safe_report_reference(profile["qualification_report"]),
         prerequisite_source: :operator_report_and_live_provider_reads
       }}
    else
      _ -> {:error, :workstations_prerequisites_unavailable}
    end
  end

  defp provider_preflight(%{kind: "kubernetes"} = config, profile, _quota, opts) do
    # Adapter preflight reads the actual immutable contract, controller deployment,
    # CRD schemas, runtime class, CSI classes and isolation policy. It cannot prove
    # the upstream deletion/create ordering barrier, which is intentionally fatal.
    with :ok <- Kubernetes.preflight(config, opts),
         {:ok, template} <- get(config, kube_collection(config, "sandboxtemplates") <> "/" <> segment(config.provider["template"]), opts),
         containers when is_list(containers) <- get_in(template, ["spec", "podTemplate", "spec", "containers"]),
         true <- Enum.any?(containers, &(&1["image"] == profile["worker_image"])),
         true <- Enum.all?(containers, &pinned_image?(&1["image"])),
         {:ok, quotas} <- KubernetesClient.list(config, kube_collection(config, "resourcequotas"), opts),
         true <- Enum.all?(quotas, &(is_map(get_in(&1, ["status", "hard"])) and is_map(get_in(&1, ["status", "used"])))) do
      {:error, :kubernetes_controller_cleanup_ordering_unproven}
    else
      _ -> {:error, :kubernetes_prerequisites_unavailable}
    end
  end

  defp quota_evidence(profile) do
    quota = profile["quota_evidence"]

    if is_map(quota) and is_number(quota["concurrent_workers"]) and quota["concurrent_workers"] >= 5 and
         is_number(quota["retained_environments"]) and quota["retained_environments"] >= 6 and
         (not Map.has_key?(quota, "persistent_disk_gib") or (is_number(quota["persistent_disk_gib"]) and quota["persistent_disk_gib"] >= 0)) do
      {:ok, Map.take(quota, @quota_fields)}
    else
      {:error, :numeric_worker_and_storage_quota_evidence_required}
    end
  end

  defp region_quotas(region) do
    values = region["quotas"]

    if is_list(values) and values != [] do
      collect(Enum.filter(values, &(&1["metric"] in ["DISKS_TOTAL_GB", "SSD_TOTAL_GB"])), fn quota ->
        if is_number(quota["limit"]) and is_number(quota["usage"]),
          do: {:ok, max(0, quota["limit"] - quota["usage"])},
          else: {:error, :compute_quota_unavailable}
      end)
      |> case do
        {:ok, []} -> {:error, :compute_quota_unavailable}
        {:ok, available} -> {:ok, %{"persistent_disk_gib" => Enum.min(available)}}
        error -> error
      end
    else
      {:error, :compute_quota_unavailable}
    end
  end

  defp workstation_fault(request, operation, id, callbacks) do
    method = Keyword.fetch!(request, :method)
    url = Keyword.fetch!(request, :url)
    stop = operation == :stop and method == :post and String.ends_with?(url, ":stop")
    deny = stop and armed?(callbacks, {:deny_stop, id})
    request = if deny, do: Keyword.put(request, :headers, [{"authorization", "Bearer deliberately-invalid-qualification-token"}]), else: request
    result = Req.request(request)

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        cond do
          operation == :prepare and method == :post and String.ends_with?(url, "/workstations") and accepted_operation?(request, body, "create") and armed?(callbacks, {:lose_create, id}) ->
            lose(callbacks, {:lose_create, id}, :create_response_lost, id)

          operation == :prepare and method == :post and String.ends_with?(url, ":start") and accepted_operation?(request, body, "start") and armed?(callbacks, {:lose_start, id}) ->
            lose(callbacks, {:lose_start, id}, :start_response_lost, id)

          operation == :destroy and method == :delete and String.contains?(url, "/workstations/") and accepted_operation?(request, body, "delete") ->
            emit(callbacks, :delete_accepted, id)
            result

          true ->
            result
        end

      {:ok, %{status: status}} when deny and status in [401, 403] ->
        emit(callbacks, :stop_denied, id)
        result

      _ ->
        result
    end
  end

  defp accepted_operation?(request, body, verb) when is_map(body) do
    path = URI.parse(Keyword.fetch!(request, :url)).path |> String.replace_prefix("/v1/", "")

    target =
      case verb do
        "create" -> path <> "/" <> Keyword.fetch!(Keyword.fetch!(request, :params), :workstationId)
        "start" -> String.replace_suffix(path, ":start", "")
        "delete" -> path
      end

    nonblank?(body["name"]) and get_in(body, ["metadata", "target"]) == target and
      get_in(body, ["metadata", "verb"]) == verb and not Map.has_key?(body, "error")
  end

  defp accepted_operation?(_, _, _), do: false

  defp kubernetes_fault(config, entry, operation, callbacks, executable, args, opts) do
    safely(:qualification_transport_fault_failed, fn ->
      id = if entry, do: entry.record.issue_id
      mutation = kubernetes_mutation(args)
      release = gate_release?(mutation)

      with :ok <- maybe_hold_gate(config, entry, release, callbacks, opts) do
        if operation == :stop and mutation != nil and armed?(callbacks, {:deny_stop, id}) do
          deny_kubernetes(config, mutation, callbacks, id, executable, args, opts)
        else
          result = Command.run(executable, args, opts)

          case accepted_command(result) do
            {:ok, body} ->
              cond do
                operation == :prepare and sandbox_create?(config, entry, mutation, body) and armed?(callbacks, {:lose_create, id}) ->
                  lose(callbacks, {:lose_create, id}, :create_response_lost, id)

                operation == :prepare and release and released_pod?(mutation, body) and armed?(callbacks, {:lose_start, id}) ->
                  lose(callbacks, {:lose_start, id}, :start_response_lost, id)

                operation == :destroy and pvc_delete?(config, mutation, body) ->
                  emit(callbacks, :delete_accepted, id)
                  result

                true ->
                  result
              end

            _ ->
              result
          end
        end
      end
    end)
  end

  # Detect only the production client's argv/JSON protocol. SSH and read-only
  # kubectl calls pass through unchanged; no CLI prose is parsed into a resource.
  defp kubernetes_mutation(args) do
    cond do
      "patch" in args ->
        index = Enum.find_index(args, &(&1 == "patch"))

        with path when is_binary(path) <- argument(args, "--patch-file"), {:ok, bytes} <- File.read(path), {:ok, body} when is_list(body) <- Jason.decode(bytes) do
          %{verb: "patch", resource: Enum.at(args, index + 1), name: Enum.at(args, index + 2), namespace: argument(args, "--namespace"), body: body}
        else
          _ -> nil
        end

      "create" in args or "delete" in args ->
        with path when is_binary(path) <- argument(args, "--raw"),
             file when is_binary(file) <- argument(args, "-f"),
             {:ok, bytes} <- File.read(file),
             {:ok, body} when is_map(body) <- Jason.decode(bytes),
             {:ok, namespace, resource, name} <- kube_path(URI.parse(path).path) do
          %{verb: if("create" in args, do: "create", else: "delete"), resource: resource, name: name, namespace: namespace, body: body}
        else
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp gate_release?(%{verb: "patch", resource: "pods", body: body}) do
    Enum.any?(body, &(&1["op"] == "test" and &1["value"] == @gate and String.starts_with?(&1["path"] || "", "/spec/schedulingGates/"))) and
      Enum.any?(body, &(&1["op"] == "remove" and Regex.match?(~r{^/spec/schedulingGates/[0-9]+$}, &1["path"] || "")))
  end

  defp gate_release?(_), do: false

  defp maybe_hold_gate(_config, _entry, false, _callbacks, _opts), do: :ok

  defp maybe_hold_gate(config, entry, true, callbacks, opts) do
    key = {:hold_gate, entry.record.issue_id}

    if armed?(callbacks, key) do
      with {:ok, %{held?: true}} <- gate_observation(config, entry.record, Keyword.delete(opts, :command_fun)) do
        emit(callbacks, :gate_held, entry.record.issue_id)
        wait_gate(callbacks, key, opts)
      else
        _ -> {:error, :kubernetes_gate_not_held}
      end
    else
      :ok
    end
  end

  defp wait_gate(callbacks, key, opts) do
    cond do
      remaining(opts) <= 0 ->
        {:error, :kubernetes_gate_hold_deadline}

      not armed?(callbacks, key) ->
        :ok

      true ->
        Process.sleep(min(100, remaining(opts)))
        wait_gate(callbacks, key, opts)
    end
  end

  defp deny_kubernetes(config, mutation, callbacks, id, executable, args, opts) do
    identity = get_in(config.provider, ["qualification", "denied_identity"])

    with true <- nonblank?(identity) and not String.starts_with?(identity, "system:"),
         true <- mutation.namespace == config.provider["namespace"],
         true <- mutation.resource in ["sandboxes.agents.x-k8s.io", "pods", "sandboxes"],
         :ok <- denied_authorization(config, identity, mutation, opts) do
      result = Command.run(executable, ["--as=" <> identity | args], opts)

      case result do
        {:ok, %{status: status, output: output}} when status != 0 ->
          # CLI rejection is only fault-injection evidence, never physical stop
          # or absence proof. A connection error must not pass the denial check.
          if Regex.match?(~r/(?:^|\n)Error from server \((?:Forbidden|Unauthorized)\):/, output) do
            emit(callbacks, :stop_denied, id)
            result
          else
            {:error, :kubernetes_actual_denial_unobserved}
          end

        _ ->
          {:error, :kubernetes_denied_identity_did_not_reject}
      end
    else
      _ -> {:error, :kubernetes_explicit_denied_identity_required}
    end
  end

  defp denied_authorization(config, identity, mutation, opts) do
    group = if String.starts_with?(mutation.resource, "sandboxes"), do: "agents.x-k8s.io", else: ""
    resource = if group == "", do: mutation.resource, else: "sandboxes"

    body = %{
      "apiVersion" => "authorization.k8s.io/v1",
      "kind" => "SelfSubjectAccessReview",
      "spec" => %{"resourceAttributes" => %{"namespace" => mutation.namespace, "verb" => mutation.verb, "group" => group, "resource" => resource, "name" => mutation.name}}
    }

    command = fn executable, args, command_opts -> Command.run(executable, ["--as=" <> identity | args], bounded(command_opts, opts[:deadline])) end

    case KubernetesClient.request(config, :post, "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews", body, Keyword.put(opts, :command_fun, command)) do
      {:ok, %{status: 200, body: %{"status" => %{"allowed" => false} = status}}} ->
        if status["evaluationError"] in [nil, ""], do: :ok, else: {:error, :kubernetes_denial_unproven}

      _ ->
        {:error, :kubernetes_denial_unproven}
    end
  end

  defp accepted_command({:ok, %{status: 0, output: output}}) do
    case Jason.decode(output) do
      {:ok, %{"kind" => "Status", "code" => code} = body} when code in 200..299 -> {:ok, body}
      {:ok, %{"kind" => "Status"}} -> {:error, :not_accepted}
      {:ok, body} when is_map(body) -> {:ok, body}
      _ -> {:error, :not_accepted}
    end
  end

  defp accepted_command(_), do: {:error, :not_accepted}

  defp sandbox_create?(config, entry, %{verb: "create", resource: "sandboxes", namespace: ns}, body) do
    entry != nil and ns == config.provider["namespace"] and body["kind"] == "Sandbox" and
      name(body) == entry.record.key and nonblank?(uid(body)) and owned_deployment?(config, body)
  end

  defp sandbox_create?(_, _, _, _), do: false

  defp released_pod?(mutation, body) do
    expected = Enum.find_value(mutation.body, fn item -> if item["op"] == "test" and item["path"] == "/metadata/uid", do: item["value"] end)
    body["kind"] == "Pod" and uid(body) == expected and nonblank?(expected) and not own_gate?(body)
  end

  defp pvc_delete?(config, %{verb: "delete", resource: "persistentvolumeclaims", namespace: ns, body: request}, response) do
    expected = get_in(request, ["preconditions", "uid"])

    ns == config.provider["namespace"] and nonblank?(expected) and
      ((response["kind"] == "PersistentVolumeClaim" and uid(response) == expected and get_in(response, ["metadata", "deletionTimestamp"]) != nil) or
         (response["kind"] == "Status" and response["status"] == "Success" and get_in(response, ["details", "uid"]) == expected))
  end

  defp pvc_delete?(_, _, _), do: false

  defp runtime(%{kind: "google_workstations"} = config, record, opts) do
    with {:ok, workers} <- current_workers(config, [record], opts, false),
         [{_, instance}] <- Enum.filter(workers, fn {key, worker} -> key == record.key and potentially_runnable?(config.kind, worker) end),
         addresses <-
           Enum.flat_map(instance["networkInterfaces"] || [], fn interface -> List.wrap(interface["networkIP"]) ++ Enum.map(interface["ipv6AccessConfigs"] || [], & &1["internalIpv6Prefix"]) end),
         true <- addresses != [] and Enum.all?(addresses, &ip_address?/1) do
      {:ok, %{addresses: Enum.uniq(addresses), node: nil}}
    else
      _ -> {:error, :runtime_identity_unresolved}
    end
  end

  defp runtime(%{kind: "kubernetes"} = config, record, opts) do
    with {:ok, pod} <- exact_pod(config, record, opts),
         true <- uid(pod) in Map.get(record.metadata, "authorized_pod_uids", []),
         addresses <- Enum.map(get_in(pod, ["status", "podIPs"]) || [], & &1["ip"]),
         true <- addresses != [] and Enum.all?(addresses, &ip_address?/1),
         {:ok, node} <- pod_node(config, pod, opts) do
      {:ok, %{addresses: Enum.uniq(addresses), node: node}}
    else
      _ -> {:error, :runtime_identity_unresolved}
    end
  end

  defp current_workers(config, records, opts, complete_scope \\ true)

  defp current_workers(%{kind: "google_workstations"} = config, records, opts, complete_scope) do
    with {:ok, instances} <- compute_inventory(config, "instances", opts),
         true <- unique?(instances, & &1["id"]) do
      collect_owned(instances, records, fn instance ->
        owned_compute(config, records, instance, complete_scope)
      end)
    else
      _ -> {:error, :compute_inventory_incomplete}
    end
  end

  defp current_workers(%{kind: "kubernetes"} = config, records, opts, complete_scope) do
    with {:ok, pods} <- KubernetesClient.list(config, kube_collection(config, "pods"), opts),
         true <- unique?(pods, &uid/1),
         :ok <- sandbox_owner_inventory(config, records, pods, opts, complete_scope) do
      collect_owned(pods, records, fn pod -> owned_pod(config, records, pod, complete_scope) end)
    else
      _ -> {:error, :kubernetes_inventory_incomplete}
    end
  end

  defp sandbox_owner_inventory(_config, _records, _pods, _opts, false), do: :ok

  defp sandbox_owner_inventory(config, records, pods, opts, true) do
    with {:ok, sandboxes} <- KubernetesClient.list(config, kube_collection(config, "sandboxes"), opts),
         true <- unique?(sandboxes, &uid/1),
         true <-
           Enum.all?(records, fn record ->
             Enum.any?(sandboxes, &(uid(&1) == record.provider_ref and name(&1) == record.key and owned_deployment?(config, &1)))
           end),
         true <-
           Enum.all?(pods, fn pod ->
             Enum.all?(get_in(pod, ["metadata", "ownerReferences"]) || [], fn owner ->
               owner["kind"] != "Sandbox" or Enum.any?(sandboxes, &(uid(&1) == owner["uid"] and name(&1) == owner["name"]))
             end)
           end) do
      :ok
    else
      _ -> {:error, :kubernetes_orphan_parent_inventory}
    end
  end

  defp collect_owned(items, _records, classify) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case classify.(item) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, key} -> {:cont, {:ok, [{key, item} | acc]}}
        _ -> {:halt, {:error, :worker_ownership_unresolved}}
      end
    end)
  end

  defp owned_compute(config, records, instance, complete_scope) do
    labels = instance["labels"] || %{}

    matches =
      Enum.filter(records, fn record ->
        labels["symphony-ticket"] == record.key or Enum.any?(record.metadata["backing_resources"] || [], &(&1["id"] == instance["id"] and &1["selfLink"] == instance["selfLink"]))
      end)

    cond do
      matches == [] and (not owned_deployment?(config, instance) or not complete_scope) ->
        {:ok, nil}

      length(matches) != 1 ->
        {:error, :compute_orphan_or_ambiguous_owner}

      true ->
        record = hd(matches)

        with {:ok, _} <- compute_reference_path(config, instance, "instances"),
             true <- labels["symphony-managed"] == "true" and labels["symphony-ticket"] == record.key and owned_deployment?(config, instance),
             true <- instance["status"] in @compute_states do
          {:ok, record.key}
        else
          _ -> {:error, :compute_identity_or_status_unresolved}
        end
    end
  end

  defp owned_pod(config, records, pod, complete_scope) do
    matches =
      Enum.filter(records, fn record ->
        get_in(pod, ["metadata", "labels", "symphony.dev/environment"]) == record.key or owner_uid?(pod, record.provider_ref)
      end)

    cond do
      matches == [] and (not owned_deployment?(config, pod) or not complete_scope) -> {:ok, nil}
      length(matches) != 1 -> {:error, :kubernetes_orphan_or_ambiguous_owner}
      namespace(pod) != config.provider["namespace"] -> {:error, :kubernetes_namespace_changed}
      not pod_owned?(pod, hd(matches)) -> {:error, :kubernetes_pod_owner_changed}
      true -> {:ok, hd(matches).key}
    end
  end

  defp potentially_runnable?("google_workstations", instance), do: instance["status"] not in ["TERMINATED", "SUSPENDED"]
  defp potentially_runnable?("kubernetes", pod), do: not kubelet_terminated?(pod)

  defp kubelet_terminated?(pod) do
    containers = Enum.flat_map(~w(containers initContainers ephemeralContainers), &(get_in(pod, ["spec", &1]) || []))
    statuses = Enum.flat_map(~w(containerStatuses initContainerStatuses ephemeralContainerStatuses), &(get_in(pod, ["status", &1]) || []))

    get_in(pod, ["status", "phase"]) in ["Succeeded", "Failed"] and containers != [] and
      Enum.any?(get_in(pod, ["metadata", "managedFields"]) || [], &(&1["manager"] == "kubelet" and &1["subresource"] == "status")) and
      Enum.all?(containers, fn container ->
        status = Enum.find(statuses, &(&1["name"] == container["name"])) || %{}
        terminated = get_in(status, ["state", "terminated"]) || %{}
        nonblank?(terminated["containerID"]) and nonblank?(terminated["finishedAt"]) and terminated["reason"] != "ContainerStatusUnknown"
      end)
  end

  defp exact_pod(config, record, opts) do
    with true <- nonblank?(record.provider_ref),
         {:ok, workers} <- current_workers(config, [record], opts, false),
         [{_, pod}] <- workers do
      {:ok, pod}
    else
      _ -> {:error, :kubernetes_exact_owned_pod_unavailable}
    end
  end

  defp pod_owned?(pod, record) do
    labels = get_in(pod, ["metadata", "labels"]) || %{}

    nonblank?(uid(pod)) and nonblank?(name(pod)) and owner_uid?(pod, record.provider_ref) and
      Enum.any?(get_in(pod, ["metadata", "ownerReferences"]) || [], &(&1["uid"] == record.provider_ref and &1["name"] == record.key)) and
      labels["symphony.dev/environment"] in [nil, record.key] and
      labels["symphony.dev/deployment"] in [nil, kubernetes_digest(record.deployment_id)]
  end

  defp owner_uid?(pod, expected) do
    owners = Enum.filter(get_in(pod, ["metadata", "ownerReferences"]) || [], &(&1["kind"] == "Sandbox"))

    case owners do
      [%{"apiVersion" => "agents.x-k8s.io/v1beta1", "uid" => uid}] -> nonblank?(expected) and uid == expected
      _ -> false
    end
  end

  defp pod_node(config, pod, opts) do
    case get_in(pod, ["spec", "nodeName"]) do
      name when is_binary(name) and name != "" ->
        with {:ok, node} <- get(config, "/api/v1/nodes/" <> segment(name), opts),
             true <- name(node) == name and nonblank?(uid(node)) do
          {:ok, %{name: name, uid: uid(node)}}
        else
          _ -> {:error, :kubernetes_node_identity_unresolved}
        end

      _ ->
        {:ok, nil}
    end
  end

  # The harness captures this node reference only for restoring an already
  # observed physical fault. It never becomes a current runtime address.
  defp observed_node(config, record, opts) do
    captured = record.metadata["qualification_node"]

    with {:ok, workers} <- current_workers(config, [record], bounded(opts), false) do
      case workers do
        [{_, pod}] ->
          with {:ok, node} when is_map(node) <- pod_node(config, pod, opts),
               true <- captured == nil or captured == node do
            {:ok, node}
          else
            _ -> {:error, :kubernetes_fault_node_changed}
          end

        [] ->
          with %{name: name, uid: expected} <- captured,
               true <- safe_segment?(name) and nonblank?(expected),
               {:ok, node} <- get(config, "/api/v1/nodes/" <> segment(name), opts),
               true <- uid(node) == expected and name(node) == name do
            {:ok, %{name: name, uid: expected}}
          else
            _ -> {:error, :kubernetes_fault_node_unavailable}
          end

        _ ->
          {:error, :kubernetes_fault_pod_identity_unresolved}
      end
    end
  end

  defp storage(%{kind: "google_workstations"} = config, record, opts) do
    references = Enum.filter(record.metadata["backing_resources"] || [], &(is_binary(&1["selfLink"]) and String.contains?(&1["selfLink"], "/disks/")))

    with true <- references != [],
         {:ok, observations} <-
           collect(references, fn reference ->
             with {:ok, path} <- compute_reference_path(config, reference, "disks") do
               case request(config, :get, path, opts) do
                 {:ok, %{status: 200, body: disk}} ->
                   if disk["id"] == reference["id"] and disk["selfLink"] == reference["selfLink"], do: {:ok, true}, else: {:error, :storage_identity_changed}

                 {:ok, %{status: 404}} ->
                   {:ok, false}

                 _ ->
                   {:error, :storage_identity_unresolved}
               end
             end
           end) do
      {:ok, Enum.any?(observations)}
    else
      _ -> {:error, :captured_service_managed_disk_evidence_unavailable}
    end
  end

  defp storage(%{kind: "kubernetes"} = config, record, opts) do
    volumes = Map.values(record.metadata["volumes"] || %{})

    with true <- volumes != [],
         {:ok, driver} <- captured_csi_driver(config, record, opts),
         {:ok, pvs} <- KubernetesClient.list(config, "/api/v1/persistentvolumes", opts),
         {:ok, pvcs} <- KubernetesClient.list(config, kube_collection(config, "persistentvolumeclaims"), opts),
         {:ok, present} <- collect(volumes, &volume_present(config, &1, pvs, pvcs, driver)) do
      {:ok, Enum.any?(present)}
    else
      _ -> {:error, :captured_csi_storage_evidence_unavailable}
    end
  end

  defp volume_present(config, volume, pvs, pvcs, driver) do
    pvc = Enum.filter(pvcs, &(name(&1) == volume["pvc_name"]))
    pv = Enum.filter(pvs, &(name(&1) == volume["pv_name"]))

    cond do
      not nonblank?(volume["pvc_uid"]) or not nonblank?(volume["pv_uid"]) or not nonblank?(volume["volume_handle"]) ->
        {:error, :unbound_or_uncaptured_csi_storage}

      length(pvc) > 1 or length(pv) > 1 ->
        {:error, :ambiguous_csi_storage}

      pvc != [] and uid(hd(pvc)) != volume["pvc_uid"] ->
        {:error, :pvc_identity_changed}

      pv == [] ->
        # Unlike a bare missing PV, the adapter's captured CSI watch result is a
        # durable physical-deletion observation. We never manufacture that flag.
        if pvc == [] and volume["deleted"] == true, do: {:ok, false}, else: {:error, :csi_physical_deletion_unresolved}

      true ->
        object = hd(pv)
        csi = get_in(object, ["spec", "csi"]) || %{}
        claim = get_in(object, ["spec", "claimRef"]) || %{}

        if uid(object) == volume["pv_uid"] and csi["volumeHandle"] == volume["volume_handle"] and csi["driver"] == driver and
             claim["uid"] == volume["pvc_uid"] and claim["namespace"] == config.provider["namespace"] and claim["name"] == volume["pvc_name"] and
             get_in(object, ["spec", "persistentVolumeReclaimPolicy"]) == "Delete" and
             (volume["csi_finalizer_observed"] == true or @pv_finalizer in (get_in(object, ["metadata", "finalizers"]) || [])), do: {:ok, true}, else: {:error, :csi_storage_identity_changed}
    end
  end

  defp captured_csi_driver(config, record, opts) do
    with true <- nonblank?(record.metadata["qualification_uid"]),
         {:ok, contracts} <- KubernetesClient.list(config, kube_collection(config, "configmaps"), opts),
         [contract] <- Enum.filter(contracts, &(uid(&1) == record.metadata["qualification_uid"])),
         true <- contract["immutable"] == true,
         {:ok, data} <- Jason.decode(get_in(contract, ["data", "contract.json"]) || ""),
         true <- data["template_uid"] == record.metadata["template_uid"] and data["template_digest"] == record.metadata["template_digest"],
         true <- nonblank?(data["csi_driver"]) do
      {:ok, data["csi_driver"]}
    else
      _ -> {:error, :captured_csi_driver_unresolved}
    end
  end

  defp compute_inventory(config, kind, opts, token \\ nil, seen \\ MapSet.new(), pages \\ []) do
    query = [maxResults: 100, returnPartialSuccess: false, includeAllScopes: true] ++ if(token, do: [pageToken: token], else: [])
    path = compute_root(config) <> "/aggregated/" <> kind

    with {:ok, %{status: 200, body: body}} <- WorkstationsClient.request(config, :get, path, query, nil, opts),
         true <- complete_compute?(body),
         scopes when is_map(scopes) <- Map.get(body, "items", %{}),
         true <- Enum.all?(scopes, fn {_, scope} -> complete_compute?(scope) and is_list(Map.get(scope, kind, [])) end),
         items <- Enum.flat_map(scopes, fn {_, scope} -> Map.get(scope, kind, []) end),
         true <- Enum.all?(items, &is_map/1) do
      next = body["nextPageToken"]

      cond do
        next in [nil, ""] -> {:ok, pages |> Enum.reverse() |> List.flatten() |> Kernel.++(items)}
        not is_binary(next) or MapSet.member?(seen, next) -> {:error, :compute_pagination_unresolved}
        true -> compute_inventory(config, kind, opts, next, MapSet.put(seen, next), [items | pages])
      end
    else
      _ -> {:error, :compute_inventory_incomplete}
    end
  end

  defp complete_compute?(body) when is_map(body) do
    body["unreachable"] in [nil, []] and body["unreachables"] in [nil, []] and not Map.has_key?(body, "error") and
      get_in(body, ["warning", "code"]) in [nil, "NO_RESULTS_ON_PAGE"]
  end

  defp complete_compute?(_), do: false

  defp compute_reference_path(config, reference, kind) do
    with true <- nonblank?(reference["id"]) and nonblank?(reference["selfLink"]),
         uri <- URI.parse(reference["selfLink"]),
         true <- uri.scheme == "https" and uri.host in ["www.googleapis.com", "compute.googleapis.com"] and uri.query == nil and uri.fragment == nil,
         ["compute", "v1", "projects", project, scope, location, resource, name] <- String.split(uri.path || "", "/", trim: true),
         true <- project == segment(config.provider["project"]) and scope in ["zones", "regions"] and resource == kind and safe_segment?(name),
         true <- (scope == "regions" and location == config.provider["location"]) or (scope == "zones" and String.starts_with?(location, config.provider["location"] <> "-")),
         true <- reference["name"] == name do
      {:ok, uri.path}
    else
      _ -> {:error, :compute_reference_outside_authorized_scope}
    end
  end

  defp negative_control_path?(config, path) when is_binary(path) do
    uri = URI.parse(path)

    if uri.scheme == nil and uri.host == nil and uri.query == nil and uri.fragment == nil and uri.path == path do
      case config.kind do
        "google_workstations" ->
          prefix = workstation_cluster(config) <> "/workstationConfigs/"

          String.starts_with?(path, prefix) and
            case String.split(String.replace_prefix(path, prefix, ""), "/") do
              [template] -> safe_segment?(template)
              [template, "workstations", worker] -> safe_segment?(template) and safe_segment?(worker)
              _ -> false
            end

        "kubernetes" ->
          case kube_path(path) do
            {:ok, ns, resource, name} -> ns == config.provider["namespace"] and resource in ~w(pods services persistentvolumeclaims configmaps sandboxes sandboxtemplates) and safe_segment?(name)
            _ -> false
          end
      end
    else
      false
    end
  end

  defp negative_control_path?(_, _), do: false

  defp negative_identity(%{kind: "google_workstations"}, body) do
    if nonblank?(body["uid"]), do: {:ok, body["uid"]}, else: {:error, :negative_control_uid_unavailable}
  end

  defp negative_identity(%{kind: "kubernetes"}, body) do
    if nonblank?(uid(body)), do: {:ok, uid(body)}, else: {:error, :negative_control_uid_unavailable}
  end

  defp fault_permission(config, profile, scenario, phase, record) do
    cond do
      phase not in ["apply", "restore"] -> {:error, :invalid_physical_fault_phase}
      scenario == "all" and phase == "restore" and record == nil -> :ok
      scenario == "storage_deletion" and profile["storage_fault_authorized"] == true and record != nil -> record_scope(config, record)
      scenario == "node_disconnection" and config.kind == "kubernetes" and profile["node_fault_authorized"] == true and record != nil -> record_scope(config, record)
      true -> {:error, :physical_fault_not_authorized}
    end
  end

  defp fault_resource(_config, _profile, "all", "restore", nil, _opts), do: {:ok, nil}

  defp fault_resource(config, profile, "node_disconnection", phase, record, opts) do
    with true <- phase == "restore" or match?({:ok, _}, exact_pod(config, record, bounded(opts))),
         {:ok, %{node: node}} <- node_observation(config, record, profile, opts) do
      {:ok, %{environment_id: record.key, issue_id: record.issue_id, provider_resource_id: provider_id(record), node: node}}
    else
      _ -> {:error, :physical_fault_node_identity_unresolved}
    end
  end

  defp fault_resource(%{kind: "google_workstations"} = config, _profile, "storage_deletion", _phase, record, opts) do
    references = Enum.filter(record.metadata["backing_resources"] || [], &(is_binary(&1["selfLink"]) and String.contains?(&1["selfLink"], "/disks/")))

    with true <- references != [],
         {:ok, disks} <-
           collect(references, fn reference ->
             with {:ok, path} <- compute_reference_path(config, reference, "disks"),
                  {:ok, disk} <- get(config, path, opts),
                  true <- disk["id"] == reference["id"] and disk["selfLink"] == reference["selfLink"] do
               {:ok, Map.take(disk, ~w(id name selfLink zone region))}
             else
               _ -> {:error, :physical_fault_disk_identity_unresolved}
             end
           end) do
      {:ok, %{environment_id: record.key, issue_id: record.issue_id, provider_resource_id: provider_id(record), backing_resources: disks}}
    else
      _ -> {:error, :physical_fault_disk_identity_unresolved}
    end
  end

  defp fault_resource(%{kind: "kubernetes"} = config, _profile, "storage_deletion", _phase, record, opts) do
    with {:ok, true} <- storage_present(config, record, opts),
         {:ok, pvs} <- KubernetesClient.list(config, "/api/v1/persistentvolumes", opts),
         {:ok, volumes} <-
           collect(Map.values(record.metadata["volumes"] || %{}), fn volume ->
             case Enum.filter(pvs, &(uid(&1) == volume["pv_uid"] and name(&1) == volume["pv_name"] and get_in(&1, ["spec", "csi", "volumeHandle"]) == volume["volume_handle"])) do
               [pv] -> {:ok, Map.take(volume, ~w(pvc_name pvc_uid pv_name pv_uid volume_handle)) |> Map.put("csi_driver", get_in(pv, ["spec", "csi", "driver"]))}
               _ -> {:error, :physical_fault_volume_identity_unresolved}
             end
           end) do
      {:ok, %{environment_id: record.key, issue_id: record.issue_id, provider_resource_id: provider_id(record), volumes: volumes}}
    else
      _ -> {:error, :physical_fault_volume_identity_unresolved}
    end
  end

  defp credential_references(%{kind: "google_workstations", provider: provider}), do: Map.take(provider, ~w(credential_configuration impersonate_service_account))
  defp credential_references(%{kind: "kubernetes", provider: provider}), do: Map.take(provider, ~w(kubeconfig context))

  defp fault_scope(config) do
    references = credential_references(config)

    if safe_segment?(config.deployment_id) and map_size(references) == 2 and
         Enum.all?(references, fn {_, value} -> nonblank?(value) end) and
         Enum.all?(Config.scope(config), fn {_, value} -> nonblank?(value) end) and
         map_size(Config.scope(config)) == 3, do: :ok, else: {:error, :physical_fault_scope_or_credential_reference_missing}
  end

  defp validate_driver(profile) do
    path = profile["fault_driver"]

    with true <- is_binary(path) and Path.type(path) == :absolute,
         expected when is_binary(expected) <- profile["fault_driver_sha256"],
         true <- Regex.match?(~r/^[0-9a-f]{64}$/, expected),
         {:ok, %{type: :regular, size: size, mode: mode}} <- File.lstat(path),
         true <- size > 0 and size <= 16_777_216 and Bitwise.band(mode, 0o111) != 0 and Bitwise.band(mode, 0o022) == 0,
         {:ok, bytes} <- driver_bytes(path),
         true <- sha256(bytes) == expected do
      :ok
    else
      _ -> {:error, :authorized_hash_pinned_physical_fault_driver_required}
    end
  end

  defp driver_bytes(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, 16_777_217) do
          bytes when is_binary(bytes) and byte_size(bytes) in 1..16_777_216 -> {:ok, bytes}
          _ -> {:error, :physical_fault_driver_size_invalid}
        end
      after
        File.close(file)
      end
    end
  end

  defp write_executable(path, bytes) do
    with {:ok, file} <- File.open(path, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(path, 0o500), do: IO.binwrite(file, bytes)
      after
        File.close(file)
      end
    end
  end

  defp record_scope(config, record) do
    if record.kind == config.kind and record.deployment_id == config.deployment_id and record.scope == Config.scope(config), do: :ok, else: {:error, :record_outside_authorized_scope}
  end

  defp owned_deployment?(%{kind: "google_workstations", deployment_id: deployment}, object), do: get_in(object, ["labels", "symphony-deployment"]) == binary_part(sha256(deployment), 0, 32)
  defp owned_deployment?(%{kind: "kubernetes", deployment_id: deployment}, object), do: get_in(object, ["metadata", "labels", "symphony.dev/deployment"]) == kubernetes_digest(deployment)
  defp kubernetes_digest(value), do: value |> Jason.encode!() |> sha256() |> binary_part(0, 40)
  defp safe_scope(config), do: Config.scope(config) |> Map.drop(["kubeconfig"])
  defp provider_id(%{provider_ref: %{name: name, uid: uid}}), do: %{name: name, uid: uid}
  defp provider_id(%{provider_ref: uid}) when is_binary(uid), do: %{uid: uid}

  defp get(config, path, opts) do
    case request(config, :get, path, opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      _ -> {:error, :provider_evidence_request_failed}
    end
  end

  defp kube_collection(config, "sandboxes"), do: "/apis/agents.x-k8s.io/v1beta1/namespaces/" <> segment(config.provider["namespace"]) <> "/sandboxes"
  defp kube_collection(config, "sandboxtemplates"), do: "/apis/extensions.agents.x-k8s.io/v1beta1/namespaces/" <> segment(config.provider["namespace"]) <> "/sandboxtemplates"
  defp kube_collection(config, resource), do: "/api/v1/namespaces/" <> segment(config.provider["namespace"]) <> "/" <> resource

  defp kube_path(path) do
    case String.split(path, "/", trim: true) do
      ["api", "v1", "namespaces", ns, resource] -> {:ok, ns, resource, nil}
      ["api", "v1", "namespaces", ns, resource, name] -> {:ok, ns, resource, name}
      ["apis", group, "v1beta1", "namespaces", ns, resource] when group in ["agents.x-k8s.io", "extensions.agents.x-k8s.io"] -> {:ok, ns, resource, nil}
      ["apis", group, "v1beta1", "namespaces", ns, resource, name] when group in ["agents.x-k8s.io", "extensions.agents.x-k8s.io"] -> {:ok, ns, resource, name}
      _ -> {:error, :unscoped_kubernetes_path}
    end
  end

  defp workstation_cluster(config),
    do: "/v1/projects/" <> segment(config.provider["project"]) <> "/locations/" <> segment(config.provider["location"]) <> "/workstationClusters/" <> segment(config.provider["cluster"])

  defp workstation_parent(config), do: workstation_cluster(config) <> "/workstationConfigs/" <> segment(config.provider["config"])
  defp compute_root(config), do: "/compute/v1/projects/" <> segment(config.provider["project"])
  defp name(object), do: get_in(object, ["metadata", "name"])
  defp uid(object), do: get_in(object, ["metadata", "uid"])
  defp namespace(object), do: get_in(object, ["metadata", "namespace"])
  defp own_gate?(pod), do: Enum.any?(get_in(pod, ["spec", "schedulingGates"]) || [], &(&1["name"] == @gate))

  defp never_scheduled?(pod) do
    get_in(pod, ["spec", "nodeName"]) in [nil, ""] and get_in(pod, ["status", "phase"]) in [nil, "Pending"] and
      Enum.all?(~w(containerStatuses initContainerStatuses ephemeralContainerStatuses), &(get_in(pod, ["status", &1]) in [nil, []]))
  end

  defp argument(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      index -> Enum.at(args, index + 1)
    end
  end

  defp armed?(_callbacks, {_fault, nil}), do: false
  defp armed?(callbacks, key), do: callbacks.armed?.(key)
  defp emit(callbacks, event, id), do: callbacks.event.(%{event: event, issue_id: id})

  defp lose(callbacks, key, event, id) do
    callbacks.disarm.(key)
    emit(callbacks, event, id)
    {:error, :qualification_response_lost}
  end

  defp bounded(opts, ceiling \\ nil) do
    now = System.monotonic_time(:millisecond)
    timeout = Keyword.fetch!(opts, :timeout_ms)
    deadline = min(Keyword.get(opts, :deadline, now + timeout), now + timeout)
    deadline = if is_integer(ceiling), do: min(deadline, ceiling), else: deadline
    opts |> Keyword.put(:deadline, deadline) |> Keyword.put(:timeout_ms, max(1, deadline - now))
  end

  defp remaining(opts), do: max(0, opts[:deadline] - System.monotonic_time(:millisecond))
  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp safe_segment?(value), do: is_binary(value) and Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/, value)
  defp pinned_image?(value), do: is_binary(value) and Regex.match?(~r/^[a-z0-9][a-z0-9._:\/-]*@sha256:[0-9a-f]{64}$/, value)
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp ip_address?(value), do: is_binary(value) and match?({:ok, _}, :inet.parse_address(String.to_charlist(value)))

  defp safe_report_reference(value) do
    if is_binary(value) and Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,199}$/, value), do: value, else: "sha256:" <> sha256(to_string(value))
  end

  defp unique?(items, key), do: Enum.all?(items, &nonblank?(key.(&1))) and length(Enum.uniq_by(items, key)) == length(items)

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp safely(code, fun) do
    fun.()
  rescue
    _ -> {:error, code}
  catch
    _, _ -> {:error, code}
  end
end
