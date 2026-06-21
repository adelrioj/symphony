defmodule SymphonyElixir.Agent.Claude.Stream do
  @moduledoc """
  Pure folder for Claude stream-json events.

  Turns decoded events plus the process exit status into an `Agent.Result` or
  an error, with approval-prompt blocked events taking precedence over later
  nonzero exits.
  """

  alias SymphonyElixir.Agent.Result

  @approval_tool "mcp__symphony__approval_prompt"

  defstruct session_id: nil,
            tokens: %{input: 0, output: 0, total: 0},
            seconds_running: 0,
            summary: nil,
            blocked_action: nil,
            saw_result: false,
            result_status: nil

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          tokens: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()},
          seconds_running: non_neg_integer(),
          summary: String.t() | nil,
          blocked_action: String.t() | nil,
          saw_result: boolean(),
          result_status: :done | {:error, String.t()} | nil
        }

  @spec fold([map()], integer() | nil) :: {:ok, Result.t()} | {:error, term()}
  def fold(events, exit_status) when is_list(events) do
    events
    |> Enum.reduce(%__MODULE__{}, &apply_event/2)
    |> finalize(exit_status)
  end

  defp apply_event(%{"type" => "system", "subtype" => "init"} = event, acc) do
    %{acc | session_id: Map.get(event, "session_id", acc.session_id)}
  end

  defp apply_event(%{"type" => type, "message" => message}, acc) when type in ["assistant", "user"] and is_map(message) do
    acc
    |> apply_usage(Map.get(message, "usage"))
    |> apply_content(Map.get(message, "content", []))
  end

  defp apply_event(%{"type" => "result"} = event, acc) do
    %{
      acc
      | saw_result: true,
        seconds_running: div(Map.get(event, "duration_ms", acc.seconds_running * 1000), 1000),
        tokens: merge_tokens(acc.tokens, Map.get(event, "usage")),
        summary: Map.get(event, "result", acc.summary),
        result_status: result_status(event)
    }
  end

  defp apply_event(_event, acc), do: acc

  defp apply_usage(acc, nil), do: acc
  defp apply_usage(acc, usage) when is_map(usage), do: %{acc | tokens: merge_tokens(acc.tokens, usage)}
  defp apply_usage(acc, _usage), do: acc

  defp apply_content(acc, content) when is_list(content) do
    Enum.reduce(content, acc, fn
      %{"type" => "tool_use", "name" => @approval_tool, "input" => input}, inner ->
        %{inner | blocked_action: blocked_action_text(input)}

      %{"type" => "text", "text" => text}, inner when is_binary(text) ->
        %{inner | summary: append_text(inner.summary, text)}

      _content, inner ->
        inner
    end)
  end

  defp apply_content(acc, _content), do: acc

  defp merge_tokens(current, nil), do: current

  defp merge_tokens(current, usage) when is_map(usage) do
    input = Map.get(usage, "input_tokens", current.input)
    output = Map.get(usage, "output_tokens", current.output)
    total = Map.get(usage, "total_tokens", input + output)
    %{input: input, output: output, total: total}
  end

  defp merge_tokens(current, _usage), do: current

  defp result_status(%{"is_error" => false, "subtype" => "success"}), do: :done
  defp result_status(%{"subtype" => subtype}) when is_binary(subtype), do: {:error, subtype}
  defp result_status(%{"is_error" => true}), do: {:error, "error"}
  defp result_status(_event), do: :done

  defp append_text(nil, text), do: text
  defp append_text(existing, text), do: existing <> text

  defp blocked_action_text(input) when is_map(input), do: Map.get(input, "action") || Jason.encode!(input)
  defp blocked_action_text(input), do: to_string(input)

  defp finalize(%__MODULE__{blocked_action: action} = acc, _exit_status) when is_binary(action) do
    {:ok,
     Result.new(
       status: :blocked,
       session_id: acc.session_id,
       tokens: acc.tokens,
       seconds_running: acc.seconds_running,
       summary: acc.summary,
       blocked_action: action
     )}
  end

  defp finalize(%__MODULE__{saw_result: true, result_status: :done} = acc, _exit_status) do
    {:ok,
     Result.new(
       status: :done,
       session_id: acc.session_id,
       tokens: acc.tokens,
       seconds_running: acc.seconds_running,
       summary: acc.summary
     )}
  end

  defp finalize(%__MODULE__{saw_result: true, result_status: {:error, subtype}}, _exit_status) do
    {:error, {:claude_error, subtype}}
  end

  defp finalize(%__MODULE__{saw_result: false}, exit_status) when exit_status in [0, nil] do
    {:error, {:claude_stream, "stream ended without a result event"}}
  end

  defp finalize(%__MODULE__{saw_result: false}, _exit_status) do
    {:error, {:claude_stream, "nonzero exit without a result event"}}
  end
end
