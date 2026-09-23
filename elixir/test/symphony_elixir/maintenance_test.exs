defmodule SymphonyElixir.MaintenanceTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Maintenance

  @context ~w(SYMPHONY_CONTROLLER_LOCK_REQUIRED SYMPHONY_CONTROLLER_DATA_ROOT SYMPHONY_MAINTENANCE_FD SYMPHONY_MAINTENANCE_MODE)

  setup do
    previous = Map.new(@context, &{&1, System.get_env(&1)})
    Enum.each(@context, &System.delete_env/1)
    root = Path.join(System.tmp_dir!(), "symphony-maintenance-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "strict verification rejects absent ownership even outside managed images", %{root: root} do
    assert {:error, :maintenance_required} = Maintenance.verify(root, :operator)
    assert :ok = Maintenance.verify_managed(root, :controller)
    System.put_env("SYMPHONY_CONTROLLER_LOCK_REQUIRED", "1")
    assert {:error, :maintenance_required} = Maintenance.verify_managed(root, :controller)
  end

  test "a complete environment context is not a held descriptor", %{root: root} do
    System.put_env("SYMPHONY_CONTROLLER_DATA_ROOT", root)
    System.put_env("SYMPHONY_MAINTENANCE_FD", "200")
    System.put_env("SYMPHONY_MAINTENANCE_MODE", "operator")
    assert {:error, :maintenance_required} = Maintenance.verify(root, :operator)
  end

  @tag :linux
  @tag skip: if(:os.type() == {:unix, :linux}, do: false, else: "requires Linux flock and procfs")
  test "BEAM verifies the inherited open description, not another lock on its inode", %{root: root} do
      source = Path.expand("../../lib/symphony_elixir/maintenance.ex", __DIR__)

      program = """
      import fcntl, json, os, pathlib, subprocess, sys
      root = pathlib.Path(sys.argv[1]).resolve()
      directory = root / '.maintenance'
      directory.mkdir(mode=0o700)
      lock = directory / 'controller.lock'
      fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
      os.dup2(fd, 200, inheritable=True)
      os.environ.update(SYMPHONY_CONTROLLER_DATA_ROOT=str(root), SYMPHONY_MAINTENANCE_FD='200', SYMPHONY_MAINTENANCE_MODE='operator')
      expression = 'IO.inspect(SymphonyElixir.Maintenance.verify(System.get_env("SYMPHONY_CONTROLLER_DATA_ROOT"), :operator))'
      def check(expected):
          child = subprocess.run(['elixir', '-r', sys.argv[2], '-e', expression], pass_fds=(200,), capture_output=True, text=True, timeout=30)
          assert child.returncode == 0, child.stderr
          assert child.stdout.strip() == expected, child.stdout + child.stderr
      check(':ok')
      other = root / 'other'
      (other / 'child').mkdir(mode=0o700, parents=True)
      (root / 'redirect').symlink_to(other / 'child')
      original_expression = expression
      expression = 'IO.inspect(SymphonyElixir.Maintenance.verify(' + json.dumps(str(root / 'redirect' / '..')) + ', :operator))'
      check('{:error, :maintenance_required}')
      expression = original_expression
      os.environ['SYMPHONY_MAINTENANCE_MODE'] = 'controller'
      check('{:error, :maintenance_required}')
      os.environ['SYMPHONY_MAINTENANCE_MODE'] = 'operator'
      lock.chmod(0o644)
      check('{:error, :maintenance_required}')
      lock.chmod(0o600)
      reopened = os.open(lock, os.O_RDWR)
      os.dup2(reopened, 200, inheritable=True)
      check('{:error, :maintenance_required}')
      """

      {output, status} = System.cmd("python3", ["-c", program, root, source], stderr_to_stdout: true)
      assert status == 0, output
  end
end
