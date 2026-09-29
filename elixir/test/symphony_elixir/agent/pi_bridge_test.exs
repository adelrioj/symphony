defmodule SymphonyElixir.Agent.PiBridgeTest do
  use ExUnit.Case, async: false

  @moduletag :bridge

  test "bridge node tests pass" do
    case node_executable() do
      nil ->
        IO.puts("skipping: node >= 22.6 required")

      node ->
        {out, status} =
          System.cmd(node, ["--experimental-strip-types", "--test", "priv/pi/*.test.mjs"], stderr_to_stdout: true)

        assert status == 0, out
    end
  end

  defp node_executable do
    with node when is_binary(node) <- System.find_executable("node"),
         {"v" <> version, 0} <- System.cmd(node, ["--version"]),
         [major, minor | _] <- version |> String.trim() |> String.split(".") |> Enum.map(&Integer.parse/1),
         {major, _} <- major,
         {minor, _} <- minor,
         true <- {major, minor} >= {22, 6} do
      node
    else
      _ -> nil
    end
  end
end
