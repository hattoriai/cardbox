defmodule Cardbox.Choice do
  @moduledoc """
  The choices of a select, a multi-select or a status field: each an `id`,
  a `name` and a `color`, and for a status a `group`.

      %{"id" => "in_review", "name" => "In review", "color" => "purple", "group" => "doing"}

  A record keeps a choice's `id`, so a choice renamed or recolored is
  renamed everywhere at once, and a choice removed from the field is
  removed from the records that had it.

  The colors are Erabi's nine (`gray`, `brown`, `orange`, `yellow`,
  `green`, `blue`, `purple`, `pink`, `red`), which its pickers draw with
  their contrast checked in light and dark; `to_options/1` gives the
  choices as Erabi takes them.

  A status's groups are `"todo"`, `"doing"` and `"done"`, in that order:
  a board of a status field shows them, and a filter takes a whole group
  (`in_group`).
  """

  alias Cardbox.Key

  @colors ~w(gray brown orange yellow green blue purple pink red)
  @color_atoms Map.new(@colors, &{&1, String.to_atom(&1)})
  @groups ~w(todo doing done)
  @max 200

  @doc "The colors a choice takes."
  @spec colors() :: [String.t()]
  def colors, do: @colors

  @doc "The groups of a status's choices, in their order."
  @spec groups() :: [String.t()]
  def groups, do: @groups

  @doc false
  # A status field with no choices given starts with these.
  def default_status do
    [
      %{"id" => "not_started", "name" => "Not started", "color" => "gray", "group" => "todo"},
      %{"id" => "in_progress", "name" => "In progress", "color" => "blue", "group" => "doing"},
      %{"id" => "done", "name" => "Done", "color" => "green", "group" => "done"}
    ]
  end

  @doc false
  # The choices of a field's options, checked: names given as text or maps
  # (with or without an id, a color, a group), each given an id made from
  # its name and kept after, and a color of the palette in turn. `previous`
  # are the field's choices before, whose ids a choice of the same id or
  # name keeps.
  @spec normalize(term(), boolean(), [map()]) :: {:ok, [map()]} | {:error, String.t()}
  def normalize(choices, status?, previous \\ [])

  def normalize(choices, _status?, _previous) when not is_list(choices),
    do: {:error, "choices are a list of names, or of maps with a \"name\""}

  def normalize(choices, _status?, _previous) when length(choices) > @max,
    do: {:error, "a field has at most #{@max} choices"}

  def normalize(choices, status?, previous) do
    by_name = Map.new(previous, &{String.downcase(&1["name"]), &1["id"]})

    choices
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {choice, i}, {:ok, acc, names} ->
      with {:ok, choice} <- read(choice),
           :ok <- unique_name(choice, names),
           {:ok, choice} <- complete(choice, i, status?, acc, by_name) do
        {:cont, {:ok, [choice | acc], MapSet.put(names, String.downcase(choice["name"]))}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, acc, _names} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp read(name) when is_binary(name), do: read(%{"name" => name})

  defp read(%{} = choice) do
    choice = Map.new(choice, fn {k, v} -> {to_string(k), v} end)
    name = choice["name"]

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, "each choice has a name"}

      String.length(name) > 100 ->
        {:error, "a choice's name is at most 100 characters: #{inspect(name)}"}

      true ->
        {:ok, Map.take(%{choice | "name" => String.trim(name)}, ~w(id name color group))}
    end
  end

  defp read(other), do: {:error, "a choice is a name or a map with a \"name\", got: #{inspect(other)}"}

  defp unique_name(choice, names) do
    if MapSet.member?(names, String.downcase(choice["name"])),
      do: {:error, "two choices are named #{inspect(choice["name"])}"},
      else: :ok
  end

  defp complete(choice, i, status?, acc, by_name) do
    taken = Enum.map(acc, & &1["id"])

    id =
      cond do
        Key.valid?(choice["id"]) and choice["id"] not in taken -> choice["id"]
        (id = by_name[String.downcase(choice["name"])]) && id not in taken -> id
        true -> Key.from_name(choice["name"], taken, "choice")
      end

    color = choice["color"] || Enum.at(@colors, rem(i, length(@colors)))

    cond do
      color not in @colors ->
        {:error, "a choice's color is one of #{Enum.join(@colors, ", ")}, got: #{inspect(color)}"}

      status? and choice["group"] not in [nil | @groups] ->
        {:error,
         "a status's group is one of #{Enum.join(@groups, ", ")}, got: #{inspect(choice["group"])}"}

      status? ->
        {:ok, Map.merge(choice, %{"id" => id, "color" => color, "group" => choice["group"] || "todo"})}

      true ->
        {:ok, choice |> Map.delete("group") |> Map.merge(%{"id" => id, "color" => color})}
    end
  end

  @doc """
  The choice of a list with this id, or with this name (without case), or nil.
  """
  @spec find([map()], term()) :: map() | nil
  def find(choices, value) when is_binary(value) do
    Enum.find(choices, &(&1["id"] == value)) ||
      Enum.find(choices, &(String.downcase(&1["name"]) == String.downcase(value)))
  end

  def find(_choices, _value), do: nil

  @doc """
  The choices as Erabi's options (`Erabi.Option`): `value` the id, `label`
  the name, `color` the color as an atom, and a status's group as `group`.
  """
  @spec to_options([map()]) :: [map()]
  def to_options(choices) do
    Enum.map(choices, fn choice ->
      %{value: choice["id"], label: choice["name"], color: @color_atoms[choice["color"]]}
      |> then(&if(choice["group"], do: Map.put(&1, :group, choice["group"]), else: &1))
    end)
  end
end
