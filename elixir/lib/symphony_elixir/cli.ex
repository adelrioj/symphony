defmodule SymphonyElixir.CLI do
  @moduledoc """
  Entrypoint for the installation daemon, lane commands, and standalone Linear MCP.
  """

  alias SymphonyElixir.LogFile
  alias SymphonyElixir.MCP.LinearServer

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @serve_switches [
    {@acknowledgement_switch, :boolean},
    data_root: :string,
    port: :integer,
    host: :string,
    events_retention_days: :integer
  ]
  @import_switches [slug: :string, name: :string, note: :string, data_root: :string]
  @export_switches [data_root: :string]
  @mcp_switches [linear_mcp: :boolean, workflow: :string]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          required(:ensure_all_started) => (-> ensure_started_result()),
          required(:start_repo) => (-> :ok | {:error, term()}),
          required(:import_lane) => (Path.t(), keyword() -> {:ok, SymphonyElixir.Lanes.Lane.t(), [String.t()]} | {:error, [SymphonyElixir.Lanes.error()]}),
          required(:export_lane) => (String.t() -> {:ok, String.t()} | {:error, :not_found | :no_version}),
          required(:operator_token) => (-> String.t() | nil),
          required(:write_output) => (String.t() -> :ok),
          optional(:ensure_linear_mcp_started) => (-> ensure_started_result()),
          optional(:configure_linear_mcp_logger) => (-> :ok),
          optional(:serve_linear_mcp) => (-> :ok)
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    main(args, fn -> Application.ensure_all_started(:symphony_elixir) end)
  end

  @doc false
  @spec main([String.t()], (-> ensure_started_result())) :: no_return()
  def main(args, ensure_all_started) do
    case evaluate_mode(args, runtime_deps(ensure_all_started)) do
      {:ok, :daemon} ->
        wait_for_shutdown()

      {:ok, :linear_mcp} ->
        System.halt(0)

      {:ok, :command} ->
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case evaluate_mode(args, deps) do
      {:ok, _mode} -> :ok
      {:error, _message} = error -> error
    end
  end

  defp evaluate_mode(["serve" | args], deps) do
    with :ok <- evaluate_serve(args, deps), do: {:ok, :daemon}
  end

  defp evaluate_mode(["lanes", "import" | args], deps) do
    with :ok <- evaluate_import(args, deps), do: {:ok, :command}
  end

  defp evaluate_mode(["lanes", "export" | args], deps) do
    with :ok <- evaluate_export(args, deps), do: {:ok, :command}
  end

  defp evaluate_mode(args, deps) do
    with {:ok, opts, []} <- parse(args, @mcp_switches, 0),
         true <- Keyword.get(opts, :linear_mcp, false),
         :ok <- evaluate_linear_mcp(opts, deps) do
      {:ok, :linear_mcp}
    else
      false -> {:error, usage_message()}
      {:error, _message} = error -> error
    end
  end

  defp evaluate_serve(args, deps) do
    with {:ok, opts, []} <- parse(args, @serve_switches, 0),
         :ok <- validate_serve_options(opts),
         :ok <- require_guardrails_acknowledgement(opts),
         {:ok, token} <- require_operator_token(deps),
         {:ok, root} <- prepare_data_root(opts),
         :ok <- create_directory(Path.join(root, "log")) do
      Application.put_env(:symphony_elixir, :data_root, root)
      Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(root))
      Application.put_env(:symphony_elixir, :server_port, Keyword.get(opts, :port, 4000))
      Application.put_env(:symphony_elixir, :server_host, Keyword.get(opts, :host, "127.0.0.1"))
      Application.put_env(:symphony_elixir, :events_retention_days, Keyword.get(opts, :events_retention_days, 30))
      Application.put_env(:symphony_elixir, :operator_token, token)

      case deps.ensure_all_started.() do
        {:ok, _apps} -> :ok
        {:error, reason} -> {:error, "Failed to start Symphony: #{inspect(reason)}"}
      end
    end
  end

  defp evaluate_import(args, deps) do
    with {:ok, opts, [path]} <- parse(args, @import_switches, 1),
         {:ok, slug} <- require_option(opts, :slug),
         :ok <- start_repo(opts, deps) do
      case deps.import_lane.(Path.expand(path), Keyword.take(opts, [:name, :note]) |> Keyword.put(:slug, slug)) do
        {:ok, lane, warnings} ->
          lines = ["imported lane #{lane.slug} version #{lane.current_version_id}" | Enum.map(warnings, &("warning: " <> &1))]
          deps.write_output.(Enum.join(lines, "\n") <> "\n")

        {:error, errors} ->
          {:error, "Invalid lane configuration in #{path}:\n" <> Enum.map_join(errors, "\n", &"  #{&1.path}: #{&1.message}")}
      end
    end
  end

  defp evaluate_export(args, deps) do
    with {:ok, opts, [slug]} <- parse(args, @export_switches, 1),
         :ok <- start_repo(opts, deps) do
      case deps.export_lane.(slug) do
        {:ok, content} -> deps.write_output.(content)
        {:error, :not_found} -> {:error, "no lane with slug #{slug}"}
        {:error, :no_version} -> {:error, "lane #{slug} has no version"}
      end
    end
  end

  defp evaluate_linear_mcp(opts, deps) do
    with {:ok, workflow} <- require_option(opts, :workflow) do
      expanded_workflow = Path.expand(workflow)
      :ok = SymphonyElixir.Workflow.set_workflow_file_path(expanded_workflow)
      :ok = configure_linear_mcp_logger(deps)

      case ensure_linear_mcp_started(deps) do
        {:ok, _apps} ->
          serve = Map.get(deps, :serve_linear_mcp, &serve_linear_mcp/0)
          serve.()

        {:error, reason} ->
          {:error, "Failed to start Symphony linear MCP runtime with workflow #{expanded_workflow}: #{inspect(reason)}"}
      end
    end
  end

  defp parse(args, switches, count) do
    case OptionParser.parse(args, strict: switches) do
      {opts, positional, []} when length(positional) == count ->
        if valid_data_root?(opts) and Enum.all?(positional, &(String.trim(&1) != "")),
          do: {:ok, opts, positional},
          else: {:error, usage_message()}

      _ ->
        {:error, usage_message()}
    end
  end

  defp valid_data_root?(opts) do
    case Keyword.get(opts, :data_root) do
      nil -> true
      root -> String.trim(root) != ""
    end
  end

  defp validate_serve_options(opts) do
    port = Keyword.get(opts, :port, 4000)
    retention = Keyword.get(opts, :events_retention_days, 30)
    host = Keyword.get(opts, :host, "127.0.0.1")

    if port in 0..65_535 and retention > 0 and valid_host?(host) do
      :ok
    else
      {:error, usage_message()}
    end
  end

  defp valid_host?(host), do: match?({:ok, _address}, :inet.parse_strict_address(String.to_charlist(host)))

  defp require_option(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) ->
        if String.trim(value) != "", do: {:ok, value}, else: {:error, "--#{key} is required\n" <> usage_message()}

      _ ->
        {:error, "--#{key} is required\n" <> usage_message()}
    end
  end

  defp require_operator_token(deps) do
    case deps.operator_token.() do
      token when is_binary(token) ->
        if String.trim(token) == "", do: {:error, operator_token_message()}, else: {:ok, token}

      _ ->
        {:error, operator_token_message()}
    end
  end

  defp operator_token_message do
    "SYMPHONY_OPERATOR_TOKEN is not set. The web UI can change lane configuration, so serve refuses to start without an operator token."
  end

  defp prepare_data_root(opts) do
    root = Path.expand(Keyword.get(opts, :data_root, File.cwd!()))
    with :ok <- create_directory(root), do: {:ok, root}
  end

  defp create_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to create Symphony data directory #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp start_repo(opts, deps) do
    with {:ok, root} <- prepare_data_root(opts) do
      Application.put_env(:symphony_elixir, :data_root, root)

      case deps.start_repo.() do
        :ok -> :ok
        {:error, reason} -> {:error, "Failed to open the Symphony database: #{inspect(reason)}"}
      end
    end
  end

  # Offline commands must not boot schedulers or leak SQL/migration logs into exports.
  defp start_repo_standalone do
    :ok = configure_linear_mcp_logger()

    with {:ok, _apps} <- Application.ensure_all_started(:ecto_sqlite3),
         {:ok, _pid} <- start_repo_process() do
      SymphonyElixir.Repo.migrate()
    end
  rescue
    exception -> {:error, exception}
  end

  defp start_repo_process do
    case SymphonyElixir.Repo.start_link() do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  defp export_lane(slug) do
    case SymphonyElixir.Lanes.get_by_slug(slug) do
      nil -> {:error, :not_found}
      lane -> SymphonyElixir.Lanes.export(lane)
    end
  end

  defp usage_message do
    """
    Usage: symphony serve [--data-root <dir>] [--port <port>] [--host <ip>] [--events-retention-days <n>] --i-understand-that-this-will-be-running-without-the-usual-guardrails
           symphony lanes import <WORKFLOW.md> --slug <slug> [--name <name>] [--note <text>] [--data-root <dir>]
           symphony lanes export <slug> [--data-root <dir>]
           symphony --linear-mcp --workflow <path-to-WORKFLOW.md>
    The daemon no longer takes a WORKFLOW.md path: import it as a lane first.
    """
    |> String.trim_trailing()
  end

  defp runtime_deps(ensure_all_started \\ fn -> Application.ensure_all_started(:symphony_elixir) end) do
    %{
      ensure_all_started: ensure_all_started,
      start_repo: &start_repo_standalone/0,
      import_lane: &SymphonyElixir.Lanes.import_file/2,
      export_lane: &export_lane/1,
      operator_token: fn -> System.get_env("SYMPHONY_OPERATOR_TOKEN") end,
      write_output: &IO.write/1,
      ensure_linear_mcp_started: &start_linear_mcp_runtime/0,
      configure_linear_mcp_logger: &configure_linear_mcp_logger/0,
      serve_linear_mcp: &serve_linear_mcp/0
    }
  end

  defp start_linear_mcp_runtime do
    with {:ok, apps} <- Application.ensure_all_started(:req),
         {:ok, _pid} <- SymphonyElixir.LaneStore.start_link(file: SymphonyElixir.Workflow.workflow_file_path()) do
      :ok = SymphonyElixir.LaneContext.put(SymphonyElixir.LaneStore.file_lane_id())
      {:ok, apps}
    end
  end

  defp ensure_linear_mcp_started(deps) do
    deps
    |> Map.get(:ensure_linear_mcp_started, &start_linear_mcp_runtime/0)
    |> then(& &1.())
  end

  defp configure_linear_mcp_logger(deps) do
    deps
    |> Map.get(:configure_linear_mcp_logger, &configure_linear_mcp_logger/0)
    |> then(& &1.())
  end

  defp configure_linear_mcp_logger do
    {:ok, _apps} = Application.ensure_all_started(:logger)

    case :logger.remove_handler(:default) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp serve_linear_mcp do
    serve_linear_mcp_loop(:stdio, :stdio)
  end

  @doc false
  @spec serve_linear_mcp_loop(IO.device(), IO.device()) :: :ok
  def serve_linear_mcp_loop(input, output) do
    case read_linear_mcp_request(input) do
      :eof ->
        :ok

      :skip ->
        serve_linear_mcp_loop(input, output)

      {:ok, request, framing} ->
        request
        |> LinearServer.handle_request()
        |> write_linear_mcp_response(output, framing)

        serve_linear_mcp_loop(input, output)
    end
  end

  defp read_linear_mcp_request(input) do
    case IO.binread(input, :line) do
      :eof ->
        :eof

      {:error, _reason} ->
        :eof

      line ->
        decode_linear_mcp_line(input, line)
    end
  end

  defp decode_linear_mcp_line(input, line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :skip

      content_length = content_length(trimmed) ->
        with :ok <- skip_mcp_headers(input),
             {:ok, body} <- read_mcp_body(input, content_length),
             {:ok, request} <- Jason.decode(body) do
          {:ok, request, :content_length}
        else
          _ -> :skip
        end

      true ->
        case Jason.decode(trimmed) do
          {:ok, request} -> {:ok, request, :line}
          {:error, _reason} -> :skip
        end
    end
  end

  defp content_length(line) do
    with [name, value] <- String.split(line, ":", parts: 2),
         true <- String.downcase(name) == "content-length" do
      parse_content_length(value)
    else
      _ -> nil
    end
  end

  defp parse_content_length(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {length, ""} when length >= 0 -> length
      _ -> nil
    end
  end

  defp skip_mcp_headers(input) do
    case IO.binread(input, :line) do
      line when is_binary(line) ->
        if String.trim(line) == "" do
          :ok
        else
          skip_mcp_headers(input)
        end

      _ ->
        :error
    end
  end

  defp read_mcp_body(_input, 0), do: {:ok, ""}

  defp read_mcp_body(input, byte_count) do
    case IO.binread(input, byte_count) do
      body when is_binary(body) and byte_size(body) == byte_count -> {:ok, body}
      _ -> :error
    end
  end

  defp write_linear_mcp_response(nil, _output, _framing), do: :ok

  defp write_linear_mcp_response(response, output, :content_length) do
    encoded = Jason.encode!(response)
    IO.write(output, ["Content-Length: ", Integer.to_string(byte_size(encoded)), "\r\n\r\n", encoded])
  end

  defp write_linear_mcp_response(response, output, :line) do
    IO.puts(output, Jason.encode!(response))
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
