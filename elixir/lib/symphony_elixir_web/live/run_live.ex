defmodule SymphonyElixirWeb.RunLive do
  @moduledoc "One durable attempt, its timings, token totals and live event tail."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{LaneStore, Runs}
  alias SymphonyElixir.Runs.Event
  alias SymphonyElixirWeb.ObservabilityPubSub

  @impl true
  def mount(%{"attempt_id" => attempt_id}, _session, socket) do
    # Subscribe before reading: a concurrent finish must not fall between the snapshot and subscription.
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe_run(attempt_id)

    case Runs.get_by_attempt(attempt_id) do
      nil ->
        {:ok, missing_run(socket)}

      run ->
        events = Runs.events(run.id)
        run = Runs.get_by_attempt(attempt_id) || run

        lane_slug =
          case LaneStore.lookup(run.lane_id) do
            {:ok, entry} -> entry.slug
            :error -> nil
          end

        if connected?(socket) and run.status == "running", do: schedule_tick()

        {:ok,
         socket
         |> assign(run: run, lane_slug: lane_slug, now: DateTime.utc_now(), last_event_id: Enum.reduce(events, 0, &max(&1.id, &2)))
         |> stream(:events, events)}
    end
  end

  @impl true
  def handle_info({:run_event, %Event{run_id: run_id, id: id} = event}, socket)
      when run_id == socket.assigns.run.id and is_integer(id) and id > socket.assigns.last_event_id do
    # Events already included in the initial query can still be queued in our mailbox.
    {:noreply, socket |> stream_insert(:events, event) |> assign(:last_event_id, id) |> refresh_run()}
  end

  def handle_info({:run_event, _event}, socket), do: {:noreply, socket}

  def handle_info({:run_updated, attempt_id}, socket) when attempt_id == socket.assigns.run.attempt_id,
    do: {:noreply, refresh_run(socket)}

  def handle_info({:run_updated, _attempt_id}, socket), do: {:noreply, socket}

  def handle_info(:runtime_tick, socket) do
    if socket.assigns.run.status == "running", do: schedule_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <p class="eyebrow">Run</p>
        <h1 class="hero-title">{@run.issue_identifier}</h1>
        <p class="hero-copy mono">{@run.attempt_id}</p>
        <p class="hero-copy">
          <span id="run-status" class="state-badge">{@run.status}</span>
          · lane <a :if={@lane_slug} class="issue-link" href={"/lanes/#{@lane_slug}"}>{@lane_slug}</a>
          <span :if={is_nil(@lane_slug)}>removed</span>
          · executor {@run.executor}
          · version {@run.lane_version_id}
        </p>
        <p id="run-timings" class="hero-copy">
          Started <time class="mono" datetime={DateTime.to_iso8601(@run.started_at)}>{DateTime.to_iso8601(@run.started_at)}</time>
          <span :if={@run.finished_at}>· finished <time class="mono" datetime={DateTime.to_iso8601(@run.finished_at)}>{DateTime.to_iso8601(@run.finished_at)}</time></span>
          · elapsed {max(DateTime.diff(@run.finished_at || @now, @run.started_at), 0)}s
        </p>
        <p id="run-totals" class="hero-copy numeric" aria-live="polite">
          Turns {@run.turns} · tokens in {@run.input_tokens} / out {@run.output_tokens} / cached {@run.cached_tokens} / total {@run.input_tokens + @run.output_tokens}
        </p>
      </header>
      <section class="section-card">
        <h2 class="section-title">Events</h2>
        <p :if={@last_event_id == 0} class="empty-state">No events recorded yet.</p>
        <ol id="events" phx-update="stream" class="run-events mono" aria-label="Run events">
          <li :for={{dom_id, event} <- @streams.events} id={dom_id}>
            <time class="muted" datetime={DateTime.to_iso8601(event.at)}>{DateTime.to_iso8601(event.at)}</time>
            <strong>{event.kind}</strong>
            <span>{describe(event.payload)}</span>
          </li>
        </ol>
      </section>
    </section>
    """
  end

  defp refresh_run(socket) do
    case Runs.get_by_attempt(socket.assigns.run.attempt_id) do
      nil -> missing_run(socket)
      run -> assign(socket, run: run, now: DateTime.utc_now())
    end
  end

  defp missing_run(socket), do: socket |> put_flash(:error, "Run no longer exists") |> push_navigate(to: "/")
  defp schedule_tick, do: Process.send_after(self(), :runtime_tick, 1_000)

  defp describe(%{"message" => message}) when is_binary(message) and message != "", do: message
  defp describe(%{"total_tokens" => total} = payload), do: "in #{payload["input_tokens"]} / out #{payload["output_tokens"]} / cached #{payload["cached_tokens"] || 0} / total #{total}"
  defp describe(%{"event" => event}) when is_binary(event), do: event
  defp describe(payload), do: Jason.encode!(payload)
end
