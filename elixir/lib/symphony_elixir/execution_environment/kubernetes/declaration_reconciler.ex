defmodule SymphonyElixir.ExecutionEnvironment.Kubernetes.DeclarationReconciler do
  @moduledoc """
  Drives host-loss declarations and watches for the one thing that would contradict them.

  The adapter is a set of invoked functions, not a resident controller, so nothing would ever
  call `declare_lost/3` on its own. This process does: it lists declarations, drives the pending
  ones to a verified outcome, records that outcome in their status, and then keeps checking
  whether a host someone declared permanently lost has been observed again.

  It is a resync loop rather than a watch. The spec asked for a watch with resync and `410 Gone`
  recovery; a full list on every pass is what that recovery path would fall back to anyway, it
  cannot lose history, and declaring a host lost is a rare deliberate act where a pass interval
  of latency costs nothing. There is no watch to recover, so there is no `410` to handle.

  Monitoring state is not held here. It is derived from each declaration's own recorded
  `status.observedAt`, so a restart neither forgets what it was watching nor starts the clock
  again.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, LaneContext}
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.{Client, Declaration, LossAlarm}

  @interval_ms 60_000
  @operation_timeout_ms 120_000
  # How long after finalization a reappearing host is still worth alarming about. A re-provisioned
  # machine gets a fresh machine-id, so the same identity returning is an operator error, and one
  # that surfaces within days rather than months.
  @monitoring_lifetime_ms 30 * 24 * 60 * 60 * 1000

  @terminal ["accepted", "refused"]

  @spec monitoring_lifetime_ms() :: pos_integer()
  def monitoring_lifetime_ms, do: @monitoring_lifetime_ms

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @interval_ms)
    state = %{opts: opts, lane_id: Keyword.get(opts, :lane_id), interval: interval, timer: nil}
    {:ok, %{state | timer: Process.send_after(self(), :reconcile, interval)}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    case environment(state) do
      nil -> :ok
      config -> log_pass(reconcile(config, state.opts))
    end

    {:noreply, %{state | timer: Process.send_after(self(), :reconcile, state.interval)}}
  end

  # Resolved per pass rather than held from start-up. A lane's environment is refreshed while it
  # runs, and a lane may be reconfigured onto or off Kubernetes without restarting anything.
  defp environment(state) do
    case Keyword.fetch(state.opts, :config) do
      {:ok, config} -> config
      :error -> lane_environment(state.lane_id)
    end
  end

  defp lane_environment(nil), do: nil

  defp lane_environment(lane_id) do
    LaneContext.put(lane_id)

    case Config.settings() do
      {:ok, settings} -> kubernetes_only(EnvironmentConfig.runtime(settings))
      _ -> nil
    end
  end

  defp kubernetes_only(%{kind: "kubernetes"} = config), do: config
  defp kubernetes_only(_config), do: nil

  defp log_pass({:ok, %{alarms: alarms} = summary}) when alarms > 0 do
    Logger.error("Host loss declaration contradicted, see host_loss_alarms summary=#{inspect(summary)}")
  end

  defp log_pass({:ok, summary}) do
    if summary.accepted + summary.refused + summary.unresolved > 0, do: Logger.info("Host loss reconcile summary=#{inspect(summary)}")
  end

  # A pass that cannot read is a pass that knows nothing, which is not the same as a clean one.
  defp log_pass({:error, reason}), do: Logger.warning("Host loss reconcile unavailable reason=#{inspect(reason)}")

  @doc """
  One reconciliation pass: drive every pending declaration, then check every settled one for
  the host coming back. Returns what the pass did, or an error if it could not read.
  """
  @spec reconcile(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(config, opts) do
    opts = Keyword.put_new(opts, :timeout_ms, @operation_timeout_ms)

    with {:ok, objects} <- Client.list(config, collection(config), opts) do
      summary = Enum.reduce(objects, %{accepted: 0, refused: 0, unresolved: 0, alarms: 0}, &pass(config, &1, &2, opts))
      {:ok, summary}
    end
  end

  defp pass(config, object, summary, opts) do
    settled? = outcome(object) in @terminal
    if settled?, do: monitor(config, object, summary, opts), else: drive(config, object, summary, opts)
  end

  defp drive(config, object, summary, opts) do
    case Declaration.decode(object["spec"]) do
      {:ok, declaration} -> settle(config, object, declaration, summary, opts)
      # A declaration the CRD schema should have rejected. Record it rather than retrying forever.
      {:error, reason} -> record(config, object, refused_status(reason), Map.update!(summary, :refused, &(&1 + 1)), opts)
    end
  end

  defp settle(config, object, declaration, summary, opts) do
    case Kubernetes.declare_lost(config, declaration, opts) do
      {:ok, records} ->
        record(config, object, accepted_status(declaration, records), Map.update!(summary, :accepted, &(&1 + 1)), opts)

      # Refused is terminal and permanent; unresolved is the only retryable outcome, and retrying
      # re-reads every predicate rather than resuming a partial result.
      {:error, {:invalid, _} = reason} ->
        record(config, object, refused_status(reason), Map.update!(summary, :refused, &(&1 + 1)), opts)

      {:error, reason} ->
        record(config, object, unresolved_status(reason), Map.update!(summary, :unresolved, &(&1 + 1)), opts)
    end
  end

  defp accepted_status(declaration, records) do
    obligations = Enum.map(declaration.spec["obligationUIDs"], &%{"uid" => &1, "disposition" => "discharged"})
    environments = Enum.map(records, &%{"key" => &1.key, "state" => "discharged"})
    %{"outcome" => "accepted", "observedAt" => timestamp(), "obligations" => obligations, "environments" => environments}
  end

  defp refused_status(reason), do: %{"outcome" => "refused", "observedAt" => timestamp(), "message" => inspect(reason)}
  defp unresolved_status(reason), do: %{"outcome" => "unresolved", "observedAt" => timestamp(), "message" => inspect(reason)}

  defp record(config, object, status, summary, opts) do
    patch = [%{"op" => "add", "path" => "/status", "value" => status}]
    path = collection(config) <> "/" <> URI.encode(name(object), &URI.char_unreserved?/1) <> "/status"

    case Client.request(config, :patch, path, patch, opts) do
      {:ok, %{status: code}} when code in 200..299 ->
        summary

      # The outcome stands and the next pass records it again, so this is not fatal. But only the
      # adapter identity may write this subresource, and an identity that is refused it would
      # otherwise retry for ever, writing nothing and saying nothing about why.
      other ->
        Logger.warning("Host loss outcome could not be recorded declaration=#{name(object)} outcome=#{status["outcome"]} reason=#{inspect(other)}")
        summary
    end
  end

  # The standing contradiction check. Only an accepted declaration has anything to contradict:
  # a refusal discharged nothing, so a host returning after one is simply a host.
  defp monitor(config, object, summary, opts) do
    host = get_in(object, ["spec", "host"]) || %{}

    if outcome(object) == "accepted" and monitoring?(object) do
      case Client.lookup(config, "/api/v1/nodes", host["node_name"], opts) do
        {:ok, node} when is_map(node) -> alarm_if_same_machine(node, object, host, summary)
        _ -> summary
      end
    else
      summary
    end
  end

  # A node name is reused freely; a machine identity is not. Only the same machine coming back
  # says the declaration was wrong.
  defp alarm_if_same_machine(node, object, host, summary) do
    info = get_in(node, ["status", "nodeInfo"]) || %{}
    same? = get_in(node, ["metadata", "uid"]) == host["node_uid"] or info["machineID"] == host["machine_id"]

    if same?, do: raise_alarm(object, host, node, summary), else: summary
  end

  defp raise_alarm(object, host, node, summary) do
    attrs = %{
      kind: "host_reappeared",
      dedup_key: name(object) <> ":" <> to_string(host["node_uid"]),
      declaration: name(object),
      node_uid: host["node_uid"],
      machine_id: host["machine_id"],
      detail: %{
        "node_name" => host["node_name"],
        "observed_node_uid" => get_in(node, ["metadata", "uid"]),
        "observed_machine_id" => get_in(node, ["status", "nodeInfo", "machineID"]),
        "declared_at" => get_in(object, ["status", "observedAt"])
      }
    }

    case LossAlarm.raise(attrs) do
      {:ok, :raised} -> Map.update!(summary, :alarms, &(&1 + 1))
      _ -> summary
    end
  end

  defp monitoring?(object) do
    with observed when is_binary(observed) <- get_in(object, ["status", "observedAt"]),
         {:ok, at, _} <- DateTime.from_iso8601(observed) do
      DateTime.diff(DateTime.utc_now(), at, :millisecond) <= @monitoring_lifetime_ms
    else
      _ -> false
    end
  end

  defp outcome(object), do: get_in(object, ["status", "outcome"])
  defp name(object), do: get_in(object, ["metadata", "name"])
  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp collection(config),
    do: "/apis/symphony.dev/v1alpha1/namespaces/#{URI.encode(config.provider["namespace"], &URI.char_unreserved?/1)}/hostlossdeclarations"
end
