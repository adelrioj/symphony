defmodule SymphonyElixir.Agent.EventTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.Event

  test "to_worker_update/1 maps tokens to codex-style usage keys" do
    event = %Event{
      kind: :usage_updated,
      session_id: "t-1",
      tokens: %{input: 3, output: 5, total: 8},
      seconds_running: 2,
      detail: %{}
    }

    update = Event.to_worker_update(event)

    assert update.event == :usage_updated
    assert update.session_id == "t-1"
    assert update.usage == %{input_tokens: 3, output_tokens: 5, total_tokens: 8}
    assert %DateTime{} = update.timestamp
  end

  test "to_worker_update/1 uses zero token defaults" do
    event = %Event{kind: :session_started, session_id: "t-1", tokens: nil, seconds_running: nil, detail: %{}}

    update = Event.to_worker_update(event)

    assert update.event == :session_started
    assert update.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end
end
