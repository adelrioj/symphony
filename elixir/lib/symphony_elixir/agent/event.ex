defmodule SymphonyElixir.Agent.Event do
  @moduledoc """
  Backend-neutral progress event that can be converted to the orchestrator's
  existing worker-update map shape.
  """

  @enforce_keys [:kind]
  defstruct kind: nil, session_id: nil, tokens: nil, seconds_running: nil, detail: %{}

  @type t :: %__MODULE__{
          kind: :session_started | :usage_updated | :blocked | :completed | :error,
          session_id: String.t() | nil,
          tokens: %{optional(:input | :output | :total) => non_neg_integer()} | nil,
          seconds_running: non_neg_integer() | nil,
          detail: map()
        }

  @spec to_worker_update(t()) :: %{
          event: atom(),
          timestamp: DateTime.t(),
          session_id: String.t() | nil,
          usage: %{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            total_tokens: non_neg_integer()
          }
        }
  def to_worker_update(%__MODULE__{} = event) do
    tokens = event.tokens || %{}

    %{
      event: event.kind,
      timestamp: DateTime.utc_now(),
      session_id: event.session_id,
      usage: %{
        input_tokens: Map.get(tokens, :input, 0),
        output_tokens: Map.get(tokens, :output, 0),
        total_tokens: Map.get(tokens, :total, 0)
      }
    }
  end
end
