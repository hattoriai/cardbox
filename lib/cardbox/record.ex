defmodule Cardbox.Record do
  @moduledoc """
  A record of a collection: its values, by field key, in `data`.

      %Cardbox.Record{id: 7, data: %{"title" => "Dune", "status" => "reading", "rating" => 5}}

  `data` holds the values as they are kept (`Cardbox.Type`): a day as text,
  a choice as its id, no key for an empty value. `get/3` reads a value for
  Elixir, and `to_map/2` gives every value by field name, as an agent or a
  JSON API takes them.

  `search_text` is the words of its texts and of its choices' names,
  without case and accents, that a search looks in; Cardbox writes it with
  the values.

  `position` is the record's place in the collection's own order (Narabe's
  position keys), the order of a view with no sort. `created_by` and
  `updated_by` are the ids of who made it and who changed it last.
  """

  use Ecto.Schema

  alias Cardbox.{Collection, Type}

  @type t :: %__MODULE__{
          id: integer() | nil,
          collection_id: integer() | nil,
          data: map(),
          search_text: String.t() | nil,
          position: String.t() | nil,
          created_by: String.t() | nil,
          updated_by: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "cardbox_records" do
    belongs_to :collection, Cardbox.Collection
    field :data, :map, default: %{}
    field :search_text, :string
    field :position, :string
    field :created_by, :string
    field :updated_by, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The value of a field of the record, read for Elixir (`Cardbox.Type.load/2`).
  `field` is a field, its key or its name.
  """
  @spec get(t(), Collection.t(), term()) :: term()
  def get(%__MODULE__{} = record, %Collection{} = collection, field) do
    case Collection.field(collection, field) do
      nil -> raise ArgumentError, "the collection has no field #{inspect(field)}"
      field -> value(record, field)
    end
  end

  @doc false
  def value(record, %{type: "created_at"}), do: record.inserted_at
  def value(record, %{type: "updated_at"}), do: record.updated_at
  def value(record, %{type: "created_by"}), do: record.created_by
  def value(record, %{type: "updated_by"}), do: record.updated_by
  def value(record, field), do: Type.load(field, Map.get(record.data, field.key))

  @doc """
  Every value of the record, by field name (or by key, with `by: :key`),
  as JSON takes them: a day as `"2026-10-25"`, a choice as its name, and
  the record's `"id"`.
  """
  @spec to_map(t(), Collection.t(), keyword()) :: map()
  def to_map(%__MODULE__{} = record, %Collection{fields: fields}, opts \\ []) do
    by = Keyword.get(opts, :by, :name)

    Map.new(fields, fn field ->
      value =
        case field.type do
          type when type in ~w(created_at updated_at) -> DateTime.to_iso8601(value(record, field))
          type when type in ~w(created_by updated_by) -> value(record, field)
          # Where each file is and what it is, not only its name.
          "file" -> Map.get(record.data, field.key)
          _ -> Type.plain(field, Map.get(record.data, field.key))
        end

      {if(by == :key, do: field.key, else: field.name), value}
    end)
    |> Map.put("id", record.id)
  end
end
