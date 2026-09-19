defmodule SymphonyElixir.ExecutionEnvironment.Kubernetes.Client do
  @moduledoc "Bounded argv-only Kubernetes JSON access; failed CLI prose is never absence evidence."

  alias SymphonyElixir.ExecutionEnvironment.{Command, Operations}

  @spec request(map(), atom(), String.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(config, method, path, body, opts) do
    opts = deadline(opts)
    provider = Map.get(config, :provider, config)

    with :ok <- credentials(provider),
         true <- remaining(opts) > 0,
         true <- String.starts_with?(path, "/") and not String.contains?(path, ["\n", "\r"]) do
      invoke = &invoke(provider, method, path, &1, opts)

      if body == nil, do: invoke.(nil), else: Command.with_json_file(body, invoke, opts)
    else
      false -> {:error, {:unknown, :kubernetes_deadline_or_path}}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, {:unknown, :kubernetes_command_failed}}
  end

  defp invoke(provider, :post, path, file, opts) do
    timeout = max(1, min(20_000, remaining(opts)))
    command = Keyword.get(opts, :command_fun, &Command.run/3)
    args = ["--kubeconfig", provider["kubeconfig"], "--context", provider["context"], "--path", path, "--file", file, "--timeout-ms", to_string(timeout)]

    case command.(System.find_executable("symphony-kubernetes-create") || "symphony-kubernetes-create", args, Keyword.merge(opts, timeout_ms: remaining(opts), max_output_bytes: 8_388_608)) do
      {:ok, %{output: output, status: status}} -> decode(output, status, :post)
      _ -> {:error, {:unknown, :kubernetes_command_failed}}
    end
  end

  defp invoke(provider, method, path, file, opts) do
    timeout = max(1, min(20_000, remaining(opts)))
    args = ["--kubeconfig", provider["kubeconfig"], "--context", provider["context"], "--request-timeout=#{timeout}ms"]
    command = Keyword.get(opts, :command_fun, &Command.run/3)
    options = Keyword.merge(opts, timeout_ms: remaining(opts), max_output_bytes: 8_388_608)

    with {:ok, suffix} <- arguments(method, path, file),
         {:ok, %{output: output, status: status}} <-
           command.(System.find_executable("kubectl") || "kubectl", args ++ suffix, options) do
      decode(output, status, method)
    else
      {:error, _} -> {:error, {:unknown, :kubernetes_command_failed}}
    end
  end

  @spec list(map(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(config, path, opts), do: pages(config, path, deadline(opts), nil, [], %{}, 0)

  @spec lookup(map(), String.t(), String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def lookup(config, collection, name, opts) do
    with {:ok, items} <- list(config, collection, opts) do
      case Enum.filter(items, &(get_in(&1, ["metadata", "name"]) == name)) do
        [] -> {:ok, nil}
        [item] -> {:ok, item}
        _ -> {:error, {:unknown, :duplicate_kubernetes_identity}}
      end
    end
  end

  @spec watch(map(), String.t(), String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def watch(config, collection, name, version, opts) do
    opts = deadline(opts)
    seconds = min(10, div(remaining(opts) - 1_000, 1_000))

    if seconds > 0 and is_binary(version) and version not in ["", "0"] do
      path = query(collection, %{"watch" => "true", "fieldSelector" => "metadata.name=#{name}", "resourceVersion" => version, "timeoutSeconds" => to_string(seconds)})

      case request(config, :watch, path, nil, opts) do
        {:ok, %{status: 200, body: events}} when is_list(events) -> {:ok, events}
        {:ok, %{status: status}} when status in [401, 403] -> {:error, {:denied, :kubernetes_watch}}
        {:error, _} = error -> error
        _ -> {:error, {:unknown, :kubernetes_watch_history_lost}}
      end
    else
      {:error, {:unknown, :watch_deadline_or_history_missing}}
    end
  end

  @spec private_directory(keyword()) :: {:ok, String.t(), Operations.staged_paths()} | {:error, term()}
  def private_directory(opts) do
    path = Path.join(System.tmp_dir!(), "symphony-kubernetes-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))

    with {:ok, lease} <- Operations.stage_private_paths(opts[:task_supervisor], Keyword.get(opts, :authority, self()), self(), [path]) do
      case Operations.create_staged_directory(lease, path) do
        :ok ->
          {:ok, path, lease}

        {:error, _} = error ->
          Operations.release_staged_paths(lease)
          error
      end
    end
  end

  @spec write_private(String.t(), binary()) :: :ok | {:error, term()}
  def write_private(path, content) do
    with {:ok, file} <- File.open(path, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(path, 0o600), do: IO.binwrite(file, content)
      after
        File.close(file)
      end
    end
  end

  defp credentials(provider) do
    if Enum.all?(["kubeconfig", "context"], &(is_binary(provider[&1]) and String.trim(provider[&1]) != "")) and File.regular?(provider["kubeconfig"]),
      do: :ok,
      else: {:error, {:invalid, :kubernetes_credentials}}
  end

  defp arguments(:get, path, _file), do: {:ok, ["get", "--raw", path]}
  defp arguments(:watch, path, _file), do: {:ok, ["get", "--raw", path]}
  defp arguments(:delete, path, file), do: {:ok, ["delete", "--raw", path, "-f", file]}

  defp arguments(:patch, path, file) do
    case String.split(path, "/", trim: true) do
      ["api", "v1", "namespaces", ns, resource, name] ->
        patch_arguments(resource, name, ns, file)

      ["apis", group, _version, "namespaces", ns, resource, name] ->
        patch_arguments(resource <> "." <> group, name, ns, file)

      # A status subresource is a separate write with separate RBAC, which is the whole point of
      # splitting it out: the adapter records an outcome without touching what it was given.
      ["apis", group, _version, "namespaces", ns, resource, name, "status"] ->
        patch_arguments(resource <> "." <> group, name, ns, file, ["--subresource=status"])

      _ ->
        {:error, {:invalid, :kubernetes_patch_path}}
    end
  end

  defp arguments(_, _, _), do: {:error, {:invalid, :kubernetes_method}}

  defp patch_arguments(resource, name, namespace, file, extra \\ []),
    do: {:ok, ["patch", resource, name, "--namespace", namespace, "--type=json", "--patch-file", file, "-o", "json"] ++ extra}

  defp decode(output, 0, :watch) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, events} ->
      case Jason.decode(line) do
        {:ok, %{"type" => type} = event} when type in ["ADDED", "MODIFIED", "DELETED", "BOOKMARK"] -> {:cont, {:ok, [event | events]}}
        _ -> {:halt, {:error, {:unknown, :kubernetes_watch_history_lost}}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, %{status: 200, body: Enum.reverse(events)}}
      error -> error
    end
  end

  defp decode(output, status, _method) do
    case Jason.decode(output) do
      {:ok, %{"kind" => "Status", "code" => code} = body} when is_integer(code) -> {:ok, %{status: code, body: body}}
      {:ok, body} when is_map(body) and status == 0 -> {:ok, %{status: 200, body: body}}
      _ -> {:error, {:unknown, :kubernetes_unstructured_response}}
    end
  end

  defp pages(config, path, opts, token, acc, seen, restarts) do
    params = page_params(token)

    case request(config, :get, query(path, params), nil, opts) do
      {:ok, %{status: 200, body: %{"items" => items, "metadata" => metadata} = body}} when is_list(items) and is_map(metadata) ->
        with {:ok, items} <- typed_items(body, items) do
          continue_page(config, path, opts, items, metadata, acc, seen, restarts)
        end

      {:ok, %{status: 410}} when restarts < 2 ->
        pages(config, path, opts, nil, [], %{}, restarts + 1)

      {:ok, %{status: code}} when code in [401, 403] ->
        {:error, {:denied, :kubernetes_inventory}}

      {:error, _} when token != nil and restarts < 2 ->
        pages(config, path, opts, nil, [], %{}, restarts + 1)

      {:error, _} = error ->
        error

      _ ->
        {:error, {:unknown, :kubernetes_incomplete_inventory}}
    end
  end

  # Typed API lists omit per-item TypeMeta; object consumers still validate it.
  defp typed_items(%{"apiVersion" => version, "kind" => kind}, items) when is_binary(version) and is_binary(kind) do
    item_kind = String.replace_suffix(kind, "List", "")

    valid =
      version != "" and item_kind != "" and item_kind != kind and
        Enum.all?(items, fn item ->
          is_map(item) and Map.get(item, "apiVersion", version) == version and Map.get(item, "kind", item_kind) == item_kind
        end)

    if valid do
      {:ok, Enum.map(items, &(Map.put_new(&1, "apiVersion", version) |> Map.put_new("kind", item_kind)))}
    else
      {:error, {:unknown, :kubernetes_incomplete_inventory}}
    end
  end

  defp typed_items(_body, items), do: {:ok, items}

  defp page_params(nil), do: %{"limit" => "100"}
  defp page_params(token), do: %{"limit" => "100", "continue" => token}

  defp continue_page(config, path, opts, items, metadata, acc, seen, restarts) do
    next = Map.get(metadata, "continue", "")

    cond do
      not Enum.all?(items, &is_map/1) -> {:error, {:unknown, :kubernetes_incomplete_inventory}}
      next == "" -> {:ok, acc |> Enum.reverse() |> List.flatten() |> Kernel.++(items)}
      not is_binary(next) or Map.has_key?(seen, next) -> {:error, {:unknown, :kubernetes_continuation_loop}}
      true -> pages(config, path, opts, next, [items | acc], Map.put(seen, next, true), restarts)
    end
  end

  defp query(path, params) do
    uri = URI.parse(path)
    existing = URI.decode_query(uri.query || "")
    URI.to_string(%{uri | query: URI.encode_query(Map.merge(existing, params))})
  end

  defp deadline(opts), do: Keyword.put_new_lazy(opts, :deadline, fn -> System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 20_000) end)
  defp remaining(opts), do: max(0, opts[:deadline] - System.monotonic_time(:millisecond))
end
