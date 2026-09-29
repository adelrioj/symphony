defmodule SymphonyElixir.Agent.Pi.StreamTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Agent.Pi.Stream
  alias SymphonyElixir.Agent.Result

  defp events(name) do
    "test/fixtures/pi/#{name}.jsonl"
    |> File.stream!()
    |> Enum.flat_map(fn l ->
      case Jason.decode(l) do
        {:ok, %{} = e} -> [e]
        _ -> []
      end
    end)
  end

  test "success run folds to done" do
    assert {:ok, %Result{status: :done, summary: summary}} = Stream.fold(events("success"), 0)
    assert is_binary(summary)
  end

  test "errors use pi tags" do
    truncated = Enum.reject(events("success"), &(&1["type"] == "agent_end"))
    assert {:error, {:pi_stream, "stream ended without an agent_end event"}} = Stream.fold(truncated, 0)
    assert {:error, {:pi_stream, "nonzero exit after successful agent_end"}} = Stream.fold(events("success"), 2)

    errored =
      Enum.map(events("success"), fn
        %{"type" => "message_end", "message" => %{"role" => "assistant"} = m} = e ->
          put_in(e, ["message"], Map.put(m, "stopReason", "error"))

        e ->
          e
      end)

    assert {:error, {:pi_error, "error"}} = Stream.fold(errored, 0)
  end
end
