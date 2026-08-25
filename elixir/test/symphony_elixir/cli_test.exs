defmodule SymphonyElixir.CLITest do
  use SymphonyElixir.TestSupport

  require Logger

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  setup do
    default_logger_handler = :logger.get_handler_config(:default)

    on_exit(fn ->
      restore_default_logger_handler(default_logger_handler)
    end)

    :ok
  end

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end,
      preflight: fn -> :ok end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      preflight: fn -> :ok end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      preflight: fn -> :ok end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      preflight: fn -> :ok end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      preflight: fn -> :ok end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end,
      preflight: fn -> :ok end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      preflight: fn -> :ok end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "a failing preflight prevents the supervision tree from starting" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> flunk("application must not start when preflight fails") end,
      preflight: fn -> {:error, {:linear_preflight_failed, ["unknown Linear team key \"NOPE\""]}} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Tracker preflight failed"
    assert message =~ "NOPE"
  end

  test "a passing preflight starts the supervision tree" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end,
      preflight: fn ->
        send(parent, :preflighted)
        :ok
      end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)

    # Drained in mailbox order: preflight must run before the supervision tree starts.
    markers =
      Enum.map(1..2, fn _ ->
        receive do
          marker -> marker
        after
          0 -> :no_message
        end
      end)

    assert markers == [:preflighted, :started]
  end

  defmodule NeverCalledLinearClient do
    def graphql(query, variables) do
      send(self(), {:linear_request, query, variables})

      # Also breaks the `:ok` assertion below if it is ever reached: an empty team page makes
      # preflight fail, so a reintroduced ordering bug cannot pass quietly.
      {:ok, %{"data" => %{"teams" => %{"nodes" => []}}}}
    end
  end

  # `run/2` preflights before `deps.ensure_all_started` reaches `WorkflowStore.init/1`, where
  # `Config.validate!/0` runs. Without an explicit offline gate, an operator with a blank endpoint
  # got a Linear error instead of the config error that names the real problem, and Symphony
  # issued a live request for a configuration it was about to reject offline.
  test "an offline-invalid tracker config is never preflighted" do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, NeverCalledLinearClient)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous_client)
      end
    end)

    workflow_path = Workflow.workflow_file_path()

    # Seeded valid first: `WorkflowStore` runs during tests, so `Config.settings/0` answers with
    # the last known good config even after the file goes bad. Seeding a team-scoped config makes
    # those stale settings the ones that DO query Linear, so only a real offline gate can keep the
    # request from happening.
    write_workflow_file!(workflow_path, tracker_project_slug: nil, tracker_provider: %{"team_keys" => ["MDZ"]})
    assert :ok = Config.validate!()

    log =
      capture_log(fn ->
        # Blank endpoint: rejected by `Linear.Adapter.validate_config/1` with no request at all,
        # while `team_keys` stays non-empty so preflight would otherwise query Linear.
        write_workflow_file!(workflow_path,
          tracker_endpoint: "",
          tracker_project_slug: nil,
          tracker_provider: %{"team_keys" => ["MDZ"]}
        )

        assert {:error, :invalid_linear_endpoint} = Config.validate!()
        assert :ok = CLI.evaluate([@ack_flag, workflow_path])
      end)

    refute_received {:linear_request, _query, _variables}

    # Deferred, not swallowed: `WorkflowStore.init/1` is the boot step `deps.ensure_all_started`
    # reaches, and it stops on the reason the CLI then reports verbatim.
    assert {:stop, :invalid_linear_endpoint} = WorkflowStore.init([])
    assert log =~ "invalid_linear_endpoint"
  end

  test "evaluate/2 with --linear-mcp loads the workflow and enters mcp mode" do
    test_pid = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn path ->
        send(test_pid, {:workflow, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, []} end,
      ensure_linear_mcp_started: fn ->
        send(test_pid, :mcp_started)
        {:ok, [:req]}
      end,
      serve_linear_mcp: fn ->
        send(test_pid, :served)
        :ok
      end,
      preflight: fn -> :ok end
    }

    assert :ok = CLI.evaluate(["--linear-mcp", "--workflow", "/abs/WORKFLOW.md"], deps)
    assert_received {:workflow, "/abs/WORKFLOW.md"}
    assert_received :mcp_started
    assert_received :served
  end

  test "evaluate/2 with --linear-mcp keeps logger output off protocol stdout" do
    test_pid = self()
    response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"isError" => true}})
    protocol_output = IO.iodata_to_binary(["Content-Length: ", Integer.to_string(byte_size(response)), "\r\n\r\n", response])

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, []} end,
      ensure_linear_mcp_started: fn -> {:ok, [:req]} end,
      serve_linear_mcp: fn ->
        send(test_pid, {:default_logger_handler, :logger.get_handler_config(:default)})
        Logger.error("Linear GraphQL request failed: :timeout")
        IO.write(protocol_output)
        :ok
      end,
      preflight: fn -> :ok end
    }

    stdout =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = CLI.evaluate(["--linear-mcp", "--workflow", "/abs/WORKFLOW.md"], deps)
        Logger.flush()
      end)

    assert stdout == protocol_output
    assert_received {:default_logger_handler, {:error, {:not_found, :default}}}
  end

  test "evaluate/2 with --linear-mcp returns startup errors before serving" do
    test_pid = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, []} end,
      ensure_linear_mcp_started: fn -> {:error, :req_failed} end,
      serve_linear_mcp: fn ->
        send(test_pid, :served)
        :ok
      end,
      preflight: fn -> :ok end
    }

    assert {:error, message} = CLI.evaluate(["--linear-mcp", "--workflow", "/abs/WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony linear MCP runtime"
    assert message =~ ":req_failed"
    refute_received :served
  end

  test "serve_linear_mcp_loop/2 handles Content-Length framed requests and responses" do
    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      })

    input = ["Content-Length: ", Integer.to_string(byte_size(request)), "\r\n\r\n", request]

    {:ok, input_pid} = StringIO.open(IO.iodata_to_binary(input))
    {:ok, output_pid} = StringIO.open("")

    assert :ok = CLI.serve_linear_mcp_loop(input_pid, output_pid)

    {_input, output} = StringIO.contents(output_pid)
    assert output =~ "Content-Length: "

    [_headers, body] = String.split(output, "\r\n\r\n", parts: 2)
    response = Jason.decode!(body)

    assert response["id"] == 1
    assert response["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort() == ["approval_prompt", "linear_fetch_attachment", "linear_graphql"]
  end

  test "serve_linear_mcp_loop/2 preserves newline-delimited JSON compatibility" do
    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "approval_prompt", "arguments" => %{"action" => "write"}}
      })

    {:ok, input_pid} = StringIO.open(request <> "\n")
    {:ok, output_pid} = StringIO.open("")

    assert :ok = CLI.serve_linear_mcp_loop(input_pid, output_pid)

    {_input, output} = StringIO.contents(output_pid)
    response = output |> String.trim() |> Jason.decode!()

    assert response["id"] == 2
    assert response["result"]["isError"] == true
  end

  defp restore_default_logger_handler({:ok, config}) do
    :logger.remove_handler(:default)
    :logger.add_handler(:default, config.module, Map.drop(config, [:id, :module]))
    :ok
  end

  defp restore_default_logger_handler({:error, {:not_found, :default}}) do
    :logger.remove_handler(:default)
    :ok
  end
end
