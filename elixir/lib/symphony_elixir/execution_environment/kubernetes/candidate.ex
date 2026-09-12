if Mix.env() == :test do
  defmodule SymphonyElixir.ExecutionEnvironment.Kubernetes.Candidate do
    @moduledoc "Test-artifact-only, operator-pinned candidate validation. Never a qualification assertion."
    alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Client

    @fields ~w(namespace namespace_uid deployment_id consumer_source_commit consumer_artifact_sha256 helper_sha256 contract schema_digests controller_spec_digest controller_authorization runtime_class_spec_digest storage_class_digests network_policy_spec_digest)
    @contract_fields ~w(release stage qualified termination_contract qualification_report template_uid template_digest controller_namespace controller_name controller_uid controller_source_commit controller_image runtime_class_uid runtime_handler storage_class_uids csi_driver network_policy_uid network_profile_label worker_image)
    @schemas ~w(sandboxes.agents.x-k8s.io sandboxtemplates.extensions.agents.x-k8s.io)
    @authorization_fields ~w(service_account workload_role workload_binding management_role management_binding)
    @value_flags ~w(watch-namespace leader-election-namespace cluster-domain metrics-bind-address health-probe-bind-address pprof-block-profile-rate pprof-mutex-profile-fraction kube-api-qps kube-api-burst api-connections sandbox-concurrent-workers sandbox-claim-concurrent-workers sandbox-warm-pool-concurrent-workers sandbox-template-concurrent-workers sandbox-warm-pool-max-batch-size zap-log-level zap-encoder zap-time-encoding zap-stacktrace-level)
    @boolean_flags ~w(version leader-elect extensions enable-tracing enable-pprof enable-pprof-debug separate-watch-connection zap-devel)

    @spec artifact_identity() :: %{mix_env: String.t(), sha256: String.t(), modules: %{String.t() => String.t()}}
    def artifact_identity do
      Application.load(:symphony_elixir)
      {:ok, application_modules} = :application.get_key(:symphony_elixir, :modules)

      modules =
        Enum.map(application_modules, fn module ->
          {:module, ^module} = Code.ensure_loaded(module)
          {^module, bytes, _path} = :code.get_object_code(module)
          {Atom.to_string(module), sha256(bytes)}
        end)

      %{mix_env: "test", sha256: sha256(Jason.encode!(canonical(Map.new(modules)))), modules: Map.new(modules)}
    end

    @spec validate(map(), term()) :: {:ok, map()} | {:error, term()}
    def validate(config, pins) do
      q = pins["contract"]

      with true <- exact_keys?(pins, @fields) and is_map(q) and exact_keys?(q, @contract_fields),
           true <- Enum.all?(@fields -- ~w(contract schema_digests storage_class_digests controller_authorization), &nonblank?(pins[&1])),
           true <- authorization_pins?(pins["controller_authorization"]),
           true <- Enum.all?(@contract_fields -- ~w(qualified storage_class_uids), &nonblank?(q[&1])),
           true <- q["qualified"] == false and q["stage"] == "candidate-unqualified",
           true <- q["termination_contract"] == "candidate-unqualified-kubelet-all-containers-v1",
           true <- pins["namespace"] == get_in(config, [:provider, "namespace"]) and pins["deployment_id"] == config[:deployment_id],
           true <- hex?(pins["consumer_source_commit"], 40) and hex?(q["controller_source_commit"], 40),
           true <- image?(q["controller_image"]) and image?(q["worker_image"]),
           true <- exact_keys?(pins["schema_digests"], @schemas) and Enum.all?(pins["schema_digests"], fn {_, hash} -> hex?(hash, 40) end),
           true <- hex?(pins["controller_spec_digest"], 40) and hex?(q["template_digest"], 40) and hex?(pins["runtime_class_spec_digest"], 40) and hex?(pins["network_policy_spec_digest"], 40),
           true <- is_list(q["storage_class_uids"]) and q["storage_class_uids"] != [] and Enum.all?(q["storage_class_uids"], &nonblank?/1),
           true <- exact_keys?(pins["storage_class_digests"], q["storage_class_uids"]) and Enum.all?(pins["storage_class_digests"], fn {_, hash} -> hex?(hash, 40) end),
           true <- hex?(pins["helper_sha256"], 64) and pins["consumer_artifact_sha256"] == artifact_identity().sha256,
           helper when is_binary(helper) <- System.find_executable("symphony-kubernetes-create"),
           {:ok, bytes} <- File.read(helper),
           true <- sha256(bytes) == pins["helper_sha256"] do
        {:ok,
         %{
           release: q["release"],
           termination_contract: q["termination_contract"],
           controller_source_commit: q["controller_source_commit"],
           controller_image: q["controller_image"],
           schemas: Map.to_list(pins["schema_digests"]),
           candidate: pins
         }}
      else
        _ -> {:error, {:invalid, :kubernetes_candidate_identity}}
      end
    rescue
      _ -> {:error, {:invalid, :kubernetes_candidate_identity}}
    end

    @spec contract(map(), map(), map(), map(), keyword()) :: :ok | {:error, term()}
    def contract(config, q, template, pins, opts) do
      ns = URI.encode(pins["namespace"], &URI.char_unreserved?/1)
      spec = get_in(template, ["spec", "podTemplate", "spec"]) || %{}
      containers = (spec["containers"] || []) ++ (spec["initContainers"] || [])

      with true <- q == pins["contract"],
           true <- containers != [] and Enum.all?(containers, &(&1["image"] == q["worker_image"])),
           {:ok, %{status: 200, body: namespace}} <- Client.request(config, :get, "/api/v1/namespaces/#{ns}", nil, opts),
           true <- get_in(namespace, ["metadata", "uid"]) == pins["namespace_uid"],
           {:ok, runtimes} <- Client.list(config, "/apis/node.k8s.io/v1/runtimeclasses", opts),
           runtime when is_map(runtime) <- Enum.find(runtimes, &(uid(&1) == q["runtime_class_uid"])),
           true <- digest(Map.take(runtime, ["handler", "overhead", "scheduling"])) == pins["runtime_class_spec_digest"],
           {:ok, classes} <- Client.list(config, "/apis/storage.k8s.io/v1/storageclasses", opts),
           true <-
             Enum.all?(pins["storage_class_digests"], fn {uid, expected} ->
               class = Enum.find(classes, &(uid(&1) == uid))
               is_map(class) and digest(Map.drop(class, ["metadata", "apiVersion", "kind"])) == expected
             end),
           {:ok, controllers} <- Client.list(config, "/apis/apps/v1/namespaces/#{URI.encode(q["controller_namespace"], &URI.char_unreserved?/1)}/deployments", opts),
           controller when is_map(controller) <- Enum.find(controllers, &(uid(&1) == q["controller_uid"])),
           true <- digest(controller["spec"]) == pins["controller_spec_digest"],
           true <- scoped_controller?(controller, q["controller_image"], pins["namespace"], q["controller_namespace"]),
           :ok <- controller_authorization(config, controller, pins, opts),
           {:ok, policies} <- Client.list(config, "/apis/networking.k8s.io/v1/namespaces/#{ns}/networkpolicies", opts),
           policy when is_map(policy) <- Enum.find(policies, &(uid(&1) == q["network_policy_uid"])),
           true <- digest(policy["spec"]) == pins["network_policy_spec_digest"] do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, {:invalid, :kubernetes_candidate_contract_mismatch}}
      end
    end

    defp scoped_controller?(controller, image, namespace, management_namespace) do
      case Enum.filter(get_in(controller, ["spec", "template", "spec", "containers"]) || [], &(&1["image"] == image)) do
        [container] ->
          with true <- container["command"] in [nil, []],
               {:ok, flags} <- controller_flags(container["args"] || [], %{}) do
            flags["watch-namespace"] == namespace and flags["leader-election-namespace"] == management_namespace and
              Map.get(flags, "leader-elect", "true") == "true" and Map.get(flags, "extensions", "false") == "false" and
              Map.get(flags, "version", "false") == "false"
          else
            _ -> false
          end

        _ ->
          false
      end
    end

    # Only canonical double-dash flags are accepted. This rejects Go flag.Parse's
    # positional/-- stopping cases instead of searching beyond its stopping point.
    defp controller_flags([], flags), do: {:ok, flags}

    defp controller_flags(["--watch-namespace", value | rest], flags),
      do: put_controller_flag("watch-namespace", value, rest, flags)

    defp controller_flags([arg | rest], flags) when is_binary(arg) do
      case Regex.run(~r/\A--([a-z][a-z0-9-]*)=([^\r\n]*)\z/, arg, capture: :all_but_first) do
        [name, value] ->
          put_controller_flag(name, value, rest, flags)

        _ ->
          if String.replace_prefix(arg, "--", "") in @boolean_flags and String.starts_with?(arg, "--"), do: put_controller_flag(String.replace_prefix(arg, "--", ""), "true", rest, flags), else: :error
      end
    end

    defp controller_flags(_, _), do: :error

    defp put_controller_flag(name, value, rest, flags) do
      valid =
        (name in @value_flags and nonblank?(value) and not String.starts_with?(value, "--")) or
          (name in @boolean_flags and value in ["true", "false"])

      if valid and not Map.has_key?(flags, name), do: controller_flags(rest, Map.put(flags, name, value)), else: :error
    end

    defp authorization_pins?(pins) do
      exact_keys?(pins, @authorization_fields) and
        Enum.all?(pins, fn {_, pin} ->
          exact_keys?(pin, ~w(name namespace uid digest)) and Enum.all?(~w(name namespace uid), &nonblank?(pin[&1])) and hex?(pin["digest"], 40)
        end)
    end

    defp controller_authorization(config, controller, pins, opts) do
      auth = pins["controller_authorization"]
      sa = auth["service_account"]
      management = pins["contract"]["controller_namespace"]
      rbac = "/apis/rbac.authorization.k8s.io/v1/"

      with true <- sa["namespace"] == management and get_in(controller, ["spec", "template", "spec", "serviceAccountName"]) == sa["name"],
           {:ok, accounts} <- Client.list(config, "/api/v1/namespaces/#{URI.encode(management, &URI.char_unreserved?/1)}/serviceaccounts", opts),
           true <- Enum.any?(accounts, &pinned_authorization?(&1, sa)),
           {:ok, roles} <- Client.list(config, rbac <> "roles", opts),
           {:ok, bindings} <- Client.list(config, rbac <> "rolebindings", opts),
           {:ok, cluster_roles} <- Client.list(config, rbac <> "clusterroles", opts),
           {:ok, cluster_bindings} <- Client.list(config, rbac <> "clusterrolebindings", opts),
           true <- pinned_role_pair?(roles, bindings, auth["workload_role"], auth["workload_binding"], sa, pins["namespace"], :workload),
           true <- pinned_role_pair?(roles, bindings, auth["management_role"], auth["management_binding"], sa, management, :lease),
           true <- Enum.all?(bindings, &bounded_binding?(&1, false, sa, auth, roles, cluster_roles)),
           true <- Enum.all?(cluster_bindings, &bounded_binding?(&1, true, sa, auth, roles, cluster_roles)) do
        :ok
      else
        _ -> {:error, {:invalid, :kubernetes_candidate_authorization}}
      end
    end

    defp pinned_authorization?(object, pin) do
      Map.take(object["metadata"] || %{}, ~w(name namespace uid)) == Map.take(pin, ~w(name namespace uid)) and
        digest(Map.drop(object, ~w(metadata apiVersion kind))) == pin["digest"]
    end

    defp pinned_role_pair?(roles, bindings, role_pin, binding_pin, sa, namespace, kind) do
      role = Enum.find(roles, &pinned_authorization?(&1, role_pin))
      binding = Enum.find(bindings, &pinned_authorization?(&1, binding_pin))

      role_pin["namespace"] == namespace and binding_pin["namespace"] == namespace and is_map(role) and is_map(binding) and
        binding["roleRef"] == %{"apiGroup" => "rbac.authorization.k8s.io", "kind" => "Role", "name" => role_pin["name"]} and
        binding["subjects"] == [%{"kind" => "ServiceAccount", "name" => sa["name"], "namespace" => sa["namespace"]}] and
        is_list(role["rules"]) and role["rules"] != [] and Enum.all?(role["rules"], &scoped_rule?(&1, kind))
    end

    defp scoped_rule?(rule, kind) do
      groups = rule["apiGroups"]
      resources = rule["resources"]
      verbs = rule["verbs"]

      is_list(groups) and groups != [] and is_list(resources) and resources != [] and is_list(verbs) and verbs != [] and
        rule["nonResourceURLs"] in [nil, []] and Enum.all?(verbs, &(&1 in ~w(get list watch create update patch delete))) and
        Enum.all?(groups, fn group ->
          Enum.all?(resources, fn resource ->
            case kind do
              :lease ->
                group == "coordination.k8s.io" and resource == "leases"

              :workload ->
                (group == "" and resource in ~w(pods persistentvolumeclaims services events)) or
                  (group == "events.k8s.io" and resource == "events") or
                  (group == "agents.x-k8s.io" and resource in ~w(sandboxes sandboxes/status sandboxes/finalizers))
            end
          end)
        end)
    end

    defp bounded_binding?(binding, cluster?, sa, auth, roles, cluster_roles) do
      subjects = binding["subjects"] || []

      if Enum.any?(subjects, &controller_subject?(&1, binding, cluster?, sa)) do
        pinned = not cluster? and Enum.any?(~w(workload_binding management_binding), &pinned_authorization?(binding, auth[&1]))
        ref = binding["roleRef"] || %{}

        role =
          cond do
            ref["apiGroup"] != "rbac.authorization.k8s.io" ->
              nil

            ref["kind"] == "ClusterRole" ->
              Enum.find(cluster_roles, &(get_in(&1, ["metadata", "name"]) == ref["name"]))

            ref["kind"] == "Role" and not cluster? ->
              Enum.find(roles, &(get_in(&1, ["metadata", "name"]) == ref["name"] and get_in(&1, ["metadata", "namespace"]) == get_in(binding, ["metadata", "namespace"])))

            true ->
              nil
          end

        pinned or (is_map(role) and is_list(role["rules"]) and Enum.all?(role["rules"], &read_or_self_review?/1))
      else
        true
      end
    end

    defp controller_subject?(subject, binding, cluster?, sa) do
      case subject["kind"] do
        "ServiceAccount" ->
          subject["name"] == sa["name"] and
            (subject["namespace"] || if(not cluster?, do: get_in(binding, ["metadata", "namespace"]))) == sa["namespace"]

        "User" ->
          subject["name"] == "system:serviceaccount:#{sa["namespace"]}:#{sa["name"]}"

        "Group" ->
          subject["name"] in ["system:authenticated", "system:serviceaccounts", "system:serviceaccounts:#{sa["namespace"]}"]

        _ ->
          false
      end
    end

    defp read_or_self_review?(rule) do
      verbs = rule["verbs"] || []
      resources = rule["resources"] || []
      groups = rule["apiGroups"] || []
      urls = rule["nonResourceURLs"] || []

      read_only =
        verbs != [] and Enum.all?(verbs, &(&1 in ~w(get list watch))) and resources == [] and groups == [] and
          is_list(urls) and urls != [] and Enum.all?(urls, &(is_binary(&1) and String.starts_with?(&1, "/")))

      self_review =
        verbs == ["create"] and rule["nonResourceURLs"] in [nil, []] and resources != [] and
          ((groups == ["authorization.k8s.io"] and Enum.all?(resources, &(&1 in ~w(selfsubjectaccessreviews selfsubjectrulesreviews)))) or
             (groups == ["authentication.k8s.io"] and resources == ["selfsubjectreviews"]))

      read_only or self_review
    end

    # Same canonical identity convention as the adapter's existing stock template/schema pins.
    @spec digest(term()) :: String.t()
    def digest(value), do: sha256(Jason.encode!(canonical(value))) |> binary_part(0, 40)
    @spec sha256(iodata()) :: String.t()
    def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    defp canonical(map) when is_map(map), do: map |> Enum.map(fn {key, value} -> [key, canonical(value)] end) |> Enum.sort()
    defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
    defp canonical(value), do: value
    defp uid(object), do: get_in(object, ["metadata", "uid"])
    defp exact_keys?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
    defp nonblank?(value), do: is_binary(value) and String.trim(value) != "" and not String.contains?(value, ["\n", "\r", <<0>>])
    defp hex?(value, length), do: is_binary(value) and byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)
    defp image?(value), do: is_binary(value) and Regex.match?(~r/\A[^\s@]+@sha256:[0-9a-f]{64}\z/, value)
  end
end
