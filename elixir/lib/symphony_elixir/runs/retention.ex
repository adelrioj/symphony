defmodule SymphonyElixir.Runs.Retention do
  @moduledoc "Prunes expired events after boot and daily thereafter; attempt summaries are never pruned."

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Runs}

  @first_run_ms 60_000
  @interval_ms 24 * 60 * 60 * 1000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(_opts), do: {:ok, Process.send_after(self(), :prune, @first_run_ms)}

  @impl true
  def handle_info(:prune, timer) do
    Process.cancel_timer(timer)
    days = Config.events_retention_days()
    deleted = Runs.prune_events(days)
    Logger.info("Pruned run events older than #{days} days count=#{deleted}")
    {:noreply, Process.send_after(self(), :prune, @interval_ms)}
  end
end
