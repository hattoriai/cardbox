defmodule Mix.Tasks.Cardbox.Gen.Migration do
  @shortdoc "Writes the migration of Cardbox's tables"

  @moduledoc """
  Writes the migration of the five tables where Cardbox keeps collections,
  their fields, their records, the links of their relations and their
  views.

      $ mix cardbox.gen.migration
      $ mix cardbox.gen.migration --migrations-path priv/other_repo/migrations

  Then run `mix ecto.migrate`.

  The tables are the same on PostgreSQL and SQLite. On PostgreSQL the
  records' values are `jsonb` with a GIN index, which the filters on
  multi-selects use, the search text has a trigram index (`pg_trgm`), and
  the position columns compare bytes (`Narabe.Migration`). On SQLite, a
  search reads the search text column as it is.

  ## Options

    * `--migrations-path` - where to write it, `priv/repo/migrations`
      unless given.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: [migrations_path: :string])
    dir = Keyword.get(opts, :migrations_path, "priv/repo/migrations")
    write(dir, Mix.Project.config()[:app], timestamp())
  end

  @doc false
  # Writes the migration to `dir`, and returns its path.
  @spec write(Path.t(), atom(), String.t()) :: Path.t()
  def write(dir, app, timestamp) do
    existing = Path.wildcard(Path.join(dir, "*_create_cardbox_tables.exs"))
    if existing != [], do: Mix.raise("a migration of Cardbox's tables exists: #{hd(existing)}")

    path = Path.join(dir, "#{timestamp}_create_cardbox_tables.exs")
    File.mkdir_p!(dir)
    File.write!(path, migration(app))
    Mix.shell().info("* creating #{path}")
    path
  end

  @doc false
  @spec migration(atom()) :: String.t()
  def migration(app) do
    app_module = app |> to_string() |> Macro.camelize()

    """
    defmodule #{app_module}.Repo.Migrations.CreateCardboxTables do
      use Ecto.Migration
      import Narabe.Migration

      # Cardbox's tables: collections, the fields of each, its records (their
      # values a JSON map by field key) and its saved views.
      def change do
        create table(:cardbox_collections) do
          add :owner_type, :string, size: 64
          add :owner_id, :string, size: 64
          add :name, :string, size: 200, null: false
          add :description, :text
          add :icon, :string, size: 64
          timestamps(type: :utc_datetime_usec)
        end

        create index(:cardbox_collections, [:owner_type, :owner_id])

        create table(:cardbox_fields) do
          add :collection_id, references(:cardbox_collections, on_delete: :delete_all), null: false
          add :key, :string, size: 64, null: false
          add :name, :string, size: 100, null: false
          add :type, :string, size: 32, null: false
          add :options, :map, null: false
          add :description, :text
          position()
          timestamps(type: :utc_datetime_usec)
        end

        create unique_index(:cardbox_fields, [:collection_id, :key])
        create index(:cardbox_fields, [:collection_id, :position])

        create table(:cardbox_records) do
          add :collection_id, references(:cardbox_collections, on_delete: :delete_all), null: false
          add :data, :map, null: false
          add :search_text, :text
          position()
          add :created_by, :string, size: 64
          add :updated_by, :string, size: 64
          timestamps(type: :utc_datetime_usec)
        end

        create index(:cardbox_records, [:collection_id, :position])

        # On PostgreSQL, an index of the values for the filters on lists, and
        # a trigram index of the search text for searches (pg_trgm, which
        # every PostgreSQL has, needs to be made once in each database).
        if repo().__adapter__() == Ecto.Adapters.Postgres do
          create index(:cardbox_records, [:data], using: "GIN")
          execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", ""
          create index(:cardbox_records, ["search_text gin_trgm_ops"], name: :cardbox_records_search_text_index, using: "GIN")
        end

        # The links of relations: from a record, by a field, to a record. Each
        # goes with its field and with either record.
        create table(:cardbox_links) do
          add :field_id, references(:cardbox_fields, on_delete: :delete_all), null: false
          add :record_id, references(:cardbox_records, on_delete: :delete_all), null: false
          add :target_id, references(:cardbox_records, on_delete: :delete_all), null: false
          add :position, :integer, null: false, default: 0
          timestamps(type: :utc_datetime_usec, updated_at: false)
        end

        create unique_index(:cardbox_links, [:field_id, :record_id, :target_id])
        create index(:cardbox_links, [:target_id, :field_id])
        create index(:cardbox_links, [:record_id])

        create table(:cardbox_views) do
          add :collection_id, references(:cardbox_collections, on_delete: :delete_all), null: false
          add :name, :string, size: 100, null: false
          add :type, :string, size: 32, null: false
          add :query, :map, null: false
          add :options, :map, null: false
          add :owner, :string, size: 64
          position()
          timestamps(type: :utc_datetime_usec)
        end

        create index(:cardbox_views, [:collection_id, :position])
      end
    end
    """
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, hh, mm, ss]) |> to_string()
  end
end
