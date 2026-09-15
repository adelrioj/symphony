Code.require_file("../support/kubernetes_candidate_runner.exs", __DIR__)

defmodule SymphonyElixir.KubernetesCandidateLiveTest do
  use ExUnit.Case, async: false

  @moduletag :candidate_live
  @moduletag timeout: 1_900_000
  @moduletag skip: System.get_env("SYMPHONY_RUN_KUBERNETES_CANDIDATE") != "1"

  test "explicitly scoped test artifact runs managed SSH and conservative cleanup" do
    input = System.fetch_env!("SYMPHONY_KUBERNETES_CANDIDATE_INPUT")
    assert Path.type(input) == :absolute
    config = input |> File.read!() |> Jason.decode!()
    assert {:ok, output} = SymphonyElixir.KubernetesCandidateRunner.run_file(input)
    evidence = output |> File.read!() |> Jason.decode!()
    assert evidence["stage"] == "candidate-unqualified"
    assert evidence["qualified"] == false
    model_run? = config["mode"] == "run" and is_binary(config["backend"])
    expected_sessions = if model_run?, do: config["worker_count"], else: 0
    assert evidence["model_sessions_started"] == expected_sessions
    assert evidence["model_sessions_completed"] == expected_sessions
    assert evidence["model_probes_completed"] == expected_sessions

    if config["mode"] == "run" do
      assert evidence["runner"] == "passed"
      workers = Map.values(evidence["workers"])
      assert length(workers) == config["worker_count"]
      assert Enum.all?(workers, &(&1["outcome"] == "passed"))
      assert length(Enum.uniq_by(workers, & &1["environment_id"])) == config["worker_count"]
      assert Enum.all?(evidence["dispatches"], fn {_, dispatch} -> is_binary(dispatch["ended_at"]) end)
    end

    if model_run? do
      probes = evidence["dispatches"] |> Map.values() |> Enum.filter(&is_binary(&1["probe_finished_at"]))
      assert length(probes) == expected_sessions
      assert Enum.all?(probes, &(&1["artifact_matched"] == true and &1["dispatch"] == "ok" and &1["backend"] == config["backend"]))

      if config["worker_count"] > 1 do
        intervals =
          Enum.map(probes, fn probe ->
            started = Enum.find(probe["lifecycle"], &(&1["event"] == "session_started"))
            completed = Enum.find(probe["lifecycle"], &(&1["event"] in ["completed", "turn_completed"] and &1["session_id"] == started["session_id"]))
            {started["observed_monotonic_ms"], completed["observed_monotonic_ms"]}
          end)

        assert Enum.max(Enum.map(intervals, &elem(&1, 0))) < Enum.min(Enum.map(intervals, &elem(&1, 1)))
      end
    end

    assert evidence["cleanup"] == "complete"
    assert evidence["status"] == "candidate_stage_complete"
    lane = SymphonyElixir.Lanes.get!(evidence["lane_id"])
    refute lane.enabled
    refute SymphonyElixir.LaneSupervisor.running?(lane.id)
    assert lane.current_version_id == evidence["lane_version_id"]
  end
end
