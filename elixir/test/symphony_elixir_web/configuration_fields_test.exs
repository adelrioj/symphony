defmodule SymphonyElixirWeb.ConfigurationFieldsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionProfiles.Configuration
  alias SymphonyElixirWeb.ConfigurationFields

  test "provider JSON must describe an object and failures retain the original worker" do
    original = %{"ssh_hosts" => ["existing-worker"]}

    for json <- ["[]", "null", "{"] do
      {attrs, errors} = ConfigurationFields.profile_attributes(Map.put(params(), "provider_json", json), original)
      assert Enum.any?(errors, &(&1.path == "worker.environment.provider"))
      assert attrs["worker"] == original
    end
  end

  test "unsupported worker modes cannot silently convert an existing worker to local" do
    original = %{"ssh_hosts" => ["existing-worker"]}
    {attrs, errors} = ConfigurationFields.profile_attributes(Map.put(params(), "worker_mode", "unknown"), original)
    assert Enum.any?(errors, &(&1.path == "worker_mode"))
    assert attrs["worker"] == original
  end

  test "required identity values reject blanks and nontext values" do
    for {field, value} <- [{"name", "  "}, {"name", nil}, {"workspace_base", false}] do
      {_attrs, errors} = ConfigurationFields.profile_attributes(Map.put(params(), field, value))
      assert Enum.any?(errors, &(&1.path == field))
    end
  end

  test "SSH concurrency limits reject fractional and nontext form values" do
    for limit <- ["1.5", 2] do
      input = Map.merge(params(), %{"worker_mode" => "ssh", "ssh_hosts" => "worker-a", "max_concurrent_agents_per_host" => limit})
      {_attrs, errors} = ConfigurationFields.profile_attributes(input)
      assert Enum.any?(errors, &(&1.path == "worker.max_concurrent_agents_per_host"))
    end
  end

  test "managed durations reject nontext values without replacing the worker" do
    input = Map.merge(params(), %{"worker_mode" => "managed", "startup_timeout" => 1})
    original = %{"ssh_hosts" => ["worker-a"]}
    {attrs, errors} = ConfigurationFields.profile_attributes(input, original)
    assert Enum.any?(errors, &(&1.path == "worker.environment.startup_timeout_ms"))
    assert attrs["worker"] == original
  end

  test "managed startup timeout zero survives exact conversion but fails domain validation" do
    input =
      Map.merge(params(), %{
        "worker_mode" => "managed",
        "environment_kind" => "kubernetes",
        "deployment_id" => "existing",
        "startup_timeout" => "0",
        "shutdown_timeout" => "2",
        "terminal_retention" => "0"
      })

    {attrs, []} = ConfigurationFields.profile_attributes(input)
    assert {:error, errors} = Configuration.validate_profile(attrs)
    assert Enum.any?(errors, &(&1.path == "worker.environment"))
  end

  defp params do
    %{"name" => "Worker", "description" => "", "workspace_base" => "/tmp/component-worker", "worker_mode" => "local", "provider_json" => "{}"}
  end
end
