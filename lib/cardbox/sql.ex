defmodule Cardbox.SQL do
  @moduledoc """
  A query's filter, search and sorts, in the SQL of the app's database: an
  `Ecto.Query` of `Cardbox.Record` that the database filters, sorts and
  counts, reading only the records it returns.

  The values of records are a JSON map (`jsonb` on PostgreSQL, JSON text on
  SQLite), read with the database's own JSON functions. Each value is read
  only when it is of the field's type, so a comparison never fails on a
  value of another type.

  Cardbox runs on PostgreSQL (`Ecto.Adapters.Postgres`) and SQLite
  (`Ecto.Adapters.SQLite3`, with its JSON functions, which every build of
  SQLite has had since 3.38). On SQLite, a search and `contains` compare
  without case only the letters of ASCII, as SQLite's `LIKE` does.
  """

  import Ecto.Query

  alias Cardbox.{Collection, Condition, Field, Query, Record, Sort}

  @type dialect :: :postgres | :sqlite

  @doc "The dialect of a repo's database."
  @spec dialect(module()) :: dialect()
  def dialect(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> :postgres
      Ecto.Adapters.SQLite3 -> :sqlite
      other -> raise ArgumentError, "Cardbox runs on PostgreSQL and SQLite, not #{inspect(other)}"
    end
  end

  @doc """
  The records of a collection that meet a query, in its order: an
  `Ecto.Query` to read, count or narrow further.

  `opts`: `:me`, `:time_zone` and `:now`, which the query's conditions are
  read with (see `Cardbox.Filter`).
  """
  @spec query(Collection.t(), Query.t(), dialect(), keyword()) :: Ecto.Query.t()
  def query(%Collection{} = collection, %Query{} = query, dialect, opts \\ []) do
    collection
    |> where_query(query, dialect, opts)
    |> order(query.sorts, collection, dialect)
  end

  @doc false
  # The records that meet the query, in no order: for counts and groups.
  def where_query(%Collection{id: id} = collection, %Query{} = query, dialect, opts) do
    condition = Condition.lower(query, collection, Condition.context(opts))

    from(r in Record, as: :record, where: r.collection_id == ^id)
    |> where(^condition(condition, dialect))
  end

  @doc false
  def condition(true, _dialect), do: dynamic(true)
  def condition(false, _dialect), do: dynamic(false)

  def condition({:and, items}, dialect) do
    Enum.reduce(items, dynamic(true), fn item, acc -> dynamic(^acc and ^condition(item, dialect)) end)
  end

  def condition({:or, items}, dialect) do
    Enum.reduce(items, dynamic(false), fn item, acc -> dynamic(^acc or ^condition(item, dialect)) end)
  end

  def condition({:not, inner}, dialect), do: dynamic(not (^condition(inner, dialect)))
  def condition({:empty, ref}, dialect), do: empty(ref, dialect)
  def condition({:has, ref, value}, dialect), do: has(ref, value, dialect)

  def condition({:like, ref, mode, text}, dialect) do
    escaped = String.replace(text, ~r/([\\%_])/, "\\\\\\1")

    pattern =
      case mode do
        :contains -> "%" <> escaped <> "%"
        :starts_with -> escaped <> "%"
        :ends_with -> "%" <> escaped
      end

    expr = value(ref, dialect)

    case dialect do
      :postgres -> dynamic(fragment("? ILIKE ? ESCAPE '\\'", ^expr, ^pattern))
      :sqlite -> dynamic(fragment("? LIKE ? ESCAPE '\\'", ^expr, ^pattern))
    end
  end

  # A ticked checkbox is JSON's true, which neither database binds as a
  # parameter the way it reads it from JSON.
  def condition({:cmp, {:data, key, :boolean}, :eq, true}, :postgres),
    do: dynamic([record: r], fragment("coalesce((?->?) = 'true'::jsonb, false)", r.data, ^key))

  def condition({:cmp, {:data, key, :boolean}, :eq, true}, :sqlite),
    do: dynamic([record: r], fragment("coalesce(json_type(?, ?) = 'true', false)", r.data, ^path(key)))

  def condition({:cmp, ref, op, value}, dialect) do
    expr = value(ref, dialect)
    value = param(ref, value, dialect)

    case op do
      :eq -> dynamic(^expr == ^value)
      :neq -> dynamic(^expr != ^value)
      :lt -> dynamic(^expr < ^value)
      :lte -> dynamic(^expr <= ^value)
      :gt -> dynamic(^expr > ^value)
      :gte -> dynamic(^expr >= ^value)
    end
  end

  # A value of a record, as its kind reads it, or NULL when it is of another
  # type (or none).
  defp value({:column, column, _kind}, _dialect), do: dynamic([record: r], field(r, ^column))

  defp value({:data, key, kind}, :postgres) do
    case kind do
      :number ->
        dynamic([record: r], fragment("(CASE WHEN jsonb_typeof(?->?) = 'number' THEN (?->>?)::numeric END)", r.data, ^key, r.data, ^key))

      :boolean ->
        dynamic([record: r], fragment("(CASE WHEN jsonb_typeof(?->?) = 'boolean' THEN (?->>?)::boolean END)", r.data, ^key, r.data, ^key))

      date when date in [:date, :datetime] ->
        dynamic([record: r], fragment("(CASE WHEN jsonb_typeof(?->?) = 'string' THEN (?->>?) END) COLLATE \"C\"", r.data, ^key, r.data, ^key))

      _text ->
        dynamic([record: r], fragment("(CASE WHEN jsonb_typeof(?->?) = 'string' THEN (?->>?) END)", r.data, ^key, r.data, ^key))
    end
  end

  defp value({:data, key, kind}, :sqlite) do
    path = path(key)

    case kind do
      :number ->
        dynamic([record: r], fragment("(CASE WHEN json_type(?, ?) IN ('integer', 'real') THEN json_extract(?, ?) END)", r.data, ^path, r.data, ^path))

      :boolean ->
        dynamic([record: r], fragment("(CASE WHEN json_type(?, ?) IN ('true', 'false') THEN json_extract(?, ?) END)", r.data, ^path, r.data, ^path))

      _text ->
        dynamic([record: r], fragment("(CASE WHEN json_type(?, ?) = 'text' THEN json_extract(?, ?) END)", r.data, ^path, r.data, ^path))
    end
  end

  defp empty({:column, column, _kind}, _dialect), do: dynamic([record: r], is_nil(field(r, ^column)))

  defp empty({:data, key, _kind}, :postgres) do
    dynamic([record: r], fragment("coalesce((?->?) IN ('null'::jsonb, '\"\"'::jsonb, '[]'::jsonb), true)", r.data, ^key))
  end

  defp empty({:data, key, _kind}, :sqlite) do
    path = path(key)

    dynamic(
      [record: r],
      fragment(
        "coalesce(json_type(?, ?) = 'null' OR (json_type(?, ?) = 'text' AND json_extract(?, ?) = '') OR (json_type(?, ?) = 'array' AND json_array_length(?, ?) = 0), true)",
        r.data, ^path, r.data, ^path, r.data, ^path, r.data, ^path, r.data, ^path
      )
    )
  end

  defp has({:data, key, _kind}, value, :postgres) when is_integer(value) do
    dynamic([record: r], fragment("coalesce((?->?) @> jsonb_build_array(?::bigint), false)", r.data, ^key, ^value))
  end

  defp has({:data, key, _kind}, value, :postgres) do
    dynamic([record: r], fragment("coalesce((?->?) @> jsonb_build_array(?::text), false)", r.data, ^key, ^value))
  end

  defp has({:data, key, _kind}, value, :sqlite) do
    path = path(key)

    dynamic(
      [record: r],
      fragment(
        "coalesce(json_type(?, ?) = 'array' AND EXISTS (SELECT 1 FROM json_each(?, ?) WHERE value = ?), false)",
        r.data, ^path, r.data, ^path, ^value
      )
    )
  end

  # A value to compare with: a moment as text for a value of the data, a
  # number as a decimal for PostgreSQL's numeric.
  defp param({:data, _key, :datetime}, %DateTime{} = dt, _dialect),
    do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp param({:column, _column, :datetime}, %DateTime{} = dt, _dialect),
    do: %{dt | microsecond: {elem(dt.microsecond, 0), 6}}

  defp param({:data, _key, :number}, value, :postgres) when is_float(value), do: Decimal.from_float(value)
  defp param(_ref, value, _dialect), do: value

  defp path(key), do: "$." <> key

  @doc false
  # The query's sorts, empty values last, then the collection's own order.
  @spec order(Ecto.Query.t(), [Sort.t()], Collection.t(), dialect()) :: Ecto.Query.t()
  def order(ecto, sorts, collection, dialect) do
    terms =
      Enum.flat_map(sorts, fn %Sort{field: key, dir: dir} ->
        field = Collection.field(collection, key)
        expr = sort_value(field, dialect)
        [{:asc, dynamic(is_nil(^expr))}, {dir, expr}]
      end)

    order_by(ecto, [record: r], ^(terms ++ [asc: dynamic([record: r], r.position), asc: dynamic([record: r], r.id)]))
  end

  defp sort_value(%Field{type: type} = field, dialect) when type in ~w(select status) do
    order = "|" <> Enum.join(Condition.choice_order(field), "|") <> "|"
    expr = value(Condition.ref(field), dialect)

    case dialect do
      :postgres -> dynamic(fragment("nullif(strpos(?, '|' || ? || '|'), 0)", ^order, ^expr))
      :sqlite -> dynamic(fragment("nullif(instr(?, '|' || ? || '|'), 0)", ^order, ^expr))
    end
  end

  defp sort_value(field, dialect) do
    case Condition.ref(field) do
      {:data, _key, kind} = ref when kind in [:text, :choice] -> dynamic(fragment("lower(?)", ^value(ref, dialect)))
      ref -> value(ref, dialect)
    end
  end
end
