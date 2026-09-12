Code.require_file("../support/managed_environment_fixture/provider.exs", __DIR__)

defmodule SymphonyElixir.ManagedEnvironmentProviderFixtureTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ManagedEnvironmentFixture.Provider
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Client

  test "single-attempt helper response loss retains exact accepted create attribution", context do
    config = kubernetes_config(context)
    entry = %{attempt_id: "worker-attempt", record: %{key: "se-ticket", issue_id: "issue-1"}}

    body = %{
      "apiVersion" => "agents.x-k8s.io/v1beta1",
      "kind" => "Sandbox",
      "metadata" => %{
        "name" => "se-ticket",
        "namespace" => "workers",
        "labels" => %{"symphony.dev/deployment" => digest(Jason.encode!(config.deployment_id), 40)},
        "annotations" => %{
          "symphony.dev/create-protocol" => "symphony-create-drain-v1",
          "symphony.dev/create-guard-uid" => "guard-uid",
          "symphony.dev/create-attempt-id" => "create-attempt"
        }
      }
    }

    Process.put(:fault_armed, true)

    command = fn executable, args, _opts ->
      assert Path.basename(executable) == "symphony-kubernetes-create"

      assert Enum.at(args, Enum.find_index(args, &(&1 == "--path")) + 1) ==
               "/apis/agents.x-k8s.io/v1beta1/namespaces/workers/sandboxes"

      file = Enum.at(args, Enum.find_index(args, &(&1 == "--file")) + 1)
      accepted = File.read!(file) |> Jason.decode!() |> put_in(["metadata", "uid"], "sandbox-uid")
      accepted = if Process.get(:changed_guard), do: put_in(accepted, ["metadata", "annotations", "symphony.dev/create-guard-uid"], "replacement"), else: accepted
      send(self(), :create_sent)
      {:ok, %{status: 0, output: Jason.encode!(accepted)}}
    end

    callbacks = %{
      armed?: fn {:lose_create, "issue-1"} -> Process.get(:fault_armed) end,
      disarm: fn _ -> Process.put(:fault_armed, false) end,
      event: fn event -> send(self(), {:event, event}) end
    }

    opts = [timeout_ms: 10_000, task_supervisor: start_supervised!(Task.Supervisor), command_fun: command]
    opts = Provider.fault_options(config, entry, :prepare, opts, callbacks)

    assert {:error, {:unknown, :kubernetes_command_failed}} =
             Client.request(config, :post, "/apis/agents.x-k8s.io/v1beta1/namespaces/workers/sandboxes", body, opts)

    assert_receive :create_sent
    refute_receive :create_sent
    assert_receive {:event, %{event: :create_accepted, attempt_id: "worker-attempt", create_attempt_id: "create-attempt", guard_uid: "guard-uid", resource_uid: "sandbox-uid"}}
    assert_receive {:event, %{event: :create_response_lost, create_attempt_id: "create-attempt", guard_uid: "guard-uid"}}
    refute Process.get(:fault_armed)
    Process.put(:fault_armed, true)
    Process.put(:changed_guard, true)
    assert {:ok, %{status: 200}} = Client.request(config, :post, "/apis/agents.x-k8s.io/v1beta1/namespaces/workers/sandboxes", body, opts)
    assert_receive :create_sent
    refute_receive {:event, %{event: :create_accepted}}
    refute_receive {:event, %{event: :create_response_lost}}
    assert Process.get(:fault_armed)
  end

  test "stop guard patch denial uses impersonated kubectl authorization and mutation", context do
    config = put_in(kubernetes_config(context), [:provider, "qualification"], %{"denied_identity" => "qualification-denied"})
    entry = %{attempt_id: "worker-attempt", record: %{key: "se-ticket", issue_id: "issue-1"}}
    patch = [%{"op" => "test", "path" => "/metadata/uid", "value" => "guard-uid"}]

    command = fn executable, args, _opts ->
      assert Path.basename(executable) == "kubectl"
      assert "--as=qualification-denied" in args

      if "create" in args do
        assert Enum.at(args, Enum.find_index(args, &(&1 == "--raw")) + 1) ==
                 "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews"

        file = Enum.at(args, Enum.find_index(args, &(&1 == "-f")) + 1)
        review = File.read!(file) |> Jason.decode!()
        assert review["spec"]["resourceAttributes"] == %{"namespace" => "workers", "verb" => "patch", "group" => "", "resource" => "configmaps", "name" => "symphony-guard-test"}
        {:ok, %{status: 0, output: Jason.encode!(%{"status" => %{"allowed" => false}})}}
      else
        send(self(), :guard_patch_denied)
        output = if Process.get(:local_parse_error), do: "error: unknown flag: --as", else: "Error from server (Forbidden): configmaps is forbidden"
        {:ok, %{status: 1, output: output}}
      end
    end

    callbacks = %{armed?: fn _ -> true end, event: fn event -> send(self(), {:event, event}) end}
    opts = [timeout_ms: 10_000, task_supervisor: start_supervised!(Task.Supervisor), command_fun: command]
    opts = Provider.fault_options(config, entry, :stop, opts, callbacks)

    assert {:error, {:unknown, :kubernetes_unstructured_response}} =
             Client.request(config, :patch, "/api/v1/namespaces/workers/configmaps/symphony-guard-test", patch, opts)

    assert_receive :guard_patch_denied
    assert_receive {:event, %{event: :stop_denied, attempt_id: "worker-attempt", guard_uid: "guard-uid", resource_name: "symphony-guard-test"}}
    refute_receive :guard_patch_denied
    Process.put(:local_parse_error, true)

    assert {:error, {:unknown, :kubernetes_command_failed}} =
             Client.request(config, :patch, "/api/v1/namespaces/workers/configmaps/symphony-guard-test", patch, opts)

    refute_receive {:event, %{event: :stop_denied}}
  end

  test "guard-only and post-parent ownership remain unknown inventory obligations", context do
    config = kubernetes_config(context)
    scope = Map.take(config.provider, ~w(kubeconfig context namespace))

    record = %{
      key: "se-ticket",
      deployment_id: config.deployment_id,
      tracker_kind: "memory",
      issue_id: "ticket",
      kind: "kubernetes",
      scope: scope,
      workspace_path: "/workspaces/se-ticket",
      template_identity: "template",
      metadata: %{},
      pending: [],
      provider_ref: nil,
      desired: :stopped
    }

    guard_name = SymphonyElixir.ExecutionEnvironment.Kubernetes.Guard.name(record)

    for phase <- ["Open", "ReadyToFinalize"] do
      parent_uid = if phase == "Open", do: nil, else: "parent-uid"

      operations =
        if parent_uid do
          [
            %{
              "id" => "create-parent",
              "issuerId" => "issuer",
              "resource" => "sandboxes",
              "namespace" => "workers",
              "name" => record.key,
              "guardUID" => "guard-uid",
              "parentUID" => nil,
              "state" => "Committed",
              "objectUID" => parent_uid
            }
          ]
        else
          []
        end

      saved = %{record | desired: if(phase == "Open", do: :stopped, else: :absent), provider_ref: parent_uid}

      data = %{
        "protocol" => "symphony-create-drain-v1",
        "identity" => %{"deploymentID" => config.deployment_id, "environmentKey" => record.key, "scope" => scope},
        "phase" => phase,
        "operations" => operations,
        "parentUID" => parent_uid,
        "closeRequestId" => if(phase == "Open", do: nil, else: "close-request"),
        "record" => saved,
        "evidence" => %{}
      }

      guard = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => guard_name,
          "namespace" => "workers",
          "uid" => "guard-uid",
          "resourceVersion" => "7",
          "labels" => %{"symphony.dev/create-guard" => "true", "symphony.dev/environment" => record.key}
        },
        "data" => %{"guard.json" => Jason.encode!(data)}
      }

      pods =
        if parent_uid do
          owner = %{"apiVersion" => "agents.x-k8s.io/v1beta1", "kind" => "Sandbox", "name" => record.key, "uid" => parent_uid}

          [
            pod()
            |> put_in(["metadata", "labels"], %{"symphony.dev/environment" => record.key})
            |> put_in(["metadata", "ownerReferences"], [owner])
          ]
        else
          []
        end

      opts =
        kubernetes_opts(fn path ->
          items =
            case Path.basename(path) do
              "configmaps" -> [guard]
              "pods" -> pods
              _ -> []
            end

          %{"items" => items, "metadata" => %{}}
        end)

      assert {:ok, %{records: [observed], live_worker_counts: counts}} = Provider.inventory(config, opts)
      assert counts == %{"se-ticket" => length(pods)}
      assert observed.phase == :unknown
      refute observed.absent?
      assert observed.metadata["guard"] == %{"kind" => "ConfigMap", "name" => guard_name, "uid" => "guard-uid", "namespace" => "workers", "phase" => phase}
    end
  end

  @workstation_path "/v1/projects/p/locations/l/workstationClusters/c/workstationConfigs/other/workstations/control"
  @pod_path "/api/v1/namespaces/workers/pods/control"

  # These injected JSON protocols are local unit evidence, never live qualification.
  test "same UID Workstations configuration and lifecycle mutations change the negative control" do
    body = %{"uid" => "control-uid", "state" => "STATE_RUNNING", "labels" => %{"owner" => "other"}}
    baseline = workstation_snapshot(body)
    refute workstation_snapshot(Map.put(body, "state", "STATE_STOPPED")) == baseline
    refute workstation_snapshot(put_in(body, ["labels", "owner"], "changed")) == baseline
  end

  test "Kubernetes spec ownership and deletion changes cannot hide behind an unchanged UID", context do
    config = kubernetes_config(context)
    body = pod()
    baseline = kubernetes_snapshot(config, body)
    refute kubernetes_snapshot(config, put_in(body, ["spec", "nodeName"], "different-node")) == baseline
    refute kubernetes_snapshot(config, put_in(body, ["metadata", "labels", "owner"], "changed")) == baseline
    deleting = put_in(body, ["metadata", "deletionTimestamp"], "2026-09-11T10:00:00Z")
    refute kubernetes_snapshot(config, deleting) == baseline
  end

  test "annotation-only collateral changes alter the fingerprint without exposing annotation values", context do
    config = kubernetes_config(context)
    body = put_in(pod(), ["metadata", "annotations"], %{"operator.example/policy" => "PRIVATE-BASELINE"})
    baseline = kubernetes_snapshot(config, body)
    changed = put_in(body, ["metadata", "annotations", "operator.example/policy"], "PRIVATE-CHANGED")
    observed = kubernetes_snapshot(config, changed)
    refute observed == baseline
    refute Jason.encode!([baseline, observed]) =~ "PRIVATE-"
  end

  test "orphaned durable CSI handles remain exact despite opaque punctuation and length", context do
    config = kubernetes_config(context)
    handle = "_tenant#disk%2F=雪\\\"\n" <> String.duplicate("x", 2_100)
    scope = Map.take(config.provider, ~w(kubeconfig context namespace))

    record = %{
      key: "se-ticket",
      deployment_id: config.deployment_id,
      tracker_kind: "memory",
      issue_id: "opaque-issue",
      kind: "kubernetes",
      scope: scope,
      workspace_path: "/home/user/workspaces/ticket",
      desired: :stopped,
      pending: [],
      metadata: %{"volumes" => %{"claim" => %{"pv_uid" => "pv-uid", "volume_handle" => handle}}}
    }

    orphan =
      pod()
      |> put_in(["metadata", "labels"], %{"symphony.dev/deployment" => digest(Jason.encode!(config.deployment_id), 40)})
      |> put_in(["metadata", "annotations"], %{"symphony.dev/record" => Jason.encode!(record)})

    opts =
      kubernetes_opts(fn path ->
        %{"items" => if(String.ends_with?(path, "/pods"), do: [orphan], else: []), "metadata" => %{}}
      end)

    assert {:error, {:unknown, {:qualification_inventory_unresolved, resources}}} = Provider.inventory(config, opts)
    assert Enum.any?(Jason.decode!(Jason.encode!(resources)), &(&1["volume_handle"] == handle))
    assert_safe_resources(resources)
  end

  test "canonical fingerprints ignore volatile versions timestamps and map insertion order", context do
    config = kubernetes_config(context)
    baseline = kubernetes_snapshot(config, pod())

    bookkeeping =
      pod()
      |> put_in(["metadata", "resourceVersion"], "99")
      |> put_in(["metadata", "managedFields"], [%{"time" => "later", "manager" => "controller"}])
      |> put_in(["status", "conditions"], [%{"type" => "Ready", "status" => "True", "lastTransitionTime" => "later"}])
      |> Enum.reverse()
      |> Map.new()

    assert kubernetes_snapshot(config, bookkeeping) == baseline
    assert [%{fingerprint: fingerprint}] = baseline
    assert Regex.match?(~r/^[0-9a-f]{64}$/, fingerprint)

    body = %{"uid" => "control-uid", "state" => "STATE_RUNNING"}
    volatile = Map.merge(body, %{"etag" => "new", "updateTime" => "later", "startTime" => "later"})
    assert workstation_snapshot(volatile) == workstation_snapshot(body)
  end

  test "orphan backing inventory errors retain safe disk references without response bodies" do
    disk = %{
      "id" => "123",
      "name" => "orphan",
      "selfLink" => "https://www.googleapis.com/compute/v1/projects/p/zones/l-a/disks/orphan",
      "labels" => workstation_labels(),
      "secret" => "raw-secret-body"
    }

    request = fn req ->
      case Path.basename(URI.parse(req[:url]).path) do
        "workstationConfigs" -> response(%{"workstationConfigs" => []})
        "operations" -> response(%{"operations" => []})
        "instances" -> response(%{"items" => %{}})
        "disks" -> response(%{"items" => %{"zones/l-a" => %{"disks" => [disk]}}})
      end
    end

    assert {:error, {:unknown, {:qualification_inventory_unresolved, resources}}} =
             Provider.inventory(workstations_config(), workstation_opts(request))

    assert Enum.any?(resources, &(&1["id"] == "123" and &1["selfLink"] == disk["selfLink"]))
    refute inspect(resources) =~ "raw-secret-body"
    assert_safe_resources(resources)
  end

  test "invalid owned Kubernetes records retain their identifiers without annotations", context do
    config = kubernetes_config(context)
    deployment = digest(Jason.encode!(config.deployment_id), 40)

    invalid =
      pod()
      |> put_in(["metadata", "labels"], %{"symphony.dev/deployment" => deployment})
      |> put_in(["metadata", "annotations"], %{"symphony.dev/record" => "raw-secret-body"})

    opts =
      kubernetes_opts(fn path ->
        items = if String.ends_with?(path, "/pods"), do: [invalid], else: []
        %{"items" => items, "metadata" => %{}}
      end)

    assert {:error, {:unknown, {:qualification_inventory_unresolved, resources}}} = Provider.inventory(config, opts)
    identifiers = Enum.flat_map(resources, &Map.values/1)
    assert "control" in identifiers
    assert "control-uid" in identifiers
    refute inspect(resources) =~ "raw-secret-body"
    assert_safe_resources(resources)
  end

  test "observed owned workers survive a later ownership classification failure" do
    Process.put(:fixture_instance_reads, 0)

    workers =
      Enum.map(["first", "second"], fn id ->
        %{
          "id" => id,
          "name" => id,
          "selfLink" => "https://www.googleapis.com/compute/v1/projects/p/zones/l-a/instances/" <> id,
          "labels" => workstation_labels(),
          "status" => "RUNNING",
          "metadata" => %{"secret" => "raw-secret-body"}
        }
      end)

    request = fn req ->
      case Path.basename(URI.parse(req[:url]).path) do
        "workstationConfigs" ->
          response(%{"workstationConfigs" => []})

        "operations" ->
          response(%{"operations" => []})

        "disks" ->
          response(%{"items" => %{}})

        "instances" ->
          reads = Process.get(:fixture_instance_reads)
          Process.put(:fixture_instance_reads, reads + 1)
          items = if reads == 0, do: [], else: workers
          response(%{"items" => %{"zones/l-a" => %{"instances" => items}}})
      end
    end

    assert {:error, {:unknown, {:qualification_inventory_unresolved, resources}}} =
             Provider.inventory(workstations_config(), workstation_opts(request))

    assert Enum.any?(resources, &(&1["id"] == "first"))
    assert Enum.any?(resources, &(&1["id"] == "second"))
    refute inspect(resources) =~ "raw-secret-body"
    assert_safe_resources(resources)
  end

  test "unrecognized provider failures remain fixed safe errors" do
    opts = workstation_opts(fn _ -> {:error, %{"secret" => "raw-secret-body"}} end)
    assert Provider.inventory(workstations_config(), opts) == {:error, :complete_owned_inventory_unavailable}
  end

  test "ConfigMap contents remain meaningful even when their keys look like bookkeeping", context do
    config = kubernetes_config(context)
    path = "/api/v1/namespaces/workers/configmaps/control"
    body = %{"metadata" => pod()["metadata"], "immutable" => true, "data" => %{"updateTime" => "first"}}
    baseline = kubernetes_snapshot(config, body, path)
    changed = put_in(body, ["data", "updateTime"], "second")
    refute kubernetes_snapshot(config, changed, path) == baseline
    refute kubernetes_snapshot(config, Map.put(body, "immutable", false), path) == baseline
  end

  test "service routes and PVC storage bindings are covered by negative controls", context do
    config = kubernetes_config(context)
    service_path = "/api/v1/namespaces/workers/services/control"
    pvc_path = "/api/v1/namespaces/workers/persistentvolumeclaims/control"
    service = %{"metadata" => pod()["metadata"], "spec" => %{"selector" => %{"app" => "original"}}}
    pvc = %{"metadata" => pod()["metadata"], "spec" => %{"volumeName" => "original-volume"}}

    refute kubernetes_snapshot(config, service, service_path) ==
             kubernetes_snapshot(config, put_in(service, ["spec", "selector", "app"], "different"), service_path)

    refute kubernetes_snapshot(config, pvc, pvc_path) ==
             kubernetes_snapshot(config, put_in(pvc, ["spec", "volumeName"], "different-volume"), pvc_path)
  end

  test "nested template ownership and sandbox suspension are meaningful but template versions are not", context do
    config = kubernetes_config(context)
    template_path = "/apis/extensions.agents.x-k8s.io/v1beta1/namespaces/workers/sandboxtemplates/control"
    sandbox_path = "/apis/agents.x-k8s.io/v1beta1/namespaces/workers/sandboxes/control"
    template = %{"metadata" => pod()["metadata"], "spec" => %{"podTemplate" => pod()}}
    baseline = kubernetes_snapshot(config, template, template_path)
    bookkeeping = put_in(template, ["spec", "podTemplate", "metadata", "resourceVersion"], "99")
    changed = put_in(template, ["spec", "podTemplate", "metadata", "labels", "owner"], "different")
    assert kubernetes_snapshot(config, bookkeeping, template_path) == baseline
    refute kubernetes_snapshot(config, changed, template_path) == baseline
    sandbox = %{"metadata" => pod()["metadata"], "spec" => %{"replicas" => 1}}

    refute kubernetes_snapshot(config, sandbox, sandbox_path) ==
             kubernetes_snapshot(config, put_in(sandbox, ["spec", "replicas"], 0), sandbox_path)
  end

  test "Workstations template boot configuration and idle policy are not reduced to UID" do
    path = Path.dirname(Path.dirname(@workstation_path))
    body = %{"uid" => "template-uid", "host" => %{"gceInstance" => %{"machineType" => "n2-standard-4"}}}
    baseline = workstation_snapshot(body, path)
    machine_change = put_in(body, ["host", "gceInstance", "machineType"], "n2-standard-8")
    refute workstation_snapshot(machine_change, path) == baseline
    refute workstation_snapshot(Map.put(body, "idleAction", "STOP"), path) == baseline
  end

  test "negative controls reject owned and out of scope resources without exposing their bodies" do
    body = %{"uid" => "control-uid", "labels" => workstation_labels(), "secret" => "raw-secret-body"}
    opts = workstation_opts(fn _ -> response(body) end)
    expected = {:error, :negative_control_identity_unavailable}
    assert Provider.unrelated_snapshot(workstations_config(), [@workstation_path], opts) == expected
    outside = String.replace(@workstation_path, "/projects/p/", "/projects/elsewhere/")
    assert Provider.unrelated_snapshot(workstations_config(), [outside], opts) == expected
  end

  test "invalid owned identifiers are bounded and unsafe text is not serialized", context do
    config = kubernetes_config(context)
    labels = %{"symphony.dev/deployment" => digest(Jason.encode!(config.deployment_id), 40)}
    invalid = pod() |> put_in(["metadata", "labels"], labels) |> put_in(["metadata", "name"], "secret\\nbody")

    opts =
      kubernetes_opts(fn path ->
        items = if String.ends_with?(path, "/pods"), do: [invalid], else: []
        %{"items" => items, "metadata" => %{}}
      end)

    assert {:error, {:unknown, {:qualification_inventory_unresolved, [%{"id" => "control-uid"}]}}} =
             Provider.inventory(config, opts)
  end

  defp workstation_snapshot(body, path \\ @workstation_path) do
    opts = workstation_opts(fn _ -> response(body) end)
    assert {:ok, snapshot} = Provider.unrelated_snapshot(workstations_config(), [path], opts)
    snapshot
  end

  defp kubernetes_snapshot(config, body, path \\ @pod_path) do
    assert {:ok, snapshot} = Provider.unrelated_snapshot(config, [path], kubernetes_opts(fn _ -> body end))
    snapshot
  end

  defp pod do
    %{
      "kind" => "Pod",
      "metadata" => %{"name" => "control", "uid" => "control-uid", "namespace" => "workers", "labels" => %{"owner" => "other"}},
      "spec" => %{"nodeName" => "node", "containers" => [%{"name" => "app", "image" => "image@sha256:abc"}]},
      "status" => %{"phase" => "Running", "conditions" => [%{"type" => "Ready", "status" => "True"}]}
    }
  end

  defp workstations_config do
    %{
      kind: "google_workstations",
      deployment_id: "deployment",
      provider: %{"project" => "p", "location" => "l", "cluster" => "c", "config" => "cfg"}
    }
  end

  defp kubernetes_config(context) do
    directory = Path.join(System.tmp_dir!(), "qualification-unit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "kubeconfig")
    File.write!(path, "local protocol fixture #{context.test}")

    %{
      kind: "kubernetes",
      deployment_id: "deployment",
      provider: %{"namespace" => "workers", "context" => "unit", "kubeconfig" => path}
    }
  end

  defp workstation_labels do
    %{"symphony-managed" => "true", "symphony-deployment" => digest("deployment", 32), "symphony-ticket" => "missing"}
  end

  defp digest(value, length) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower) |> binary_part(0, length)
  end

  defp workstation_opts(request) do
    [request_fun: request, token_fun: fn _, _ -> {:ok, "unit-token"} end, timeout_ms: 10_000]
  end

  defp kubernetes_opts(read) do
    command = fn _executable, args, _opts ->
      ["get", "--raw", path] = Enum.take(args, -3)
      body = read.(URI.parse(path).path)
      {:ok, %{status: 0, output: Jason.encode!(body)}}
    end

    [command_fun: command, timeout_ms: 10_000]
  end

  defp response(body), do: {:ok, %{status: 200, body: body}}

  defp assert_safe_resources(resources) do
    allowed = ~w(kind id name uid selfLink zone region namespace volume_handle)
    assert Enum.all?(resources, fn resource -> Enum.all?(Map.keys(resource), &(&1 in allowed)) end)
  end
end
