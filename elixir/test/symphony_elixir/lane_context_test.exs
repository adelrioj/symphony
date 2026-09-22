defmodule SymphonyElixir.LaneContextTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LaneContext
  alias SymphonyElixir.LaneContext.NoLaneContext
  alias SymphonyElixir.LaneStore.Entry

  test "a direct tag resolves and can be replaced in the tagging process" do
    assert :ok = LaneContext.put(7)
    assert {:ok, 7} = LaneContext.current()
    assert 7 = LaneContext.current!()

    assert :ok = LaneContext.put(8)
    assert {:ok, 8} = LaneContext.current()
  end

  test "nil is a lane tag rather than an absent tag, directly and through callers" do
    LaneContext.put(11)

    task =
      Task.async(fn ->
        LaneContext.put(nil)
        direct = LaneContext.current()
        inherited = Task.async(fn -> LaneContext.current() end) |> Task.await()
        {direct, inherited}
      end)

    assert {{:ok, nil}, {:ok, nil}} = Task.await(task)
    assert {:ok, 11} = LaneContext.current()
  end

  test "supervised children and nested tasks resolve past untagged callers" do
    supervisor = start_supervised!(Task.Supervisor)
    snapshot = %Entry{lane_id: 11, version_id: 1, name: "dispatch version"}
    LaneContext.install(snapshot)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        inner = Task.async(fn -> {LaneContext.current!(), LaneContext.capture()} end) |> Task.await()
        {LaneContext.current!(), inner}
      end)

    assert {11, {11, {:ok, ^snapshot}}} = Task.await(task)
  end

  test "the nearest tag wins and nested task overrides do not retag their ancestors" do
    LaneContext.install(%Entry{lane_id: 11, version_id: 1, name: "ancestor dispatch"})

    task =
      Task.async(fn ->
        LaneContext.put(22)

        nested =
          Task.async(fn ->
            inherited = {LaneContext.current!(), LaneContext.snapshot()}
            LaneContext.put(33)
            descendant = Task.async(fn -> LaneContext.current!() end) |> Task.await()
            {inherited, LaneContext.current!(), descendant}
          end)
          |> Task.await()

        {nested, LaneContext.current!()}
      end)

    assert {{{22, :error}, 33, 33}, 22} = Task.await(task)
    assert 11 = LaneContext.current!()
    assert {:ok, %{lane_id: 11, name: "ancestor dispatch"}} = LaneContext.snapshot()
  end

  test "two active lanes and their nested tasks remain isolated under one supervisor" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    tasks =
      for lane_id <- [1, 2] do
        Task.Supervisor.async_nolink(supervisor, fn ->
          LaneContext.put(lane_id)
          send(parent, {:ready, self()})

          receive do
            :resolve ->
              inherited = Task.async(fn -> LaneContext.current!() end) |> Task.await()
              {LaneContext.current!(), inherited}
          end
        end)
      end

    assert_receive {:ready, first}, 1_000
    assert_receive {:ready, second}, 1_000
    send(first, :resolve)
    send(second, :resolve)

    assert [{1, 1}, {2, 2}] = Enum.map(tasks, &Task.await/1)
    assert :error = LaneContext.current()
  end

  test "a surviving task skips a dead tagged caller and resolves the next live tag" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    snapshot = %Entry{lane_id: 11, version_id: 1, name: "surviving dispatch"}
    LaneContext.install(snapshot)

    caller =
      Task.Supervisor.async_nolink(supervisor, fn ->
        LaneContext.install(%Entry{lane_id: 22, version_id: 2, name: "expired dispatch"})

        {:ok, reader} =
          Task.Supervisor.start_child(supervisor, fn ->
            receive do
              :resolve -> send(parent, {:resolved, LaneContext.current(), LaneContext.capture()})
            end
          end)

        receive do
          :finish -> reader
        end
      end)

    monitor = Process.monitor(caller.pid)
    send(caller.pid, :finish)
    reader = Task.await(caller)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    send(reader, :resolve)

    assert_receive {:resolved, {:ok, 11}, {:ok, ^snapshot}}, 1_000
  end

  test "a surviving task reports missing context when its only tagged caller has died" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    caller =
      Task.Supervisor.async_nolink(supervisor, fn ->
        LaneContext.install(%Entry{lane_id: 22, version_id: 2, name: "expired dispatch"})

        {:ok, reader} =
          Task.Supervisor.start_child(supervisor, fn ->
            receive do
              :resolve ->
                send(parent, {:resolved, LaneContext.current(), LaneContext.snapshot(), LaneContext.capture()})
            end
          end)

        receive do
          :finish -> reader
        end
      end)

    monitor = Process.monitor(caller.pid)
    send(caller.pid, :finish)
    reader = Task.await(caller)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    send(reader, :resolve)

    assert_receive {:resolved, :error, :error, {:error, :no_lane_context}}, 1_000
  end

  test "missing context raises an actionable error identifying the calling module and function" do
    assert :error = LaneContext.current()
    error = assert_raise NoLaneContext, fn -> require_lane_context() end
    message = Exception.message(error)

    assert message =~ "SymphonyElixir.LaneContextTest.require_lane_context/0"
    assert message =~ "SymphonyElixir.LaneContext.put/1"
    assert message =~ inspect(self())
  end

  test "a process started directly at current! still raises the diagnostic exception" do
    ExUnit.CaptureLog.capture_log(fn ->
      {pid, ref} = spawn_monitor(LaneContext, :current!, [])
      assert_receive {:DOWN, ^ref, :process, ^pid, {%NoLaneContext{message: message}, _stack}}, 1_000
      assert message =~ "no lane context"
      assert message =~ "SymphonyElixir.LaneContext.put/1"
    end)
  end

  test "ordinary spawned processes do not inherit their parent's tag" do
    parent = self()
    LaneContext.put(11)

    spawn_link(fn -> send(parent, {:resolved, LaneContext.current(), LaneContext.snapshot()}) end)

    assert_receive {:resolved, :error, :error}, 1_000
  end

  defp require_lane_context do
    lane_id = LaneContext.current!()
    {:lane, lane_id}
  end
end
