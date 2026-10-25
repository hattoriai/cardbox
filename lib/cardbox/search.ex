defmodule Cardbox.Search do
  @moduledoc false
  # A record's search text: the words of its texts and of its choices'
  # names, without case and without accents, kept in its own column on
  # every write. A search looks for each of its words there, the same way on
  # every database: on PostgreSQL with a trigram index, on SQLite in the
  # column as it is.

  alias Cardbox.{Choice, Collection, Field, Type}

  @max 20_000

  @doc false
  @spec text(Collection.t(), map()) :: String.t() | nil
  def text(%Collection{fields: fields}, data) do
    fields
    |> Enum.flat_map(&words(&1, Map.get(data, &1.key)))
    |> Enum.join("\n")
    |> normalize()
    |> case do
      "" -> nil
      text -> String.slice(text, 0, @max)
    end
  end

  defp words(_field, nil), do: []

  defp words(%Field{type: type} = field, value) when type in ~w(select status) do
    case Choice.find(Field.choices(field), value) do
      %{"name" => name} -> [name]
      nil -> []
    end
  end

  defp words(%Field{type: "multi_select"} = field, ids) when is_list(ids),
    do: for(id <- ids, %{"name" => name} <- [Choice.find(Field.choices(field), id)], do: name)

  defp words(field, value) when is_binary(value) do
    if Type.kind(field) == :text, do: [value], else: []
  end

  defp words(_field, _value), do: []

  @doc false
  # Text without case and accents: "Élan" and "elan" are the same words.
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
  end

  @doc false
  # The words of a search, each to be found.
  @spec words(String.t()) :: [String.t()]
  def words(search),
    do: search |> normalize() |> String.split(~r/\s+/u, trim: true) |> Enum.uniq()
end
