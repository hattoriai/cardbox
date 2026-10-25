defmodule Cardbox.Query do
  @moduledoc """
  Which records of a collection, in which order: a filter (conditions, in
  groups of `and` and `or`), sorts, and a search.

  A query has a wire format of plain maps and lists, which a saved view
  keeps, a URL carries and an agent writes:

      %{
        "filter" => %{
          "and" => [
            %{"field" => "status", "op" => "in_group", "value" => ["todo", "doing"]},
            %{"or" => [
              %{"field" => "owner", "op" => "eq", "value" => "me"},
              %{"field" => "owner", "op" => "is_empty"}
            ]}
          ]
        },
        "sort" => [%{"field" => "due", "dir" => "asc"}],
        "search" => "invoice"
      }

  `parse/3` reads it against a collection's fields: each field named by key
  or by name, each operator one its type has, each value read for its type
  (a choice's name becomes its id). An error says where it is and what to
  write instead, for a person or an agent to correct. The conditions are
  `Cardbox.Filter`'s and the sorts `Cardbox.Sort`'s.

  `search` finds records with the words in a text field, or in the name of
  a chosen choice, without case.

  ## Limits

  Groups nest four deep, with at most 100 conditions in all and 10 sorts;
  a search is at most 200 characters.
  """

  alias Cardbox.{Collection, Filter, Sort}

  @type filter :: Filter.t() | {:and, [filter()]} | {:or, [filter()]} | nil

  @type t :: %__MODULE__{filter: filter(), sorts: [Sort.t()], search: String.t() | nil}

  defstruct filter: nil, sorts: [], search: nil

  @max_depth 4
  @max_conditions 100
  @max_sorts 10
  @max_search 200

  @doc """
  Reads a query of the wire format against the collection.

  With `lenient: true`, a condition or a sort that does not check is left
  out instead of failing the query: a saved view whose field was deleted
  still opens, with what of it still holds.
  """
  @spec parse(map() | t() | nil, Collection.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def parse(query, collection, opts \\ [])

  def parse(nil, _collection, _opts), do: {:ok, %__MODULE__{}}
  def parse(%__MODULE__{} = query, _collection, _opts), do: {:ok, query}

  def parse(%{} = wire, %Collection{} = collection, opts) do
    wire = Map.new(wire, fn {k, v} -> {to_string(k), v} end)
    lenient? = Keyword.get(opts, :lenient, false)

    with :ok <- known_keys(wire),
         {:ok, filter} <- filter(wire["filter"], collection, lenient?, 1),
         :ok <- count(filter),
         {:ok, sorts} <- sorts(wire["sort"], collection, lenient?),
         {:ok, search} <- search(wire["search"]) do
      {:ok, %__MODULE__{filter: filter, sorts: sorts, search: search}}
    end
  end

  def parse(other, _collection, _opts),
    do: {:error, "a query is a map of \"filter\", \"sort\" and \"search\", got: #{inspect(other)}"}

  @doc "The query in the wire format."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{filter: filter, sorts: sorts, search: search}) do
    %{}
    |> then(&if(filter, do: Map.put(&1, "filter", filter_to_wire(filter)), else: &1))
    |> then(&if(sorts != [], do: Map.put(&1, "sort", Enum.map(sorts, fn s -> Sort.to_wire(s) end)), else: &1))
    |> then(&if(search, do: Map.put(&1, "search", search), else: &1))
  end

  @doc "The keys of the fields a query names, in its filter and its sorts."
  @spec fields(t()) :: [String.t()]
  def fields(%__MODULE__{filter: filter, sorts: sorts}) do
    Enum.uniq(filter_fields(filter) ++ Enum.map(sorts, & &1.field))
  end

  defp filter_fields(nil), do: []
  defp filter_fields(%Filter{field: field}), do: [field]
  defp filter_fields({_op, filters}), do: Enum.flat_map(filters, &filter_fields/1)

  defp known_keys(wire) do
    case Map.keys(wire) -- ~w(filter sort search) do
      [] -> :ok
      [key | _] -> {:error, "a query has \"filter\", \"sort\" and \"search\", got: #{inspect(key)}"}
    end
  end

  defp filter(nil, _collection, _lenient?, _depth), do: {:ok, nil}

  defp filter(_wire, _collection, _lenient?, depth) when depth > @max_depth,
    do: {:error, "groups of conditions nest at most #{@max_depth} deep"}

  defp filter(%{} = wire, collection, lenient?, depth) do
    wire = Map.new(wire, fn {k, v} -> {to_string(k), v} end)

    case wire do
      %{"and" => list} when map_size(wire) == 1 -> group(:and, list, collection, lenient?, depth)
      %{"or" => list} when map_size(wire) == 1 -> group(:or, list, collection, lenient?, depth)
      condition -> condition(condition, collection, lenient?)
    end
  end

  defp filter(list, collection, lenient?, depth) when is_list(list),
    do: group(:and, list, collection, lenient?, depth)

  defp filter(other, _collection, _lenient?, _depth),
    do: {:error, "a filter is a condition, or a map of \"and\" or \"or\" and a list, got: #{inspect(other)}"}

  defp group(op, list, collection, lenient?, depth) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case filter(item, collection, lenient?, depth + 1) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, filter} -> {:cont, {:ok, [filter | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, nil}
      {:ok, filters} -> {:ok, {op, Enum.reverse(filters)}}
      error -> error
    end
  end

  defp group(op, other, _collection, _lenient?, _depth),
    do: {:error, "\"#{op}\" takes a list of conditions, got: #{inspect(other)}"}

  defp condition(condition, collection, lenient?) do
    case Filter.parse(condition, collection) do
      {:error, _message} when lenient? -> {:ok, nil}
      other -> other
    end
  end

  defp count(filter) do
    if length(filter_fields(filter)) > @max_conditions,
      do: {:error, "a filter has at most #{@max_conditions} conditions"},
      else: :ok
  end

  defp sorts(nil, _collection, _lenient?), do: {:ok, []}
  defp sorts(%{} = sort, collection, lenient?), do: sorts([sort], collection, lenient?)

  defp sorts(list, _collection, _lenient?) when is_list(list) and length(list) > @max_sorts,
    do: {:error, "a query has at most #{@max_sorts} sorts"}

  defp sorts(list, collection, lenient?) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case Sort.parse(item, collection) do
        {:ok, sort} -> {:cont, {:ok, [sort | acc]}}
        {:error, _message} when lenient? -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sorts} -> {:ok, sorts |> Enum.reverse() |> Enum.uniq_by(& &1.field)}
      error -> error
    end
  end

  defp sorts(other, _collection, _lenient?),
    do: {:error, "\"sort\" is a list of sorts, got: #{inspect(other)}"}

  defp search(nil), do: {:ok, nil}

  defp search(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:ok, nil}
      String.length(text) > @max_search -> {:error, "a search is at most #{@max_search} characters"}
      true -> {:ok, text}
    end
  end

  defp search(other), do: {:error, "a search is a text, got: #{inspect(other)}"}

  defp filter_to_wire(%Filter{} = filter), do: Filter.to_wire(filter)
  defp filter_to_wire({op, filters}), do: %{Atom.to_string(op) => Enum.map(filters, &filter_to_wire/1)}
end
