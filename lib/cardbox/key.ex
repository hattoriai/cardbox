defmodule Cardbox.Key do
  @moduledoc false
  # The keys of fields and choices: made once from a name, in lowercase
  # letters, digits and underscores, and never changed after, so a value
  # stored under a key, a saved view and an agent's query outlive a rename.

  @max 40

  @doc "A key from a name, not one of `taken`: `\"Due date\"` is `\"due_date\"`, then `\"due_date_2\"`."
  @spec from_name(String.t(), [String.t()], String.t()) :: String.t()
  def from_name(name, taken, fallback) do
    base =
      name
      |> String.normalize(:nfd)
      |> String.replace(~r/[^\x00-\x7F]/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, @max)
      |> String.trim_trailing("_")

    base =
      cond do
        base == "" -> fallback
        base =~ ~r/^[0-9]/ -> fallback <> "_" <> base
        true -> base
      end

    unique(base, MapSet.new(taken), 1)
  end

  defp unique(base, taken, 1) do
    if MapSet.member?(taken, base), do: unique(base, taken, 2), else: base
  end

  defp unique(base, taken, n) do
    key = "#{base}_#{n}"
    if MapSet.member?(taken, key), do: unique(base, taken, n + 1), else: key
  end

  @doc "Whether a text is a key."
  @spec valid?(term()) :: boolean()
  def valid?(key), do: is_binary(key) and key =~ ~r/^[a-z][a-z0-9_]{0,63}$/
end
