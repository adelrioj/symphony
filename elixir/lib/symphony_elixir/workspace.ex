# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, ExecutionContext, PathSafety, SSH}
  alias SymphonyElixir.Config.Schema

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @type hook_result :: :ok | {:error, {:managed_execution_unknown, term()}}
  @type hook_observer :: (%{event: :hook, timestamp: DateTime.t(), payload: String.t()} -> term()) | nil

  @doc false
  @spec location_inventory(Schema.t()) :: :empty | :retained | {:error, term()}
  def location_inventory(%Schema{} = settings) do
    worker = settings.worker

    case worker.ssh_hosts do
      [] -> local_inventory(settings.workspace.root)
      hosts -> remote_inventories(hosts, settings.workspace.root)
    end
  end

  @doc false
  @spec remote_effective_root([String.t()], Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def remote_effective_root(hosts, base, subdir) when is_list(hosts) and is_binary(base) and is_binary(subdir) do
    effective = Path.join(base, subdir)

    hosts
    |> Enum.reduce_while([], fn host, roots ->
      case remote_canonical_paths(host, base, effective) do
        {:ok, canonical_base, canonical_effective} ->
          base_parts = Path.split(canonical_base)
          effective_parts = Path.split(canonical_effective)

          if Enum.take(effective_parts, length(base_parts)) == base_parts do
            {:cont, [canonical_effective | roots]}
          else
            {:halt, {:error, :remote_workspace_outside_base}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      [root | roots] -> if(Enum.all?(roots, &(&1 == root)), do: {:ok, root}, else: {:error, :remote_workspace_roots_differ})
      {:error, reason} -> {:error, reason}
      [] -> {:error, :missing_ssh_host}
    end
  end

  defp local_inventory(root) do
    case PathSafety.canonicalize(root) do
      {:ok, canonical_root} ->
        case File.ls(canonical_root) do
          {:ok, []} -> :empty
          {:ok, _entries} -> :retained
          {:error, :enoent} -> :empty
          {:error, reason} -> {:error, {:workspace_inventory_unverifiable, :local, reason}}
        end

      {:error, reason} ->
        {:error, {:workspace_inventory_unverifiable, :local, reason}}
    end
  end

  defp remote_inventories(hosts, root) do
    Enum.reduce_while(hosts, :empty, fn host, _acc ->
      case remote_inventory(host, root) do
        :empty -> {:cont, :empty}
        result -> {:halt, result}
      end
    end)
  end

  defp remote_inventory(host, root) do
    command =
      [
        remote_shell_assign("workspace_root", root),
        "if [ -d \"$workspace_root\" ]; then find \"$workspace_root\" -mindepth 1 -maxdepth 1 -print -quit; exit $?; fi",
        "if [ -e \"$workspace_root\" ] || [ -L \"$workspace_root\" ]; then exit 1; fi",
        "ancestor=$workspace_root",
        "while [ ! -e \"$ancestor\" ] && [ ! -L \"$ancestor\" ] && [ \"$ancestor\" != / ]; do ancestor=${ancestor%/*}; [ -n \"$ancestor\" ] || ancestor=/; done",
        "[ -d \"$ancestor\" ] && [ -x \"$ancestor\" ]"
      ]
      |> Enum.join("\n")

    task = Task.async(fn -> SSH.run(host, command, stderr_to_stdout: true) end)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, 0}}} -> if(String.trim(output) == "", do: :empty, else: :retained)
      {:ok, {:ok, {output, status}}} -> {:error, {:workspace_inventory_unverifiable, host, status, output}}
      {:ok, {:error, reason}} -> {:error, {:workspace_inventory_unverifiable, host, reason}}
      {:exit, reason} -> {:error, {:workspace_inventory_unverifiable, host, reason}}
      nil -> {:error, {:workspace_inventory_unverifiable, host, :timeout}}
    end
  end

  defp remote_canonical_paths(host, base, effective) do
    command =
      [
        "set -eu",
        remote_shell_assign("workspace_root", base),
        remote_shell_assign("workspace", effective),
        "printf '%s\\t%s\\n' \"$(realpath -m -- \"$workspace_root\")\" \"$(realpath -m -- \"$workspace\")\""
      ]
      |> Enum.join("\n")

    task = Task.async(fn -> SSH.run(host, command, stderr_to_stdout: true) end)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, 0}}} ->
        case String.split(String.trim(output), "\t", parts: 2) do
          [canonical_base, canonical_effective]
          when canonical_base != "" and canonical_effective != "" ->
            {:ok, canonical_base, canonical_effective}

          _ ->
            {:error, {:remote_path_canonicalize_failed, host}}
        end

      {:ok, {:ok, {output, status}}} ->
        {:error, {:remote_path_canonicalize_failed, host, status, output}}

      {:ok, {:error, reason}} ->
        {:error, {:remote_path_canonicalize_failed, host, reason}}

      nil ->
        {:error, {:remote_path_canonicalize_failed, host, :timeout}}
    end
  end

  @spec create_for_issue(map() | String.t() | nil, ExecutionContext.t(), hook_observer()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, %ExecutionContext{} = worker_host, on_hook \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = workspace_key(issue_or_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host) do
        case maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, on_hook) do
          :ok ->
            {:ok, workspace}

          {:error, {:managed_execution_unknown, _detail}} = error ->
            error

          {:error, _reason} = error ->
            case cleanup_failed_new_workspace(workspace, created?, worker_host) do
              {:error, {:managed_execution_unknown, _detail}} = unknown -> unknown
              _ -> error
            end
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, %ExecutionContext{mode: :local}) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, %ExecutionContext{} = worker_host) do
    script =
      [
        "set -eu",
        remote_workspace_guard(workspace, worker_host),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        case parse_remote_workspace_output(output) do
          {:ok, _canonical_path, created?} when worker_host.mode == :managed -> {:ok, workspace, created?}
          result -> result
        end

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host.worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t(), ExecutionContext.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, %ExecutionContext{mode: :local} = context) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, context) do
          :ok ->
            remove_local_workspace(workspace, context)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, %ExecutionContext{} = worker_host) do
    case run_before_remove_hook(workspace, Path.basename(workspace), worker_host) do
      :ok -> remove_remote_workspace(workspace, worker_host)
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp remove_remote_workspace(workspace, worker_host) do
    script =
      [
        remote_workspace_guard(workspace, worker_host),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms, :workspace_remove) do
      {:ok, {_output, 0}} -> {:ok, []}
      {:ok, {output, status}} -> {:error, {:workspace_remove_failed, worker_host.worker_host, status, output}, ""}
      {:error, reason} -> {:error, reason, ""}
    end
  end

  @doc false
  @spec remove_recorded(Path.t(), ExecutionContext.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, %ExecutionContext{mode: :local} = context) when is_binary(workspace) do
    if Path.type(workspace) == :absolute do
      case validate_workspace_path(workspace, context) do
        :ok ->
          remove_local_workspace(workspace, context)

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}
    end
  end

  def remove_recorded(workspace, %ExecutionContext{} = context) when is_binary(workspace) do
    remove(workspace, context)
  end

  def remove_recorded(workspace, _worker_host) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}
  end

  defp remove_local_workspace(workspace, context) do
    run_before_remove_hook(workspace, Path.basename(workspace), context)
    File.rm_rf(workspace)
  end

  @spec remove_issue_workspaces(term(), ExecutionContext.t()) :: :ok | {:error, {:managed_execution_unknown, term()}}
  def remove_issue_workspaces(issue_or_identifier, %ExecutionContext{} = context) when is_map(issue_or_identifier) or is_binary(issue_or_identifier) do
    case workspace_path_for_issue(workspace_key(issue_or_identifier), context) do
      {:ok, workspace} ->
        case remove(workspace, context) do
          {:error, {:managed_execution_unknown, _detail} = reason, _path} -> {:error, reason}
          _ -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  def remove_issue_workspaces(_issue_or_identifier, %ExecutionContext{}), do: :ok

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, ExecutionContext.t(), hook_observer()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, %ExecutionContext{} = worker_host, on_hook \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host, on_hook)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, ExecutionContext.t(), hook_observer()) :: hook_result()
  def run_after_run_hook(workspace, issue_or_identifier, %ExecutionContext{} = worker_host, on_hook \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host, on_hook)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(_safe_id, %ExecutionContext{mode: :managed, workspace_path: path}) when is_binary(path), do: {:ok, path}

  defp workspace_path_for_issue(safe_id, %ExecutionContext{mode: :local, workspace_root: root}) when is_binary(safe_id) do
    root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, %ExecutionContext{mode: :ssh, workspace_root: root}) when is_binary(safe_id) do
    {:ok, Path.join(root, safe_id)}
  end

  defp workspace_path_for_issue(_safe_id, _context), do: {:error, :invalid_workspace_context}

  @doc """
  Returns the collision-safe directory name for an issue identifier.

  The hash is derived from the original identifier so callers that only know the identifier can
  derive the same key as callers holding a full tracker issue.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = safe_identifier(identifier)

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp safe_identifier(identifier) when is_binary(identifier),
    do: String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, on_hook) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host, on_hook)
        end

      false ->
        :ok
    end
  end

  defp cleanup_failed_new_workspace(_workspace, false, _worker_host), do: :ok

  defp cleanup_failed_new_workspace(workspace, true, %ExecutionContext{mode: :local}) do
    case File.rm_rf(workspace) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Failed to remove partial workspace path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp cleanup_failed_new_workspace(workspace, true, %ExecutionContext{} = worker_host) do
    script = [remote_workspace_guard(workspace, worker_host), "rm -rf \"$workspace\""] |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms, :workspace_cleanup) do
      {:ok, {_output, 0}} ->
        :ok

      {:error, {:managed_execution_unknown, _detail}} = unknown ->
        unknown

      result ->
        Logger.warning("Failed to remove partial workspace worker_host=#{worker_host_for_log(worker_host)} result=#{inspect(result)}")
    end
  end

  @spec run_before_remove_hook(Path.t(), map() | String.t() | nil, ExecutionContext.t()) :: hook_result()
  def run_before_remove_hook(workspace, issue, %ExecutionContext{} = context) do
    case Config.settings!().hooks.before_remove do
      nil ->
        :ok

      command ->
        if ExecutionContext.remote?(context) or File.dir?(workspace) do
          run_hook(command, workspace, issue_context(issue), "before_remove", context, nil)
          |> ignore_hook_failure()
        else
          :ok
        end
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, {:managed_execution_unknown, _detail}} = unknown), do: unknown
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, context, nil) do
    execute_hook(command, workspace, issue_context, hook_name, context, nil)
  end

  defp run_hook(command, workspace, issue_context, hook_name, context, on_hook) do
    on_hook = isolate_hook_observer(on_hook, hook_name, issue_context)
    notify_hook(on_hook, hook_name, "started")

    result = execute_hook(command, workspace, issue_context, hook_name, context, on_hook)

    case result do
      :ok -> notify_hook(on_hook, hook_name, "finished")
      {:error, reason} -> notify_hook(on_hook, hook_name, "failed: #{inspect(reason)}")
    end

    result
  catch
    kind, reason ->
      notify_hook(on_hook, hook_name, "failed: #{Exception.format_banner(kind, reason)}")
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp notify_hook(on_hook, hook_name, outcome) do
    on_hook.(%{event: :hook, timestamp: DateTime.utc_now(), payload: "#{hook_name} #{outcome}"})
  end

  defp isolate_hook_observer(on_hook, hook_name, issue_context) do
    fn event ->
      try do
        on_hook.(event)
      catch
        kind, reason ->
          Logger.warning("Hook observer failed hook=#{hook_name} #{issue_log_context(issue_context)} reason=#{Exception.format_banner(kind, reason)}")
          :ok
      end
    end
  end

  # Command tasks are linked: report exceptions here before their exit can kill the caller.
  defp execute_hook_task(command, nil, _hook_name), do: command.()

  defp execute_hook_task(command, on_hook, hook_name) do
    command.()
  catch
    kind, reason ->
      notify_hook(on_hook, hook_name, "failed: #{Exception.format_banner(kind, reason)}")
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp execute_hook(command, workspace, issue_context, hook_name, %ExecutionContext{mode: :local} = context, on_hook) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    with :ok <- validate_workspace_path(workspace, context) do
      run_command = fn -> System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true) end
      task = Task.async(fn -> execute_hook_task(run_command, on_hook, hook_name) end)

      case Task.yield(task, timeout_ms) do
        {:ok, cmd_result} ->
          handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

        nil ->
          Task.shutdown(task, :brutal_kill)
          Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")
          {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
      end
    end
  end

  defp execute_hook(command, workspace, issue_context, hook_name, %ExecutionContext{} = worker_host, on_hook) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")

    script = remote_workspace_guard(workspace, worker_host) <> "\ncd \"$workspace\"\n" <> command

    case run_remote_command(worker_host, script, timeout_ms, hook_name, on_hook) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  @spec validate_workspace_path(Path.t(), ExecutionContext.t()) :: :ok | {:error, term()}
  def validate_workspace_path(workspace, %ExecutionContext{mode: :local, workspace_root: root, workspace_base: base}) when is_binary(workspace) do
    validate_local_workspace_path(workspace, root, base || root)
  end

  def validate_workspace_path(workspace, %ExecutionContext{} = context) when is_binary(workspace) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      invalid_remote_path?(workspace) or invalid_remote_path?(context.workspace_root) or
          invalid_remote_path?(context.workspace_base || context.workspace_root) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        validate_managed_workspace_path(workspace, context)
    end
  end

  defp validate_managed_workspace_path(workspace, %ExecutionContext{mode: :managed} = context) do
    if workspace == context.workspace_path do
      script = remote_workspace_guard(workspace, context)
      timeout_ms = Config.settings!().hooks.timeout_ms

      case run_remote_command(context, script, timeout_ms) do
        {:ok, {_output, 0}} -> :ok
        {:ok, {output, status}} -> {:error, {:workspace_path_unreadable, workspace, {status, output}}}
        {:error, _reason} = error -> error
      end
    else
      {:error, {:workspace_path_unreadable, workspace, :identity_mismatch}}
    end
  end

  defp validate_managed_workspace_path(_workspace, _context), do: :ok

  defp invalid_remote_path?(path) when is_binary(path), do: String.match?(path, ~r/[\x00-\x1f\x7f]/)
  defp invalid_remote_path?(_path), do: true

  defp remote_workspace_guard(workspace, %ExecutionContext{} = context) do
    base = context.workspace_base || context.workspace_root

    invalid_path? =
      invalid_remote_path?(workspace) or invalid_remote_path?(context.workspace_root) or
        invalid_remote_path?(base)

    identity_mismatch? = context.mode == :managed and workspace != context.workspace_path

    if invalid_path? or identity_mismatch? do
      "exit 64"
    else
      [
        "set -eu",
        remote_shell_assign("workspace_base", base),
        remote_shell_assign("workspace_root", context.workspace_root),
        remote_shell_assign("workspace", workspace),
        "base_real=$(realpath -m -- \"$workspace_base\")",
        "root_real=$(realpath -m -- \"$workspace_root\")",
        "workspace_real=$(realpath -m -- \"$workspace\")",
        "case \"$root_real\" in",
        "  \"$base_real\"|\"$base_real\"/*) ;;",
        "  *) exit 64 ;;",
        "esac",
        "case \"$workspace_real\" in",
        "  \"$root_real\"/*) test \"$workspace_real\" != \"$root_real\" ;;",
        "  *) exit 64 ;;",
        "esac"
      ]
      |> Enum.join("\n")
    end
  end

  defp validate_local_workspace_path(workspace, workspace_root, workspace_base)
       when is_binary(workspace) and is_binary(workspace_root) and is_binary(workspace_base) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_base = Path.expand(workspace_base)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root),
         {:ok, canonical_base} <- PathSafety.canonicalize(expanded_base),
         {:ok, root_contained?} <- PathSafety.contained?(canonical_root, canonical_base) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        not root_contained? ->
          {:error, {:workspace_root_outside_base, canonical_root, canonical_base}}

        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(%ExecutionContext{target: target} = context, script, timeout_ms, operation \\ :remote_command, on_hook \\ nil)
       when is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        execute_hook_task(fn -> SSH.run(target, script, stderr_to_stdout: true) end, on_hook, operation)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)

        if context.mode == :managed do
          {:error, {:managed_execution_unknown, {:remote_command_timeout, operation, timeout_ms}}}
        else
          {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
        end
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(%ExecutionContext{mode: :local}), do: "local"
  defp worker_host_for_log(%ExecutionContext{worker_host: label}), do: label

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
