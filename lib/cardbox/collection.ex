defmodule Cardbox.Collection do
  @moduledoc """
  A collection: records of one kind, with the same fields.

  A collection belongs to something of your app, its `owner`: a workspace,
  an account, a page. `owner_type` and `owner_id` say which, as text, so a
  collection belongs to a record of any table and id of any type:

      MyApp.Cardbox.create_collection(%{name: "Reading list", owner: {"workspace", 42}})

  `fields` are its fields in their order (`Cardbox.Field`), loaded with
  it. Every function of `use Cardbox` that changes the fields returns the
  collection as it is after.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          owner_type: String.t() | nil,
          owner_id: String.t() | nil,
          name: String.t(),
          description: String.t() | nil,
          icon: String.t() | nil,
          fields: [Cardbox.Field.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "cardbox_collections" do
    field :owner_type, :string
    field :owner_id, :string
    field :name, :string
    field :description, :string
    field :icon, :string
    has_many :fields, Cardbox.Field, preload_order: [asc: :position, asc: :id]
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:owner_type, :owner_id, :name, :description, :icon])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 200)
    |> validate_length(:description, max: 2000)
    |> validate_length(:icon, max: 64)
    |> validate_length(:owner_type, max: 64)
    |> validate_length(:owner_id, max: 64)
  end

  @doc """
  The field that names a record, as a relation shows it: the first text
  field, or nil.
  """
  @spec title_field(t()) :: Cardbox.Field.t() | nil
  def title_field(%__MODULE__{fields: fields}), do: Enum.find(fields, &(&1.type == "text"))

  @doc """
  The field of a collection with this key, or with this name (without case),
  or nil. A field struct is taken as itself.
  """
  @spec field(t(), term()) :: Cardbox.Field.t() | nil
  def field(%__MODULE__{}, %Cardbox.Field{} = field), do: field

  def field(%__MODULE__{fields: fields}, ref) when is_atom(ref) and not is_nil(ref),
    do: find(fields, Atom.to_string(ref))

  def field(%__MODULE__{fields: fields}, ref) when is_binary(ref), do: find(fields, ref)
  def field(%__MODULE__{}, _ref), do: nil

  defp find(fields, ref) do
    Enum.find(fields, &(&1.key == ref)) ||
      Enum.find(fields, &(String.downcase(&1.name) == String.downcase(ref)))
  end
end
