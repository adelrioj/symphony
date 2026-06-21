defmodule SymphonyElixir.Agent.ResultTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Agent.Result

  test "new/1 fills token defaults and required fields" do
    result = Result.new(status: :done, session_id: "t-1", seconds_running: 5)

    assert result.status == :done
    assert result.session_id == "t-1"
    assert result.seconds_running == 5
    assert result.tokens == %{input: 0, output: 0, total: 0}
    assert result.summary == nil
    assert result.blocked_action == nil
  end

  test "new/1 keeps a blocked_action for blocked results" do
    result = Result.new(status: :blocked, blocked_action: "approve shell write", summary: "needs approval")

    assert result.status == :blocked
    assert result.blocked_action == "approve shell write"
    assert result.summary == "needs approval"
  end
end
