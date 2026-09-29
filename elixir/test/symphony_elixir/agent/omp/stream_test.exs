defmodule SymphonyElixir.Agent.Omp.StreamTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.Omp.Stream
  alias SymphonyElixir.Agent.Result

  defp events(name) do
    "test/fixtures/omp/#{name}.jsonl"
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{} = event} -> [event]
        _ -> []
      end
    end)
  end

  test "success run folds to a done result with summed usage and last assistant text" do
    assert {:ok, %Result{status: :done, summary: "ok", session_id: id, tokens: tokens}} =
             Stream.fold(events("success"), 0)

    assert is_binary(id)
    assert tokens.output > 0
    assert tokens.total >= tokens.input + tokens.output - 1
  end

  test "tool_call run keeps the final assistant text as summary" do
    assert {:ok, %Result{status: :done, summary: summary}} = Stream.fold(events("tool_call"), 0)
    assert summary =~ "hello"
  end

  test "input tokens include cache reads and writes" do
    event = %{
      "type" => "message_end",
      "message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "x"}],
        "stopReason" => "stop",
        "usage" => %{"input" => 3, "output" => 4, "cacheRead" => 10, "cacheWrite" => 5, "totalTokens" => 22}
      }
    }

    {acc, update} = Stream.step(event, Stream.new())
    assert acc.tokens == %{input: 18, output: 4, total: 22}
    assert acc.cached_tokens == 15
    assert update.usage.input_tokens == 18
  end

  test "tool execution surfaces the tool name as activity and keeps args in detail only" do
    {acc, update} =
      Stream.step(
        %{"type" => "tool_execution_start", "toolName" => "bash", "args" => %{"command" => "mix test"}},
        Stream.new()
      )

    assert acc.activity == "Using tool: bash"
    assert update.event == :tool_use
    assert update.payload == "Using tool: bash"
    assert update.detail == "bash: mix test"
  end

  test "non-stop final stopReason is an error even with exit 0" do
    assert {:error, {:omp_error, "error"}} = Stream.fold(events("error"), 0)
  end

  test "stream without agent_end is an error" do
    truncated = Enum.reject(events("success"), &(&1["type"] == "agent_end"))
    assert {:error, {:omp_stream, "stream ended without an agent_end event"}} = Stream.fold(truncated, 0)
    assert {:error, {:omp_stream, "nonzero exit without an agent_end event"}} = Stream.fold(truncated, 1)
  end

  test "nonzero exit after a successful agent_end is an error" do
    assert {:error, {:omp_stream, "nonzero exit after successful agent_end"}} = Stream.fold(events("success"), 2)
  end

  test "unknown events are ignored" do
    assert {%Stream{}, nil} = Stream.step(%{"type" => "message_update"}, Stream.new())
  end
end
