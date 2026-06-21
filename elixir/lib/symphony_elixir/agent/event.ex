defmodule SymphonyElixir.Agent.Event do
  @moduledoc """
  Adapter-internal normalized progress event. Adapters build these, then convert
  to the orchestrator's existing worker-update map via `to_worker_update/1`.
  """

  @enforce_keys [:kind]
  defstruct kind: nil, session_id: nil, tokens: nil, seconds_running: nil, detail: %{}

  @type t :: %__MODULE__{
          kind: :session_started | :usage_updated | :blocked | :completed | :error,
          session_id: String.t() | nil,
          tokens: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()} | nil,
          seconds_running: non_neg_integer() | nil,
          detail: map()
        }

  @spec to_worker_update(t()) :: %{
          event: atom(),
          timestamp: integer(),
          session_id: String.t() | nil,
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer(), total_tokens: non_neg_integer()}
        }
  def to_worker_update(%__MODULE__{} = event) do
    tokens = event.tokens || %{input: 0, output: 0, total: 0}

    %{
      event: event.kind,
      timestamp: System.monotonic_time(:millisecond),
      session_id: event.session_id,
      usage: %{
        input_tokens: Map.get(tokens, :input, 0),
        output_tokens: Map.get(tokens, :output, 0),
        total_tokens: Map.get(tokens, :total, 0)
      }
    }
  end
end
