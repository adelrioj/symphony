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
    dynamic_tool_binding().tool_specs ++ [@approval_tool]
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
        "params" => %{"name" => name} = params
      }) do
    binding = dynamic_tool_binding()

    if Enum.any?(binding.tool_specs, &(&1["name"] == name)) do
      tool_result = DynamicTool.execute(name, Map.get(params, "arguments", %{}), binding)

      result(id, %{
        "isError" => not Map.get(tool_result, "success", false),
        "content" => [
          %{"type" => "text", "text" => Map.get(tool_result, "output", "")}
        ]
      })
    else
      error(id, -32_601, "Unknown tool: #{name}")
    end
  end

  def handle_request(%{"id" => id}) do
    error(id, -32_600, "Unsupported MCP request")
  end

  def handle_request(_request), do: nil

  defp dynamic_tool_binding do
    case Process.get({__MODULE__, :dynamic_tool_binding}) do
      nil ->
        binding = DynamicTool.bind()
        Process.put({__MODULE__, :dynamic_tool_binding}, binding)
        binding

      binding ->
        binding
    end
  end

  defp result(id, payload), do: %{"jsonrpc" => "2.0", "id" => id, "result" => payload}

  defp error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end
end
