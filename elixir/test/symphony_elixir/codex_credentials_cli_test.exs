defmodule SymphonyElixir.CodexCredentialsCLITest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.CLI

  test "credentials dispatch is isolated from scheduler repo and MCP startup" do
    caller = self()

    deps =
      deps(
        fn options ->
          assert options[:action] == "inspect"
          assert options[:data_root] == "/data" and options[:workflow] == "/workflow"
          {:ok, %{action: "inspect", authority: nil, resources: [], admission: "maintenance"}}
        end,
        caller
      )

    assert :ok = CLI.evaluate(["credentials", "reconcile", "--data-root", "/data", "--workflow", "/workflow"], deps)
    assert_receive {:output, output}

    assert Jason.decode!(output) == %{
             "ok" => true,
             "result" => %{"action" => "inspect", "authority" => nil, "resources" => [], "admission" => "maintenance"}
           }
  end

  for action <- ["checkpoint", "reseed-stop", "reseed-commit"] do
    test "#{action} preserves exact generation and original resource options" do
      action = unquote(action)

      args = [
        "credentials",
        "reconcile",
        "--data-root",
        "/data",
        "--workflow",
        "/workflow",
        "--action",
        action,
        "--resource",
        "projects/p/locations/l/workstationClusters/c/workstationConfigs/f/workstations/w",
        "--expected-epoch",
        "1",
        "--expected-generation",
        "12345678901234567890"
      ]

      args = if action == "checkpoint", do: args ++ ["--receipt-file", "/private/receipt.json"], else: args

      deps =
        deps(
          fn options ->
            assert options[:action] == action and options[:expected_epoch] == 1
            assert options[:expected_generation] == "12345678901234567890"
            {:error, :authority_changed}
          end,
          self()
        )

      assert {:error, error} = CLI.evaluate(args, deps)
      assert Jason.decode!(error) == %{"ok" => false, "reason" => "authority_changed"}
    end
  end

  test "malformed or duplicate mutation switches never reach recovery" do
    base = ["credentials", "reconcile", "--data-root", "/data", "--workflow", "/workflow"]
    deps = deps(fn _ -> flunk("invalid recovery arguments reached provider") end, self())

    for suffix <- [
          ["--force"],
          ["--action", "reseed-stop"],
          ["--action", "inspect", "--action", "checkpoint"],
          ["--stop-proof", "forged"]
        ] do
      assert {:error, error} = CLI.evaluate(base ++ suffix, deps)
      assert Jason.decode!(error)["ok"] == false
    end
  end

  test "oversized result and arbitrary exception content are never printed" do
    args = ["credentials", "reconcile", "--data-root", "/data", "--workflow", "/workflow"]
    deps = deps(fn _ -> {:ok, %{resources: [String.duplicate("sensitive", 150_000)]}} end, self())
    assert {:error, bounded} = CLI.evaluate(args, deps)
    assert byte_size(bounded) < 200
    refute_received {:output, _}
    deps = deps(fn _ -> raise "private-account-token" end, self())
    assert {:error, bounded} = CLI.evaluate(args, deps)
    refute String.contains?(bounded, "private-account-token")
  end

  defp deps(reconcile, caller) do
    %{
      reconcile_credentials: reconcile,
      ensure_all_started: fn -> flunk("scheduler started") end,
      start_repo: fn -> flunk("Repo/migrations started") end,
      ensure_linear_mcp_started: fn -> flunk("MCP started") end,
      operator_token: fn -> flunk("operator secret read") end,
      write_output: fn output ->
        send(caller, {:output, output})
        :ok
      end
    }
  end
end
