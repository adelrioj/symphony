defmodule SymphonyElixir.Agent.Claude.StreamTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.Claude.Stream
  alias SymphonyElixir.Agent.Result

  defp load(name) do
    Path.join([__DIR__, "..", "..", "..", "fixtures", "claude", name])
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  test "success stream folds to a done result with tokens and summary" do
    assert {:ok, %Result{} = result} = Stream.fold(load("success.jsonl"), 0)
    assert result.status == :done
    assert result.session_id == "sess-1"
    assert result.tokens == %{input: 10, output: 20, total: 30}
    assert result.seconds_running == 1
    assert result.summary == "done summary"
  end

  test "max_turns stream folds to an error" do
    assert {:error, {:claude_error, "error_max_turns"}} = Stream.fold(load("max_turns.jsonl"), 1)
  end

  test "blocked-wins: approval_prompt then nonzero exit still yields blocked" do
    assert {:ok, %Result{status: :blocked, blocked_action: action}} = Stream.fold(load("blocked.jsonl"), 1)
    assert action =~ "write outside workspace"
  end

  test "truncated stream with no result and nonzero exit is a stream error" do
    assert {:error, {:claude_stream, _}} = Stream.fold([%{"type" => "system", "subtype" => "init", "session_id" => "sess-4"}], 1)
  end
end
