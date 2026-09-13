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

  test "step/1 initializes a stream accumulator and emits a worker update" do
    assert {%Stream{session_id: "sess-step"}, %{event: :session_started, session_id: "sess-step", timestamp: %DateTime{}}} =
             Stream.step(%{"type" => "system", "subtype" => "init", "session_id" => "sess-step"})
  end

  test "max_turns stream folds to an error" do
    assert {:error, {:claude_error, "error_max_turns"}} = Stream.fold(load("max_turns.jsonl"), 1)
  end

  test "blocked-wins: approval_prompt then nonzero exit still yields blocked" do
    assert {:ok, %Result{status: :blocked, blocked_action: action}} = Stream.fold(load("blocked.jsonl"), 1)
    assert action =~ "write outside workspace"
  end

  test "successful result with a nonzero exit is a stream error" do
    assert {:error, {:claude_stream, "nonzero exit after successful result"}} = Stream.fold(load("success.jsonl"), 1)
  end

  test "truncated stream with no result and nonzero exit is a stream error" do
    assert {:error, {:claude_stream, _}} = Stream.fold([%{"type" => "system", "subtype" => "init", "session_id" => "sess-4"}], 1)
  end

  test "fallback branches preserve useful stream state" do
    events = [
      %{"type" => "unknown"},
      %{
        "type" => "assistant",
        "message" => %{
          "usage" => "not usage",
          "content" => [
            %{"type" => "text", "text" => "first "},
            %{"type" => "ignored"},
            %{"type" => "text", "text" => "second"}
          ]
        }
      },
      %{"type" => "user", "message" => %{"content" => "not content"}},
      %{"type" => "result", "duration_ms" => 2_000, "usage" => "not usage"}
    ]

    assert {:ok, %Result{} = result} = Stream.fold(events, 0)
    assert result.status == :done
    assert result.summary == "first second"
    assert result.seconds_running == 2
    assert result.tokens == %{input: 0, output: 0, total: 0}
  end

  test "result error without subtype maps to generic claude error" do
    assert {:error, {:claude_error, "error"}} =
             Stream.fold([%{"type" => "result", "is_error" => true}], 1)
  end

  test "approval input without action is stringified and wins" do
    events = [
      %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "tool_use", "name" => "mcp__symphony__approval_prompt", "input" => "approve me"}
          ]
        }
      },
      %{"type" => "result", "subtype" => "success", "is_error" => false}
    ]

    assert {:ok, %Result{status: :blocked, blocked_action: "approve me"}} = Stream.fold(events, 0)
  end

  test "failure activity reports the outcome instead of retaining the last successful action" do
    {acc, _} =
      Stream.step(%{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "Reading code"}]}})

    {_, update} = Stream.step(%{"type" => "result", "is_error" => true, "subtype" => "error_max_turns"}, acc)

    message = SymphonyElixir.StatusDashboard.humanize_codex_message(%{event: update.event, message: update.payload})
    assert message =~ "error_max_turns"
    refute message =~ "Reading code"
  end

  test "cached usage deduplicates repeated message blocks and reconciles final invocation totals" do
    event = %{"type" => "assistant", "message" => %{"id" => "message-1", "usage" => %{"input_tokens" => 2, "cache_read_input_tokens" => 8}, "content" => []}}
    {first, update} = Stream.step(event)
    assert update.usage.cached_tokens == 8
    {repeated, update} = Stream.step(event, first)
    assert update.usage.cached_tokens == 8
    second = put_in(event, ["message", "id"], "message-2")
    {summed, update} = Stream.step(second, repeated)
    assert update.usage.cached_tokens == 16
    {_final, update} = Stream.step(%{"type" => "result", "subtype" => "success", "is_error" => false, "usage" => %{"input_tokens" => 4, "cache_read_input_tokens" => 16}}, summed)
    assert update.usage.cached_tokens == 16
    assert update.usage.input_tokens == 20
  end

  test "empty successful stream still reports a stream error" do
    assert {:error, {:claude_stream, "stream ended without a result event"}} = Stream.fold([], 0)
    assert {:error, {:claude_stream, "stream ended without a result event"}} = Stream.fold([], nil)
  end
end
