defmodule SymphonyElixir.KubernetesLossAlarmTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.LossAlarm
  alias SymphonyElixir.Repo

  setup do
    Repo.delete_all(LossAlarm)
    on_exit(fn -> Repo.delete_all(LossAlarm) end)
    :ok
  end

  test "an alarm is recorded durably" do
    assert {:ok, :raised} = LossAlarm.raise(alarm())

    assert [recorded] = LossAlarm.all()
    assert recorded.kind == "host_reappeared"
    assert recorded.declaration == "symphony-loss-abc"
    assert recorded.machine_id == "machine"
    assert recorded.detail["node_name"] == "worker-1"
  end

  # A reconciler that re-reads every predicate on every pass would otherwise record the same
  # contradiction on every tick, burying the first observation under thousands of copies.
  test "the same contradiction is recorded once however often it is observed" do
    assert {:ok, :raised} = LossAlarm.raise(alarm())
    assert {:ok, :duplicate} = LossAlarm.raise(alarm())
    assert {:ok, :duplicate} = LossAlarm.raise(alarm(%{detail: %{"node_name" => "seen-again"}}))

    assert [recorded] = LossAlarm.all()
    assert recorded.detail["node_name"] == "worker-1"
  end

  test "distinct contradictions are recorded separately" do
    assert {:ok, :raised} = LossAlarm.raise(alarm())
    assert {:ok, :raised} = LossAlarm.raise(alarm(%{dedup_key: "symphony-loss-def:node-uid"}))

    assert length(LossAlarm.all()) == 2
  end

  defp alarm(overrides \\ %{}) do
    Map.merge(
      %{
        kind: "host_reappeared",
        dedup_key: "symphony-loss-abc:node-uid",
        declaration: "symphony-loss-abc",
        node_uid: "node-uid",
        machine_id: "machine",
        detail: %{"node_name" => "worker-1"}
      },
      overrides
    )
  end
end
