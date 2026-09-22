defmodule SymphonyElixir.ExecutionProfileConfigurationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionProfiles.Configuration

  @tag :tmp_dir
  test "splitting infrastructure preserves uncommon workspace policy through composition", %{tmp_dir: root} do
    raw = %{"worker" => %{}, "workspace" => %{"retention" => %{"keep" => true}}, "tracker" => %{"kind" => "memory"}}
    {profile, lane} = Configuration.split(raw)
    assert profile == %{"worker" => %{}}
    assert {:ok, resolved} = Configuration.resolve(Map.put(profile, "workspace_base", root), lane, "isolated", "work")
    assert resolved.workflow.config["workspace"] == %{"root" => Path.join(root, "isolated"), "retention" => %{"keep" => true}}
  end

  test "invalid composition representations return errors rather than selecting an execution location" do
    assert {:error, [%{path: "config"}]} = Configuration.resolve(%{}, [], ".", "work")
    assert {:error, [%{path: "config"}]} = Configuration.resolve(%{}, %{}, ".", "work", [])
    assert {:error, [%{path: "config.workspace"}]} = Configuration.resolve(%{}, %{"workspace" => false}, ".", "work")
    assert {:error, [%{path: "profile.worker"}]} = Configuration.resolve(%{"worker" => []}, %{}, ".", "work")
  end

  test "profile validation rejects invalid worker configuration without hiding field paths" do
    assert {:error, [%{path: "profile"}]} = Configuration.validate_profile([])
    assert {:error, errors} = Configuration.validate_profile(%{"worker" => %{"ssh_hosts" => "not-an-array"}})
    assert Enum.any?(errors, &(&1.path == "worker.ssh_hosts"))
  end

  test "semantic backend validation identifies the invalid command field" do
    config = %{"tracker" => %{"kind" => "memory"}, "codex" => %{"command" => ""}}
    assert {:error, [%{path: "codex.command"}]} = Configuration.resolve(%{}, config, ".", "work")
  end

  test "invalid provider qualification prevents composing a runnable managed lane" do
    environment = %{"kind" => "kubernetes", "deployment_id" => "unqualified", "provider" => %{}, "startup_timeout_ms" => 1_000, "shutdown_timeout_ms" => 1_000, "terminal_retention_ms" => 0}
    assert {:error, [%{path: "config"}]} = Configuration.resolve(%{"worker" => %{"environment" => environment}}, %{"tracker" => %{"kind" => "memory"}}, ".", "work")
  end

  test "unbound workspace references compose against the configured default base" do
    key = "SYMPHONY_UNBOUND_PROFILE_BASE"
    previous = System.get_env(key)
    on_exit(fn -> if previous, do: System.put_env(key, previous), else: System.delete_env(key) end)
    System.delete_env(key)
    config = %{"tracker" => %{"kind" => "memory"}}
    assert {:ok, expected_root} = SymphonyElixir.PathSafety.canonicalize(Path.expand(%Schema.Workspace{}.root, Config.data_root()))

    assert {:ok, missing} = Configuration.resolve(%{"workspace_base" => "$" <> key}, config, ".", "work")
    assert missing.settings.workspace.root == expected_root
    System.put_env(key, "")
    assert {:ok, empty} = Configuration.resolve(%{"workspace_base" => "$" <> key}, config, ".", "work")
    assert empty.settings.workspace.root == expected_root
    assert {:ok, omitted} = Configuration.resolve(%{}, config, ".", "work")
    assert omitted.settings.workspace.root == expected_root
  end

  @tag :tmp_dir
  test "a dollar-prefixed literal directory is not an environment reference", %{tmp_dir: root} do
    previous = Application.fetch_env(:symphony_elixir, :data_root)
    Application.put_env(:symphony_elixir, :data_root, root)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :data_root, value)
        :error -> Application.delete_env(:symphony_elixir, :data_root)
      end
    end)

    assert {:ok, resolved} = Configuration.resolve(%{"workspace_base" => "$literal/path"}, %{"tracker" => %{"kind" => "memory"}}, ".", "work")
    assert resolved.settings.workspace.root == Path.join(root, "$literal/path")
  end

  @tag :remediation
  test "secret projections preserve only complete environment references through nested containers" do
    original = %{
      "api_key" => "$private-token",
      "credentials" => %{
        "empty_name" => "$",
        "digit_prefix" => "$1TOKEN",
        "trailing_newline" => "$TOKEN\n",
        "multiline_suffix" => "$TOKEN\nprivate",
        "nested" => [%{"value" => "$private-token", "reference" => "$_TOKEN_2"}, ["$a"]]
      },
      "extension" => %{"path" => "$literal/path"}
    }

    expected = %{
      "api_key" => "$REDACTED",
      "credentials" => %{
        "empty_name" => "$REDACTED",
        "digit_prefix" => "$REDACTED",
        "trailing_newline" => "$REDACTED",
        "multiline_suffix" => "$REDACTED",
        "nested" => [%{"value" => "$REDACTED", "reference" => "$_TOKEN_2"}, ["$a"]]
      },
      "extension" => %{"path" => "$literal/path"}
    }

    projected = Configuration.redact_secrets(original)
    assert projected == expected
    assert Configuration.redact_secrets(projected) == expected
    assert {:ok, ^original} = Configuration.restore_redacted(projected, original, "")
  end

  test "redaction restoration rejects unmatched values inside nested arrays with a usable field path" do
    assert {:error, [%{path: "accounts[0].token"}]} = Configuration.restore_redacted(%{"accounts" => [%{"token" => "$REDACTED"}]}, %{}, "")
    original = %{"accounts" => [%{"token" => "stored", "name" => "original"}]}
    replacement = %{"accounts" => [%{"token" => "$REDACTED", "name" => "changed"}]}
    assert {:ok, %{"accounts" => [%{"token" => "stored", "name" => "changed"}]}} = Configuration.restore_redacted(replacement, original, "")
  end
end
