Code.require_file("../support/kubernetes_candidate_runner.exs", __DIR__)

defmodule SymphonyElixir.KubernetesCandidateLiveTest do
  use ExUnit.Case, async: false

  @moduletag :candidate_live
  @moduletag timeout: 1_900_000
  @moduletag skip: System.get_env("SYMPHONY_RUN_KUBERNETES_CANDIDATE") != "1"

  test "explicitly scoped test artifact runs real non-model managed SSH and conservative cleanup" do
    input = System.fetch_env!("SYMPHONY_KUBERNETES_CANDIDATE_INPUT")
    assert Path.type(input) == :absolute
    assert {:ok, output} = SymphonyElixir.KubernetesCandidateRunner.run_file(input)
    evidence = output |> File.read!() |> Jason.decode!()
    assert evidence["stage"] == "candidate-unqualified"
    assert evidence["qualified"] == false
    assert evidence["backend_sessions"] == 0
    assert evidence["cleanup"] == "complete"
    assert evidence["status"] == "candidate_stage_complete"
  end
end
