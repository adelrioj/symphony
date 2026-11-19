defmodule SymphonyElixir.MCP.LinearServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.MCP.LinearServer

  test "initialize returns MCP tool capabilities" do
    response =
      LinearServer.handle_request(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "initialize",
        "params" => %{}
      })

    assert response["result"]["capabilities"] == %{"tools" => %{}}
    assert response["result"]["serverInfo"]["name"] == "symphony-linear"
  end

  test "initialized notification does not produce a response" do
    assert LinearServer.handle_request(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) == nil
    assert LinearServer.handle_request(%{"jsonrpc" => "2.0", "method" => "notifications/cancelled"}) == nil
  end

  test "tools/list returns linear tools and approval_prompt" do
    response =
      LinearServer.handle_request(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      })

    names = response["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["approval_prompt", "linear_fetch_attachment", "linear_graphql"]
  end

  test "approval_prompt always denies" do
    response =
      LinearServer.handle_request(%{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "approval_prompt", "arguments" => %{"action" => "write file"}}
      })

    text = response["result"]["content"] |> hd() |> Map.get("text")
    assert response["result"]["isError"] == true
    assert text =~ "denied"
  end

  test "linear_graphql routes through the dynamic tool response format" do
    response =
      LinearServer.handle_request(%{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "linear_graphql", "arguments" => %{}}
      })

    text = response["result"]["content"] |> hd() |> Map.get("text")
    assert response["result"]["isError"] == true
    assert text =~ "requires a non-empty `query` string"
  end

  test "unknown tool and unsupported requests return JSON-RPC errors" do
    unknown_tool =
      LinearServer.handle_request(%{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "not_real"}
      })

    unsupported =
      LinearServer.handle_request(%{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "resources/list"
      })

    assert unknown_tool["error"]["message"] == "Unknown tool: not_real"
    assert unsupported["error"]["message"] == "Unsupported MCP request"
  end

  test "Bonbons exposes only the live section for the bound issue and gates Error Reporting", %{test: test} do
    bug_text = ~s(BUG_MARKER. Call mcp__symphony__read_procedure with {"section": "error-reporting"} when needed.)

    configure_procedures(test, "bonbons-delivery", %{
      "qa" => "QA_MARKER",
      "bug" => bug_text,
      "deliver" => "DELIVER_MARKER",
      "error-reporting" => "ERROR_MARKER"
    })

    assert "read_procedure" in Enum.map(LinearServer.tool_specs(), & &1["name"])
    live_issue("Todo", ["GROOMED", "bug-Symphony"])
    assert %{"isError" => true} = read_procedure("deliver")
    assert %{"isError" => true} = read_procedure("error-reporting")
    assert %{"isError" => false, "content" => [%{"text" => ^bug_text}]} = read_procedure("bug")
    assert %{"isError" => false, "content" => [%{"text" => "ERROR_MARKER"}]} = read_procedure("error-reporting")

    live_issue("In Review", ["groomed", "Bug", "chore"])
    assert %{"isError" => true} = read_procedure("bug")
    assert %{"isError" => true} = read_procedure("error-reporting")
    assert %{"isError" => false, "content" => [%{"text" => "QA_MARKER"}]} = read_procedure("qa")
    assert %{"isError" => true} = read_procedure("error-reporting")

    live_issue("In Progress", ["groomed"])
    assert %{"isError" => true} = read_procedure("error-reporting")
    assert %{"isError" => false, "content" => [%{"text" => "DELIVER_MARKER"}]} = read_procedure("deliver")
    assert %{"isError" => true} = read_procedure("error-reporting")
  end

  test "Chorus rejects unrelated issue routes, conflicts and Error Reporting", %{test: test} do
    configure_procedures(test, "chorus-delivery", %{
      "bug" => "CHORUS_BUG",
      "deliver" => "CHORUS_DELIVER",
      "error-reporting" => "MUST_NOT_BE_EXPOSED"
    })

    for {state, labels} <- [
          {"In Progress", ["groomed", "Human"]},
          {"In Progress", ["chore"]},
          {"In Progress", ["groomed", "Bug", "feat-symphony"]},
          {"Done", ["groomed"]}
        ] do
      live_issue(state, labels)
      assert %{"isError" => true} = read_procedure("deliver")
      assert %{"isError" => true} = read_procedure("bug")
    end

    live_issue("In Progress", ["groomed", "Improvement"])

    assert %{"isError" => true} =
             read_procedure("bug", %{"issue_id" => "other-issue", "state" => "Todo", "labels" => ["groomed", "Bug"]})

    assert %{"isError" => true} = read_procedure("bug")
    assert %{"isError" => false, "content" => [%{"text" => "CHORUS_DELIVER"}]} = read_procedure("deliver")
    assert %{"isError" => true} = read_procedure("error-reporting")
  end

  for {slug, bug_text} <- [{"bonbons-delivery", %{}}, {"chorus-delivery", %{"bug" => " \n"}}] do
    test "#{slug} latches missing selected text without returning other sections", %{test: test} do
      path =
        configure_procedures(test, unquote(slug), Map.put(unquote(Macro.escape(bug_text)), "deliver", "UNUSED"))

      live_issue("Todo", ["groomed", "Bug"])
      assert %{"isError" => true, "content" => [%{"text" => detail}]} = read_procedure("bug")
      assert detail =~ "missing or blank"
      assert File.read!(path <> ".outcome") == "blocked:bug"

      live_issue("In Progress", ["groomed"])
      assert %{"isError" => true, "content" => [%{"text" => rejected}]} = read_procedure("deliver")
      refute rejected =~ "UNUSED"
      assert File.read!(path <> ".outcome") == "blocked:bug"
    end
  end

  test "Bonbons blocks only if its missing Error Reporting section is requested", %{test: test} do
    deliver = ~s(Call mcp__symphony__read_procedure with {"section":"error-reporting"} when needed.)
    path = configure_procedures(test, "bonbons-delivery", %{"deliver" => deliver})
    live_issue("In Progress", ["groomed"])

    assert %{"isError" => true} = read_procedure("error-reporting")
    assert File.read!(path <> ".outcome") == ""
    assert %{"isError" => false, "content" => [%{"text" => ^deliver}]} = read_procedure("deliver")
    assert %{"isError" => true, "content" => [%{"text" => detail}]} = read_procedure("error-reporting")
    assert detail =~ "selected error-reporting procedure is missing or blank"
    assert File.read!(path <> ".outcome") == "blocked:error-reporting"
  end

  for {rule, changed_labels} <- [
        {:required_labels, ["groomed", "delivery"]},
        {:any_labels, ["groomed", "ready"]},
        {:excluded_labels, ["groomed", "ready", "delivery", " HOLD "]}
      ] do
    test "procedure reads stop after an issue no longer matches #{rule}", %{test: test} do
      path = configure_procedures(test, "bonbons-delivery", %{"deliver" => "DELIVER_MARKER"})

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_required_labels: ["ready"],
        tracker_any_labels: ["delivery", "maintenance"],
        tracker_excluded_labels: ["hold"]
      )

      live_issue("In Progress", ["groomed", "ready", "delivery"])
      assert %{"isError" => false, "content" => [%{"text" => "DELIVER_MARKER"}]} = read_procedure("deliver")

      live_issue("In Progress", unquote(changed_labels))
      assert %{"isError" => true, "content" => [%{"text" => detail}]} = read_procedure("deliver")
      refute detail =~ "DELIVER_MARKER"
      assert File.read!(path <> ".outcome") == "read:deliver"
    end
  end

  defp configure_procedures(test, slug, procedures) do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    path = Path.join(Path.dirname(Workflow.workflow_file_path()), "#{test}.json")
    File.write!(path, Jason.encode!(%{"issue_id" => "bound-issue", "slug" => slug, "procedures" => procedures}))
    File.write!(path <> ".outcome", "")
    name = "SYMPHONY_CLAUDE_PROCEDURE_CONTEXT"
    previous = System.get_env(name)
    System.put_env(name, path)
    on_exit(fn -> restore_env(name, previous) end)
    path
  end

  defp live_issue(state, labels) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "other-issue", state: "Todo", labels: ["groomed", "Bug"]},
      %Issue{id: "bound-issue", state: state, labels: labels, dispatchable: true}
    ])
  end

  defp read_procedure(section, extra \\ %{}) do
    response =
      LinearServer.handle_request(%{
        "method" => "tools/call",
        "id" => 1,
        "params" => %{"name" => "read_procedure", "arguments" => Map.put(extra, "section", section)}
      })

    response["result"]
  end
end
