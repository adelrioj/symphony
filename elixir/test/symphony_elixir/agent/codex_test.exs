defmodule SymphonyElixir.Agent.CodexTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.Codex
  alias SymphonyElixir.Agent.Result

  test "to_result/1 maps a codex turn map with usage to a done Result" do
    turn = %{
      result: %{"usage" => %{"input_tokens" => 4, "output_tokens" => 6, "total_tokens" => 10}, "summary" => "did the thing"},
      session_id: "thread-1-turn-1",
      thread_id: "thread-1",
      turn_id: "turn-1"
    }

    assert {:ok, %Result{} = result} = Codex.to_result(turn)
    assert result.status == :done
    assert result.session_id == "thread-1-turn-1"
    assert result.tokens == %{input: 4, output: 6, total: 10}
    assert result.summary == "did the thing"
  end

  test "to_result/1 maps the current codex turn completion shape to a done Result" do
    turn = %{
      result: :turn_completed,
      session_id: "thread-1-turn-1",
      thread_id: "thread-1",
      turn_id: "turn-1"
    }

    assert {:ok, %Result{} = result} = Codex.to_result(turn)
    assert result.status == :done
    assert result.session_id == "thread-1-turn-1"
    assert result.tokens == %{input: 0, output: 0, total: 0}
    assert result.summary == nil
  end

  test "to_result/1 defaults tokens to zero when usage is absent" do
    assert {:ok, %Result{tokens: %{input: 0, output: 0, total: 0}}} =
             Codex.to_result(%{result: %{}, session_id: "s", thread_id: "t", turn_id: "u"})
  end
end
