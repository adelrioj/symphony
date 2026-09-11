defmodule SymphonyElixir.ExecutionEnvironmentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.ExecutionEnvironment, as: Environment
  alias SymphonyElixir.ExecutionEnvironment.{Config, Connection, Record}
  alias SymphonyElixir.SSH.Target

  test "opaque issue keys cannot collide through separator or display-name changes" do
    left = Environment.resource_key("deployment:a", "linear", "b")
    right = Environment.resource_key("deployment", "a:linear", "b")
    refute left == right
    assert left == Environment.resource_key("deployment:a", "linear", "b")
    assert String.match?(left, ~r/^se-[0-9a-f]{56}$/)
    refute left == Environment.resource_key("deployment:a", "linear", "B")
  end

  test "managed startup cannot have a zero deadline" do
    assert {:error, {:invalid_environment_config, _}} = Config.parse(Map.put(attributes(), "startup_timeout_ms", 0))
  end

  test "managed configuration rejects missing required values and invalid boundaries" do
    for field <- ["kind", "deployment_id", "provider", "startup_timeout_ms", "shutdown_timeout_ms"] do
      assert {:error, {:invalid_environment_config, _}} = Config.parse(Map.delete(attributes(), field))
      assert {:error, {:invalid_environment_config, _}} = Config.parse(Map.put(attributes(), field, nil))
    end

    for {field, value} <- [
          {"kind", "shell"},
          {"deployment_id", " \t"},
          {"provider", []},
          {"shutdown_timeout_ms", -1},
          {"terminal_retention_ms", -1},
          {"terminal_retention_ms", nil}
        ] do
      assert {:error, {:invalid_environment_config, _}} = Config.parse(Map.put(attributes(), field, value))
    end

    for value <- [nil, %{}, [], "managed"] do
      assert {:error, {:invalid_environment_config, _}} = Config.parse(value)
    end
  end

  test "provider maps preserve opaque string keys and accept empty provider configuration privately" do
    assert {:ok, config} = Config.parse(Map.put(attributes(), "provider", %{}))
    assert config.provider == %{}
    assert config.terminal_retention_ms == 0

    assert {:ok, config} = Config.parse(Map.put(attributes(), "provider", %{opaque: %{"not_an_atom_80913" => [%{nested: "value"}]}}))
    assert config.provider == %{"opaque" => %{"not_an_atom_80913" => [%{"nested" => "value"}]}}
  end

  test "runtime config captures full settings without consulting changing process state" do
    settings = settings()
    runtime = Config.runtime(settings)
    assert runtime.workspace_root == "/workspaces"
    assert runtime.tracker_kind == "linear"
    assert runtime.deployment_id == "isolated-deployment"
    assert runtime.provider["project"] == "project-a"
    assert Config.runtime(%{worker: %{}, workspace: %{root: "/unused"}}) == nil
    assert Config.identity(%{worker: %{}}) == nil
    assert_raise ArgumentError, fn -> Config.runtime(%{worker: %{environment: %{}}}) end
  end

  test "identity ignores mutable knobs and secrets but follows ownership and authentication references" do
    settings = settings()
    identity = Config.identity(settings)

    changed =
      settings
      |> put_in([:worker, :environment, "terminal_retention_ms"], 100)
      |> put_in([:worker, :environment, "startup_timeout_ms"], 42)
      |> put_in([:worker, :environment, "provider", "access_token"], "changed-secret")
      |> Map.put(:polling, %{interval_ms: 1})
      |> Map.put(:agent, %{max_concurrent_agents: 99})

    assert Config.identity(changed) == identity

    for field <- ["project", "location", "cluster", "config", "credential_configuration", "impersonate_service_account"] do
      refute Config.identity(put_in(settings, [:worker, :environment, "provider", field], "changed")) == identity
    end

    refute Config.identity(put_in(settings, [:workspace, :root], "/elsewhere")) == identity
    refute Config.identity(put_in(settings, [:worker, :environment, "deployment_id"], "other")) == identity
  end

  test "identity canonicalizes nested reference maps without confusing maps and lists" do
    settings = settings()
    left = put_in(settings, [:worker, :environment, "provider", "config"], %{"b" => [%{"z" => 1, "a" => 2}], "a" => 3})
    right = put_in(settings, [:worker, :environment, "provider", "config"], Map.new([{"a", 3}, {"b", [Map.new([{"a", 2}, {"z", 1}])]}]))
    assert Config.identity(left) == Config.identity(right)
    refute Config.identity(left) == Config.identity(put_in(right, [:worker, :environment, "provider", "config"], [{"a", 3}, {"b", []}]))
  end

  test "Kubernetes identity includes cluster credentials namespace and template references" do
    settings = put_in(settings(), [:worker, :environment], Map.merge(attributes(), %{"kind" => "kubernetes", "provider" => kubernetes_provider()}))
    identity = Config.identity(settings)

    for field <- ["kubeconfig", "context", "namespace", "template", "ssh_auth_volume"] do
      refute Config.identity(put_in(settings, [:worker, :environment, "provider", field], "changed")) == identity
    end
  end

  test "unknown adapters fail closed without treating input as a module name" do
    assert {:ok, SymphonyElixir.ExecutionEnvironment.Workstations} = Environment.adapter("google_workstations")
    assert {:ok, SymphonyElixir.ExecutionEnvironment.Kubernetes} = Environment.adapter("kubernetes")
    assert {:error, _} = Environment.adapter("Elixir.System")
    assert {:error, _} = Environment.adapter(nil)
  end

  test "managed contexts require matching running resources and live connections" do
    config = Config.runtime(settings())
    record = record(config)
    connection = connection()
    context = ExecutionContext.managed(config, record, connection)
    assert ExecutionContext.remote?(context)
    assert context.workspace_path == "/workspaces/persisted-ticket"
    assert context.environment.record.template_identity == "persisted-template-v1"

    for changes <- [
          %{key: "se-wrong"},
          %{deployment_id: "other"},
          %{tracker_kind: "github"},
          %{issue_id: "other"},
          %{kind: "kubernetes"},
          %{scope: %{"project" => "other"}},
          %{phase: :stopped},
          %{absent?: true},
          %{workspace_path: "/workspaces/../outside"},
          %{workspace_path: "/workspaces-other/ticket"},
          %{template_identity: nil}
        ] do
      assert_raise ArgumentError, fn -> ExecutionContext.managed(config, struct!(record, changes), connection) end
    end

    {owner, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    for invalid <- [%{connection | owner: owner}, %{connection | id: nil}, %{connection | target: nil}, nil] do
      assert_raise ArgumentError, fn -> ExecutionContext.managed(config, record, invalid) end
    end

    assert_raise ArgumentError, fn -> ExecutionContext.managed(%{}, record, connection) end
  end

  test "redacted inspection does not expose provider metadata or connection credentials" do
    config = Config.runtime(settings())
    record = %{record(config) | metadata: %{"secret" => "metadata-secret"}, provider_ref: "provider-secret"}
    connection = connection()
    context = ExecutionContext.managed(config, record, connection)

    for value <- [record, connection, context] do
      text = inspect(value)
      refute text =~ "metadata-secret"
      refute text =~ "provider-secret"
      refute text =~ "transport-secret"
      refute text =~ "config-secret"
    end
  end

  defp attributes do
    %{
      "kind" => "google_workstations",
      "deployment_id" => "isolated-deployment",
      "provider" => %{
        "project" => "project-a",
        "location" => "region-a",
        "cluster" => "cluster-a",
        "config" => "config-a",
        "credential_configuration" => "/operator/credentials.json",
        "impersonate_service_account" => "worker@example.test",
        "ssh_user" => "worker",
        "access_token" => "config-secret"
      },
      "startup_timeout_ms" => 60_000,
      "shutdown_timeout_ms" => 120_000
    }
  end

  defp settings do
    %{worker: %{environment: attributes()}, workspace: %{root: "/workspaces"}, tracker: %{kind: "linear"}}
  end

  defp kubernetes_provider do
    %{"kubeconfig" => "/operator/kubeconfig", "context" => "test", "namespace" => "workers", "template" => "/operator/template.yaml", "ssh_user" => "worker", "ssh_auth_volume" => "operator-key", "ssh_port" => 2222}
  end

  defp record(config) do
    %Record{
      key: Environment.resource_key(config.deployment_id, config.tracker_kind, "opaque:issue"),
      deployment_id: config.deployment_id,
      tracker_kind: config.tracker_kind,
      issue_id: "opaque:issue",
      kind: config.kind,
      scope: Map.take(config.provider, ["project", "location", "cluster"]),
      workspace_path: "/workspaces/persisted-ticket",
      template_identity: "persisted-template-v1",
      phase: :running
    }
  end

  defp connection do
    %Connection{target: %Target{executable: "/usr/bin/ssh", prefix: ["-i", "transport-secret", "worker@localhost"], label: "managed-worker", env: [{"SECRET", "transport-secret"}]}, owner: self(), id: make_ref()}
  end
end
