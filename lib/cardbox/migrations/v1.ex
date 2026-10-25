defmodule Cardbox.Migrations.V1 do
  @moduledoc false
  # Version 1: the five tables of collections, their fields, records, the
  # links of their relations and their views. Run by Cardbox.Migrations,
  # inside the app's migration.

  use Ecto.Migration
  import Narabe.Migration

  @spec up() :: :ok
  def up do
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
      execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

      create index(:cardbox_records, ["search_text gin_trgm_ops"],
               name: :cardbox_records_search_text_index,
               using: "GIN"
             )
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
    :ok
  end

  # The extension stays: other tables of the app may use it.
  @spec down() :: :ok
  def down do
    drop table(:cardbox_views)
    drop table(:cardbox_links)
    drop table(:cardbox_records)
    drop table(:cardbox_fields)
    drop table(:cardbox_collections)
    :ok
  end
end
