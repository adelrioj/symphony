defmodule SymphonyElixir.ExecutionEnvironment.Kubernetes.Guard do
  @moduledoc false
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Client

  @protocol "symphony-create-drain-v1"
  @limit 196_608
  @phases ["Open", "Closing", "ReadyToFinalize", "Complete"]

  @spec name(map()) :: String.t()
  def name(record) do
    hash = :crypto.hash(:sha256, Jason.encode!([record.deployment_id, record.scope, record.key])) |> Base.encode16(case: :lower)
    "symphony-guard-" <> binary_part(hash, 0, 40)
  end

  @spec decode(map(), map()) :: {:ok, map()} | {:error, term()}
  def decode(object, record) do
    with true <- guard_object?(object, record),
         {:ok, data} when is_map(data) <- Jason.decode(get_in(object, ["data", "guard.json"]) || ""),
         true <- data["protocol"] == @protocol and data["identity"] == identity(record),
         true <- data["phase"] in @phases and is_map(data["record"]) and is_map(data["evidence"]),
         true <- data["hostBinding"] == nil or valid_host_binding?(data["hostBinding"]),
         true <- record_identity?(data["record"], record),
         true <- valid_operations?(data["operations"], uid(object), record),
         true <- valid_phase?(data),
         true <- record.provider_ref == nil or data["parentUID"] == record.provider_ref do
      {:ok, %{object: object, data: data}}
    else
      _ -> unknown(:kubernetes_guard_invalid)
    end
  end

  defp guard_object?(%{"apiVersion" => "v1", "kind" => "ConfigMap"} = object, record) do
    nonempty?(uid(object)) and nonempty?(version(object)) and guard_metadata?(object["metadata"], record)
  end

  defp guard_object?(_, _), do: false

  defp guard_metadata?(metadata, record) do
    labels = metadata["labels"] || %{}

    labels["symphony.dev/create-guard"] == "true" and labels["symphony.dev/environment"] == record.key and
      metadata["name"] == name(record) and metadata["namespace"] == record.scope["namespace"] and
      metadata["ownerReferences"] in [nil, []]
  end

  defp record_identity?(saved, record) do
    fields = [:deployment_id, :key, :scope, :tracker_kind, :issue_id, :kind, :workspace_path, :template_identity]
    Enum.all?(fields, &(saved[Atom.to_string(&1)] == Map.fetch!(record, &1)))
  end

  @spec fetch(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(config, record, opts) do
    case Client.lookup(config, collection(config), name(record), opts) do
      {:ok, object} when is_map(object) -> decode(object, record)
      {:ok, nil} -> unknown(:kubernetes_guard_missing)
      error -> error
    end
  end

  @spec establish(map(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def establish(config, record, encoded, opts) do
    case Client.lookup(config, collection(config), name(record), opts) do
      {:ok, nil} -> bootstrap(config, record, encoded, opts)
      {:ok, existing} -> decode(existing, record)
      error -> error
    end
  end

  defp bootstrap(config, record, encoded, opts) do
    if record.provider_ref != nil or record.metadata["orphaned"] == true do
      unknown(:kubernetes_guard_missing)
    else
      post_bootstrap(config, record, encoded, opts)
    end
  end

  defp post_bootstrap(config, record, encoded, opts) do
    with {:ok, binding} <- host_binding(config, opts) do
      post_bootstrap(config, record, encoded, binding, opts)
    end
  end

  defp post_bootstrap(config, record, encoded, binding, opts) do
    initial = %{
      "protocol" => @protocol,
      "identity" => identity(record),
      "phase" => "Open",
      "operations" => [],
      "parentUID" => nil,
      "closeRequestId" => nil,
      "record" => Jason.decode!(encoded),
      "evidence" => %{}
    }

    initial = if binding, do: Map.put(initial, "hostBinding", binding), else: initial

    metadata = %{
      "name" => name(record),
      "namespace" => config.provider["namespace"],
      "labels" => %{"symphony.dev/create-guard" => "true", "symphony.dev/environment" => record.key}
    }

    body = %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => metadata,
      "data" => %{"guard.json" => Jason.encode!(initial)}
    }

    # Bootstrap POSTs may race, but this permanent name is never deleted or reused.
    Client.request(config, :post, collection(config), body, opts)

    with {:ok, observed} <- fetch(config, record, opts),
         true <- observed.data == initial do
      {:ok, observed}
    else
      _ -> unknown(:kubernetes_guard_bootstrap_unknown)
    end
  end

  @spec open(map(), map(), keyword()) :: :ok | {:error, term()}
  def open(config, record, opts) do
    with {:ok, guard} <- fetch(config, record, opts),
         true <- guard.data["phase"] == "Open" and guard.data["closeRequestId"] == nil do
      :ok
    else
      false -> unknown(:kubernetes_issuance_closed)
      error -> error
    end
  end

  @spec create(map(), map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(config, record, resource, body, opts) do
    with {:ok, guard} <- fetch(config, record, opts),
         {:ok, guard} <- settle(config, record, guard, opts),
         true <- guard.data["phase"] == "Open" and guard.data["closeRequestId"] == nil,
         :ok <- unused_name(config, guard, resource, body, opts) do
      operation = %{
        "id" => random_id(),
        "issuerId" => random_id(),
        "resource" => resource,
        "namespace" => config.provider["namespace"],
        "name" => get_in(body, ["metadata", "name"]),
        "guardUID" => uid(guard.object),
        "parentUID" => if(resource == "secrets", do: guard.data["parentUID"], else: nil),
        "state" => "Issued"
      }

      body = update_in(body, ["metadata", "annotations"], &Map.merge(&1 || %{}, attribution(operation)))
      issue_create(config, record, guard, operation, body, opts)
    else
      false -> unknown(:kubernetes_issuance_closed)
      error -> error
    end
  end

  defp issue_create(config, record, guard, operation, body, opts) do
    target = Map.update!(guard.data, "operations", &(&1 ++ [operation]))

    # Deliberately no read-after-error here: recovered issuance is NOT send permission.
    with true <- byte_size(Jason.encode!(target)) <= @limit,
         {:ok, _issued} <- update(config, record, guard, target, opts, false) do
      response = Client.request(config, :post, resource_collection(config, operation["resource"]), body, opts)
      confirm_create(config, record, operation, create_evidence(response, operation), opts)
    else
      false -> unknown(:kubernetes_guard_full)
      error -> error
    end
  end

  defp create_evidence({:ok, %{status: status, body: object}}, operation) when status in 200..299 do
    if matches?(object, operation), do: object
  end

  defp create_evidence(_, _), do: nil

  defp confirm_create(config, record, operation, positive, opts) do
    with {:ok, current} <- fetch(config, record, opts),
         {:ok, settled} <- settle(config, record, current, opts, %{operation["id"] => positive}),
         committed when is_map(committed) <- committed_operation(settled, operation["id"]),
         {:ok, object} when is_map(object) <-
           Client.lookup(config, resource_collection(config, operation["resource"]), operation["name"], opts),
         true <- matches?(object, committed) do
      {:ok, object}
    else
      _ -> unknown(:kubernetes_create_outcome)
    end
  end

  defp committed_operation(guard, id) do
    Enum.find(guard.data["operations"], &(&1["id"] == id and &1["state"] == "Committed"))
  end

  @spec save(map(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def save(config, record, encoded, opts) do
    with {:ok, guard} <- fetch(config, record, opts),
         true <- guard.data["phase"] in ["Open", "Closing"],
         true <- guard.data["phase"] == "Open" or record.desired == :absent do
      update(config, record, guard, Map.put(guard.data, "record", retain_evidence(guard.data["record"], Jason.decode!(encoded))), opts)
    else
      false -> unknown(:kubernetes_issuance_closed)
      error -> error
    end
  end

  @spec close(map(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def close(config, record, encoded, opts) do
    with {:ok, guard} <- fetch(config, record, opts) do
      if guard.data["phase"] == "Open" do
        target = Map.merge(guard.data, %{"phase" => "Closing", "closeRequestId" => random_id(), "record" => retain_evidence(guard.data["record"], Jason.decode!(encoded))})
        update(config, record, guard, target, opts)
      else
        {:ok, guard}
      end
    end
  end

  @spec settle(map(), map(), map(), keyword(), map()) :: {:ok, map()} | {:error, term()}
  def settle(config, record, guard, opts, positives \\ %{}) do
    Enum.reduce_while(guard.data["operations"], {:ok, guard}, fn operation, {:ok, current} ->
      case settle_operation(config, record, current, operation, opts, positives) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        error -> {:halt, error}
      end
    end)
  end

  defp settle_operation(_config, _record, guard, %{"state" => "Committed"}, _opts, _positives), do: {:ok, guard}

  defp settle_operation(config, record, guard, operation, opts, positives) do
    with {:ok, object} <- observe_operation(config, operation, opts, positives) do
      settle_observed(config, record, guard, operation, object, opts)
    end
  end

  defp observe_operation(config, operation, opts, positives) do
    case positives[operation["id"]] do
      object when is_map(object) -> {:ok, object}
      _ -> Client.lookup(config, resource_collection(config, operation["resource"]), operation["name"], opts)
    end
  end

  defp settle_observed(_config, _record, guard, _operation, nil, _opts), do: {:ok, guard}

  defp settle_observed(config, record, guard, operation, object, opts) do
    if matches?(object, operation) do
      committed = Map.merge(operation, %{"state" => "Committed", "objectUID" => uid(object)})
      target = Map.update!(guard.data, "operations", &Enum.map(&1, fn op -> replace_operation(op, committed) end))
      target = if operation["resource"] == "sandboxes", do: Map.put(target, "parentUID", uid(object)), else: target
      update(config, record, guard, target, opts)
    else
      unknown(:kubernetes_create_attribution_conflict)
    end
  end

  defp replace_operation(%{"id" => id}, %{"id" => id} = committed), do: committed
  defp replace_operation(previous, _committed), do: previous

  @spec drained(map()) :: :ok | {:error, term()}
  def drained(guard) do
    if guard.data["phase"] != "Open" and Enum.all?(guard.data["operations"], &(&1["state"] == "Committed")), do: :ok, else: unknown(:kubernetes_provider_issuance_unresolved)
  end

  @spec transition(map(), map(), map(), String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def transition(config, record, guard, phase, encoded, evidence, opts) do
    allowed = {guard.data["phase"], phase} in [{"Closing", "ReadyToFinalize"}, {"ReadyToFinalize", "Complete"}]
    target = Map.merge(guard.data, %{"phase" => phase, "record" => Jason.decode!(encoded), "evidence" => evidence})
    if allowed, do: update(config, record, guard, target, opts), else: unknown(:kubernetes_guard_transition)
  end

  @spec confirm(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def confirm(config, record, expected, opts) do
    with {:ok, actual} <- fetch(config, record, opts),
         true <- uid(actual.object) == uid(expected.object) and actual.data == expected.data do
      {:ok, actual}
    else
      _ -> unknown(:kubernetes_guard_update_unconfirmed)
    end
  end

  @spec matches?(map() | nil, map()) :: boolean()
  def matches?(object, operation) do
    nonempty?(uid(object)) and matching_kind?(object, operation) and matching_owner?(object, operation) and
      matching_address?(object, operation) and matching_uid?(object, operation) and
      matching_attribution?(object, operation)
  end

  defp matching_kind?(object, %{"resource" => "sandboxes"}),
    do: object["kind"] == "Sandbox" and object["apiVersion"] == "agents.x-k8s.io/v1beta1"

  defp matching_kind?(object, %{"resource" => "secrets"}),
    do: object["kind"] == "Secret" and object["apiVersion"] == "v1"

  defp matching_kind?(_, _), do: false

  defp matching_owner?(object, %{"resource" => "secrets"} = operation) do
    Enum.any?(get_in(object, ["metadata", "ownerReferences"]) || [], fn owner ->
      owner["kind"] == "Sandbox" and owner["uid"] == operation["parentUID"]
    end)
  end

  defp matching_owner?(_, _), do: true

  defp matching_address?(object, operation) do
    get_in(object, ["metadata", "namespace"]) == operation["namespace"] and
      get_in(object, ["metadata", "name"]) == operation["name"]
  end

  defp matching_uid?(object, operation), do: operation["objectUID"] == nil or operation["objectUID"] == uid(object)

  defp matching_attribution?(object, operation) do
    annotations = get_in(object, ["metadata", "annotations"]) || %{}
    Enum.all?(attribution(operation), fn {key, value} -> annotations[key] == value end)
  end

  defp unused_name(config, guard, resource, body, opts) do
    prior = Enum.filter(guard.data["operations"], &(&1["resource"] == resource and &1["name"] == get_in(body, ["metadata", "name"])))

    cond do
      Enum.any?(prior, &(&1["state"] == "Issued")) ->
        unknown(:kubernetes_create_outcome)

      resource == "sandboxes" and prior != [] ->
        unknown(:kubernetes_incarnation_retained)

      resource == "secrets" and not nonempty?(guard.data["parentUID"]) ->
        unknown(:kubernetes_parent_missing)

      true ->
        absent_address(config, resource, get_in(body, ["metadata", "name"]), opts)
    end
  end

  defp absent_address(config, resource, name, opts) do
    case Client.lookup(config, resource_collection(config, resource), name, opts) do
      {:ok, nil} -> :ok
      _ -> unknown(:kubernetes_create_name_retained)
    end
  end

  defp update(config, record, guard, target, opts, recover \\ true) do
    patch = [
      %{"op" => "test", "path" => "/metadata/uid", "value" => uid(guard.object)},
      %{"op" => "test", "path" => "/metadata/resourceVersion", "value" => version(guard.object)},
      %{"op" => "add", "path" => "/data/guard.json", "value" => Jason.encode!(target)}
    ]

    response = Client.request(config, :patch, collection(config) <> "/" <> name(record), patch, opts)

    case response do
      {:ok, %{status: status, body: object}} when status in 200..299 ->
        with {:ok, observed} <- decode(object, record),
             true <- uid(observed.object) == uid(guard.object) and observed.data == target do
          {:ok, observed}
        else
          _ -> unknown(:kubernetes_guard_update_unconfirmed)
        end

      _ when recover ->
        confirm(config, record, %{guard | data: target}, opts)

      _ ->
        unknown(:kubernetes_guard_issuance_unknown)
    end
  end

  defp valid_operations?(operations, guard_uid, record) when is_list(operations) do
    Enum.all?(operations, &valid_operation?(&1, guard_uid, record)) and
      length(Enum.uniq_by(operations, & &1["id"])) == length(operations)
  end

  defp valid_operations?(_, _, _), do: false

  defp valid_operation?(operation, guard_uid, record) when is_map(operation) do
    Enum.all?(~w(id issuerId namespace name guardUID), &nonempty?(operation[&1])) and
      operation["guardUID"] == guard_uid and operation["namespace"] == record.scope["namespace"] and
      valid_operation_parent?(operation, record) and valid_operation_outcome?(operation)
  end

  defp valid_operation?(_, _, _), do: false

  defp valid_operation_parent?(%{"resource" => "sandboxes"} = operation, record),
    do: operation["name"] == record.key and operation["parentUID"] == nil

  defp valid_operation_parent?(%{"resource" => "secrets"} = operation, _record),
    do: nonempty?(operation["parentUID"])

  defp valid_operation_parent?(_, _), do: false

  defp valid_operation_outcome?(%{"state" => "Issued"} = operation), do: not Map.has_key?(operation, "objectUID")
  defp valid_operation_outcome?(%{"state" => "Committed"} = operation), do: nonempty?(operation["objectUID"])
  defp valid_operation_outcome?(_), do: false

  defp retain_evidence(prior, current) do
    old = prior["metadata"] || %{}
    metadata = Map.merge(old, current["metadata"] || %{})

    metadata =
      Enum.reduce(~w(authorized_pods termination_evidence pod_safety volumes controller_pod_operations), metadata, fn key, acc ->
        Map.put(acc, key, Map.merge(old[key] || %{}, metadata[key] || %{}, fn _, previous, next -> merge_evidence(key, previous, next) end))
      end)

    metadata = Map.put(metadata, "authorized_pod_uids", Enum.uniq((old["authorized_pod_uids"] || []) ++ (metadata["authorized_pod_uids"] || [])))
    metadata = if old["creation_journal"] == nil, do: metadata, else: Map.put(metadata, "creation_journal", old["creation_journal"])
    Map.put(current, "metadata", metadata)
  end

  defp merge_evidence("controller_pod_operations", %{"state" => "Committed"} = previous, _next), do: previous
  defp merge_evidence(_key, previous, next), do: Map.merge(previous, next)

  defp valid_phase?(data) do
    parent_ops = Enum.filter(data["operations"], &(&1["resource"] == "sandboxes"))

    parent_binding?(parent_ops, data["parentUID"]) and close_binding?(data) and
      Enum.all?(data["operations"], &(&1["resource"] != "secrets" or &1["parentUID"] == data["parentUID"]))
  end

  defp parent_binding?([], parent_uid), do: parent_uid == nil
  defp parent_binding?([%{"state" => "Issued"}], parent_uid), do: parent_uid == nil
  defp parent_binding?([%{"state" => "Committed", "objectUID" => uid}], parent_uid), do: parent_uid == uid
  defp parent_binding?(_, _), do: false

  defp close_binding?(%{"phase" => "Open"} = data), do: data["closeRequestId"] == nil
  defp close_binding?(data), do: nonempty?(data["closeRequestId"]) and data["record"]["desired"] == "absent"

  defp attribution(op) do
    fields = %{"symphony.dev/create-protocol" => @protocol, "symphony.dev/create-guard-uid" => op["guardUID"], "symphony.dev/create-attempt-id" => op["id"]}
    if op["resource"] == "secrets", do: Map.put(fields, "symphony.dev/create-parent-uid", op["parentUID"]), else: fields
  end

  defp identity(record), do: %{"deploymentID" => record.deployment_id, "environmentKey" => record.key, "scope" => record.scope}
  defp resource_collection(config, "sandboxes"), do: "/apis/agents.x-k8s.io/v1beta1/namespaces/#{URI.encode_www_form(config.provider["namespace"])}/sandboxes"
  defp resource_collection(config, resource), do: "/api/v1/namespaces/#{URI.encode_www_form(config.provider["namespace"])}/#{resource}"
  defp collection(config), do: resource_collection(config, "configmaps")
  defp uid(object), do: get_in(object || %{}, ["metadata", "uid"])
  defp version(object), do: get_in(object || %{}, ["metadata", "resourceVersion"])
  defp nonempty?(value), do: is_binary(value) and value != ""
  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  defp unknown(reason), do: {:error, {:unknown, reason}}

  # The host a permanently-lost-host declaration can name. Captured once, at guard creation,
  # because after the machine is gone none of it can be recovered — and an environment without
  # it can never be declared lost. Every field is an API read of the Node object; nothing here
  # touches the host, so no /etc/machine-id and no SSH.
  #
  # boot_id identifies a boot, not a machine: machine_id + system_uuid + node_uid identify the
  # machine, and a boot_id change on its own is a reboot.
  @host_binding_version 1
  @host_binding_fields ~w(node_name node_uid machine_id system_uuid boot_id)

  # Two outcomes, and the difference is deliberate. A deployment that does not pin its worker to
  # one host has nothing to bind, so the binding is simply absent and that environment can never
  # be declared lost — the documented consequence, not an error. But a deployment that DOES pin a
  # host and then cannot read that Node has failed to capture something it should have, and that
  # fails allocation rather than silently producing an undeclarable environment.
  @spec host_binding(map(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def host_binding(config, opts) do
    case pinned_host(config, opts) do
      {:ok, nil} -> {:ok, nil}
      {:ok, node_name} -> bind_pinned_host(config, node_name, opts)
    end
  end

  defp bind_pinned_host(config, node_name, opts) do
    with {:ok, node} when is_map(node) <- Client.lookup(config, "/api/v1/nodes", node_name, opts),
         info when is_map(info) <- get_in(node, ["status", "nodeInfo"]),
         binding = %{
           "version" => @host_binding_version,
           "node_name" => node_name,
           "node_uid" => get_in(node, ["metadata", "uid"]),
           "machine_id" => info["machineID"],
           "system_uuid" => info["systemUUID"],
           "boot_id" => info["bootID"],
           "node_resource_version" => get_in(node, ["metadata", "resourceVersion"])
         },
         true <- valid_host_binding?(binding) do
      {:ok, binding}
    else
      _ -> unknown(:kubernetes_host_binding_unavailable)
    end
  end

  # The node is pinned by configuration rather than scheduled, so it is known before creation.
  # Exactly one hostname, or the binding is meaningless.
  defp pinned_host(config, opts) do
    # Any inability to resolve a pinned host means there is nothing to bind, never an error:
    # guard creation must not fail for a reason that belongs to placement.
    case Client.lookup(config, template_collection(config), config.provider["template"], opts) do
      {:ok, template} when is_map(template) ->
        host = get_in(template, ["spec", "podTemplate", "spec", "nodeSelector", "kubernetes.io/hostname"])
        if is_binary(host) and String.trim(host) != "", do: {:ok, host}, else: {:ok, nil}

      _ ->
        {:ok, nil}
    end
  end

  defp template_collection(config),
    do: "/apis/extensions.agents.x-k8s.io/v1beta1/namespaces/#{URI.encode_www_form(config.provider["namespace"])}/sandboxtemplates"

  @spec valid_host_binding?(term()) :: boolean()
  def valid_host_binding?(binding) do
    is_map(binding) and binding["version"] == @host_binding_version and
      Enum.all?(@host_binding_fields, &(is_binary(binding[&1]) and String.trim(binding[&1]) != ""))
  end
end
