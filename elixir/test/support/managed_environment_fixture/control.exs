defmodule SymphonyElixir.ManagedEnvironmentFixture.Control do
  @moduledoc false
  use GenServer

  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.ExecutionEnvironment.Kubernetes.Guard
  alias SymphonyElixir.Tracker.Memory

  @resource_keys ~w(kind id name uid selfLink zone region namespace volume_handle)
  @event_keys [
    :event,
    :issue_id,
    :operation,
    :attempt_id,
    :outcome,
    :mode,
    :environment_id,
    :create_attempt_id,
    :guard_uid,
    :resource_uid,
    :resource_name,
    :resource,
    :namespace
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def qualified?(state) do
    uninterrupted = not state.interrupted and not state.runner_rejected
    absent = state.inventory_complete and state.observed_resources == []
    uninterrupted and absent and Enum.all?(state.checks, fn {_, check} -> check.status == :passed end)
  end

  def unrelated_unchanged?(state, observed) do
    is_list(state.baseline) and state.baseline != [] and observed == state.baseline
  end

  @impl true
  def init(opts) do
    limit = if is_integer(opts[:session_limit]) and opts[:session_limit] > 0, do: opts[:session_limit], else: 0

    {:ok,
     %{
       issues: [],
       faults: MapSet.new(),
       events: [],
       sessions: 0,
       limit: limit,
       config: opts[:config],
       baseline: nil,
       allocation_started: false,
       interrupted: false,
       captured_resources: [],
       retained_guards: [],
       observed_resources: [],
       inventory_complete: false,
       runner_rejected: false,
       runner_invocations: 0,
       checks: Map.new(opts[:checks], &{&1, %{name: &1, status: :not_run}})
     }}
  end

  @impl true
  def handle_call({:issues, issues}, _from, state) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    {:reply, :ok, %{state | issues: issues}}
  end

  def handle_call({:transition, id, next}, _from, state) do
    :ok = Memory.update_issue_state(id, next)

    receive do
      {:memory_tracker_state_update, ^id, ^next} -> :ok
    after
      1_000 -> raise "Memory transition notification unavailable"
    end

    {:reply, :ok, apply_transition(state, id, next)}
  end

  def handle_call({:fault, action, key}, _from, state) do
    faults = if action == :arm, do: MapSet.put(state.faults, key), else: MapSet.delete(state.faults, key)
    {:reply, :ok, %{state | faults: faults}}
  end

  def handle_call({:armed?, key}, _from, state), do: {:reply, MapSet.member?(state.faults, key), state}

  def handle_call({:event, %{event: :runner_invocation} = event}, _from, state) do
    allowed = valid_runner?(event, state)
    options = Map.get(event, :options)
    opts = if Keyword.keyword?(options), do: options, else: []
    context = opts[:execution_context]
    mode = runner_mode(context)
    record = %{event: :runner_invocation, issue_id: Map.get(event, :issue_id), attempt_id: opts[:attempt_id], mode: mode}
    record = Map.put(record, :outcome, if(allowed, do: :accepted, else: :rejected))
    record = if allowed, do: Map.put(record, :environment_id, context.environment.record.key), else: record
    rejected = state.runner_rejected or not allowed
    state = %{state | runner_rejected: rejected, runner_invocations: state.runner_invocations + 1}
    reply = if allowed, do: :ok, else: {:error, :qualification_runner_context_rejected}
    {:reply, reply, append_event(state, record)}
  end

  def handle_call({:event, %{event: :inventory_observation, result: result}}, _from, state) do
    resources = result_resources(result)
    complete = match?({:ok, %{records: _, live_worker_counts: _}}, result)
    observed = if complete, do: observed_resources(result), else: []
    state = state |> capture(resources) |> capture_guards(result)
    {:reply, :ok, %{state | inventory_complete: complete, observed_resources: observed}}
  end

  def handle_call({:event, %{event: :record_observation, result: result}}, _from, state) do
    {:reply, :ok, state |> capture(result_resources(result)) |> capture_guards(result)}
  end

  def handle_call({:event, event}, _from, state), do: {:reply, :ok, append_event(state, event)}

  def handle_call({:check, name, result}, _from, state) do
    {:reply, :ok, %{state | checks: Map.put(state.checks, name, Map.merge(%{name: name}, result))}}
  end

  def handle_call({:baseline, baseline}, _from, state), do: {:reply, :ok, %{state | baseline: decode_baseline(baseline)}}
  def handle_call(:allocation_started, _from, state), do: {:reply, :ok, %{state | allocation_started: true}}
  def handle_call(:clear_faults, _from, state), do: {:reply, :ok, %{state | faults: MapSet.new()}}

  def handle_call({:interrupted, evidence}, _from, state) do
    state = capture(state, safe_resources(evidence["captured_resources"] || []))
    state = capture(state, safe_resources(evidence["remaining_owned_resources"] || []))
    state = %{state | retained_guards: Enum.uniq(state.retained_guards ++ safe_resources(evidence["retained_guards"] || []))}

    cleanup_issues =
      (evidence["cleanup_issue_ids"] || [])
      |> Enum.filter(&safe_opaque_id?/1)
      |> Enum.uniq()
      |> Enum.map(&%SymphonyElixir.Tracker.Issue{id: &1, identifier: &1, state: "Done", dispatchable: false})

    state = %{state | issues: Enum.uniq_by(state.issues ++ cleanup_issues, & &1.id)}
    restored_events = Enum.reduce(evidence["events"] || [], %{state | events: []}, &append_event(&2, &1))

    state = %{
      restored_events
      | interrupted: true,
        sessions: evidence["backend_sessions"] || 0,
        baseline: decode_baseline(evidence["unrelated_baseline"]),
        runner_rejected: state.runner_rejected or evidence["runner_rejected"] != false,
        runner_invocations: evidence["runner_invocations"] || 0,
        inventory_complete: false,
        observed_resources: []
    }

    {:reply, :ok, state}
  end

  def handle_call(:session, _from, state) do
    allowed = state.sessions < state.limit
    {:reply, allowed, %{state | sessions: state.sessions + if(allowed, do: 1, else: 0)}}
  end

  # Serialize evidence writes with observations, so a delayed writer cannot erase a rejection.
  def handle_call({:persist, writer}, _from, state), do: {:reply, persist(writer, state), state}
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info({:memory_tracker_state_update, id, next}, state), do: {:noreply, apply_transition(state, id, next)}
  def handle_info({:memory_tracker_comment, _, _}, state), do: {:noreply, state}

  defp persist(writer, state) do
    writer.(state)
    :ok
  rescue
    _ -> {:error, :qualification_evidence_write_failed}
  catch
    _, _ -> {:error, :qualification_evidence_write_failed}
  end

  defp valid_runner?(%{issue_id: issue_id, options: opts}, state) do
    with true <- Keyword.keyword?(opts),
         %ExecutionContext{mode: :managed} = context <- opts[:execution_context],
         %{config: config, record: record} <- context.environment,
         true <- safe_opaque_id?(issue_id) and safe_opaque_id?(opts[:attempt_id]),
         true <- record.issue_id == issue_id and record.attempt_id == opts[:attempt_id],
         true <- same_scope?(state.config, config),
         true <- Enum.any?(state.issues, &(&1.id == issue_id)) do
      ExecutionContext.managed(config, record, context.connection) == context
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp valid_runner?(_, _), do: false

  defp same_scope?(expected, actual) when is_map(expected) and is_map(actual) do
    fields = [:kind, :deployment_id, :tracker_kind, :workspace_root]
    same_identity = Map.take(expected, fields) == Map.take(actual, fields)
    same_identity and EnvironmentConfig.scope(expected) == EnvironmentConfig.scope(actual)
  end

  defp same_scope?(_, _), do: false
  defp runner_mode(%ExecutionContext{mode: mode}) when mode in [:local, :ssh, :managed], do: mode
  defp runner_mode(nil), do: :missing
  defp runner_mode(_), do: :invalid

  defp append_event(state, event) do
    safe =
      Enum.reduce(@event_keys, %{}, fn key, acc ->
        value = Map.get(event, key, Map.get(event, Atom.to_string(key)))
        if is_atom(value) or safe_opaque_id?(value), do: Map.put(acc, key, value), else: acc
      end)

    %{state | events: Enum.take([safe | state.events], 512)}
  end

  defp capture(state, resources), do: %{state | captured_resources: Enum.uniq(state.captured_resources ++ resources)}

  defp result_resources({:ok, %{records: records}}), do: Enum.flat_map(records, &record_resources/1)
  defp result_resources({:ok, records}) when is_list(records), do: Enum.flat_map(records, &record_resources/1)
  defp result_resources({:ok, %ExecutionContext{environment: %{record: record}}}), do: record_resources(record)
  defp result_resources({:ok, %{key: _} = record}), do: record_resources(record)
  defp result_resources({:error, error, record}), do: record_resources(record) ++ result_resources({:error, error})

  defp result_resources({:error, {:unknown, {kind, resources}}})
       when kind in [:qualification_inventory_unresolved, :orphan_backing_resources], do: safe_resources(resources)

  defp result_resources({:error, {:unknown, {:kubernetes_invalid_owned_record, ids}}}) when is_list(ids) do
    safe_resources(ids)
  end

  defp result_resources(_), do: []

  defp record_resources(%{key: key, metadata: metadata, provider_ref: ref} = record) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    parent =
      case ref do
        ref when is_map(ref) ->
          %{"kind" => "environment", "name" => Map.get(ref, :name), "uid" => Map.get(ref, :uid), "id" => key}

        id when is_binary(id) ->
          %{"kind" => "environment", "uid" => id, "id" => key}

        _ ->
          %{"kind" => "environment", "id" => key}
      end

    backing = safe_resources(metadata["backing_resources"] || [])
    volumes = metadata |> Map.get("volumes") |> resource_entries() |> Enum.flat_map(fn {_, value} -> volume_resources(value) end)
    cleanup = metadata |> Map.get("cleanup_remaining") |> resource_entries() |> Enum.flat_map(&cleanup_resources/1)
    guard = if Map.get(record, :absent?) == true, do: [], else: safe_resources([metadata["guard"] || %{}])
    safe_resources([parent]) ++ backing ++ volumes ++ cleanup ++ guard
  end

  defp record_resources(_), do: []

  defp capture_guards(state, result) do
    receipts = Enum.uniq(state.retained_guards ++ result_guards(result))

    resources =
      Enum.reject(state.captured_resources, fn resource ->
        resource["kind"] == "ConfigMap" and Enum.any?(receipts, &(&1["uid"] == resource["uid"] and is_binary(resource["uid"])))
      end)

    %{state | retained_guards: receipts, captured_resources: resources}
  end

  defp result_guards({:ok, %{records: records} = inventory}) do
    safe_resources(Map.get(inventory, :retained_guards, [])) ++ Enum.flat_map(records, &record_guards/1)
  end

  defp result_guards({:ok, %{key: _} = record}), do: record_guards(record)
  defp result_guards({:error, _, record}), do: record_guards(record)
  defp result_guards(_), do: []

  defp record_guards(%{kind: "kubernetes", absent?: true, proof: {:quiescent, %{guard_uid: uid}}} = record) do
    safe_resources([%{"kind" => "ConfigMap", "name" => Guard.name(record), "uid" => uid, "namespace" => record.scope["namespace"]}])
  end

  defp record_guards(_), do: []

  defp volume_resources(volume) when is_map(volume) do
    safe_resources([
      %{"kind" => "pvc", "name" => volume["pvc_name"], "uid" => volume["pvc_uid"]},
      %{"kind" => "pv", "name" => volume["pv_name"], "uid" => volume["pv_uid"], "volume_handle" => volume["volume_handle"]}
    ])
  end

  defp volume_resources(_), do: []
  defp resource_entries(value) when is_map(value), do: Map.to_list(value)
  defp resource_entries(_), do: []

  defp cleanup_resources({kind, resources}) when kind in ~w(pods persistentvolumeclaims services secrets) do
    resources |> safe_resources() |> Enum.map(&Map.put(&1, "kind", kind))
  end

  defp cleanup_resources(_), do: []

  defp observed_resources({:ok, %{records: records, live_worker_counts: counts}}) do
    parents =
      Enum.flat_map(records, fn record ->
        safe_resources([%{"kind" => "environment", "id" => record.key}])
      end)

    workers = for {key, count} <- counts, is_integer(count) and count > 0, do: %{"kind" => "live_worker", "id" => key, "live_worker_count" => count}
    Enum.map(parents ++ workers, &Map.put(&1, "status", "observed_present"))
  end

  defp safe_resources(resources) when is_list(resources) do
    resources |> Enum.map(&safe_resource/1) |> Enum.filter(&identified_resource?/1)
  end

  defp safe_resources(_), do: []

  defp safe_resource(resource) when is_binary(resource), do: safe_resource(%{"id" => resource})

  defp safe_resource(resource) when is_map(resource) do
    resource |> Map.take(@resource_keys) |> Map.filter(&safe_resource_field?/1)
  end

  defp safe_resource(_), do: %{}

  # Keep exact CSI handles across JSON persistence; the provider response bounds their size.
  defp safe_resource_field?({"volume_handle", value}) when is_binary(value) do
    byte_size(value) in 1..8_388_608 and String.valid?(value)
  end

  defp safe_resource_field?({_key, value}), do: safe_identifier?(value)

  defp identified_resource?(resource) do
    Enum.any?(~w(id name uid selfLink volume_handle), &Map.has_key?(resource, &1))
  end

  defp safe_identifier?(value) when is_binary(value) do
    byte_size(value) <= 2_048 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]*\z/, value)
  end

  defp safe_identifier?(_), do: false

  defp safe_opaque_id?(value) when is_binary(value) do
    byte_size(value) <= 2_048 and Regex.match?(~r/\A[A-Za-z0-9_-][A-Za-z0-9._:\/@+-]*\z/, value)
  end

  defp safe_opaque_id?(_), do: false

  defp decode_baseline(baseline) when is_list(baseline) do
    decoded = Enum.map(baseline, &baseline_resource/1)
    if Enum.all?(decoded, &is_map/1), do: decoded, else: nil
  end

  defp decode_baseline(_), do: nil

  defp baseline_resource(resource) when is_map(resource) do
    path = Map.get(resource, :path, resource["path"])
    uid = Map.get(resource, :uid, resource["uid"])
    fingerprint = Map.get(resource, :fingerprint, resource["fingerprint"])

    valid = safe_resource_path?(path) and safe_identifier?(uid) and valid_fingerprint?(fingerprint)
    if valid, do: %{path: path, uid: uid, fingerprint: fingerprint}, else: nil
  end

  defp baseline_resource(_), do: nil
  defp valid_fingerprint?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp valid_fingerprint?(_), do: false

  defp safe_resource_path?("/" <> path), do: safe_identifier?(path)
  defp safe_resource_path?(_), do: false

  defp apply_transition(state, id, next) do
    issues = Enum.map(state.issues, fn issue -> if issue.id == id, do: %{issue | state: next}, else: issue end)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    %{state | issues: issues}
  end
end
