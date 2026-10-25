defmodule Cardbox.Link do
  @moduledoc false
  # A link of a relation: from a record, by a field, to a record of the
  # field's collection. The database keeps links whole: a link goes with its
  # field and with either of its records.
  use Ecto.Schema

  schema "cardbox_links" do
    field :field_id, :integer
    field :record_id, :integer
    field :target_id, :integer
    field :position, :integer, default: 0
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule Cardbox.Links do
  @moduledoc false
  # Relations, kept in cardbox_links rather than in the records' data: read
  # into each record's data when records are read (so a relation's value is
  # a list of ids, as for any list), written apart from the data, and
  # filtered with EXISTS. A two-way relation's other side is a field of the
  # other collection that reads the same links from their targets.

  import Ecto.Query

  alias Cardbox.{Collection, Field, Link, Record}

  @doc "Whether a field is a relation, whose values are links."
  def relation?(%Field{type: "relation"}), do: true
  def relation?(_field), do: false

  @doc """
  The field whose links a relation reads, and from which side: its own from
  their records, or a two-way relation's from their targets.
  """
  def side(%Field{options: %{"reverse_of" => id}}) when is_integer(id), do: {id, :target}
  def side(%Field{id: id}), do: {id, :source}

  @doc "The records, with the ids of each relation's links in their data."
  def fill(_repo, _collection, []), do: []

  def fill(repo, %Collection{fields: fields}, records) do
    relations = Enum.filter(fields, &relation?/1)

    if relations == [] do
      records
    else
      ids = Enum.map(records, & &1.id)

      by_field =
        Map.new(relations, fn field ->
          {field.key, field |> links_of(ids) |> repo.all() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))}
        end)

      Enum.map(records, fn record ->
        data =
          Enum.reduce(by_field, record.data, fn {key, links}, data ->
            case Map.get(links, record.id, []) do
              [] -> Map.delete(data, key)
              targets -> Map.put(data, key, targets)
            end
          end)

        %{record | data: data}
      end)
    end
  end

  defp links_of(field, ids) do
    case side(field) do
      {id, :source} ->
        from(l in Link, where: l.field_id == ^id and l.record_id in ^ids, order_by: [l.position, l.id], select: {l.record_id, l.target_id})

      {id, :target} ->
        from(l in Link, where: l.field_id == ^id and l.target_id in ^ids, order_by: l.id, select: {l.target_id, l.record_id})
    end
  end

  @doc """
  Sets a record's links of a relation to these ids, in their order. Returns
  the records at the other end whose links changed: `{record_id, field_id,
  side}` of the side they see them from.
  """
  def put(repo, %Field{} = field, record_id, ids) do
    {link_field, side} = side(field)
    ids = ids || []

    before =
      case side do
        :source -> repo.all(from(l in Link, where: l.field_id == ^link_field and l.record_id == ^record_id, select: l.target_id))
        :target -> repo.all(from(l in Link, where: l.field_id == ^link_field and l.target_id == ^record_id, select: l.record_id))
      end

    case side do
      :source -> repo.delete_all(from(l in Link, where: l.field_id == ^link_field and l.record_id == ^record_id))
      :target -> repo.delete_all(from(l in Link, where: l.field_id == ^link_field and l.target_id == ^record_id))
    end

    now = DateTime.utc_now()

    rows =
      ids
      |> Enum.with_index()
      |> Enum.map(fn {id, i} ->
        {source, target} = if side == :source, do: {record_id, id}, else: {id, record_id}
        %{field_id: link_field, record_id: source, target_id: target, position: i, inserted_at: now}
      end)

    if rows != [], do: repo.insert_all(Link, rows)

    other_side = if side == :source, do: :target, else: :source
    changed = (before -- ids) ++ (ids -- before)
    Enum.map(Enum.uniq(changed), &{&1, link_field, other_side})
  end

  @doc """
  The records that link to a record, or that it links to: `{record_id,
  field_id, side}`, for the events of a record deleted.
  """
  def around(repo, record_id) do
    sources = repo.all(from(l in Link, where: l.target_id == ^record_id, select: {l.record_id, l.field_id}))
    targets = repo.all(from(l in Link, where: l.record_id == ^record_id, select: {l.target_id, l.field_id}))
    Enum.uniq(for({id, f} <- sources, do: {id, f, :source}) ++ for({id, f} <- targets, do: {id, f, :target}))
  end

  @doc "Every link of a relation, gone: for a field that stops being one."
  def delete_field_links(repo, %Field{id: id}), do: repo.delete_all(from(l in Link, where: l.field_id == ^id))

  @doc false
  # The keys of the fields that show links of a field from a side, in the
  # collection of a record: the relation itself, or its other side.
  def keys(fields, link_field, side) do
    for field <- fields, relation?(field), side(field) == {link_field, side}, do: field.key
  end

  @doc false
  def record_query(ids), do: from(r in Record, where: r.id in ^ids)
end
