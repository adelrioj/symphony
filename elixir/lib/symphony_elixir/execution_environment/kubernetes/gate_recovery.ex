defmodule SymphonyElixir.ExecutionEnvironment.Kubernetes.GateRecovery do
  @moduledoc false

  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Client

  @selector "symphony.dev/create-drain"
  @selector_value "symphony-create-drain-v1"
  @provider_annotation "symphony.dev/creation-provider"
  @policy_name "symphony-create-drain-pod-safety"
  @create_gate "request.operation != 'CREATE' || has(object.spec.schedulingGates) && object.spec.schedulingGates.exists(g, g.name == 'symphony.dev/start-authorized')"
  @release_gate "request.operation != 'UPDATE' || !has(oldObject.spec.schedulingGates) || !oldObject.spec.schedulingGates.exists(g, g.name == 'symphony.dev/start-authorized') || (has(object.spec.schedulingGates) && object.spec.schedulingGates.exists(g, g.name == 'symphony.dev/start-authorized')) || request.userInfo.username == variables.provider"
  @provider_variable "has(namespaceObject.metadata.annotations) && 'symphony.dev/creation-provider' in namespaceObject.metadata.annotations ? namespaceObject.metadata.annotations['symphony.dev/creation-provider'] : ''"

  # This is an explicit, one-environment operator authorization, not a general inference from
  # Pod absence. The admission policy and its binding must have existed unchanged before the
  # Sandbox, and the namespace selector/provider identity must have been owned unchanged since
  # before it was created. Otherwise the historical gate cannot be established.
  @spec proof(map(), map(), map(), map(), keyword()) :: {:ok, map() | nil}
  def proof(config, record, sandbox, operation, opts) do
    namespace = get_in(sandbox, ["metadata", "namespace"])

    with {:ok, receipt} <-
           Client.lookup(config, "/api/v1/namespaces/#{namespace}/configmaps", "symphony-gate-recovery", opts),
         true <- receipt != nil,
         {:ok, authorization} <- decode_receipt(receipt, record, sandbox, operation),
         true <- is_binary(record.metadata["qualification_uid"]) and record.metadata["qualification_uid"] != "",
         {:ok, policy} <-
           Client.lookup(
             config,
             "/apis/admissionregistration.k8s.io/v1/validatingadmissionpolicies",
             @policy_name,
             opts
           ),
         {:ok, binding} <-
           Client.lookup(
             config,
             "/apis/admissionregistration.k8s.io/v1/validatingadmissionpolicybindings",
             @policy_name,
             opts
           ),
         {:ok, scope} <- Client.lookup(config, "/api/v1/namespaces", namespace, opts),
         true <- valid_policy?(policy, sandbox, authorization),
         true <- valid_binding?(binding, sandbox, authorization),
         true <- valid_scope?(scope, sandbox, authorization) do
      {:ok,
       %{
         "kind" => "admission_never_executable",
         "uid" => operation["objectUID"],
         "operation_id" => operation["id"],
         "parent_uid" => record.provider_ref,
         "qualification_uid" => record.metadata["qualification_uid"],
         "policy_uid" => authorization["policyUID"],
         "binding_uid" => authorization["bindingUID"],
         "namespace_uid" => authorization["namespaceUID"]
       }}
    else
      {:ok, nil} -> {:ok, nil}
      false -> {:ok, nil}
      _ -> {:ok, nil}
    end
  end

  defp decode_receipt(%{"immutable" => true, "data" => %{"recovery.json" => json}}, record, sandbox, operation)
       when is_binary(json) do
    with {:ok, authorization} <- Jason.decode(json),
         true <- is_map(authorization),
         true <- authorization["parentUID"] == record.provider_ref,
         true <- authorization["podUID"] == operation["objectUID"],
         true <- authorization["operationID"] == operation["id"],
         true <- get_in(sandbox, ["metadata", "uid"]) == record.provider_ref,
         true <-
           Enum.all?(~w(policyUID bindingUID namespaceUID), &(is_binary(authorization[&1]) and authorization[&1] != "")) do
      {:ok, authorization}
    else
      _ -> :invalid
    end
  end

  defp decode_receipt(_, _, _, _), do: :invalid

  defp valid_policy?(%{"metadata" => metadata, "spec" => spec}, sandbox, authorization) do
    stable?(metadata, sandbox, authorization["policyUID"]) and
      spec["failurePolicy"] == "Fail" and
      get_in(spec, ["matchConstraints", "matchPolicy"]) == "Equivalent" and
      get_in(spec, ["matchConstraints", "namespaceSelector"]) in [nil, %{}] and
      get_in(spec, ["matchConstraints", "objectSelector"]) in [nil, %{}] and
      get_in(spec, ["matchConstraints", "excludeResourceRules"]) in [nil, []] and
      spec["matchConditions"] in [nil, []] and spec["paramKind"] == nil and
      Enum.any?(spec["matchConstraints"]["resourceRules"] || [], fn rule ->
        "" in (rule["apiGroups"] || []) and "*" in (rule["apiVersions"] || []) and
          "pods" in (rule["resources"] || []) and
          Enum.all?(["CREATE", "UPDATE"], &(&1 in (rule["operations"] || []))) and
          rule["scope"] == "*"
      end) and
      Enum.all?([@create_gate, @release_gate], fn expected ->
        Enum.any?(spec["validations"] || [], &(whitespace(&1["expression"]) == expected))
      end) and
      Enum.any?(spec["variables"] || [], fn variable ->
        variable["name"] == "provider" and whitespace(variable["expression"]) == @provider_variable
      end)
  end

  defp valid_policy?(_, _, _), do: false

  defp valid_binding?(%{"metadata" => metadata, "spec" => spec}, sandbox, authorization) do
    stable?(metadata, sandbox, authorization["bindingUID"]) and
      spec["policyName"] == @policy_name and "Deny" in (spec["validationActions"] || []) and
      get_in(spec, ["matchResources", "matchPolicy"]) == "Equivalent" and
      get_in(spec, ["matchResources", "namespaceSelector"]) == %{
        "matchLabels" => %{@selector => @selector_value}
      } and
      get_in(spec, ["matchResources", "objectSelector"]) in [nil, %{}] and
      get_in(spec, ["matchResources", "resourceRules"]) in [nil, []] and
      get_in(spec, ["matchResources", "excludeResourceRules"]) in [nil, []] and
      spec["paramRef"] == nil
  end

  defp valid_binding?(_, _, _), do: false

  defp valid_scope?(%{"metadata" => metadata}, sandbox, authorization) do
    parent_created = get_in(sandbox, ["metadata", "creationTimestamp"])
    writers = metadata["managedFields"] || []

    metadata["uid"] == authorization["namespaceUID"] and
      get_in(metadata, ["labels", @selector]) == @selector_value and
      get_in(metadata, ["annotations", @provider_annotation]) == "system:serviceaccount:symphony:symphony-provider" and
      before?(metadata["creationTimestamp"], parent_created) and
      field_stable?(writers, "f:labels", "f:" <> @selector, parent_created) and
      field_stable?(writers, "f:annotations", "f:" <> @provider_annotation, parent_created)
  end

  defp valid_scope?(_, _, _), do: false

  defp field_stable?(writers, group, field, parent_created) do
    matches =
      Enum.filter(writers, fn writer ->
        get_in(writer, ["fieldsV1", "f:metadata", group, field]) != nil
      end)

    matches != [] and Enum.all?(matches, &before?(&1["time"], parent_created))
  end

  defp stable?(metadata, sandbox, uid) do
    metadata["uid"] == uid and metadata["generation"] == 1 and
      before?(metadata["creationTimestamp"], get_in(sandbox, ["metadata", "creationTimestamp"]))
  end

  defp before?(earlier, later) when is_binary(earlier) and is_binary(later), do: earlier <= later
  defp before?(_, _), do: false

  defp whitespace(expression) when is_binary(expression), do: String.replace(expression, ~r/\s+/, " ")
  defp whitespace(_), do: nil
end
