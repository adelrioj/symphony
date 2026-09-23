defmodule SymphonyElixir.CodexCredentials.Recovery do
  @moduledoc "Explicit, maintenance-locked recovery using the current installation and existing provider lifecycle."
  import Bitwise
  alias Exqlite.Sqlite3
  alias SymphonyElixir.{Maintenance, PathSafety, Workflow}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.CodexCredentials.{ControlStore, GoogleClient, Record}
  alias SymphonyElixir.ExecutionEnvironment.{Config, Credentials, Lifecycle, Operations, Workstations}

  @actions ~w(inspect checkpoint reseed-stop reseed-commit)
  @keys ~w(data_root workflow action resource expected_epoch expected_generation receipt_file)a
  @assignment_keys ~w(schema credential_id epoch claim_id owner secret_version)
  @max_output 1_048_576

  @spec validate_options(keyword()) :: :ok | {:error, :invalid_arguments}
  def validate_options(options) do
    action = Keyword.get(options, :action, "inspect")
    valid = Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in @keys)) and
      length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
      Enum.all?([:data_root, :workflow], &nonblank?(options[&1])) and action in @actions
    mutation = action == "inspect" or (nonblank?(options[:resource]) and is_integer(options[:expected_epoch]) and options[:expected_epoch] > 0 and decimal?(options[:expected_generation]))
    receipt = if action == "checkpoint", do: nonblank?(options[:receipt_file]), else: is_nil(options[:receipt_file])
    if valid and mutation and receipt, do: :ok, else: {:error, :invalid_arguments}
  end

  @spec reconcile(keyword(), keyword()) :: {:ok, map()} | {:error, atom()}
  def reconcile(options, deps \\ []) do
    with :ok <- validate_options(options),
         root = Path.expand(options[:data_root]),
         :ok <- Keyword.get(deps, :verify_maintenance, &Maintenance.verify/2).(root, :operator),
         {:ok, config} <- installation(root, options[:workflow]),
         {:ok, _} <- Application.ensure_all_started(:req),
         {:ok, supervisor} <- Task.Supervisor.start_link() do
      try do
        opts = Keyword.get(deps, :operation_options, [])
          |> Keyword.merge(task_supervisor: supervisor, authority: self(), credential_reconcile: false, credential_inventory: true)
        adapter = Keyword.get(deps, :adapter, Workstations)
        execute(config, adapter, Keyword.put_new(options, :action, "inspect"), opts)
      after
        Supervisor.stop(supervisor)
      end
    else
      {:error, reason} when reason in [:invalid_arguments, :maintenance_required, :installation_required, :lanes_enabled, :workflow_mismatch, :configuration_invalid] -> {:error, reason}
      _ -> {:error, :recovery_failed}
    end
  rescue
    _ -> {:error, :recovery_failed}
  catch
    _, _ -> {:error, :recovery_failed}
  end

  defp installation(root, workflow) do
    database = Path.join(root, "symphony.sqlite3")
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(database),
         {:ok, db} <- Sqlite3.open(database, mode: :readonly) do
      try do
        with {:ok, [[0]]} <- query(db, "SELECT COUNT(*) FROM lanes WHERE enabled IS NOT 0"),
             {:ok, [[front, prompt]]} <- query(db, "SELECT v.front_matter, v.prompt FROM lanes l JOIN lane_versions v ON v.id = l.current_version_id AND v.lane_id = l.id WHERE l.slug = 'features' AND l.deleted_at IS NULL"),
             {:ok, persisted} <- Workflow.parse_parts(front, prompt),
             {:ok, content} <- File.read(workflow),
             {:ok, supplied} <- Workflow.parse(content),
             true <- persisted == supplied,
             {:ok, settings} <- Schema.parse(persisted.config, resolve_secrets: false),
             %{kind: "google_workstations", codex_credentials: refs} = config when is_map(refs) <- Config.runtime(settings),
             :ok <- Workstations.validate_config(config.provider) do
          {:ok, config}
        else
          {:ok, [[enabled]]} when is_integer(enabled) and enabled > 0 -> {:error, :lanes_enabled}
          false -> {:error, :workflow_mismatch}
          _ -> {:error, :configuration_invalid}
        end
      after
        Sqlite3.close(db)
      end
    else
      _ -> {:error, :installation_required}
    end
  end

  defp query(db, sql) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        Sqlite3.fetch_all(db, statement)
      after
        Sqlite3.release(db, statement)
      end
    end
  end

  defp execute(config, adapter, options, opts) do
    with {:ok, authority} <- read_authority(config, opts),
         :ok <- expected(authority, options),
         :ok <- resource_scope(config, options[:resource]),
         :ok <- selected_owner(authority, options),
         {:ok, resources} <- Operations.run(adapter, config, nil, :discover, opts),
         :ok <- inventory(config, resources),
         {:ok, selected} <- select(resources, options, authority) do
      case options[:action] do
        "inspect" -> result("inspect", authority, selected)
        "reseed-stop" -> reseed_stop(config, adapter, resources, authority, options, opts)
        "reseed-commit" -> reseed_commit(config, adapter, resources, authority, options, opts)
        "checkpoint" -> checkpoint(config, adapter, resources, authority, options, opts)
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :provider_unconfirmed}
    end
  end

  defp selected_owner(snapshot, options) do
    if options[:action] == "inspect" do
      :ok
    else
      record = snapshot.record
      owner = record["owner"] || get_in(record, ["last_handoff", "owner"])
      if is_map(owner) and owner["workstation_name"] != options[:resource], do: {:error, :resource_mismatch}, else: :ok
    end
  end

  # Only a current metadata 404 is absence. Existing content is always read and
  # validated by the generation-pinned store, never by an alternate record parser.
  defp read_authority(config, opts) do
    refs = config.codex_credentials
    url = "https://storage.googleapis.com/storage/v1/b/" <> encode(refs["control_bucket"]) <> "/o/" <> encode(refs["control_object"])
    case GoogleClient.request(config, :get, url, [], nil, opts) do
      {:ok, 404, _, _} -> {:ok, nil}
      {:ok, 200, _, _} -> ControlStore.read(config, opts)
      _ -> {:error, :authority_unconfirmed}
    end
  end

  defp expected(_snapshot, options) when not is_list(options), do: {:error, :invalid_arguments}
  defp expected(snapshot, options) do
    if options[:action] == "inspect" do
      :ok
    else
      case snapshot do
        %{generation: generation, record: record} ->
          if generation == options[:expected_generation] and record["epoch"] == options[:expected_epoch], do: :ok, else: {:error, :authority_changed}
        _ -> {:error, :authority_required}
      end
    end
  end

  defp inventory(config, records) when is_list(records) do
    names = Enum.map(records, &Credentials.resource_name(config, &1))
    if length(names) == length(Enum.uniq(names)) and Enum.all?(records, &valid_resource?(config, &1)), do: :ok, else: {:error, :inventory_unaccounted}
  end
  defp inventory(_, _), do: {:error, :inventory_unaccounted}

  defp valid_resource?(config, record) do
    assigned = Credentials.assignment(record)
    valid_assignment?(assigned) and assigned["credential_id"] == config.codex_credentials["credential_id"] and
      String.starts_with?(assigned["secret_version"], config.codex_credentials["secret"] <> "/versions/") and
      assigned["owner"]["deployment_id"] == config.deployment_id and assigned["owner"]["lane"] == "features" and
      record.provider_ref == %{name: assigned["owner"]["workstation_name"], uid: assigned["owner"]["workstation_uid"]} and
      record.deployment_id == config.deployment_id and record.scope == Config.scope(config) and
      record.phase in [:running, :stopped, :stopping, :preparing] and
      (Credentials.data(record)["stage"] != "committed" or not is_nil(Credentials.disposition(record))) and
      Enum.all?(record.pending, &(&1.outcome in [:succeeded, :failed]))
  end

  defp valid_assignment?(assigned) when is_map(assigned) do
    MapSet.new(Map.keys(assigned)) == MapSet.new(@assignment_keys) and
      Record.validate(Map.merge(Record.initial(assigned["credential_id"], assigned["epoch"], assigned["secret_version"]),
        %{"state" => "OWNED", "claim_id" => assigned["claim_id"], "owner" => assigned["owner"], "transition_id" => "resource-evidence"})) == :ok and
      is_binary(assigned["owner"]["workstation_uid"])
  rescue
    _ -> false
  end
  defp valid_assignment?(_), do: false

  defp resource_scope(_config, nil), do: :ok
  defp resource_scope(config, name) do
    prefix = "projects/#{config.provider["project"]}/locations/#{config.provider["location"]}/workstationClusters/#{config.provider["cluster"]}/workstationConfigs/"
    suffix = String.replace_prefix(name, prefix, "")
    if String.starts_with?(name, prefix) and Regex.match?(~r/\A[A-Za-z0-9._~-]+\/workstations\/[A-Za-z0-9._~-]+\z/, suffix),
      do: :ok, else: {:error, :resource_mismatch}
  end

  defp select(resources, options, authority) do
    case options[:resource] do
      nil -> {:ok, resources}
      name ->
        case Enum.filter(resources, &(&1.provider_ref.name == name)) do
          [record] -> {:ok, [record]}
          [] -> if resources == [] and unbound_snapshot?(authority) and options[:action] in ["inspect", "reseed-stop", "reseed-commit"], do: {:ok, []}, else: {:error, :resource_mismatch}
          _ -> {:error, :resource_mismatch}
        end
    end
  end

  defp unbound_available?(%{record: %{"state" => "AVAILABLE", "last_handoff" => nil}}), do: true
  defp unbound_available?(_), do: false
  defp unbound_snapshot?(%{record: record}), do: unbound_authority?(record)
  defp unbound_snapshot?(_), do: false

  defp reseed_stop(config, adapter, resources, authority, options, opts) do
    with :ok <- accounted(resources, authority.record),
         {:ok, stopped} <- stop_all(config, adapter, resources, opts),
         {:ok, current} <- read_authority(config, opts),
         :ok <- unchanged(authority, current),
         :ok <- expected(current, options) do
      result("reseed-stop", current, stopped)
    end
  end

  defp accounted(resources, authority) do
    active = if authority["state"] == "AVAILABLE", do: authority["last_handoff"], else: authority
    known = Enum.all?(resources, fn record ->
      assigned = Credentials.assignment(record)
      matching = is_map(active) and active["claim_id"] == assigned["claim_id"] and active["owner"] == assigned["owner"]
      matching = matching and
        if authority["state"] == "AVAILABLE" do
          assigned["epoch"] in [authority["epoch"], authority["epoch"] - 1]
        else
          Record.assignment(authority) == {:ok, assigned}
        end
      historical = Credentials.resolved?(record) and inactive?(authority, assigned) and disposition_epoch(record) <= authority["epoch"]
      matching or historical
    end)
    bound = is_map(active) and is_binary(active["owner"]["workstation_uid"])
    present = not bound or Enum.any?(resources, &(Credentials.assignment(&1)["owner"] == active["owner"]))
    if known and present and (bound or unbound_authority?(authority)), do: :ok, else: {:error, :inventory_unaccounted}
  end

  defp unbound_authority?(%{"state" => "AVAILABLE", "last_handoff" => nil}), do: true
  defp unbound_authority?(%{"state" => state, "owner" => %{"workstation_uid" => nil}}) when state in ["OWNED", "RECOVERY_REQUIRED"], do: true
  defp unbound_authority?(_), do: false
  defp inactive?(authority, assigned), do: not is_map(authority["owner"]) or authority["owner"]["workstation_name"] != assigned["owner"]["workstation_name"]
  defp disposition_epoch(record), do: Credentials.data(record)["disposition"]["resolved_epoch"] || Credentials.data(record)["disposition"]["epoch"]

  defp stop_all(config, adapter, resources, opts) do
    Enum.reduce_while(resources, {:ok, []}, fn record, {:ok, stopped} ->
      case stop(config, adapter, record, opts) do
        {:ok, current} -> {:cont, {:ok, stopped ++ [current]}}
        _ -> {:halt, {:error, :physical_stop_unconfirmed}}
      end
    end)
  end

  defp stop(config, adapter, record, opts) do
    with {:ok, current} <- operation(config, adapter, record, :inspect, opts) do
      observed = if stop_proof(current), do: {:ok, current}, else: operation(config, adapter, current, :credential_safety_stop, opts)
      with {:ok, stopped} <- observed,
           true <- valid_resource?(config, stopped) and not is_nil(stop_proof(stopped)) do
        {:ok, stopped}
      else
        _ -> {:error, :physical_stop_unconfirmed}
      end
    end
  end

  defp checkpoint(config, adapter, resources, authority, options, opts) do
    record = Enum.find(resources, &(&1.provider_ref.name == options[:resource]))
    with {:ok, receipt} <- read_receipt(options[:receipt_file], options[:data_root]),
         :ok <- receipt_matches(receipt, record, authority.record),
         :ok <- accounted(resources, authority.record),
         {:ok, _} <- GoogleClient.version_metadata(config, receipt["secret_version"], opts),
         {:ok, stopped} <- checkpoint_provenance(config, adapter, record, authority.record, receipt, opts),
         {:ok, current} <- read_authority(config, opts),
         :ok <- unchanged(authority, current),
         {:ok, committed} <- commit_checkpoint(config, current, receipt, stop_proof(stopped), opts),
         {:ok, resolved} <- persist_handoff(config, adapter, stopped, committed, opts),
         {:ok, final} <- read_authority(config, opts) do
      result("checkpoint", final, replace_resource(resources, resolved))
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :checkpoint_unconfirmed}
    end
  end

  defp receipt_matches(receipt, record, authority) do
    assigned = Credentials.assignment(record)
    source = Map.merge(authority, %{"state" => "OWNED", "claim_id" => assigned["claim_id"], "owner" => assigned["owner"], "epoch" => assigned["epoch"], "head_version" => assigned["secret_version"], "candidate" => nil, "stop_proof" => nil, "last_handoff" => nil, "reason" => nil, "transition_id" => "receipt-validation"})
    active = if authority["state"] == "AVAILABLE", do: authority["last_handoff"], else: authority
    with true <- authority["epoch"] == assigned["epoch"] and is_map(active) and active["claim_id"] == assigned["claim_id"] and active["owner"] == assigned["owner"],
         {:ok, _} <- Record.transition(source, {:checkpoint, receipt}, "receipt-validation") do
      :ok
    else
      _ -> {:error, :receipt_mismatch}
    end
  end

  defp checkpoint_provenance(config, adapter, record, authority, receipt, opts) do
    cond do
      is_map(authority["candidate"]) ->
        if authority["candidate"] == receipt, do: stop(config, adapter, record, opts), else: {:error, :receipt_mismatch}
      authority["state"] == "AVAILABLE" ->
        if authority["head_version"] == receipt["secret_version"], do: stop(config, adapter, record, opts), else: {:error, :receipt_mismatch}
      true -> worker_checkpoint(config, adapter, record, receipt, opts)
    end
  end

  defp worker_checkpoint(config, adapter, record, receipt, opts) do
    entry = entry(record)
    case Operations.run(adapter, config, entry, :prepare, opts) do
      {:ok, context} ->
        evidence = Operations.checkpoint_receipt(context, opts)
        stopped = Operations.run(adapter, config, %{entry | record: context.environment.record, context: context}, :credential_safety_stop, opts)
        with {:ok, ^receipt} <- evidence,
             {:ok, current} <- stopped,
             true <- valid_resource?(config, current) and not is_nil(stop_proof(current)) do
          {:ok, current}
        else
          _ -> {:error, :checkpoint_unconfirmed}
        end
      {:error, _, current} ->
        operation(config, adapter, current, :credential_safety_stop, opts)
        {:error, :checkpoint_unconfirmed}
      _ -> {:error, :checkpoint_unconfirmed}
    end
  end

  defp commit_checkpoint(_config, %{record: %{"state" => "AVAILABLE"}} = snapshot, _receipt, _proof, _opts), do: {:ok, snapshot}
  defp commit_checkpoint(config, snapshot, receipt, proof, opts) do
    source = Map.merge(snapshot.record, %{"state" => "OWNED", "candidate" => nil, "stop_proof" => nil, "reason" => nil})
    transition = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    with {:ok, checkpointed} <- Record.transition(source, {:checkpoint, receipt}, transition),
         {:ok, stopped} <- Record.transition(checkpointed, {:stopped, source["claim_id"], proof}, transition),
         {:ok, released} <- Record.transition(stopped, {:release, source["claim_id"]}, transition) do
      ControlStore.replace(config, snapshot, released, opts)
    end
  end

  defp reseed_commit(config, adapter, resources, authority, _options, opts) do
    handoff = authority.record["last_handoff"]
    cond do
      unbound_available?(authority) and resources == [] -> result("reseed-commit", authority, [])
      authority.record["state"] != "AVAILABLE" or not is_map(handoff) -> {:error, :handoff_mismatch}
      true ->
        record = Enum.find(resources, &(Credentials.assignment(&1)["owner"] == handoff["owner"]))
        with true <- not is_nil(record) and authority.record["epoch"] == Credentials.assignment(record)["epoch"] + 1,
             :ok <- accounted(resources, authority.record),
             {:ok, stopped} <- observe_stopped(config, adapter, resources, opts),
             current = Enum.find(stopped, &(&1.key == record.key)),
             true <- stop_proof(current) == handoff["stop_proof"],
             {:ok, fresh} <- read_authority(config, opts),
             :ok <- unchanged(authority, fresh),
             {:ok, resolved} <- persist_handoff(config, adapter, current, fresh, opts),
             {:ok, final} <- read_authority(config, opts) do
          result("reseed-commit", final, replace_resource(stopped, resolved))
        else
          _ -> {:error, :handoff_unconfirmed}
        end
    end
  end

  defp observe_stopped(config, adapter, resources, opts) do
    Enum.reduce_while(resources, {:ok, []}, fn record, {:ok, acc} ->
      with {:ok, current} <- operation(config, adapter, record, :inspect, opts),
           true <- valid_resource?(config, current) and not is_nil(stop_proof(current)) do
        {:cont, {:ok, acc ++ [current]}}
      else
        _ -> {:halt, {:error, :physical_stop_unconfirmed}}
      end
    end)
  end

  defp persist_handoff(config, adapter, record, authority, opts) do
    with true <- authority.record["last_handoff"]["stop_proof"] == stop_proof(record),
         {:ok, current} <- Operations.reconcile_credentials(adapter, config, record, opts),
         true <- Credentials.resolved?(current) do
      {:ok, current}
    else
      _ -> {:error, :disposition_unconfirmed}
    end
  end

  defp operation(config, adapter, record, action, opts), do: Operations.run(adapter, config, entry(record), action, opts)
  defp entry(record), do: Lifecycle.new(record, Credentials.assignment(record)["owner"]["attempt_id"], :cleanup)
  defp replace_resource(resources, record), do: Enum.map(resources, fn previous -> if previous.key == record.key, do: record, else: previous end)
  defp unchanged(snapshot, snapshot), do: :ok
  defp unchanged(_, _), do: {:error, :authority_changed}

  defp stop_proof(%{phase: :stopped, proof: {:quiescent, %{uid: uid, operation: operation}}} = record) do
    assigned = Credentials.assignment(record)
    owner = assigned["owner"]
    proof = %{"uid" => uid, "operation" => operation, "attempt_id" => owner["attempt_id"]}
    head = assigned["secret_version"]
    authority = Record.initial(assigned["credential_id"], assigned["epoch"], head)
      |> Map.merge(%{"transition_id" => "stop-validation", "last_handoff" => %{"claim_id" => assigned["claim_id"], "owner" => owner, "secret_version" => head, "stop_proof" => proof, "resource_acknowledged" => false}})
    if Record.validate(authority) == :ok and Enum.all?(record.pending, &(&1.outcome in [:succeeded, :failed])), do: proof, else: nil
  end
  defp stop_proof(_), do: nil

  defp result(action, authority, resources) do
    rows = Enum.map(resources, fn record ->
      %{name: record.provider_ref.name, uid: record.provider_ref.uid, assignment: Credentials.assignment(record), phase: Atom.to_string(record.phase),
        pending: Enum.map(record.pending, &%{name: &1.id, verb: Atom.to_string(&1.verb), outcome: Atom.to_string(&1.outcome)}),
        stop_proof: stop_proof(record), disposition: Credentials.disposition(record)}
    end)
    value = %{action: action, authority: authority, resources: rows, admission: "maintenance"}
    if byte_size(Jason.encode!(%{ok: true, result: value})) < @max_output, do: {:ok, value}, else: {:error, :output_limit}
  end

  defp read_receipt(path, root) do
    expanded = Path.expand(path)
    with {:ok, ^expanded} <- PathSafety.canonicalize(expanded),
         {:ok, %{uid: uid}} <- File.stat(root),
         {:ok, parent} <- File.lstat(Path.dirname(expanded)),
         true <- parent.type == :directory and parent.uid == uid and band(parent.mode, 0o777) == 0o700,
         {:ok, before} <- File.lstat(expanded),
         true <- before.type == :regular and before.links == 1 and before.uid == uid and band(before.mode, 0o777) == 0o600 and before.size <= 16_384,
         {:ok, file} <- :file.open(String.to_charlist(expanded), [:read, :binary, :raw]) do
      try do
        with {:ok, descriptor} <- :file.read_file_info(file, time: :universal),
             true <- same_file?(File.Stat.from_record(descriptor), before),
             {:ok, bytes} <- :file.read(file, 16_385),
             true <- byte_size(bytes) == before.size,
             {:ok, after_read} <- File.lstat(expanded),
             true <- same_file?(after_read, before),
             {:ok, receipt} when is_map(receipt) <- Jason.decode(bytes) do
          {:ok, receipt}
        else
          _ -> {:error, :receipt_invalid}
        end
      after
        :file.close(file)
      end
    else
      _ -> {:error, :receipt_invalid}
    end
  end

  defp same_file?(left, right), do: Map.drop(Map.from_struct(left), [:atime]) == Map.drop(Map.from_struct(right), [:atime])

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp decimal?(value), do: is_binary(value) and Regex.match?(~r/\A[1-9][0-9]*\z/, value)
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
