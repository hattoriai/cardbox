defmodule Cardbox.Field do
  @moduledoc """
  A field of a collection: its `name`, its `type` (`Cardbox.Type`) and
  that type's `options`.

  `key` is made from the name when the field is added (`"Due date"` is
  `due_date`) and never changes: a record keeps its values under their
  fields' keys, and a saved view names fields by key, so a field renamed
  is renamed everywhere at once. Queries and writes take a field's key or
  its name.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          collection_id: integer() | nil,
          key: String.t(),
          name: String.t(),
          type: String.t(),
          options: map(),
          description: String.t() | nil,
          position: String.t() | nil
        }

  schema "cardbox_fields" do
    belongs_to :collection, Cardbox.Collection
    field :key, :string
    field :name, :string
    field :type, :string
    field :options, :map, default: %{}
    field :description, :string
    field :position, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(field, attrs) do
    field
    |> cast(attrs, [:name, :type, :options, :description])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :type])
    |> validate_length(:name, max: 100)
    |> validate_length(:description, max: 2000)
    |> validate_inclusion(:type, Cardbox.Type.names(),
      message: "is one of #{Enum.join(Cardbox.Type.names(), ", ")}"
    )
  end

  @doc "The field's choices, for a select, a multi-select or a status; `[]` for others."
  @spec choices(t()) :: [map()]
  def choices(%__MODULE__{options: options}), do: options["choices"] || []
end
