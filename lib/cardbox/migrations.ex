defmodule Cardbox.Migrations do
  @moduledoc """
  Cardbox's tables, in versions, for the migrations of your app.

      $ mix cardbox.gen.migration

  writes a migration that pins the latest version:

      defmodule MyApp.Repo.Migrations.AddCardbox do
        use Ecto.Migration

        def up, do: Cardbox.Migrations.up(version: 1)
        def down, do: Cardbox.Migrations.down(to: 0)
      end

  A later Cardbox that changes the tables has a new version, and
  `mix cardbox.gen.migration` writes the migration that takes them there,
  from the version your migrations already pin:

      def up, do: Cardbox.Migrations.up(version: 2)
      def down, do: Cardbox.Migrations.down(to: 1)

  So a migration, once written, does the same thing whichever Cardbox
  runs it: your history is the same for a new developer, in CI and in
  production. The version a database is at is kept in a table of one row,
  `cardbox_schema`, and `up/1` runs only the versions after it, so the
  migrations of an app that made the tables another way run once.

  The versions run on PostgreSQL and on SQLite.

  ## Versions

    1. The five tables: `cardbox_collections`, `cardbox_fields`,
       `cardbox_records` (the values a JSON map, with a GIN index and a
       trigram index of the search text on PostgreSQL), `cardbox_links`
       and `cardbox_views`.
  """

  use Ecto.Migration

  @versions [Cardbox.Migrations.V1]
  @latest length(@versions)
  @table "cardbox_schema"

  @doc "The latest version of Cardbox's tables."
  @spec latest_version() :: pos_integer()
  def latest_version, do: @latest

  @doc """
  Takes the tables up to `:version` (the latest unless given: pin it, as
  `mix cardbox.gen.migration` does). Call it in a migration.
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    target = Keyword.get(opts, :version, @latest)

    if target not in 1..@latest//1 do
      raise ArgumentError,
            "Cardbox has the versions 1 to #{@latest} of its tables, not #{inspect(target)}"
    end

    query!("CREATE TABLE IF NOT EXISTS #{@table} (version INTEGER NOT NULL)")
    current = tracked(repo())

    if current < target do
      for {module, version} <- range(current, target) do
        module.up()
        flush()
        record!(version)
      end
    end

    :ok
  end

  @doc """
  Takes the tables back down to `:to` (`0`, no tables, unless given). Call
  it in a migration.
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    if Keyword.has_key?(opts, :version) do
      raise ArgumentError,
            "Cardbox.Migrations.down/1 takes :to, the version to go back to: " <>
              "down(to: 1) undoes the versions after 1"
    end

    target = Keyword.get(opts, :to, 0)
    current = migrated_version(repo())

    for {module, version} <- Enum.reverse(range(target, current)) do
      module.down()
      flush()
      record!(version - 1)
    end

    :ok
  end

  @doc """
  The version the tables of a repo are at: `0` before Cardbox's migration
  has run.
  """
  @spec migrated_version(Ecto.Repo.t()) :: non_neg_integer()
  def migrated_version(repo) do
    if tracking?(repo), do: tracked(repo), else: 0
  end

  @doc """
  `:ok` when the tables of a repo are at the latest version, else an
  error that says which migration to write: for a release check, or a
  health check of your app.
  """
  @spec check(Ecto.Repo.t()) :: :ok | {:error, String.t()}
  def check(repo) do
    case migrated_version(repo) do
      @latest ->
        :ok

      version ->
        {:error,
         "Cardbox's tables are at version #{version}, and this Cardbox has version #{@latest}: " <>
           "run `mix cardbox.gen.migration`, then `mix ecto.migrate`"}
    end
  end

  # The versions after `current`, up to `target`, oldest first.
  defp range(current, target) do
    @versions
    |> Enum.with_index(1)
    |> Enum.filter(fn {_module, version} -> version > current and version <= target end)
  end

  defp tracking?(repo) do
    sql =
      case repo.__adapter__() do
        Ecto.Adapters.Postgres ->
          "SELECT 1 FROM pg_tables WHERE schemaname = current_schema() AND tablename = '#{@table}'"

        _sqlite ->
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '#{@table}'"
      end

    repo.query!(sql, [], log: false).rows != []
  end

  defp tracked(repo) do
    case repo.query!("SELECT version FROM #{@table}", [], log: false).rows do
      [[version] | _] -> version
      [] -> 0
    end
  end

  # The version done, in the one row of the table; at 0, no table.
  defp record!(0), do: query!("DROP TABLE IF EXISTS #{@table}")

  defp record!(version) when is_integer(version) do
    query!("DELETE FROM #{@table}")
    query!("INSERT INTO #{@table} (version) VALUES (#{version})")
  end

  defp query!(sql), do: repo().query!(sql, [], log: false)
end
