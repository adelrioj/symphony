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
end
