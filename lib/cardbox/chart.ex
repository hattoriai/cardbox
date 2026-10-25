defmodule Cardbox.Chart do
  @moduledoc false
  # A chart view's options, checked when it is saved, whether or not the app
  # draws charts (Cardbox.Fude does, with Fude).

  alias Cardbox.{Collection, Field, Type}

  @kinds ~w(bar line area pie donut number)

  @doc false
  def kinds, do: @kinds

  @doc false
  # Checks a chart view's options (Cardbox.Views).
  def check_options(collection, options) do
    kind = options["kind"] || "bar"

    with :ok <- check_kind(kind),
         {:ok, options} <- check_x(collection, kind, options),
         {:ok, options} <- check_y(collection, options),
         {:ok, options} <- check_color(collection, options) do
      {:ok, Map.put(options, "kind", kind)}
    end
  end

  defp check_kind(kind) when kind in @kinds, do: :ok

  defp check_kind(kind),
    do: {:error, "a chart's kind is one of #{Enum.join(@kinds, ", ")}, got: #{inspect(kind)}"}

  defp check_x(_collection, "number", options), do: {:ok, Map.drop(options, ~w(x unit color))}

  defp check_x(collection, _kind, options) do
    with {:ok, field} <- groupable(collection, options["x"], "a chart's x") do
      unit = options["unit"]
      date? = Type.kind(field) in [:date, :datetime]

      cond do
        date? and unit in ~w(day month year) ->
          {:ok, Map.merge(options, %{"x" => field.key, "unit" => unit})}

        date? ->
          {:ok, Map.merge(options, %{"x" => field.key, "unit" => "month"})}

        unit != nil ->
          {:error, "only a date's chart has a unit, got: #{inspect(unit)}"}

        true ->
          {:ok, Map.put(options, "x", field.key)}
      end
    end
  end

  defp check_y(_collection, %{"y" => y} = options) when y in [nil, "count"],
    do: {:ok, Map.put(options, "y", "count")}

  defp check_y(collection, %{"y" => %{} = y} = options) when map_size(y) == 1 do
    [{op, ref}] = y |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.to_list()

    case {op in ~w(sum mean min max), Collection.field(collection, ref)} do
      {true, %Field{type: "number"} = field} ->
        {:ok, Map.put(options, "y", %{op => field.key})}

      _ ->
        {:error,
         "a chart's y is \"count\", or sum, mean, min or max of a number field, got: #{inspect(y)}"}
    end
  end

  defp check_y(_collection, %{"y" => y}),
    do:
      {:error,
       "a chart's y is \"count\", or sum, mean, min or max of a number field, got: #{inspect(y)}"}

  defp check_y(_collection, options), do: {:ok, Map.put(options, "y", "count")}

  defp check_color(_collection, %{"color" => nil} = options),
    do: {:ok, Map.delete(options, "color")}

  defp check_color(collection, %{"color" => ref} = options) do
    with {:ok, field} <- groupable(collection, ref, "a chart's color") do
      if Type.kind(field) in [:date, :datetime],
        do: {:error, "a chart's color is not a date"},
        else: {:ok, Map.put(options, "color", field.key)}
    end
  end

  defp check_color(_collection, options), do: {:ok, options}

  defp groupable(collection, ref, what) do
    case (is_binary(ref) or is_atom(ref)) && ref && Collection.field(collection, ref) do
      %Field{} = field ->
        if Type.kind(field) == :list,
          do: {:error, "#{what} cannot be #{inspect(field.name)}: it holds several values"},
          else: {:ok, field}

      _ ->
        {:error, "#{what} names a field of the collection, got: #{inspect(ref)}"}
    end
  end
end
