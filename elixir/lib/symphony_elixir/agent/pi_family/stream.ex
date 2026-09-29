defmodule SymphonyElixir.Agent.PiFamily.Stream do
  @moduledoc """
  Pure folder for `omp`/`pi --mode json` events (shared pi-family event format); harness modules supply the error tags.

  Assistant `message_end` events carry per-call usage and the final `stopReason`; `agent_end`
  marks a complete run. Tool input rides only in `detail` (operator-only run history), as in Claude.
  """

  alias SymphonyElixir.Agent.Result

  @tool_detail_keys ~w(command file_path path pattern url query description)

  defstruct error_tag: :omp_error,
            stream_tag: :omp_stream,
            session_id: nil,
            tokens: %{input: 0, output: 0, total: 0},
            cached_tokens: 0,
            activity: nil,
            activity_kind: :notification,
            activity_detail: nil,
            summary: nil,
            stop_reason: nil,
            saw_agent_end: false

  @type t :: %__MODULE__{}

  @spec new(atom(), atom()) :: t()
  def new(error_tag, stream_tag), do: %__MODULE__{error_tag: error_tag, stream_tag: stream_tag}

  @spec fold([map()], integer() | nil) :: {:ok, Result.t()} | {:error, term()}
  def fold(events, exit_status) do
    events
    |> Enum.reduce(%__MODULE__{}, fn event, acc -> elem(step(event, acc), 0) end)
    |> finalize(exit_status)
  end

  @spec step(map(), t()) :: {t(), map() | nil}
  def step(%{"type" => "session"} = event, acc) do
    acc = %{acc | session_id: Map.get(event, "id", acc.session_id)}
    {acc, worker_update(:session_started, acc)}
  end

  def step(%{"type" => "message_end", "message" => %{"role" => "assistant"} = message}, acc) do
    acc =
      acc
      |> apply_usage(message["usage"])
      |> apply_text(message["content"])
      |> Map.put(:stop_reason, message["stopReason"])

    {acc, worker_update(acc.activity_kind, acc)}
  end

  def step(%{"type" => "tool_execution_start", "toolName" => name} = event, acc) when is_binary(name) do
    name = String.slice(name, 0, 200)

    acc = %{
      acc
      | activity: "Using tool: " <> name,
        activity_kind: :tool_use,
        activity_detail: tool_detail(name, event["args"])
    }

    {acc, worker_update(:tool_use, acc)}
  end

  def step(%{"type" => "agent_end"}, acc) do
    acc = %{acc | saw_agent_end: true}
    kind = if acc.stop_reason == "stop", do: :completed, else: :error
    {acc, worker_update(kind, acc)}
  end

  def step(_event, acc), do: {acc, nil}

  @spec finalize(t(), integer() | nil) :: {:ok, Result.t()} | {:error, term()}
  def finalize(%__MODULE__{saw_agent_end: true, stop_reason: "stop"} = acc, status) when status in [0, nil] do
    {:ok, Result.new(status: :done, session_id: acc.session_id, tokens: acc.tokens, summary: acc.summary)}
  end

  def finalize(%__MODULE__{saw_agent_end: true, stop_reason: "stop"} = acc, _status),
    do: {:error, {acc.stream_tag, "nonzero exit after successful agent_end"}}

  def finalize(%__MODULE__{saw_agent_end: true, stop_reason: reason} = acc, _status),
    do: {:error, {acc.error_tag, to_string(reason || "unknown")}}

  def finalize(%__MODULE__{} = acc, status) when status in [0, nil],
    do: {:error, {acc.stream_tag, "stream ended without an agent_end event"}}

  def finalize(%__MODULE__{} = acc, _status), do: {:error, {acc.stream_tag, "nonzero exit without an agent_end event"}}

  defp apply_usage(acc, %{} = usage) do
    cache = Map.get(usage, "cacheRead", 0) + Map.get(usage, "cacheWrite", 0)
    input = Map.get(usage, "input", 0) + cache
    output = Map.get(usage, "output", 0)
    total = Map.get(usage, "totalTokens", input + output)

    %{
      acc
      | tokens: %{
          input: acc.tokens.input + input,
          output: acc.tokens.output + output,
          total: acc.tokens.total + total
        },
        cached_tokens: acc.cached_tokens + cache
    }
  end

  defp apply_usage(acc, _usage), do: acc

  defp apply_text(acc, content) when is_list(content) do
    text = for %{"type" => "text", "text" => t} when is_binary(t) <- content, into: "", do: t

    if text == "" do
      acc
    else
      %{acc | summary: text, activity: String.slice(text, 0, 500), activity_kind: :notification, activity_detail: nil}
    end
  end

  defp apply_text(acc, _content), do: acc

  defp tool_detail(name, input) when is_map(input) do
    case Enum.find(@tool_detail_keys, &(is_binary(input[&1]) and input[&1] != "")) do
      nil -> nil
      key -> name <> ": " <> String.slice(input[key], 0, 300)
    end
  end

  defp tool_detail(_name, _input), do: nil

  defp worker_update(kind, acc) do
    %{
      event: kind,
      timestamp: DateTime.utc_now(),
      session_id: acc.session_id,
      usage_scope: :turn,
      payload: acc.activity || "agent #{kind}",
      detail: acc.activity_detail,
      usage: %{
        input_tokens: acc.tokens.input,
        output_tokens: acc.tokens.output,
        cached_tokens: acc.cached_tokens,
        total_tokens: acc.tokens.total
      }
    }
  end
end
