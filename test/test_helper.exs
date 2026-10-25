# The tests run on SQLite, in a file of their own, with no setup; with
# DATABASE_URL they run on PostgreSQL, as CI does too:
#
#     DATABASE_URL=postgres://postgres:postgres@localhost/cardbox_test mix test
repo =
  if url = System.get_env("DATABASE_URL") do
    Application.put_env(:cardbox, CardboxTest.PostgresRepo,
      url: url,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 10,
      log: false
    )

    config = Ecto.Repo.Supervisor.parse_url(url)
    _ = Ecto.Adapters.Postgres.storage_down(config)
    :ok = Ecto.Adapters.Postgres.storage_up(config)
    CardboxTest.PostgresRepo
  else
    path = Path.expand("../tmp/cardbox_test.db", __DIR__)
    File.mkdir_p!(Path.dirname(path))
    for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)

    Application.put_env(:cardbox, CardboxTest.SQLiteRepo,
      database: path,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 2,
      log: false
    )

    CardboxTest.SQLiteRepo
  end

{:ok, _pid} = repo.start_link()
{:ok, _pid} = Phoenix.PubSub.Supervisor.start_link(name: CardboxTest.PubSub)
Application.put_env(:cardbox, :test_repo, repo)

# The tables, from the migration mix cardbox.gen.migration writes.
[{migration, _}] = Code.compile_string(Mix.Tasks.Cardbox.Gen.Migration.migration(:cardbox_test))
Ecto.Migrator.up(repo, 1, migration, log: false)

ExUnit.start()
