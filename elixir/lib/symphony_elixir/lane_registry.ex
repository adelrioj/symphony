defmodule SymphonyElixir.LaneRegistry do
  @moduledoc "Registry of per-lane runtime processes, keyed by `{lane_id, role}`."

  @type role :: :runtime | :tasks | :orchestrator

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: __MODULE__)

  @spec via(term(), role()) :: {:via, Registry, {__MODULE__, {term(), role()}}}
  def via(lane_id, role), do: {:via, Registry, {__MODULE__, {lane_id, role}}}

  @spec whereis(term(), role()) :: pid() | nil
  def whereis(lane_id, role) do
    case Registry.lookup(__MODULE__, {lane_id, role}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end
end
