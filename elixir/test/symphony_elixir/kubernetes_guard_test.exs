defmodule SymphonyElixir.KubernetesGuardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Guard

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    Process.put(:guard_requests, [])
    Process.put(:guard_unexpected, [])
    {:ok, opts: [command_fun: &command/3, timeout_ms: 60_000, task_supervisor: supervisor, authority: self()]}
  end

  test "malformed guard identities and operation bindings cannot authorize adoption" do
    operation = operation()

    invalid_data = [
      %{"operations" => %{}},
      %{"operations" => [nil]},
      %{"operations" => [Map.put(operation, "resource", "pods")]},
      %{"operations" => [Map.put(operation, "state", "Cancelled")]},
      %{"operations" => [Map.put(operation, "guardUID", "replacement-guard")]},
      %{"operations" => [Map.put(operation, "namespace", "other")]},
      %{"operations" => [Map.put(operation, "objectUID", "uncommitted-parent")]},
      %{"operations" => [operation, operation]},
      %{"operations" => [operation, Map.put(operation, "id", "second-parent")]},
      %{"operations" => [operation], "parentUID" => "uncommitted-parent"},
      %{"phase" => "Closing", "closeRequestId" => nil}
    ]

    for changes <- invalid_data do
      assert {:error, {:unknown, :kubernetes_guard_invalid}} = Guard.decode(object(changes), record())
    end

    for malformed <- [nil, %{}, Map.put(object(), "kind", "Secret"), put_in(object(), ["data", "guard.json"], "not-json")] do
      assert {:error, {:unknown, :kubernetes_guard_invalid}} = Guard.decode(malformed, record())
    end
  end

  test "a child journal cannot rebind the immutable parent incarnation" do
    parent = Map.merge(operation(), %{"state" => "Committed", "objectUID" => "parent-uid"})
    child = Map.merge(operation(), %{"id" => "child", "resource" => "secrets", "name" => "connection", "parentUID" => "other-parent"})
    guard = object(%{"operations" => [parent, child], "parentUID" => "parent-uid"})
    assert {:error, {:unknown, :kubernetes_guard_invalid}} = Guard.decode(guard, record())

    bound = object(%{"operations" => [parent], "parentUID" => "parent-uid"})
    assert {:error, {:unknown, :kubernetes_guard_invalid}} = Guard.decode(bound, %{record() | provider_ref: "replacement-parent"})
  end

  test "lookup denial is preserved by every guard acquisition entry point", %{opts: opts} do
    for action <- [:fetch, :establish, :open, :save, :close, :create] do
      requests([{:get, "configmaps", status(403)}])

      result =
        case action do
          :fetch -> Guard.fetch(config(), record(), opts)
          :establish -> Guard.establish(config(), record(), encoded(), opts)
          :open -> Guard.open(config(), record(), opts)
          :save -> Guard.save(config(), record(), encoded(), opts)
          :close -> Guard.close(config(), record(), encoded(), opts)
          :create -> Guard.create(config(), record(), "sandboxes", parent_body(), opts)
        end

      assert {:error, {:denied, :kubernetes_inventory}} = result
      assert_finished()
    end
  end

  test "absent guards are never recreated for owned or orphaned resources", %{opts: opts} do
    for retained <- [%{record() | provider_ref: "parent-uid"}, %{record() | metadata: %{"orphaned" => true}}] do
      requests([{:get, "configmaps", inventory([])}])
      assert {:error, {:unknown, :kubernetes_guard_missing}} = Guard.establish(config(), retained, Jason.encode!(retained), opts)
      assert_finished()
    end

    requests([{:get, "configmaps", inventory([])}])
    assert {:error, {:unknown, :kubernetes_guard_missing}} = Guard.fetch(config(), record(), opts)
    assert_finished()
  end

  test "bootstrap requires exact authoritative readback even after a successful POST", %{opts: opts} do
    for readback <- [inventory([]), status(403), inventory([object(%{"evidence" => %{"foreign" => true}})])] do
      requests([{:get, "configmaps", inventory([])}, {:post, "configmaps", object()}, {:get, "configmaps", readback}])
      result = Guard.establish(config(), record(), encoded(), opts)
      assert {:error, {:unknown, :kubernetes_guard_bootstrap_unknown}} = result
      assert_finished()
    end
  end

  test "a lost bootstrap response is recoverable from the exact permanent guard", %{opts: opts} do
    requests([{:get, "configmaps", inventory([])}, {:post, "configmaps", {:error, :timeout}}, {:get, "configmaps", inventory([object()])}])
    assert {:ok, guard} = Guard.establish(config(), record(), encoded(), opts)
    assert {:error, {:unknown, :kubernetes_provider_issuance_unresolved}} = Guard.drained(guard)
    assert_finished()
  end

  test "full journals refuse issuance before any CAS or resource POST", %{opts: opts} do
    guard = object(%{"evidence" => %{"retained" => String.duplicate("x", 1_048_576)}})
    requests([{:get, "configmaps", inventory([guard])}, {:get, "sandboxes", inventory([])}])
    assert {:error, {:unknown, :kubernetes_guard_full}} = Guard.create(config(), record(), "sandboxes", parent_body(), opts)
    assert_finished()
  end

  test "closed issuance rejects create and non-cleanup saves without writes", %{opts: opts} do
    for phase <- ["Closing", "ReadyToFinalize", "Complete"] do
      guard = closed_object(phase)
      requests([{:get, "configmaps", inventory([guard])}])
      assert {:error, {:unknown, :kubernetes_issuance_closed}} = Guard.create(config(), record(), "sandboxes", parent_body(), opts)
      assert_finished()
      requests([{:get, "configmaps", inventory([guard])}])
      assert {:error, {:unknown, :kubernetes_issuance_closed}} = Guard.save(config(), record(), encoded(), opts)
      assert_finished()
      requests([{:get, "configmaps", inventory([guard])}])
      assert {:error, {:unknown, :kubernetes_issuance_closed}} = Guard.open(config(), record(), opts)
      assert_finished()
    end
  end

  test "a committed parent name remains reserved even when its object is absent", %{opts: opts} do
    parent = Map.merge(operation(), %{"state" => "Committed", "objectUID" => "parent-uid"})
    guard = object(%{"operations" => [parent], "parentUID" => "parent-uid"})
    requests([{:get, "configmaps", inventory([guard])}])
    assert {:error, {:unknown, :kubernetes_incarnation_retained}} = Guard.create(config(), record(), "sandboxes", parent_body(), opts)
    assert_finished()
  end

  test "child creation requires a bound parent and an authoritatively absent address", %{opts: opts} do
    requests([{:get, "configmaps", inventory([object()])}])
    assert {:error, {:unknown, :kubernetes_parent_missing}} = Guard.create(config(), record(), "secrets", secret_body(), opts)
    assert_finished()

    for observed <- [inventory([Map.put(parent_body(), "metadata", %{"name" => "se-ticket", "uid" => "foreign"})]), status(403)] do
      requests([{:get, "configmaps", inventory([object()])}, {:get, "sandboxes", observed}])
      assert {:error, {:unknown, :kubernetes_create_name_retained}} = Guard.create(config(), record(), "sandboxes", parent_body(), opts)
      assert_finished()
    end
  end

  test "failed issuance CAS never grants a send or read-after-error permission", %{opts: opts} do
    for failure <- [status(409), {:error, :timeout}] do
      requests([{:get, "configmaps", inventory([object()])}, {:get, "sandboxes", inventory([])}, {:patch, "configmaps", failure}])
      assert {:error, {:unknown, :kubernetes_guard_issuance_unknown}} = Guard.create(config(), record(), "sandboxes", parent_body(), opts)
      assert_finished()
    end
  end

  test "settlement lookup denial and foreign attribution preserve unresolved issuance", %{opts: opts} do
    source = object(%{"operations" => [operation()]})
    assert {:ok, guard} = Guard.decode(source, record())

    for {response, reason} <- [
          {status(403), {:denied, :kubernetes_inventory}},
          {inventory([Map.put(parent_body(), "metadata", %{"name" => "se-ticket", "uid" => "foreign"})]), {:unknown, :kubernetes_create_attribution_conflict}}
        ] do
      requests([{:get, "sandboxes", response}])
      assert {:error, ^reason} = Guard.settle(config(), record(), guard, opts)
      assert_finished()
    end

    requests([{:get, "sandboxes", inventory([])}])
    assert {:ok, unresolved} = Guard.settle(config(), record(), guard, opts)
    assert {:error, {:unknown, :kubernetes_provider_issuance_unresolved}} = Guard.drained(unresolved)
    assert_finished()
  end

  test "failed settlement CAS cannot certify drainage without matching readback", %{opts: opts} do
    source = closed_object("Closing", %{"operations" => [operation()]})
    assert {:ok, guard} = Guard.decode(source, record())
    requests([{:get, "sandboxes", inventory([parent_receipt()])}, {:patch, "configmaps", status(409)}, {:get, "configmaps", inventory([source])}])
    assert {:error, {:unknown, :kubernetes_guard_update_unconfirmed}} = Guard.settle(config(), record(), guard, opts)
    assert_finished()
  end

  test "settlement recovers a lost CAS response only from a validated committed receipt", %{opts: opts} do
    source = closed_object("Closing", %{"operations" => [operation()]})
    assert {:ok, guard} = Guard.decode(source, record())
    committed = Map.merge(operation(), %{"state" => "Committed", "objectUID" => "parent-uid"})
    recovered = closed_object("Closing", %{"operations" => [committed], "parentUID" => "parent-uid"})
    readback = inventory([recovered])

    requests([
      {:get, "sandboxes", inventory([parent_receipt()])},
      {:patch, "configmaps", {:error, :timeout}},
      {:get, "configmaps", readback}
    ])

    assert {:ok, settled} = Guard.settle(config(), record(), guard, opts)
    assert :ok = Guard.drained(settled)
    assert Guard.matches?(parent_receipt(), hd(settled.data["operations"]))
    refute Guard.matches?(put_in(parent_receipt(), ["metadata", "uid"], "replacement-parent"), hd(settled.data["operations"]))
    assert_finished()
  end

  test "successful CAS replies must contain the exact requested guard and UID", %{opts: opts} do
    for response <- [object(), put_in(object(), ["metadata", "uid"], "replacement-guard"), %{"kind" => "Status", "code" => 200}] do
      requests([{:get, "configmaps", inventory([object()])}, {:patch, "configmaps", response}])
      assert {:error, {:unknown, :kubernetes_guard_update_unconfirmed}} = Guard.close(config(), record(), Jason.encode!(%{record() | desired: :absent}), opts)
      assert_finished()
    end
  end

  test "confirmation rejects replaced guards and changed durable evidence", %{opts: opts} do
    assert {:ok, expected} = Guard.decode(object(), record())

    for actual <- [put_in(object(), ["metadata", "uid"], "replacement-guard"), object(%{"evidence" => %{"latePodUID" => "late-pod"}})] do
      requests([{:get, "configmaps", inventory([actual])}])
      result = Guard.confirm(config(), record(), expected, opts)
      assert {:error, {:unknown, :kubernetes_guard_update_unconfirmed}} = result
      assert_finished()
    end
  end

  test "unsupported resource kinds cannot produce a validated create receipt" do
    refute Guard.matches?(parent_receipt(), Map.put(operation(), "resource", "pods"))
  end

  defp requests(steps), do: Process.put(:guard_requests, steps)

  defp assert_finished do
    assert Process.get(:guard_requests) == []
    assert Process.get(:guard_unexpected) == []
  end

  defp command(executable, args, _opts) do
    {method, resource} =
      cond do
        Path.basename(executable) == "symphony-kubernetes-create" ->
          {:post, args |> arg("--path") |> URI.parse() |> Map.fetch!(:path) |> String.split("/") |> List.last()}

        "patch" in args ->
          {:patch, Enum.at(args, Enum.find_index(args, &(&1 == "patch")) + 1)}

        true ->
          {:get, args |> arg("--raw") |> URI.parse() |> Map.fetch!(:path) |> String.split("/") |> List.last()}
      end

    case Process.get(:guard_requests) do
      [{^method, ^resource, response} | rest] ->
        Process.put(:guard_requests, rest)
        reply(response)

      _ ->
        Process.put(:guard_unexpected, [{method, resource} | Process.get(:guard_unexpected)])
        {:error, :unexpected_request}
    end
  end

  defp reply({:error, _} = error), do: error
  defp reply(body), do: {:ok, %{status: 0, output: Jason.encode!(body)}}
  defp arg(args, flag), do: Enum.at(args, Enum.find_index(args, &(&1 == flag)) + 1)
  defp inventory(items), do: %{"metadata" => %{}, "items" => items}
  defp status(code), do: %{"kind" => "Status", "code" => code}
  defp config, do: %{provider: %{"kubeconfig" => __ENV__.file, "context" => "test", "namespace" => "test"}}
  defp encoded, do: Jason.encode!(record())

  defp record do
    %{
      key: "se-ticket",
      deployment_id: "deployment",
      tracker_kind: "memory",
      issue_id: "ticket",
      kind: "kubernetes",
      scope: %{"namespace" => "test"},
      workspace_path: "/state/workspaces/se-ticket",
      template_identity: "template-v1",
      metadata: %{},
      provider_ref: nil,
      desired: :stopped
    }
  end

  defp object(changes \\ %{}) do
    data = %{
      "protocol" => "symphony-create-drain-v1",
      "identity" => %{"deploymentID" => "deployment", "environmentKey" => "se-ticket", "scope" => %{"namespace" => "test"}},
      "phase" => "Open",
      "operations" => [],
      "parentUID" => nil,
      "closeRequestId" => nil,
      "record" => Jason.decode!(encoded()),
      "evidence" => %{}
    }

    %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => %{
        "name" => Guard.name(record()),
        "namespace" => "test",
        "uid" => "guard-uid",
        "resourceVersion" => "7",
        "labels" => %{"symphony.dev/create-guard" => "true", "symphony.dev/environment" => "se-ticket"}
      },
      "data" => %{"guard.json" => Jason.encode!(Map.merge(data, changes))}
    }
  end

  defp closed_object(phase, changes \\ %{}) do
    object(Map.merge(%{"phase" => phase, "closeRequestId" => "close-request", "record" => Jason.decode!(Jason.encode!(%{record() | desired: :absent}))}, changes))
  end

  defp operation do
    %{
      "id" => "create-parent",
      "issuerId" => "issuer",
      "resource" => "sandboxes",
      "namespace" => "test",
      "name" => "se-ticket",
      "guardUID" => "guard-uid",
      "parentUID" => nil,
      "state" => "Issued"
    }
  end

  defp parent_body, do: %{"apiVersion" => "agents.x-k8s.io/v1beta1", "kind" => "Sandbox", "metadata" => %{"name" => "se-ticket", "namespace" => "test"}}
  defp secret_body, do: %{"apiVersion" => "v1", "kind" => "Secret", "metadata" => %{"name" => "connection", "namespace" => "test"}}

  defp parent_receipt do
    Map.put(parent_body(), "metadata", %{
      "name" => "se-ticket",
      "namespace" => "test",
      "uid" => "parent-uid",
      "resourceVersion" => "8",
      "annotations" => %{
        "symphony.dev/create-protocol" => "symphony-create-drain-v1",
        "symphony.dev/create-guard-uid" => "guard-uid",
        "symphony.dev/create-attempt-id" => "create-parent"
      }
    })
  end
end
