defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool, as: BoundDynamicTool
  alias SymphonyElixir.Linear.AgentTool, as: DynamicTool

  test "tool_specs advertises the linear_graphql and linear_fetch_attachment contracts" do
    assert [
             %{
               "description" => graphql_description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             },
             %{
               "description" => attachment_description,
               "inputSchema" => %{
                 "properties" => %{"url" => _},
                 "required" => ["url"],
                 "type" => "object"
               },
               "name" => "linear_fetch_attachment"
             }
           ] = DynamicTool.tool_specs()

    assert graphql_description =~ "Linear"
    assert attachment_description =~ "attachment"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{}, [])

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "linear_fetch_attachment"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "bound tools keep the adapter and auth snapshot from session startup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "session-token",
      tracker_project_slug: "session-project"
    )

    binding = BoundDynamicTool.bind()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert BoundDynamicTool.bind().tool_specs == []

    test_pid = self()

    response =
      BoundDynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        binding,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:bound_linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_bound"}}}}
        end
      )

    assert_received {:bound_linear_client_called, "query Viewer { viewer { id } }", %{}, [tracker_settings: tracker_settings]}

    assert tracker_settings.api_key == "session-token"
    assert tracker_settings.project_slug == "session-project"
    assert response["success"] == true
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ", [])

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `tracker.provider.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  test "linear_fetch_attachment returns UTF-8 contents from an allowed Linear URL" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_fetch_attachment",
        %{"url" => "  https://uploads.linear.app/abc/MT-1-design.md  "},
        attachment_fetcher: fn url, opts ->
          send(test_pid, {:attachment_fetcher_called, url, opts})
          {:ok, "# Design spec\n"}
        end
      )

    assert response["success"] == true
    assert response["output"] == "# Design spec\n"

    assert response["contentItems"] == [
             %{"type" => "inputText", "text" => "# Design spec\n"}
           ]

    assert_received {:attachment_fetcher_called, "https://uploads.linear.app/abc/MT-1-design.md", []}
  end

  test "linear_fetch_attachment accepts a raw url string and forwards tracker settings" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_fetch_attachment",
        "https://uploads.linear.app/abc/spec.md",
        tracker_settings: %{api_key: "secret"},
        attachment_fetcher: fn url, opts ->
          send(test_pid, {:attachment_fetcher_called, url, opts})
          {:ok, "body"}
        end
      )

    assert response["success"] == true
    assert response["output"] == "body"
    assert_received {:attachment_fetcher_called, "https://uploads.linear.app/abc/spec.md", opts}
    assert opts[:tracker_settings] == %{api_key: "secret"}
  end

  test "linear_fetch_attachment requires a url" do
    response = DynamicTool.execute("linear_fetch_attachment", %{}, [])

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_fetch_attachment` requires a non-empty `url` string."
             }
           }
  end

  test "linear_fetch_attachment rejects non-Linear hosts without fetching" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_fetch_attachment",
        %{"url" => "https://evil.example.com/steal"},
        attachment_fetcher: fn _url, _opts ->
          send(test_pid, :should_not_fetch)
          {:ok, "nope"}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_fetch_attachment` only downloads Linear attachment URLs (https://uploads.linear.app/...)."
             }
           }

    refute_received :should_not_fetch
  end

  test "linear_fetch_attachment rejects oversized attachments" do
    oversized = String.duplicate("a", 1_048_577)

    response =
      DynamicTool.execute(
        "linear_fetch_attachment",
        %{"url" => "https://uploads.linear.app/abc/big.md"},
        attachment_fetcher: fn _url, _opts -> {:ok, oversized} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Attachment exceeds the 1048576-byte download limit."
             }
           }
  end

  test "linear_fetch_attachment rejects non-text attachments" do
    response =
      DynamicTool.execute(
        "linear_fetch_attachment",
        %{"url" => "https://uploads.linear.app/abc/logo.png"},
        attachment_fetcher: fn _url, _opts -> {:ok, <<0xFF, 0xFE, 0x00>>} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Attachment is not UTF-8 text and cannot be returned inline."
             }
           }
  end

  test "linear_fetch_attachment surfaces download auth and transport failures" do
    missing_token =
      DynamicTool.execute(
        "linear_fetch_attachment",
        %{"url" => "https://uploads.linear.app/abc/spec.md"},
        attachment_fetcher: fn _url, _opts -> {:error, :missing_linear_api_token} end
      )

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `tracker.provider.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_fetch_attachment",
        %{"url" => "https://uploads.linear.app/abc/spec.md"},
        attachment_fetcher: fn _url, _opts -> {:error, {:linear_api_status, 404}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear request failed with HTTP 404.",
               "status" => 404
             }
           }
  end

  test "linear_fetch_attachment accepts an atom-keyed url argument" do
    response =
      DynamicTool.execute(
        "linear_fetch_attachment",
        %{url: "https://uploads.linear.app/abc/spec.md"},
        attachment_fetcher: fn _url, _opts -> {:ok, "ok"} end
      )

    assert response["success"] == true
    assert response["output"] == "ok"
  end
end
