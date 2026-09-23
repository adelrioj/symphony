defmodule SymphonyElixir.Maintenance do
  @moduledoc """
  Verifies the inherited Linux lock held by the actual controller or operator process.
  Environment context selects a route; only descriptor-specific flock evidence proves ownership.
  """

  import Bitwise

  @fd "/proc/self/fd/200"
  @fdinfo "/proc/self/fdinfo/200"
  @lock_line ~r/^lock:\s+[0-9]+:\s+FLOCK\s+ADVISORY\s+WRITE\s+-?[0-9]+\s+([0-9a-fA-F]+):([0-9a-fA-F]+):([0-9]+)\s+0\s+EOF$/
  @modes [:controller, :operator, :offline]

  @spec verify(Path.t(), :controller | :operator | :offline) :: :ok | {:error, :maintenance_required}
  def verify(data_root, mode) when is_binary(data_root) and mode in @modes do
    root = Path.expand(data_root)
    directory = Path.join(root, ".maintenance")
    lock = Path.join(directory, "controller.lock")

    with {:unix, :linux} <- :os.type(),
         "200" <- System.get_env("SYMPHONY_MAINTENANCE_FD"),
         ^root <- System.get_env("SYMPHONY_CONTROLLER_DATA_ROOT"),
         true <- System.get_env("SYMPHONY_MAINTENANCE_MODE") == Atom.to_string(mode),
         {:ok, uid, gid} <- filesystem_identity(),
         {:ok, root_info} <- File.lstat(root),
         true <- safe_root?(root_info, uid, gid),
         true <- safe_parents?(Path.dirname(root), uid),
         {:ok, directory_info} <- File.lstat(directory),
         true <- private?(directory_info, :directory, 0o700, uid),
         {:ok, lock_info} <- File.lstat(lock),
         true <- private?(lock_info, :regular, 0o600, uid),
         {:ok, ^lock} <- File.read_link(@fd),
         {:ok, held_info} <- File.stat(@fd),
         true <- private?(held_info, :regular, 0o600, uid),
         true <- same_file?(held_info, lock_info),
         {:ok, evidence} <- File.read(@fdinfo),
         true <- valid_evidence?(evidence, held_info) do
      :ok
    else
      _ -> {:error, :maintenance_required}
    end
  end

  def verify(_data_root, _mode), do: {:error, :maintenance_required}

  @spec verify_managed(Path.t(), :controller | :operator | :offline) :: :ok | {:error, :maintenance_required}
  def verify_managed(data_root, mode) do
    if System.get_env("SYMPHONY_CONTROLLER_LOCK_REQUIRED") == "1", do: verify(data_root, mode), else: :ok
  end

  defp filesystem_identity do
    with {:ok, status} <- File.read("/proc/self/status"),
         true <- byte_size(status) <= 8192,
         [_, uid, uid] <- Regex.run(~r/^Uid:\s+[0-9]+\s+([0-9]+)\s+[0-9]+\s+([0-9]+)$/m, status),
         [_, gid, gid] <- Regex.run(~r/^Gid:\s+[0-9]+\s+([0-9]+)\s+[0-9]+\s+([0-9]+)$/m, status) do
      {:ok, String.to_integer(uid), String.to_integer(gid)}
    else
      _ -> :error
    end
  end

  defp safe_root?(info, uid, gid) do
    private_root = info.uid == uid and band(info.mode, 0o022) == 0
    pod_root = info.uid == 0 and info.gid == gid and band(info.mode, 0o002) == 0
    info.type == :directory and (private_root or pod_root)
  end

  defp safe_parents?(path, uid) do
    with {:ok, info} <- File.lstat(path),
         true <- info.type == :directory and info.uid in [0, uid],
         true <- band(info.mode, 0o022) == 0 or (info.uid == 0 and band(info.mode, 0o1000) != 0) do
      path == "/" or safe_parents?(Path.dirname(path), uid)
    else
      _ -> false
    end
  end

  defp private?(info, type, mode, uid) do
    info.type == type and info.uid == uid and band(info.mode, 0o7777) == mode and (type == :directory or info.links == 1)
  end

  defp same_file?(left, right), do: left.major_device == right.major_device and left.inode == right.inode

  defp valid_evidence?(evidence, info) when byte_size(evidence) <= 8192 do
    lines = String.split(evidence, "\n", trim: true)
    locks = Enum.filter(lines, &String.starts_with?(&1, "lock:"))
    inodes = Enum.filter(lines, &String.starts_with?(&1, "ino:"))
    flags = Enum.filter(lines, &String.starts_with?(&1, "flags:"))

    with [lock] <- locks,
         [inode] <- inodes,
         [flag] <- flags,
         ["ino:", value] <- String.split(inode),
         true <- value == Integer.to_string(info.inode),
         ["flags:", value] <- String.split(flag),
         {open_flags, ""} <- Integer.parse(value, 8),
         true <- band(open_flags, 0o2000000) == 0,
         [_, major, minor, inode] <- Regex.run(@lock_line, lock) do
      device = info.major_device
      major_device = bor(band(bsr(device, 8), 0xFFF), band(bsr(device, 32), 0xFFFFF000))
      minor_device = bor(band(device, 0xFF), band(bsr(device, 12), 0xFFFFFF00))
      String.to_integer(major, 16) == major_device and String.to_integer(minor, 16) == minor_device and String.to_integer(inode) == info.inode
    else
      _ -> false
    end
  end

  defp valid_evidence?(_evidence, _info), do: false
end
