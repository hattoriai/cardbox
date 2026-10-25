defmodule Cardbox.Sort do
  @moduledoc """
  An order of records by a field: `%{"field" => "due", "dir" => "asc"}`.

  Empty values come last in both directions. Texts sort without case; a
  select and a status sort in the order of their choices, as a board
  shows them; dates and numbers as themselves. Fields of several values
  (multi-selects, relations, several people) do not sort.
  """

  alias Cardbox.{Collection, Type}

  @type t :: %__MODULE__{field: String.t(), dir: :asc | :desc}

  @enforce_keys [:field]
  defstruct [:field, dir: :asc]

  @doc false
  @spec parse(term(), Collection.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(%{} = sort, %Collection{} = collection) do
    sort = Map.new(sort, fn {k, v} -> {to_string(k), v} end)

    with {:ok, field} <- field(sort["field"], collection),
         {:ok, dir} <- dir(sort["dir"]) do
      {:ok, %__MODULE__{field: field.key, dir: dir}}
    end
  end

  def parse(other, _collection),
    do: {:error, "a sort is a map of \"field\" and \"dir\", got: #{inspect(other)}"}

  @doc false
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{field: field, dir: dir}),
    do: %{"field" => field, "dir" => Atom.to_string(dir)}

  defp field(ref, collection) do
    case (is_binary(ref) or is_atom(ref)) && Collection.field(collection, ref) do
      nil ->
        {:error, "the collection has no field #{inspect(ref)} to sort by"}

      false ->
        {:error, "a sort names its field, got: #{inspect(ref)}"}

      field ->
        if Type.sortable?(field),
          do: {:ok, field},
          else: {:error, "#{inspect(field.name)} holds several values and does not sort"}
    end
  end

  defp dir(dir) when dir in [nil, "asc", :asc], do: {:ok, :asc}
  defp dir(dir) when dir in ["desc", :desc], do: {:ok, :desc}
  defp dir(dir), do: {:error, "a sort's dir is \"asc\" or \"desc\", got: #{inspect(dir)}"}
end
