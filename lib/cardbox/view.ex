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
  | `chart` | Fude | `kind`, `x` (and its `unit`), `y`, `color`, `title` (see `Cardbox.Fude`) |
  | `canvas` | Hakushi | `layout` (`%{record_id => %{"x" => x, "y" => y}}`), `edges` (a relation field) |

  A view with no `owner` is shared with everyone who has the collection;
  a view with an owner (a person's id) is theirs.

  An app adds types of its own (`use Cardbox, views: ["timeline"]`), whose
  options its `c:Cardbox.check_view/3` checks, and draws them itself: a
  view of any type has its query, and `list/3` of it gives its records.
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

  @doc "Cardbox's types of views."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc false
  # The types of views of an app's own (`use Cardbox, views: [...]`):
  # lowercase names that are not Cardbox's.
  def check_types!(types) do
    for type <- types do
      cond do
        not Cardbox.Key.valid?(type) ->
          raise ArgumentError,
                "a type of view is lowercase letters, digits and underscores, got: #{inspect(type)}"

        type in @types ->
          raise ArgumentError,
                "#{inspect(type)} is a type of view of Cardbox's own: name yours another way"

        true ->
          type
      end
    end
  end

  @doc false
  # `types` are the types the module takes: Cardbox's and its own.
  def changeset(view, attrs, types \\ @types) do
    view
    |> cast(attrs, [:name, :type, :query, :options, :owner])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :type])
    |> validate_length(:name, max: 100)
    |> validate_inclusion(:type, types, message: "is one of #{Enum.join(types, ", ")}")
  end
end
