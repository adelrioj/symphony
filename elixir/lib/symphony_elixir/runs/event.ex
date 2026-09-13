defmodule SymphonyElixir.Runs.Event do
  @moduledoc "A committed run event; SQLite JSON text is decoded to a map with string keys."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "run_events" do
    field(:run_id, :integer)
    field(:at, :utc_datetime_usec)
    field(:kind, :string)
    field(:payload, :map, default: %{})
  end
end
