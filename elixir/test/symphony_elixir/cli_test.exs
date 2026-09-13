defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: false

  require Logger

  alias SymphonyElixir.{CLI, Config, Lanes, TestSupport, Workflow}
  import ExUnit.CaptureIO

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @installation_keys [
    :data_root,
    :server_port,
    :server_host,
    :events_retention_days,
    :operator_token,
    :log_file,
    :workflow_file_path
  ]

  setup do
    logger = :logger.get_handler_config(:default)
    previous = Map.new(@installation_keys, &{&1, Application.fetch_env(:symphony_elixir, &1)})
    root = Path.join(System.tmp_dir!(), "symphony-cli-#{System.unique_integer([:positive, :monotonic])}")

    on_exit(fn ->
      restore_default_logger_handler(logger)

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:symphony_elixir, key, value)
          :error -> Application.delete_env(:symphony_elixir, key)
        end
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp deps(overrides \\ %{}) do
    Map.merge(
      %{
        ensure_all_started: fn -> flunk("daemon startup must not be reached") end,
        start_repo: fn -> flunk("database startup must not be reached") end,
        import_lane: &Lanes.import_file/2,
        export_lane: fn slug ->
          case Lanes.get_by_slug(slug) do
            nil -> {:error, :not_found}
            lane -> Lanes.export(lane)
          end
        end,
        operator_token: fn -> "test-token" end,
        write_output: &IO.write/1
      },
      overrides
    )
  end

  test "arguments are rejected before acknowledgement, credentials, or filesystem changes", %{root: root} do
    invalid = [
      [],
      ["WORKFLOW.md", @ack_flag],
      ["serve", "--bogus"],
      ["serve", "WORKFLOW.md"],
      ["serve", "--port", "-1"],
      ["serve", "--port", "65536"],
      ["serve", "--port", "not-a-port"],
      ["serve", "--events-retention-days", "0"],
      ["serve", "--events-retention-days", "-1"],
      ["serve", "--events-retention-days", "1.5"],
      ["serve", "--host", "localhost"],
      ["serve", "--host", "999.1.1.1"],
      ["serve", "--host", "127.0.0.1:4000"],
      ["serve", "--host", " 127.0.0.1"],
      ["serve", "--data-root", "  "],
      ["lanes", "frobnicate"],
      ["lanes", "import", "WORKFLOW.md", "--slug", "features", "--port", "4000"],
      ["lanes", "export"],
      ["lanes", "export", "features", "extra"],
      ["--linear-mcp", "--workflow", "WORKFLOW.md", "extra"],
      ["--linear-mcp", "--workflow", "WORKFLOW.md", "--port", "4000"],
      ["--linear-mcp", "--workflow", " "],
      ["--no-linear-mcp"]
    ]

    for args <- invalid do
      assert {:error, message} = CLI.evaluate(args, deps(%{operator_token: fn -> flunk("credentials read before parsing") end}))
      assert message =~ "Usage: symphony serve"
    end

    assert {:error, message} = CLI.evaluate(["WORKFLOW.md", @ack_flag], deps())
    assert message =~ "import it as a lane first"
    refute File.exists?(root)
  end

  test "serve requires acknowledgement before reading credentials or creating directories", %{root: root} do
    assert {:error, banner} =
             CLI.evaluate(["serve", "--data-root", root], deps(%{operator_token: fn -> flunk("credentials read before acknowledgement") end}))

    assert banner =~ @ack_flag
    refute File.exists?(root)
  end

  test "serve refuses missing or blank operator tokens before touching disk", %{root: root} do
    for token <- [nil, "", " \t\n"] do
      assert {:error, message} = CLI.evaluate(["serve", "--data-root", root, @ack_flag], deps(%{operator_token: fn -> token end}))
      assert message =~ "SYMPHONY_OPERATOR_TOKEN"
      refute File.exists?(root)
    end
  end

  test "serve creates installation directories and publishes configuration before starting", %{root: root} do
    File.mkdir_p!(root)

    File.cd!(root, fn ->
      assert :ok =
               CLI.evaluate(
                 ["serve", @ack_flag],
                 deps(%{
                   ensure_all_started: fn ->
                     assert Config.data_root() == File.cwd!()
                     assert Config.server_port() == 4000
                     assert Config.server_host() == "127.0.0.1"
                     assert Config.events_retention_days() == 30
                     assert Config.operator_token() == "test-token"
                     assert File.dir?(Path.join(Config.data_root(), "log"))
                     assert Application.fetch_env!(:symphony_elixir, :log_file) == Path.join(Config.data_root(), "log/symphony.log")
                     {:ok, []}
                   end
                 })
               )
    end)
  end

  test "serve accepts explicit installation values, ephemeral ports, and IPv6", %{root: root} do
    assert :ok =
             CLI.evaluate(
               ["serve", "--data-root", root, "--port", "0", "--host", "::1", "--events-retention-days", "1", @ack_flag],
               deps(%{
                 ensure_all_started: fn ->
                   assert Config.data_root() == Path.expand(root)
                   assert Config.server_port() == 0
                   assert Config.server_host() == "::1"
                   assert Config.events_retention_days() == 1
                   assert File.dir?(Path.join(root, "log"))
                   {:ok, []}
                 end
               })
             )
  end

  test "serve reports application and directory failures", %{root: root} do
    assert {:error, message} =
             CLI.evaluate(["serve", "--data-root", root, @ack_flag], deps(%{ensure_all_started: fn -> {:error, :boom} end}))

    assert message =~ "Failed to start Symphony"
    assert message =~ "boom"
    file = Path.join(root, "not-a-directory")
    File.write!(file, "")
    assert {:error, message} = CLI.evaluate(["serve", "--data-root", file, @ack_flag], deps())
    assert message =~ "Failed to create Symphony data directory"
  end

  test "import requires a nonblank slug before opening the database" do
    for suffix <- [[], ["--slug", ""], ["--slug", "   "]] do
      assert {:error, message} = CLI.evaluate(["lanes", "import", "WORKFLOW.md" | suffix], deps())
      assert message =~ "--slug"
    end
  end

  test "import persists a disabled version and export returns exact workflow bytes", %{root: root} do
    File.mkdir_p!(root)
    path = Path.join(root, "WORKFLOW.md")
    content = "---\ntracker:\n  kind: memory\nserver:\n  port: 9999\n---\nPrompt with trailing spaces  \n"
    File.write!(path, content)
    slug = "cli-#{System.unique_integer([:positive, :monotonic])}"
    offline = deps(%{start_repo: fn -> :ok end})

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.evaluate(
                   ["lanes", "import", path, "--slug", slug, "--name", "Imported lane", "--note", "initial", "--data-root", root],
                   offline
                 )
      end)

    lane = Lanes.get_by_slug(slug)
    assert lane.name == "Imported lane"
    refute lane.enabled
    assert Lanes.current_version(lane).note == "initial"
    assert output =~ "imported lane #{slug} version #{lane.current_version_id}"
    assert output =~ "warning:"
    assert capture_io(fn -> assert :ok = CLI.evaluate(["lanes", "export", slug, "--data-root", root], offline) end) == content
  end

  test "import reports real field validation and unreadable files", %{root: root} do
    File.mkdir_p!(root)
    path = Path.join(root, "WORKFLOW.md")
    File.write!(path, "---\ntracker:\n  kind: unsupported\n---\nPrompt")
    offline = deps(%{start_repo: fn -> :ok end})
    assert {:error, message} = CLI.evaluate(["lanes", "import", path, "--slug", "invalid-cli", "--data-root", root], offline)
    assert message =~ "tracker.kind:"
    assert is_nil(Lanes.get_by_slug("invalid-cli"))
    assert {:error, message} = CLI.evaluate(["lanes", "import", path <> ".missing", "--slug", "missing-cli", "--data-root", root], offline)
    assert message =~ "Invalid lane configuration"
  end

  test "offline commands report database and export errors without starting the daemon", %{root: root} do
    assert {:error, message} =
             CLI.evaluate(["lanes", "export", "missing", "--data-root", root], deps(%{start_repo: fn -> {:error, :locked} end}))

    assert message =~ "Failed to open the Symphony database"
    assert message =~ "locked"

    offline = deps(%{start_repo: fn -> :ok end})
    assert {:error, "no lane with slug missing-cli-lane"} = CLI.evaluate(["lanes", "export", "missing-cli-lane", "--data-root", root], offline)

    assert {:error, "lane empty has no version"} =
             CLI.evaluate(
               ["lanes", "export", "empty", "--data-root", root],
               deps(%{start_repo: fn -> :ok end, export_lane: fn _slug -> {:error, :no_version} end})
             )
  end

  test "evaluate/2 with --linear-mcp loads the workflow and enters mcp mode" do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.evaluate(
                   ["--linear-mcp", "--workflow", "/abs/WORKFLOW.md"],
                   deps(%{
                     ensure_linear_mcp_started: fn -> {:ok, [:req]} end,
                     serve_linear_mcp: fn ->
                       assert Workflow.workflow_file_path() == "/abs/WORKFLOW.md"
                       IO.write("MCP response")
                     end
                   })
                 )
      end)

    assert output == "MCP response"
  end

  test "evaluate/2 with --linear-mcp keeps startup and request logs off protocol stdout" do
    response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"isError" => true}})
    protocol_output = IO.iodata_to_binary(["Content-Length: ", Integer.to_string(byte_size(response)), "\r\n\r\n", response])

    stdout =
      capture_io(fn ->
        assert :ok =
                 CLI.evaluate(
                   ["--linear-mcp", "--workflow", "/abs/WORKFLOW.md"],
                   deps(%{
                     ensure_linear_mcp_started: fn ->
                       Logger.warning("startup warning")
                       {:ok, [:req]}
                     end,
                     serve_linear_mcp: fn ->
                       Logger.error("Linear GraphQL request failed: :timeout")
                       IO.write(protocol_output)
                     end
                   })
                 )

        Logger.flush()
      end)

    assert stdout == protocol_output
  end

  test "evaluate/2 with --linear-mcp returns startup errors before serving" do
    assert {:error, message} =
             CLI.evaluate(
               ["--linear-mcp", "--workflow", "/abs/WORKFLOW.md"],
               deps(%{
                 ensure_linear_mcp_started: fn -> {:error, :req_failed} end,
                 serve_linear_mcp: fn -> flunk("must not serve after startup failure") end
               })
             )

    assert message =~ "Failed to start Symphony linear MCP runtime"
    assert message =~ ":req_failed"
  end

  test "serve_linear_mcp_loop/2 handles Content-Length framed requests and responses", %{root: root} do
    File.mkdir_p!(root)
    :ok = TestSupport.write_workflow_file!(Path.join(root, "WORKFLOW.md"))
    on_exit(fn -> TestSupport.reset_lanes!() end)

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
