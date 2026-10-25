defmodule Cardbox.MigrationsTest do
  # The versions run on a database of their own, made for this test, on
  # SQLite or (with DATABASE_URL) on PostgreSQL.
  use ExUnit.Case, async: false

  alias Cardbox.MigrationsTest.{PostgresRepo, SQLiteRepo}
  alias Ecto.Adapters.Postgres
  alias Ecto.Repo.Supervisor, as: RepoSupervisor
  alias Mix.Tasks.Cardbox.Gen.Migration

  defmodule SQLiteRepo do
    use Ecto.Repo, otp_app: :cardbox, adapter: Ecto.Adapters.SQLite3
  end

  defmodule PostgresRepo do
    use Ecto.Repo, otp_app: :cardbox, adapter: Ecto.Adapters.Postgres
  end

  @tables ~w(cardbox_collections cardbox_fields cardbox_records cardbox_links cardbox_views)

  setup_all do
    repo =
      if url = System.get_env("DATABASE_URL") do
        url = String.replace(url, ~r{/([^/?]+)(\?|$)}, "/\\1_migrations\\2")
        config = [url: url, pool_size: 2, log: false]
        Application.put_env(:cardbox, PostgresRepo, config)
        parsed = RepoSupervisor.parse_url(url)
        _ = Postgres.storage_down(parsed)
        :ok = Postgres.storage_up(parsed)
        PostgresRepo
      else
        path = Path.expand("../../tmp/cardbox_migrations.db", __DIR__)
        for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
        Application.put_env(:cardbox, SQLiteRepo, database: path, pool_size: 1, log: false)
        SQLiteRepo
      end

    {:ok, pid} = repo.start_link()
    on_exit(fn -> Process.exit(pid, :normal) end)
    %{repo: repo}
  end

  defp migration(app, from, to) do
    {_name, source} = Migration.migration(app, from, to)
    [{module, _}] = Code.compile_string(source)
    module
  end

  defp tables(repo) do
    sql =
      if repo == PostgresRepo,
        do: "SELECT tablename FROM pg_tables WHERE schemaname = current_schema()",
        else: "SELECT name FROM sqlite_master WHERE type = 'table'"

    repo.query!(sql).rows |> List.flatten() |> Enum.filter(&String.starts_with?(&1, "cardbox_"))
  end

  test "a version up, down and up again", %{repo: repo} do
    add = migration(:migrations_a, 0, 1)
    assert Cardbox.Migrations.migrated_version(repo) == 0
    assert {:error, message} = Cardbox.Migrations.check(repo)
    assert message =~ "mix cardbox.gen.migration"

    Ecto.Migrator.up(repo, 1, add, log: false)
    assert Cardbox.Migrations.migrated_version(repo) == 1
    assert Cardbox.Migrations.check(repo) == :ok
    assert Enum.sort(tables(repo)) == Enum.sort(["cardbox_schema" | @tables])

    # A second migration that pins the version the tables are at runs nothing.
    again = migration(:migrations_b, 0, 1)
    Ecto.Migrator.up(repo, 2, again, log: false)
    assert Cardbox.Migrations.migrated_version(repo) == 1

    Ecto.Migrator.down(repo, 2, again, log: false)
    assert Cardbox.Migrations.migrated_version(repo) == 0
    assert tables(repo) == []

    Ecto.Migrator.down(repo, 1, add, log: false)
    Ecto.Migrator.up(repo, 1, add, log: false)
    assert Cardbox.Migrations.migrated_version(repo) == 1

    Ecto.Migrator.down(repo, 1, add, log: false)
    assert tables(repo) == []
  end

  test "a version Cardbox does not have, or down/1 given :version, is refused" do
    assert_raise ArgumentError, ~r/versions 1 to 1/, fn -> Cardbox.Migrations.up(version: 2) end
    assert_raise ArgumentError, ~r/takes :to/, fn -> Cardbox.Migrations.down(version: 0) end
  end

  describe "mix cardbox.gen.migration" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cardbox_gen_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      %{dir: dir}
    end

    test "writes the latest version, then nothing", %{dir: dir} do
      path = Migration.write(dir, :my_app, "20261025000000")
      assert Path.basename(path) == "20261025000000_add_cardbox.exs"
      source = File.read!(path)
      assert source =~ "defmodule MyApp.Repo.Migrations.AddCardbox do"
      assert source =~ "def up, do: Cardbox.Migrations.up(version: 1)"
      assert source =~ "def down, do: Cardbox.Migrations.down(to: 0)"

      assert Migration.pinned_version(dir) == 1
      assert Migration.write(dir, :my_app, "20261025000001") == nil
      assert_received {:mix_shell, :info, ["Cardbox's tables are at version 1" <> _]}
    end

    test "an upgrade goes from the version pinned" do
      {name, source} = Migration.migration(:my_app, 1, 2)
      assert name == "upgrade_cardbox_to_v2"
      assert source =~ "Migrations.UpgradeCardboxToV2 do"
      assert source =~ "Cardbox.Migrations.up(version: 2)"
      assert source =~ "Cardbox.Migrations.down(to: 1)"
    end

    test "refuses a migration that pins no version", %{dir: dir} do
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "1_add.exs"), """
      defmodule MyApp.Repo.Migrations.Add do
        use Ecto.Migration
        def up, do: Cardbox.Migrations.up()
      end
      """)

      assert_raise Mix.Error, ~r/pin the version/, fn -> Migration.pinned_version(dir) end
    end
  end
end
