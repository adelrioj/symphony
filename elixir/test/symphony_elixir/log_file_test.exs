defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.LogFile

  test "default_log_file/0 uses the installation data root" do
    previous = Application.fetch_env(:symphony_elixir, :data_root)
    Application.put_env(:symphony_elixir, :data_root, "/tmp/symphony-root")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :data_root, value)
        :error -> Application.delete_env(:symphony_elixir, :data_root)
      end
    end)

    assert LogFile.default_log_file() == "/tmp/symphony-root/log/symphony.log"
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/symphony-logs") == "/tmp/symphony-logs/log/symphony.log"
  end
end
