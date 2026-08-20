defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.LogFile
  alias SymphonyElixir.MCP.LinearServer

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [
    {@acknowledgement_switch, :boolean},
    logs_root: :string,
    port: :integer,
    linear_mcp: :boolean,
    workflow: :string
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          required(:file_regular?) => (String.t() -> boolean()),
          required(:set_workflow_file_path) => (String.t() -> :ok | {:error, term()}),
          required(:set_logs_root) => (String.t() -> :ok | {:error, term()}),
          required(:set_server_port_override) => (non_neg_integer() | nil -> :ok | {:error, term()}),
          required(:ensure_all_started) => (-> ensure_started_result()),
          optional(:ensure_linear_mcp_started) => (-> ensure_started_result()),
          optional(:configure_linear_mcp_logger) => (-> :ok),
          optional(:serve_linear_mcp) => (-> :ok),
          optional(:preflight) => (-> :ok | {:error, term()})
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

  @spec evaluate_mode([String.t()], deps()) :: {:ok, :daemon | :linear_mcp} | {:error, String.t()}
  defp evaluate_mode(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, positional, []} ->
        opts
        |> Keyword.get(:linear_mcp, false)
        |> evaluate_parsed_mode(opts, positional, deps)

      _ ->
        {:error, usage_message()}
    end
  end

  defp evaluate_parsed_mode(true, opts, positional, deps) do
    with :ok <- evaluate_linear_mcp(opts, positional, deps), do: {:ok, :linear_mcp}
  end

  defp evaluate_parsed_mode(false, opts, positional, deps) do
    with :ok <- evaluate_daemon(opts, positional, deps), do: {:ok, :daemon}
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          handle_preflight(expanded_path, deps)

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  defp handle_preflight(expanded_path, deps) do
    case run_preflight(deps) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Tracker preflight failed for workflow #{expanded_path}: #{format_preflight_error(reason)}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]\n       symphony --linear-mcp --workflow <path-to-WORKFLOW.md>"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps(ensure_all_started \\ fn -> Application.ensure_all_started(:symphony_elixir) end) do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: ensure_all_started,
      ensure_linear_mcp_started: fn -> Application.ensure_all_started(:req) end,
      configure_linear_mcp_logger: &configure_linear_mcp_logger/0,
      serve_linear_mcp: &serve_linear_mcp/0,
      preflight: fn -> SymphonyElixir.Tracker.preflight(SymphonyElixir.Config.settings!().tracker) end
    }
  end

  defp evaluate_daemon(opts, positional, deps) do
    case positional do
      [] ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      [workflow_path] ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _other ->
        {:error, usage_message()}
    end
  end

  defp evaluate_linear_mcp(opts, [], deps) do
    case Keyword.get(opts, :workflow) do
      workflow when is_binary(workflow) and workflow != "" ->
        expanded_workflow = Path.expand(workflow)
        :ok = deps.set_workflow_file_path.(expanded_workflow)

        case ensure_linear_mcp_started(deps) do
          {:ok, _started_apps} ->
            :ok = configure_linear_mcp_logger(deps)
            serve_linear_mcp = Map.get(deps, :serve_linear_mcp, &serve_linear_mcp/0)
            serve_linear_mcp.()

          {:error, reason} ->
            {:error, "Failed to start Symphony linear MCP runtime with workflow #{expanded_workflow}: #{inspect(reason)}"}
        end

      _missing ->
        {:error, usage_message()}
    end
  end

  defp evaluate_linear_mcp(_opts, _positional, _deps), do: {:error, usage_message()}

  defp ensure_linear_mcp_started(deps) do
    deps
    |> Map.get(:ensure_linear_mcp_started, fn -> {:ok, []} end)
    |> then(& &1.())
  end

  defp run_preflight(deps) do
    deps
    |> Map.get(:preflight, fn -> :ok end)
    |> then(& &1.())
  end

  defp format_preflight_error({:linear_preflight_failed, reasons}) when is_list(reasons) do
    Enum.join(reasons, "; ")
  end

  defp format_preflight_error(reason), do: inspect(reason)

  defp configure_linear_mcp_logger(deps) do
    deps
    |> Map.get(:configure_linear_mcp_logger, &configure_linear_mcp_logger/0)
    |> then(& &1.())
  end

  defp configure_linear_mcp_logger do
    case :logger.remove_handler(:default) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
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

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
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
