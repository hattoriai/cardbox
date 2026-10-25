defmodule Cardbox.Condition do
  @moduledoc false
  # A query's filter and search, lowered to a few plain conditions on the
  # values of a record, with the days said in words, "me" and the time zone
  # read: what the SQL of a database (Cardbox.SQL) and meets?/2 in Elixir
  # both answer, the same way.
  #
  #   {:cmp, ref, op, value}    op: :eq, :neq, :lt, :lte, :gt, :gte
  #   {:like, ref, mode, text}  mode: :contains, :starts_with, :ends_with; without case
  #   {:empty, ref}             no value
  #   {:has, ref, value}        a list that holds the value
  #   {:and, [c]}, {:or, [c]}, {:not, c}, true, false
  #
  # A ref is {:data, key, kind}, a value of the record's data,
  # {:column, column, kind}, one of the record's own columns, or
  # {:links, {key, {field_id, side}}, :list}, a relation's links. A comparison
  # with no value is false, as SQL's NULL is in a WHERE; a :not is only ever
  # of a condition that is never NULL, or beside an :empty that catches it.

  alias Cardbox.{Collection, Field, Filter, Links, Query, Record, Search, Type}

  @type ref :: {:data, String.t(), Type.kind()} | {:column, atom(), Type.kind()}
  @type t ::
          {:cmp, ref(), atom(), term()}
          | {:like, ref(), atom(), String.t()}
          | {:empty, ref()}
          | {:has, ref(), term()}
          | {:and, [t()]}
          | {:or, [t()]}
          | {:not, t()}
          | boolean()

  @doc false
  # What a query's conditions are read with: who "me" is, today, and the
  # time zone of days.
  def context(opts) do
    tz = Keyword.get(opts, :time_zone, "Etc/UTC")
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    %{
      me: opts |> Keyword.get(:me) |> me(),
      time_zone: tz,
      today: now |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    }
  end

  defp me(nil), do: nil
  defp me(%{id: id}), do: to_string(id)
  defp me(id), do: to_string(id)

  @doc false
  @spec lower(Query.t(), Collection.t(), map()) :: t()
  def lower(%Query{filter: filter, search: search}, collection, ctx) do
    {:and, [filter(filter, collection, ctx), search(search, collection)]}
    |> nobody()
    |> simplify()
  end

  # "Me" with nobody running the query: nobody is any record's person, so
  # "is me" is false and "is not me" true, before any database sees it.
  defp nobody({:cmp, _ref, :eq, :nobody}), do: false
  defp nobody({:cmp, _ref, :neq, :nobody}), do: true
  defp nobody({:has, _ref, :nobody}), do: false
  defp nobody({op, items}) when op in [:and, :or], do: {op, Enum.map(items, &nobody/1)}
  defp nobody({:not, inner}), do: {:not, nobody(inner)}
  defp nobody(condition), do: condition

  @doc false
  @spec ref(Field.t()) :: ref()
  def ref(%Field{type: "created_at"}), do: {:column, :inserted_at, :datetime}
  def ref(%Field{type: "updated_at"}), do: {:column, :updated_at, :datetime}
  def ref(%Field{type: "created_by"}), do: {:column, :created_by, :choice}
  def ref(%Field{type: "updated_by"}), do: {:column, :updated_by, :choice}

  def ref(%Field{type: "relation", key: key} = field),
    do: {:links, {key, Links.side(field)}, :list}

  def ref(%Field{key: key} = field), do: {:data, key, Type.kind(field)}

  defp filter(nil, _collection, _ctx), do: true

  defp filter({op, filters}, collection, ctx),
    do: {op, Enum.map(filters, &filter(&1, collection, ctx))}

  defp filter(%Filter{field: key} = filter, collection, ctx) do
    field = Collection.field(collection, key)
    condition(filter, field, ref(field), ctx)
  end

  defp condition(%Filter{op: :is_empty}, _field, ref, _ctx), do: {:empty, ref}
  defp condition(%Filter{op: :is_not_empty}, _field, ref, _ctx), do: {:not, {:empty, ref}}

  defp condition(%Filter{op: op, value: value}, field, {_, _, kind} = ref, ctx)
       when kind in [:date, :datetime],
       do: date(op, value, ref, field, ctx)

  defp condition(%Filter{op: :eq, value: value}, _field, {_, _, :boolean} = ref, _ctx),
    do: if(value, do: {:cmp, ref, :eq, true}, else: {:empty, ref})

  defp condition(%Filter{op: op, value: value}, _field, {_, _, :list} = ref, ctx) do
    has = Enum.map(value, &{:has, ref, member(&1, ctx)})

    case op do
      :has_any -> {:or, has}
      :has_all -> {:and, has}
      :has_none -> {:not, {:or, has}}
    end
  end

  defp condition(%Filter{op: op, value: value}, field, ref, ctx)
       when op in [:eq, :neq, :in, :not_in, :in_group],
       do: member_condition(op, value, field, ref, ctx)

  defp condition(%Filter{op: op, value: value}, _field, ref, _ctx)
       when op in [:contains, :not_contains, :starts_with, :ends_with],
       do: text_condition(op, value, ref)

  defp condition(%Filter{op: :between, value: value}, _field, ref, _ctx),
    do: {:and, [{:cmp, ref, :gte, hd(value)}, {:cmp, ref, :lte, List.last(value)}]}

  defp condition(%Filter{op: op, value: value}, _field, ref, _ctx)
       when op in [:gt, :gte, :lt, :lte],
       do: {:cmp, ref, op, value}

  # Conditions on one value among some: a choice, a person.
  defp member_condition(:eq, value, _field, ref, ctx), do: {:cmp, ref, :eq, member(value, ctx)}

  defp member_condition(:neq, value, _field, ref, ctx),
    do: {:or, [{:empty, ref}, {:cmp, ref, :neq, member(value, ctx)}]}

  defp member_condition(:in, values, _field, ref, ctx),
    do: {:or, Enum.map(values, &{:cmp, ref, :eq, member(&1, ctx)})}

  defp member_condition(:not_in, values, _field, ref, ctx),
    do: {:or, [{:empty, ref}, {:and, Enum.map(values, &{:cmp, ref, :neq, member(&1, ctx)})}]}

  defp member_condition(:in_group, groups, field, ref, _ctx) do
    {:or,
     for(
       %{"id" => id, "group" => g} <- Field.choices(field),
       g in groups,
       do: {:cmp, ref, :eq, id}
     )}
  end

  # Conditions on the words of a text, without case.
  defp text_condition(:not_contains, value, ref),
    do: {:or, [{:empty, ref}, {:not, {:like, ref, :contains, value}}]}

  defp text_condition(mode, value, ref), do: {:like, ref, mode, value}

  # "me" is the person who runs the query; with nobody, :nobody (nobody/1).
  defp member("me", %{me: nil}), do: :nobody
  defp member("me", %{me: me}), do: me
  defp member(value, _ctx), do: value

  # A day's conditions: on a day field, its days as text; on a field of
  # moments, the moments from the day's start, in the time zone.
  defp date(:between, [from, to], ref, field, ctx) do
    {:and, [date(:on_or_after, from, ref, field, ctx), date(:on_or_before, to, ref, field, ctx)]}
  end

  defp date(:within, range, ref, field, ctx) do
    {from, to} = range(range, ctx.today)
    date(:between, [Date.to_iso8601(from), Date.to_iso8601(to)], ref, field, ctx)
  end

  defp date(op, value, {_, _, :date} = ref, _field, ctx) do
    day = value |> day(ctx.today) |> Date.to_iso8601()

    case op do
      :eq -> {:cmp, ref, :eq, day}
      :before -> {:cmp, ref, :lt, day}
      :after -> {:cmp, ref, :gt, day}
      :on_or_before -> {:cmp, ref, :lte, day}
      :on_or_after -> {:cmp, ref, :gte, day}
    end
  end

  defp date(op, value, {_, _, :datetime} = ref, _field, ctx) do
    day = day(value, ctx.today)
    start = start_of(day, ctx.time_zone)
    next = start_of(Date.add(day, 1), ctx.time_zone)

    case op do
      :eq -> {:and, [{:cmp, ref, :gte, start}, {:cmp, ref, :lt, next}]}
      :before -> {:cmp, ref, :lt, start}
      :after -> {:cmp, ref, :gte, next}
      :on_or_before -> {:cmp, ref, :lt, next}
      :on_or_after -> {:cmp, ref, :gte, start}
    end
  end

  defp day("today", today), do: today
  defp day("tomorrow", today), do: Date.add(today, 1)
  defp day("yesterday", today), do: Date.add(today, -1)
  defp day("one_week_ago", today), do: Date.add(today, -7)
  defp day("one_week_from_now", today), do: Date.add(today, 7)
  defp day("one_month_ago", today), do: Date.shift(today, month: -1)
  defp day("one_month_from_now", today), do: Date.shift(today, month: 1)
  defp day(iso, _today), do: Date.from_iso8601!(iso)

  defp range("past_week", today), do: {Date.add(today, -7), today}
  defp range("past_month", today), do: {Date.shift(today, month: -1), today}
  defp range("past_year", today), do: {Date.shift(today, year: -1), today}
  defp range("next_week", today), do: {today, Date.add(today, 7)}
  defp range("next_month", today), do: {today, Date.shift(today, month: 1)}
  defp range("next_year", today), do: {today, Date.shift(today, year: 1)}
  defp range("this_week", today), do: {Date.beginning_of_week(today), Date.end_of_week(today)}
  defp range("this_month", today), do: {Date.beginning_of_month(today), Date.end_of_month(today)}
  defp range("this_year", today), do: {Date.new!(today.year, 1, 1), Date.new!(today.year, 12, 31)}

  # The moment a day starts in a time zone, in UTC; a day that starts in a
  # gap of the clocks starts when the clocks go on.
  defp start_of(day, tz) do
    case DateTime.new(day, ~T[00:00:00], tz) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, dt, _later} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:gap, _before, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
    end
  end

  # A search: each of its words in the record's search text (Cardbox.Search).
  defp search(nil, _collection), do: true

  defp search(text, _collection) do
    {:and,
     for(word <- Search.words(text), do: {:like, {:column, :search_text, :text}, :contains, word})}
  end

  @doc false
  # The condition with its trivial parts folded: true and false in groups,
  # groups of one.
  @spec simplify(t()) :: t()
  def simplify({op, items}) when op in [:and, :or] do
    {unit, zero} = if op == :and, do: {true, false}, else: {false, true}

    items =
      items
      |> Enum.map(&simplify/1)
      |> Enum.flat_map(fn
        {^op, inner} -> inner
        other -> [other]
      end)
      |> Enum.reject(&(&1 == unit))

    cond do
      zero in items -> zero
      items == [] -> unit
      match?([_], items) -> hd(items)
      true -> {op, items}
    end
  end

  def simplify({:not, inner}) do
    case simplify(inner) do
      true -> false
      false -> true
      other -> {:not, other}
    end
  end

  def simplify(other), do: other

  @doc false
  # Whether a record meets the condition, in Elixir: the same answer as the
  # SQL of Cardbox.SQL, for a record that changed and is not read again.
  @spec meets?(t(), Record.t()) :: boolean()
  def meets?(true, _record), do: true
  def meets?(false, _record), do: false
  def meets?({:and, items}, record), do: Enum.all?(items, &meets?(&1, record))
  def meets?({:or, items}, record), do: Enum.any?(items, &meets?(&1, record))
  def meets?({:not, inner}, record), do: not meets?(inner, record)
  def meets?({:empty, ref}, record), do: value(ref, record) in [nil, "", []]

  def meets?({:has, ref, value}, record) do
    case value(ref, record) do
      list when is_list(list) -> value in list
      _ -> false
    end
  end

  def meets?({:like, ref, mode, text}, record) do
    case value(ref, record) do
      value when is_binary(value) ->
        {value, text} = {String.downcase(value), String.downcase(text)}

        case mode do
          :contains -> String.contains?(value, text)
          :starts_with -> String.starts_with?(value, text)
          :ends_with -> String.ends_with?(value, text)
        end

      _ ->
        false
    end
  end

  def meets?({:cmp, ref, op, expected}, record) do
    case value(ref, record) do
      nil -> false
      actual -> compare(op, actual, expected)
    end
  end

  defp value({:data, key, kind}, record) do
    value = Map.get(record.data, key)

    case {kind, value} do
      {:number, v} when not is_number(v) -> nil
      {:boolean, v} when not is_boolean(v) -> nil
      {:list, v} when not is_list(v) -> nil
      {kind, v} when kind in [:text, :choice, :date, :datetime] and not is_binary(v) -> nil
      {_kind, v} -> v
    end
  end

  defp value({:column, column, _kind}, record), do: Map.fetch!(record, column)

  defp value({:links, {key, _side}, :list}, record) do
    case Map.get(record.data, key) do
      ids when is_list(ids) -> ids
      _ -> nil
    end
  end

  defp compare(op, %DateTime{} = actual, expected),
    do: order(op, DateTime.compare(actual, to_datetime(expected)))

  defp compare(op, actual, %DateTime{} = expected),
    do: order(op, DateTime.compare(to_datetime(actual), expected))

  defp compare(op, actual, expected) when is_number(actual) and is_number(expected),
    do:
      order(op, if(actual == expected, do: :eq, else: if(actual < expected, do: :lt, else: :gt)))

  defp compare(op, actual, expected) when is_binary(actual) and is_binary(expected),
    do:
      order(op, if(actual == expected, do: :eq, else: if(actual < expected, do: :lt, else: :gt)))

  defp compare(op, actual, expected), do: order(op, if(actual == expected, do: :eq, else: :neq))

  defp to_datetime(%DateTime{} = dt), do: dt

  defp to_datetime(iso) when is_binary(iso) do
    {:ok, dt, _offset} = DateTime.from_iso8601(iso)
    dt
  end

  defp order(:eq, result), do: result == :eq
  defp order(:neq, result), do: result != :eq
  defp order(:lt, result), do: result == :lt
  defp order(:lte, result), do: result in [:lt, :eq]
  defp order(:gt, result), do: result == :gt
  defp order(:gte, result), do: result in [:gt, :eq]

  @doc false
  # The choices of the collection's choice fields, by key, for the order of a
  # sort by a select or a status.
  def choice_order(%Field{} = field), do: Enum.map(Field.choices(field), & &1["id"])
end
