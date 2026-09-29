defmodule SymphonyElixir.Agent.Pi.Stream do
  @moduledoc "pi event folder: the shared pi-family folder with pi error tags."
  @behaviour SymphonyElixir.Agent.CliHarness.StreamFolder
  alias SymphonyElixir.Agent.PiFamily.Stream, as: Family

  @impl true
  @spec new() :: Family.t()
  def new, do: Family.new(:pi_error, :pi_stream)

  @impl true
  @spec step(map(), Family.t()) :: {Family.t(), map() | nil}
  defdelegate step(event, acc), to: Family

  @impl true
  @spec finalize(Family.t(), integer() | nil) :: {:ok, SymphonyElixir.Agent.Result.t()} | {:error, term()}
  defdelegate finalize(acc, exit_status), to: Family

  @spec fold([map()], integer() | nil) :: {:ok, SymphonyElixir.Agent.Result.t()} | {:error, term()}
  def fold(events, exit_status), do: events |> Enum.reduce(new(), &elem(step(&1, &2), 0)) |> finalize(exit_status)
end
