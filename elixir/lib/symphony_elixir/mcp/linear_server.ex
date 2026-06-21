defmodule SymphonyElixir.MCP.LinearServer do
  @moduledoc """
  Minimal MCP stdio server exposing Symphony's Linear GraphQL tool.
  """

  alias SymphonyElixir.Codex.DynamicTool

  @protocol_version "2025-06-18"
  @approval_tool %{
    "name" => "approval_prompt",
    "description" => "Permission prompt. Non-interactive Symphony session: always denies.",
    "inputSchema" => %{"type" => "object", "additionalProperties" => true, "properties" => %{}}
  }

  @spec tool_specs() :: [map()]
  def tool_specs do
    DynamicTool.tool_specs() ++ [@approval_tool]
  end

  @spec handle_request(map()) :: map() | nil
  def handle_request(%{"method" => "initialize", "id" => id}) do
    result(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "symphony-linear", "version" => "0.1.0"}
    })
  end

  def handle_request(%{"method" => "notifications/initialized"}), do: nil

  def handle_request(%{"method" => "tools/list", "id" => id}) do
    result(id, %{"tools" => tool_specs()})
  end

  def handle_request(%{
        "method" => "tools/call",
        "id" => id,
        "params" => %{"name" => "approval_prompt"}
      }) do
    result(id, %{
      "isError" => true,
      "content" => [
        %{
          "type" => "text",
          "text" => "Permission denied: non-interactive Symphony session."
        }
      ]
    })
  end

  def handle_request(%{
        "method" => "tools/call",
        "id" => id,
        "params" => %{"name" => "linear_graphql"} = params
      }) do
    tool_result = DynamicTool.execute("linear_graphql", Map.get(params, "arguments", %{}), [])

    result(id, %{
      "isError" => not Map.get(tool_result, "success", false),
      "content" => [
        %{"type" => "text", "text" => Map.get(tool_result, "output", "")}
      ]
    })
  end

  def handle_request(%{"method" => "tools/call", "id" => id, "params" => %{"name" => name}}) do
    error(id, -32601, "Unknown tool: #{name}")
  end

  def handle_request(%{"id" => id}) do
    error(id, -32600, "Unsupported MCP request")
  end

  def handle_request(_request), do: nil

  defp result(id, payload), do: %{"jsonrpc" => "2.0", "id" => id, "result" => payload}

  defp error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end
end
