defmodule SymphonyElixir.Agent.Result do
  @moduledoc """
  Normalized outcome of a single agent turn, backend-agnostic.
  """

  @enforce_keys [:status]
  defstruct status: nil,
            session_id: nil,
            tokens: %{input: 0, output: 0, total: 0},
            seconds_running: 0,
            summary: nil,
            blocked_action: nil

  @type t :: %__MODULE__{
          status: :done | :blocked,
          session_id: String.t() | nil,
          tokens: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()},
          seconds_running: non_neg_integer(),
          summary: String.t() | nil,
          blocked_action: String.t() | nil
        }

  @spec new(keyword() | map()) :: t()
  def new(fields) do
    attrs = Map.new(fields)
    tokens = Map.get(attrs, :tokens) || %{input: 0, output: 0, total: 0}

    %__MODULE__{
      status: Map.fetch!(attrs, :status),
      session_id: Map.get(attrs, :session_id),
      tokens: Map.merge(%{input: 0, output: 0, total: 0}, tokens),
      seconds_running: Map.get(attrs, :seconds_running, 0),
      summary: Map.get(attrs, :summary),
      blocked_action: Map.get(attrs, :blocked_action)
    }
  end
end
