defmodule SymphonyElixir.Agent.Claude.Stream do
  @moduledoc """
  Pure folder for Claude stream-json events.

  Turns decoded events plus the process exit status into an `Agent.Result` or
  an error, with approval-prompt blocked events taking precedence over later
  nonzero exits.
  """

  require Logger

  alias SymphonyElixir.Agent.Result

  @approval_tool "mcp__symphony__approval_prompt"

  defstruct session_id: nil,
            tokens: %{input: 0, output: 0, total: 0},
            cached_tokens: 0,
            message_tokens: %{},
            activity: nil,
            seconds_running: 0,
            summary: nil,
            blocked_action: nil,
            saw_result: false,
            result_status: nil

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          tokens: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()},
          cached_tokens: non_neg_integer(),
          message_tokens: %{optional(String.t()) => map()},
          activity: String.t() | nil,
          seconds_running: non_neg_integer(),
          summary: String.t() | nil,
          blocked_action: String.t() | nil,
          saw_result: boolean(),
          result_status: :done | {:error, String.t()} | nil
        }

  @type worker_update :: %{
          event: atom(),
          timestamp: DateTime.t(),
          session_id: String.t() | nil,
          usage_scope: :turn,
          payload: String.t(),
          usage: %{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            total_tokens: non_neg_integer(),
            # Cache creation and reads are included in input_tokens, not added to total again.
            cached_tokens: non_neg_integer()
          }
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec fold([map()], integer() | nil) :: {:ok, Result.t()} | {:error, term()}
  def fold(events, exit_status) when is_list(events) do
    events
    |> Enum.reduce(new(), fn event, acc ->
      {updated_acc, _update} = step(event, acc)
      updated_acc
    end)
    |> finalize(exit_status)
  end

  @spec step(map()) :: {t(), worker_update() | nil}
  def step(event), do: step(event, new())

  @spec step(map(), t()) :: {t(), worker_update() | nil}
  def step(%{"type" => "system", "subtype" => "init"} = event, acc) do
    updated_acc = %{acc | session_id: Map.get(event, "session_id", acc.session_id)}
    {updated_acc, worker_update(:session_started, updated_acc)}
  end

  def step(%{"type" => type, "message" => message}, acc) when type in ["assistant", "user"] and is_map(message) do
    updated_acc =
      acc
      |> apply_usage(message)
      |> apply_content(Map.get(message, "content", []))

    update =
      cond do
        updated_acc.blocked_action != acc.blocked_action ->
          worker_update(:blocked, updated_acc)

        is_map(Map.get(message, "usage")) ->
          worker_update(:usage_updated, updated_acc)

        updated_acc.activity != acc.activity ->
          worker_update(:notification, updated_acc)

        true ->
          nil
      end

    {updated_acc, update}
  end

  def step(%{"type" => "result"} = event, acc) do
    updated_acc = %{
      acc
      | saw_result: true,
        seconds_running: div(Map.get(event, "duration_ms", acc.seconds_running * 1000), 1000),
        tokens: merge_tokens(acc.tokens, Map.get(event, "usage")),
        cached_tokens: cached_usage(Map.get(event, "usage"), acc.cached_tokens),
        summary: Map.get(event, "result", acc.summary),
        activity: result_activity(event, acc.activity),
        result_status: result_status(event)
    }

    update_kind =
      case updated_acc.result_status do
        :done -> :completed
        {:error, _subtype} -> :error
      end

    {updated_acc, worker_update(update_kind, updated_acc)}
  end

  def step(_event, acc), do: {acc, nil}

  @spec finalize(t(), integer() | nil) :: {:ok, Result.t()} | {:error, term()}
  def finalize(%__MODULE__{blocked_action: action} = acc, _exit_status) when is_binary(action) do
    # Blocked wins over a later error/nonzero exit (a denied permission ends the
    # run), but log any discarded error subtype so the precedence is auditable.
    log_discarded_error(acc)

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

  def finalize(%__MODULE__{saw_result: true, result_status: :done} = acc, exit_status) when exit_status in [0, nil] do
    {:ok,
     Result.new(
       status: :done,
       session_id: acc.session_id,
       tokens: acc.tokens,
       seconds_running: acc.seconds_running,
       summary: acc.summary
     )}
  end

  def finalize(%__MODULE__{saw_result: true, result_status: :done}, _exit_status) do
    {:error, {:claude_stream, "nonzero exit after successful result"}}
  end

  def finalize(%__MODULE__{saw_result: true, result_status: {:error, subtype}}, _exit_status) do
    {:error, {:claude_error, subtype}}
  end

  def finalize(%__MODULE__{saw_result: false}, exit_status) when exit_status in [0, nil] do
    {:error, {:claude_stream, "stream ended without a result event"}}
  end

  def finalize(%__MODULE__{saw_result: false}, _exit_status) do
    {:error, {:claude_stream, "nonzero exit without a result event"}}
  end

  defp log_discarded_error(%__MODULE__{result_status: {:error, subtype}, session_id: session_id}) do
    Logger.warning("Claude run blocked; discarding coexisting error subtype=#{subtype} session_id=#{session_id || "unknown"}")
  end

  defp log_discarded_error(_acc), do: :ok

  defp apply_usage(acc, %{"usage" => usage} = message) when is_map(usage) do
    id = Map.get(message, "id")
    previous = Map.get(acc.message_tokens, id, %{input: 0, output: 0, total: 0})
    current = Map.merge(previous, merge_tokens(previous, usage), fn _key, old, new -> max(old, new) end)
    cached_before = Map.get(previous, :cached, 0)
    cached_now = max(cached_before, cached_usage(usage, cached_before))
    current = Map.put(current, :cached, cached_now)
    tokens = Map.new(acc.tokens, fn {key, value} -> {key, value + max(current[key] - previous[key], 0)} end)

    # Claude can emit several content blocks for one message ID. Its usage is
    # per message, whereas the final result carries the whole invocation total.
    message_tokens =
      if is_binary(id), do: Map.put(acc.message_tokens, id, current), else: acc.message_tokens

    cached_tokens = acc.cached_tokens + cached_now - cached_before

    %{acc | tokens: tokens, cached_tokens: cached_tokens, message_tokens: message_tokens}
  end

  defp apply_usage(acc, _message), do: acc

  defp apply_content(acc, content) when is_list(content) do
    Enum.reduce(content, acc, fn
      %{"type" => "tool_use", "name" => @approval_tool, "input" => input}, inner ->
        action = blocked_action_text(input)
        %{inner | blocked_action: action, activity: "Awaiting approval"}

      %{"type" => "text", "text" => text}, inner when is_binary(text) ->
        %{inner | summary: append_text(inner.summary, text), activity: String.slice(text, 0, 500)}

      %{"type" => "tool_use", "name" => name}, inner when is_binary(name) ->
        %{inner | activity: "Using tool: " <> String.slice(name, 0, 200)}

      _content, inner ->
        inner
    end)
  end

  defp apply_content(acc, _content), do: acc

  defp cached_usage(usage, default) when is_map(usage), do: Map.get(usage, "cache_read_input_tokens", default)
  defp cached_usage(_usage, default), do: default

  defp merge_tokens(current, nil), do: current

  defp merge_tokens(current, usage) when is_map(usage) do
    input =
      Map.get(usage, "input_tokens", current.input) +
        Map.get(usage, "cache_creation_input_tokens", 0) +
        Map.get(usage, "cache_read_input_tokens", 0)

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

  defp result_activity(event, previous) do
    case result_status(event) do
      {:error, subtype} -> "Claude failed: #{subtype}"
      :done -> "Completed: " <> String.slice(Map.get(event, "result") || previous || "Claude turn", 0, 500)
    end
  end

  defp worker_update(kind, acc) do
    %{
      event: kind,
      timestamp: DateTime.utc_now(),
      session_id: acc.session_id,
      usage_scope: :turn,
      payload: acc.activity || "Claude #{kind}",
      usage: %{
        input_tokens: Map.get(acc.tokens, :input, 0),
        output_tokens: Map.get(acc.tokens, :output, 0),
        cached_tokens: acc.cached_tokens,
        total_tokens: Map.get(acc.tokens, :total, 0)
      }
    }
  end
end
