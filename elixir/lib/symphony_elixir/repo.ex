defmodule SymphonyElixir.Repo do
  @moduledoc """
  SQLite storage for lanes and run history under the installation data root.

  Migrations are compiled modules so Mix and OTP releases do not need a separate
  migrations directory. SQLite's native library must be available at runtime.
  """

  use Ecto.Repo, otp_app: :symphony_elixir, adapter: Ecto.Adapters.SQLite3

  alias SymphonyElixir.Config

  @migrations [
    {20_260_912_000_001, SymphonyElixir.Repo.Migrations.CreateLanesAndRuns}
  ]

  @impl true
  def init(_context, config) do
    config =
      config
      |> Keyword.put_new_lazy(:database, fn -> Path.join(Config.data_root(), "symphony.sqlite3") end)
      |> Keyword.put_new(:pool_size, 1)
      |> Keyword.put_new(:journal_mode, :wal)
      |> Keyword.put_new(:busy_timeout, 5_000)

    case Keyword.fetch!(config, :database) do
      ":memory:" -> :ok
      database -> database |> Path.dirname() |> File.mkdir_p!()
    end

    {:ok, config}
  end

  @doc "Runs pending migrations, temporarily starting the repository if necessary."
  @spec migrate() :: :ok
  def migrate do
    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(
        __MODULE__,
        fn repo -> Ecto.Migrator.run(repo, @migrations, :up, all: true, log: false) end,
        pool_size: 1
      )

    :ok
  end
end
