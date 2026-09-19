defmodule SymphonyElixir.KubernetesDeclarationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Declaration

  test "the name is a deterministic digest over deployment, node, sorted environment keys and chunk" do
    guards = Map.new(["se-a", "se-b"], &{&1, %{"uid" => "guard-uid", "resourceVersion" => "7"}})
    {:ok, one} = Declaration.decode(spec(%{"environmentKeys" => ["se-b", "se-a"], "guards" => guards}))
    {:ok, two} = Declaration.decode(spec(%{"environmentKeys" => ["se-a", "se-b"], "guards" => guards}))

    assert one.name == two.name
    assert String.match?(one.name, ~r/^symphony-loss-[0-9a-f]{40}$/)
    assert byte_size(one.name) <= 63
  end

  test "anything that is not a map is not a declaration" do
    for value <- ["a string", nil, 7, []] do
      assert {:error, _} = Declaration.decode(value)
    end
  end

  test "a receipt whose body is malformed or incomplete is rejected" do
    {:ok, declaration} = Declaration.decode(spec(%{}))
    object = receipt()

    assert {:error, _} = Declaration.receipt(put_in(object, ["data", "receipt.json"], "{not json"), declaration)
    assert {:error, _} = Declaration.receipt(Map.put(object, "data", %{}), declaration)

    for field <- ~w(provider destroyedAt) do
      assert {:error, _} = Declaration.receipt(receipt(%{field => ""}), declaration)
    end

    assert {:error, _} = Declaration.receipt(receipt(%{"destroyedVolumeHandles" => "handle-1"}), declaration)
    assert {:error, _} = Declaration.receipt(receipt(%{"destroyedVolumeHandles" => [""]}), declaration)
  end

  test "a spec missing a required immutable field is rejected" do
    for field <- ~w(schemaVersion deploymentId host environmentKeys obligationUIDs guards receiptName operatorSubject chunkIndex chunkTotal) do
      assert {:error, _} = Declaration.decode(Map.delete(spec(%{}), field)), "#{field} was accepted as absent"
    end
  end

  test "a host identity missing any machine field is rejected" do
    for field <- ~w(node_name node_uid machine_id system_uuid) do
      assert {:error, _} = Declaration.decode(spec(%{"host" => Map.delete(spec(%{})["host"], field)}))
    end
  end

  test "more than sixty-four environment keys is rejected" do
    keys = Enum.map(1..65, &"se-#{&1}")
    assert {:error, _} = Declaration.decode(spec(%{"environmentKeys" => keys, "guards" => Map.new(keys, &{&1, %{"uid" => "g", "resourceVersion" => "1"}})}))
  end

  test "more than five hundred and twelve obligation uids is rejected" do
    assert {:error, _} = Declaration.decode(spec(%{"obligationUIDs" => Enum.map(1..513, &"uid-#{&1}")}))
  end

  test "a duplicated obligation uid is rejected" do
    assert {:error, _} = Declaration.decode(spec(%{"obligationUIDs" => ["pod-uid", "pod-uid"]}))
  end

  test "an environment key with no guard reference is rejected, and a guard reference with no key too" do
    assert {:error, _} = Declaration.decode(spec(%{"environmentKeys" => ["se-ticket", "se-other"]}))
    assert {:error, _} = Declaration.decode(spec(%{"guards" => %{"se-other" => %{"uid" => "guard-uid", "resourceVersion" => "7"}}}))
  end

  test "a chunk index outside its total is rejected" do
    assert {:error, _} = Declaration.decode(spec(%{"chunkIndex" => 1, "chunkTotal" => 1}))
    assert {:error, _} = Declaration.decode(spec(%{"chunkIndex" => -1, "chunkTotal" => 1}))
  end

  test "a receipt name outside the protected prefix is rejected" do
    for name <- ["destruction-receipt", "symphony-guard-abc", "qualification", "symphony-destruction-receipt-", ""] do
      assert {:error, _} = Declaration.decode(spec(%{"receiptName" => name})), "#{name} was accepted"
    end

    assert {:ok, _} = Declaration.decode(spec(%{"receiptName" => "symphony-destruction-receipt-3070466"}))
  end

  test "an unknown schema version is rejected" do
    assert {:error, _} = Declaration.decode(spec(%{"schemaVersion" => 2}))
  end

  test "a receipt is accepted only when it is immutable and names the declared machine" do
    {:ok, declaration} = Declaration.decode(spec(%{}))

    assert {:ok, _} = Declaration.receipt(receipt(), declaration)
    assert {:error, _} = Declaration.receipt(Map.put(receipt(), "immutable", false), declaration)
    assert {:error, _} = Declaration.receipt(Map.delete(receipt(), "immutable"), declaration)
    assert {:error, _} = Declaration.receipt(nil, declaration)
  end

  test "a receipt naming a different machine is refused" do
    {:ok, declaration} = Declaration.decode(spec(%{}))

    for field <- ~w(machine_id system_uuid) do
      assert {:error, _} = Declaration.receipt(receipt(%{field => "someone-else"}), declaration)
    end
  end

  test "a receipt discharges only the volume handles it names" do
    {:ok, declaration} = Declaration.decode(spec(%{}))
    {:ok, receipt} = Declaration.receipt(receipt(), declaration)

    assert Declaration.destroyed?(receipt, "handle-1")
    refute Declaration.destroyed?(receipt, "handle-2")
    refute Declaration.destroyed?(receipt, nil)
  end

  defp receipt(overrides \\ %{}) do
    body =
      Map.merge(
        %{
          "provider" => "hetzner-robot",
          "machine_id" => "machine",
          "system_uuid" => "system",
          "destroyedVolumeHandles" => ["handle-1"],
          "destroyedAt" => "2026-09-19T00:00:00Z"
        },
        overrides
      )

    %{"metadata" => %{"name" => "symphony-destruction-receipt-3070466"}, "immutable" => true, "data" => %{"receipt.json" => Jason.encode!(body)}}
  end

  defp spec(overrides) do
    Map.merge(
      %{
        "schemaVersion" => 1,
        "deploymentId" => "deployment",
        "host" => %{"node_name" => "worker-1", "node_uid" => "node-uid", "machine_id" => "machine", "system_uuid" => "system"},
        "environmentKeys" => ["se-ticket"],
        "obligationUIDs" => ["pod-uid"],
        "guards" => %{"se-ticket" => %{"uid" => "guard-uid", "resourceVersion" => "7"}},
        "receiptName" => "symphony-destruction-receipt-3070466",
        "operatorSubject" => "operator@example.test",
        "chunkIndex" => 0,
        "chunkTotal" => 1
      },
      overrides
    )
  end
end
