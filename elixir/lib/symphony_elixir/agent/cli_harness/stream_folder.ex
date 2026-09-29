defmodule SymphonyElixir.Agent.CliHarness.StreamFolder do
  @moduledoc "Contract for pure folders of a CLI agent's line-delimited JSON event stream."

  alias SymphonyElixir.Agent.Result

  @callback new() :: struct()
  @callback step(event :: map(), acc :: struct()) :: {struct(), map() | nil}
  @callback finalize(acc :: struct(), exit_status :: integer() | nil) :: {:ok, Result.t()} | {:error, term()}
end
