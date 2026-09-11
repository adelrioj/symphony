Code.require_file("../support/managed_environment_fixture/provider.exs", __DIR__)

defmodule SymphonyElixir.ManagedEnvironmentProviderFixtureTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ManagedEnvironmentFixture.Provider

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
