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
    assert evidence["backend_sessions"] == expected_sessions

    if config["mode"] == "run", do: assert(evidence["runner"] == "passed")

    if model_run? do
      sessions = Enum.filter(evidence["events"], &(&1["event"] == "model_session"))
      assert length(sessions) == expected_sessions
      assert Enum.all?(sessions, &(&1["artifact_matched"] == true and &1["dispatch"] == "ok" and &1["backend"] == config["backend"]))
    end

    assert evidence["cleanup"] == "complete"
    assert evidence["status"] == "candidate_stage_complete"
    lane = SymphonyElixir.Lanes.get!(evidence["lane_id"])
    refute lane.enabled
    refute SymphonyElixir.LaneSupervisor.running?(lane.id)
    assert lane.current_version_id == evidence["lane_version_id"]
  end
end
