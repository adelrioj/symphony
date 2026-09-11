defmodule SymphonyElixir.SSHTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SSH

  test "structured targets preserve shell arguments without local interpolation" do
    target = %SSH.Target{executable: "/bin/sh", prefix: ["-c"], label: "fixture"}
    assert {:ok, {"literal ' quote\n", 0}} =
             SSH.run(target, "printf '%s\\n' \"literal ' quote\"")
  end

  test "structured target environment is process scoped and ignores global SSH configuration" do
    previous = System.get_env("SYMPHONY_SSH_CONFIG")
    on_exit(fn -> restore_env("SYMPHONY_SSH_CONFIG", previous) end)
    System.put_env("SYMPHONY_SSH_CONFIG", "/nonexistent/global-config")
    target = %SSH.Target{executable: "/bin/sh", prefix: ["-c"], label: "fixture", env: [{"SYMPHONY_TARGET_VALUE", "private"}]}
    assert {:ok, {"private", 0}} = SSH.run(target, "printf '%s' \"$SYMPHONY_TARGET_VALUE\"")
    assert System.get_env("SYMPHONY_TARGET_VALUE") == nil
  end

  test "run/3 keeps bracketed IPv6 host:port targets intact" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@[::1]:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@[::1] bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 leaves unbracketed IPv6-style targets unchanged" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-raw-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("::1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T ::1:2200 bash -lc"
    refute trace =~ "-p 2200"
  end

  test "run/3 passes host:port targets through ssh -p" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)
    System.put_env("SYMPHONY_SSH_CONFIG", "/tmp/symphony-test-ssh-config")

    assert {:ok, {"", 0}} =
             SSH.run("localhost:2222", "echo ready", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-F /tmp/symphony-test-ssh-config"
    assert trace =~ "-T -p 2222 localhost bash -lc"
    assert trace =~ "echo ready"
  end

  test "run/3 keeps the user prefix when parsing user@host:port targets" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-user-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@127.0.0.1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@127.0.0.1 bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 returns an error when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)

    assert {:error, :ssh_not_found} = SSH.run("localhost", "printf ok")
  end

  test "start_port/3 carries binary stdin and exit status through a structured target" do
    target = %SSH.Target{executable: "/bin/sh", prefix: ["-c"], label: "fixture"}
    assert {:ok, port} = SSH.start_port(target, "dd bs=1 count=5 2>/dev/null; exit 7")
    assert :ok = SSH.write_stdin(port, <<0, 1, 2, 3, 255>>)
    assert receive_binary(port, <<>>) == {<<0, 1, 2, 3, 255>>, 7}
  end

  test "start_port/3 carries line-mode stdin and target environment" do
    target = %SSH.Target{executable: "/bin/sh", prefix: ["-c"], label: "fixture", env: [{"SYMPHONY_TARGET_VALUE", "remote"}]}
    assert {:ok, port} = SSH.start_port(target, "read -r value; printf '%s:%s\\n' \"$SYMPHONY_TARGET_VALUE\" \"$value\"", line: 256)
    assert :ok = SSH.write_stdin(port, "literal ' quote\n")
    assert_receive {^port, {:data, {:eol, "remote:literal ' quote"}}}, 5_000
    assert_receive {^port, {:exit_status, 0}}, 5_000
  end

  test "write_stdin/2 writes to live ports and reports closed ports" do
    live_port = Port.open({:spawn, "cat >/dev/null"}, [:binary])
    assert :ok = SSH.write_stdin(live_port, "hello")
    Port.close(live_port)

    closed_port = Port.open({:spawn, "true"}, [:exit_status])

    receive do
      {^closed_port, {:exit_status, 0}} -> :ok
    after
      500 -> flunk("expected fake port to exit")
    end

    assert SSH.write_stdin(closed_port, "hello") == {:error, :closed}
  end

  defp receive_binary(port, output) do
    receive do
      {^port, {:data, chunk}} -> receive_binary(port, output <> chunk)
      {^port, {:exit_status, status}} -> {output, status}
    after
      5_000 -> flunk("transport did not finish")
    end
  end

  defp install_fake_ssh!(test_root, trace_file, script \\ nil) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(
      fake_ssh,
      script ||
        """
        #!/bin/sh
        printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
        exit 0
        """
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end


  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
