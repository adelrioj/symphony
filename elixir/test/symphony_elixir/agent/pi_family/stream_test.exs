defmodule SymphonyElixir.Agent.PiFamily.StreamTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Agent.PiFamily.Stream

  test "tool_execution_start records tool activity with detail" do
    acc = Stream.new(:x_error, :x_stream)

    {acc, update} =
      Stream.step(%{"type" => "tool_execution_start", "toolName" => "bash", "args" => %{"command" => "ls"}}, acc)

    assert update.event == :tool_use
    assert update.detail == "bash: ls"
    assert acc.activity == "Using tool: bash"
  end

  test "errors carry the configured tags" do
    assert {:error, {:x_stream, _}} = Stream.finalize(Stream.new(:x_error, :x_stream), 0)

    failed = %{Stream.new(:x_error, :x_stream) | saw_agent_end: true, stop_reason: "error"}
    assert {:error, {:x_error, "error"}} = Stream.finalize(failed, 0)
  end
end
