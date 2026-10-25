defmodule Cardbox.View do
  @moduledoc """
  A saved view of a collection: how it shows (`type`), which records, in
  which order (`query`, `Cardbox.Query`'s wire format), and the options of
  its type.

  | Type | Shown with | Options |
  | --- | --- | --- |
  | `table` | Masu | `columns` (field keys, in order), `hidden`, `widths` (`%{key => px}`) |
  | `board` | Narabe | `group_by` (a select, status, person or checkbox field), `hidden_groups`, `card_fields` |
  | `list` | Narabe | `fields` |
  | `calendar` | Koyomi | `date_field` (a date field) |
  | `chart` | Fude | `spec` (a `Fude.Spec` map) |
  | `canvas` | Hakushi | `layout` (`%{record_id => %{"x" => x, "y" => y}}`), `edges` (a relation field) |

  A view with no `owner` is shared with everyone who has the collection;
  a view with an owner (a person's id) is theirs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(table board list calendar chart canvas)

  @type t :: %__MODULE__{
          id: integer() | nil,
          collection_id: integer() | nil,
          name: String.t(),
          type: String.t(),
          query: map(),
          options: map(),
          owner: String.t() | nil,
          position: String.t() | nil
        }

  schema "cardbox_views" do
    belongs_to :collection, Cardbox.Collection
    field :name, :string
    field :type, :string, default: "table"
    field :query, :map, default: %{}
    field :options, :map, default: %{}
    field :owner, :string
    field :position, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The types of views."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc false
  def changeset(view, attrs) do
    view
    |> cast(attrs, [:name, :type, :query, :options, :owner])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :type])
    |> validate_length(:name, max: 100)
    |> validate_inclusion(:type, @types, message: "is one of #{Enum.join(@types, ", ")}")
  end
end
