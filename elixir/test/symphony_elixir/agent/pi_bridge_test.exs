defmodule SymphonyElixir.Agent.PiBridgeTest do
  use ExUnit.Case, async: false

  @moduletag :bridge

  test "bridge node tests pass" do
    case System.find_executable("node") do
      nil ->
        IO.puts("skipping: node not installed")

      node ->
        {out, status} =
          System.cmd(node, ["--experimental-strip-types", "--test", "priv/pi/*.test.mjs"], stderr_to_stdout: true)

        assert status == 0, out
    end
  end
end
