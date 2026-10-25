defmodule Cardbox.Filter do
  @moduledoc """
  A condition on a field that a record meets or not.

      %{"field" => "status", "op" => "eq", "value" => "Done"}
      %{"field" => "due", "op" => "within", "value" => "next_week"}
      %{"field" => "owner", "op" => "eq", "value" => "me"}

  The operators of a field are those of its type (`Cardbox.Type.operators/1`):

  | Operator | Of | Value |
  | --- | --- | --- |
  | `eq`, `neq` | every type but lists | a value of the field |
  | `contains`, `not_contains`, `starts_with`, `ends_with` | texts | a text, without case |
  | `gt`, `gte`, `lt`, `lte` | numbers | a number |
  | `between` | numbers, dates | `[from, to]`, both included |
  | `before`, `after`, `on_or_before`, `on_or_after` | dates | a day |
  | `within` | dates | `past_week`, `past_month`, `past_year`, `next_week`, `next_month`, `next_year`, `this_week`, `this_month`, `this_year` |
  | `in`, `not_in` | a select, a status, a person | a list of values |
  | `in_group` | a status | `todo`, `doing` or `done`, or a list of them |
  | `has_any`, `has_all`, `has_none` | multi-selects, relations, people | a list of values |
  | `is_empty`, `is_not_empty` | every type that can be empty | none |

  A day is `"2026-10-25"`, or a day said in words that is read when the
  query runs: `today`, `tomorrow`, `yesterday`, `one_week_ago`,
  `one_week_from_now`, `one_month_ago`, `one_month_from_now`. A saved view of
  "due within the next week" shows a different week each week.

  A person is their id, or `"me"`: the person who runs the query (the
  `:me` option of a query), so one shared view of "my tasks" shows each
  person theirs.

  A choice is its id or its name. "Is not", "does not contain", "is none
  of" and "has none of" take the records with no value too, as a person
  means them.
  """

  alias Cardbox.{Choice, Collection, Field, Type}

  @type t :: %__MODULE__{field: String.t(), op: atom(), value: term()}

  @enforce_keys [:field, :op]
  defstruct [:field, :op, :value]

  @relative_days ~w(today tomorrow yesterday one_week_ago one_week_from_now one_month_ago one_month_from_now)
  @ranges ~w(past_week past_month past_year next_week next_month next_year this_week this_month this_year)
  @no_value [:is_empty, :is_not_empty]
  @list_value [:in, :not_in, :has_any, :has_all, :has_none]

  @doc "The days said in words that a date filter takes."
  @spec relative_days() :: [String.t()]
  def relative_days, do: @relative_days

  @doc "The ranges of days that `within` takes."
  @spec ranges() :: [String.t()]
  def ranges, do: @ranges

  @doc false
  # Reads a condition of the wire format against the collection's fields.
  @spec parse(map(), Collection.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(%{} = condition, %Collection{} = collection) do
    condition = Map.new(condition, fn {k, v} -> {to_string(k), v} end)

    with {:ok, field} <- field(condition["field"], collection),
         {:ok, op} <- op(condition["op"], field),
         {:ok, value} <- value(field, op, Map.get(condition, "value"), Map.has_key?(condition, "value")) do
      {:ok, %__MODULE__{field: field.key, op: op, value: value}}
    end
  end

  def parse(other, _collection),
    do: {:error, "a condition is a map of \"field\", \"op\" and \"value\", got: #{inspect(other)}"}

  @doc false
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{field: field, op: op, value: value}) do
    base = %{"field" => field, "op" => Atom.to_string(op)}
    if op in @no_value, do: base, else: Map.put(base, "value", value)
  end

  defp field(ref, collection) when is_binary(ref) or is_atom(ref) do
    case Collection.field(collection, ref) do
      %Field{} = field ->
        {:ok, field}

      nil ->
        names = Enum.map_join(collection.fields, ", ", &inspect(&1.name))
        {:error, "the collection has no field #{inspect(ref)}; its fields are #{names}"}
    end
  end

  defp field(ref, _collection), do: {:error, "a condition names its field, got: #{inspect(ref)}"}

  defp op(op, field) when is_binary(op) or is_atom(op) do
    ops = Type.operators(field)
    op = to_string(op)

    case Enum.find(ops, &(Atom.to_string(&1) == op)) do
      nil ->
        {:error,
         "#{inspect(field.name)} (#{field.type}) filters by #{Enum.map_join(ops, ", ", &Atom.to_string/1)}, got: #{inspect(op)}"}

      op ->
        {:ok, op}
    end
  end

  defp op(op, _field), do: {:error, "a condition's op is text, got: #{inspect(op)}"}

  defp value(_field, op, _value, _given?) when op in @no_value, do: {:ok, nil}

  defp value(field, op, _value, false),
    do: {:error, "#{inspect(field.name)} #{op} takes a value"}

  defp value(field, op, value, true) when op in @list_value do
    values = if is_list(value), do: value, else: [value]

    if length(values) > 1000,
      do: {:error, "a list of values has at most 1000 values"},
      else: map_ok(values, &one(field, op, &1))
  end

  defp value(_field, :in_group, value, true) do
    groups = Choice.groups()
    values = if is_list(value), do: value, else: [value]

    if Enum.all?(values, &(&1 in groups)),
      do: {:ok, values},
      else: {:error, "a status's groups are #{Enum.join(groups, ", ")}, got: #{inspect(value)}"}
  end

  defp value(field, :between, [from, to], true) do
    with {:ok, from} <- one(field, :between, from), {:ok, to} <- one(field, :between, to) do
      {:ok, [from, to]}
    end
  end

  defp value(field, :between, value, true),
    do: {:error, "#{inspect(field.name)} between takes [from, to], got: #{inspect(value)}"}

  defp value(field, :within, value, true) do
    if value in @ranges,
      do: {:ok, value},
      else: {:error, "#{inspect(field.name)} within takes one of #{Enum.join(@ranges, ", ")}, got: #{inspect(value)}"}
  end

  defp value(field, op, value, true), do: one(field, op, value)

  # One value, read for the field's kind.
  defp one(field, op, value) do
    case Type.kind(field) do
      :text -> text(field, op, value)
      :number -> number(field, value)
      :boolean -> boolean(field, value)
      kind when kind in [:date, :datetime] -> day(field, value)
      _choice_or_list -> member(field, value)
    end
  end

  defp text(field, op, value) when is_binary(value) do
    if op in [:contains, :not_contains, :starts_with, :ends_with] and value == "",
      do: {:error, "#{inspect(field.name)} #{op} takes a text of some characters"},
      else: {:ok, value}
  end

  defp text(field, _op, value), do: {:error, "#{inspect(field.name)} takes a text, got: #{inspect(value)}"}

  defp number(field, value) do
    case Type.cast(%{type: "number", options: %{}}, value) do
      {:ok, n} when is_number(n) -> {:ok, n}
      _ -> {:error, "#{inspect(field.name)} takes a number, got: #{inspect(value)}"}
    end
  end

  defp boolean(_field, value) when is_boolean(value), do: {:ok, value}
  defp boolean(_field, "true"), do: {:ok, true}
  defp boolean(_field, "false"), do: {:ok, false}
  defp boolean(field, value), do: {:error, "#{inspect(field.name)} takes true or false, got: #{inspect(value)}"}

  defp day(field, value) when is_binary(value) do
    cond do
      value in @relative_days -> {:ok, value}
      match?({:ok, _}, Date.from_iso8601(value)) -> {:ok, value}
      true -> {:error, "#{inspect(field.name)} takes a day as YYYY-MM-DD or one of #{Enum.join(@relative_days, ", ")}, got: #{inspect(value)}"}
    end
  end

  defp day(_field, %Date{} = date), do: {:ok, Date.to_iso8601(date)}
  defp day(field, value), do: day(field, inspect(value))

  defp member(%Field{type: type} = field, value) when type in ~w(select status multi_select) do
    case Choice.find(Field.choices(field), to_text(value)) do
      %{"id" => id} ->
        {:ok, id}

      nil ->
        names = field |> Field.choices() |> Enum.map_join(", ", &inspect(&1["name"]))
        {:error, "#{inspect(field.name)}'s choices are #{names}, got: #{inspect(value)}"}
    end
  end

  defp member(%Field{type: "relation"} = field, value) do
    case Type.cast(%{field | options: %{}}, [value]) do
      {:ok, [id]} -> {:ok, id}
      _ -> {:error, "#{inspect(field.name)} takes record ids, got: #{inspect(value)}"}
    end
  end

  defp member(field, value) do
    case to_text(value) do
      text when is_binary(text) and text != "" -> {:ok, text}
      _ -> {:error, "#{inspect(field.name)} takes a person's id or \"me\", got: #{inspect(value)}"}
    end
  end

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value) when is_integer(value), do: Integer.to_string(value)
  defp to_text(value) when is_atom(value) and not is_nil(value) and not is_boolean(value), do: Atom.to_string(value)
  defp to_text(_value), do: nil

  defp map_ok(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end
end
