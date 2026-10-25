defmodule Cardbox.Views do
  @moduledoc false
  # Saved views: their query kept in the wire format with fields by key and
  # choices by id (so a rename changes nothing), their options checked for
  # their type, and both kept in step when a field is deleted.

  import Ecto.Query

  alias Cardbox.{Collection, Collections, Error, Query, Store, Type, View}

  def list(mod, %Collection{id: id}, opts) do
    owner = opts[:owner] && mod.actor_id(opts[:owner])

    from(v in View,
      where: v.collection_id == ^id and (is_nil(v.owner) or v.owner == ^(owner || "")),
      order_by: [asc: v.position, asc: v.id]
    )
    |> Store.repo(mod).all()
  end

  def get(mod, %Collection{id: id}, view_id) do
    Store.repo(mod).one(from(v in View, where: v.collection_id == ^id and v.id == ^view_id))
  end

  def save(mod, %Collection{} = collection, attrs, opts) do
    attrs = Collections.stringify(attrs)

    with :ok <- Store.allow(mod, opts, :save_view, collection),
         {:ok, attrs} <- check(collection, attrs, attrs["type"] || "table") do
      views = Collections.views_of(Store.repo(mod), collection.id)
      position = Collections.position(views, :last)

      %View{collection_id: collection.id, position: position}
      |> View.changeset(attrs)
      |> Store.repo(mod).insert()
      |> broadcast(mod, collection, opts)
    end
  end

  def update(mod, %Collection{} = collection, %View{} = view, attrs, opts) do
    attrs = attrs |> Collections.stringify() |> Map.take(~w(name type query options owner))

    with :ok <- Store.allow(mod, opts, :save_view, collection),
         {:ok, attrs} <- check(collection, Map.merge(%{"query" => view.query, "options" => view.options}, attrs), attrs["type"] || view.type) do
      view
      |> View.changeset(attrs)
      |> Store.repo(mod).update()
      |> broadcast(mod, collection, opts)
    end
  end

  def delete(mod, %Collection{} = collection, %View{} = view, opts) do
    with :ok <- Store.allow(mod, opts, :delete_view, collection),
         {:ok, view} <- Store.repo(mod).delete(view) do
      Store.broadcast(mod, Store.event(:view_deleted, collection.id, opts, mod, view: view))
      {:ok, view}
    end
  end

  defp broadcast({:ok, view}, mod, collection, opts) do
    Store.broadcast(mod, Store.event(:view_saved, collection.id, opts, mod, view: view))
    {:ok, view}
  end

  defp broadcast({:error, changeset}, _mod, _collection, _opts), do: {:error, Error.from_changeset(changeset)}

  @doc false
  # A view's query, read leniently: what still holds of it after its fields
  # changed.
  def query(collection, %View{query: query}) do
    case Query.parse(query, collection, lenient: true) do
      {:ok, query} -> {:ok, query}
      {:error, message} -> {:error, Error.invalid([{"query", message}], collection.fields)}
    end
  end

  defp check(collection, attrs, type) do
    with {:ok, query} <- check_query(collection, attrs["query"]),
         {:ok, options} <- check_options(collection, type, attrs["options"] || %{}) do
      {:ok, Map.merge(attrs, %{"query" => query, "options" => options})}
    end
  end

  defp check_query(collection, query) do
    case Query.parse(query, collection) do
      {:ok, query} -> {:ok, Query.to_wire(query)}
      {:error, message} -> {:error, Error.invalid([{"query", message}], collection.fields)}
    end
  end

  defp check_options(_collection, _type, options) when not is_map(options),
    do: {:error, Error.invalid([{"options", "are a map, got: #{inspect(options)}"}])}

  defp check_options(collection, type, options) do
    options = Collections.stringify(options)

    result =
      case type do
        "table" -> table(collection, options)
        "board" -> board(collection, options)
        "list" -> keys(collection, options, ~w(fields))
        "calendar" -> calendar(collection, options)
        "chart" -> chart(options)
        "canvas" -> canvas(collection, options)
        _other -> {:ok, options}
      end

    case result do
      {:ok, options} -> {:ok, options}
      {:error, message} -> {:error, Error.invalid([{"options", message}])}
    end
  end

  defp table(collection, options) do
    with {:ok, options} <- keys(collection, options, ~w(columns hidden)) do
      case options["widths"] do
        nil -> {:ok, options}
        %{} = widths -> widths(collection, widths, options)
        other -> {:error, "a table's widths are a map of field keys and pixels, got: #{inspect(other)}"}
      end
    end
  end

  defp widths(collection, widths, options) do
    widths =
      for {ref, px} <- widths, field = Collection.field(collection, ref), is_integer(px) and px in 40..2000, into: %{},
        do: {field.key, px}

    {:ok, Map.put(options, "widths", widths)}
  end

  defp board(collection, options) do
    with {:ok, field} <- one_field(collection, options["group_by"], "a board's group_by", &(Type.kind(&1) in [:choice, :boolean])),
         {:ok, options} <- keys(collection, options, ~w(card_fields)) do
      hidden = options["hidden_groups"] || []

      if is_list(hidden),
        do: {:ok, Map.put(options, "group_by", field.key)},
        else: {:error, "a board's hidden_groups are a list, got: #{inspect(hidden)}"}
    end
  end

  defp calendar(collection, options) do
    with {:ok, field} <- one_field(collection, options["date_field"], "a calendar's date_field", &(Type.kind(&1) in [:date, :datetime])) do
      {:ok, Map.put(options, "date_field", field.key)}
    end
  end

  defp chart(options) do
    case options["spec"] do
      nil -> {:ok, options}
      %{} -> {:ok, options}
      other -> {:error, "a chart's spec is a map (Fude.Spec.dump/1), got: #{inspect(other)}"}
    end
  end

  defp canvas(collection, options) do
    with {:ok, options} <- edges(collection, options) do
      case options["layout"] do
        nil -> {:ok, options}
        %{} = layout -> {:ok, Map.put(options, "layout", layout(layout))}
        other -> {:error, "a canvas's layout is a map of record ids and places, got: #{inspect(other)}"}
      end
    end
  end

  defp edges(_collection, %{"edges" => nil} = options), do: {:ok, options}

  defp edges(collection, %{"edges" => ref} = options) do
    with {:ok, field} <- one_field(collection, ref, "a canvas's edges", &(&1.type == "relation")) do
      {:ok, Map.put(options, "edges", field.key)}
    end
  end

  defp edges(_collection, options), do: {:ok, options}

  defp layout(layout) do
    for {id, %{} = place} <- layout,
        place = Collections.stringify(place),
        is_number(place["x"]) and is_number(place["y"]),
        into: %{},
        do: {to_string(id), Map.take(place, ~w(x y w h))}
  end

  defp one_field(collection, ref, what, ok?) do
    case (is_binary(ref) or is_atom(ref)) && ref && Collection.field(collection, ref) do
      nil -> {:error, "#{what} names a field of the collection, got: #{inspect(ref)}"}
      false -> {:error, "#{what} names a field, got: #{inspect(ref)}"}
      field -> if ok?.(field), do: {:ok, field}, else: {:error, "#{what} cannot be #{inspect(field.name)} (#{field.type})"}
    end
  end

  # Options that list fields, given by key or name, kept by key.
  defp keys(collection, options, names) do
    Enum.reduce_while(names, {:ok, options}, fn name, {:ok, options} ->
      case options[name] do
        nil ->
          {:cont, {:ok, options}}

        list when is_list(list) ->
          case Enum.split_with(list, &Collection.field(collection, &1)) do
            {found, []} -> {:cont, {:ok, Map.put(options, name, Enum.map(found, &Collection.field(collection, &1).key))}}
            {_found, [ref | _]} -> {:halt, {:error, "#{name} names fields of the collection, got: #{inspect(ref)}"}}
          end

        other ->
          {:halt, {:error, "#{name} is a list of fields, got: #{inspect(other)}"}}
      end
    end)
  end

  @doc false
  # A deleted field, taken out of every view of its collection: its
  # conditions and sorts, and its key in the options.
  def drop_field(repo, collection_id, key) do
    for view <- Collections.views_of(repo, collection_id) do
      query = drop_from_query(view.query, key)
      options = drop_from_options(view.options, key)

      if query != view.query or options != view.options do
        view |> Ecto.Changeset.change(query: query, options: options) |> repo.update!()
      end
    end

    :ok
  end

  defp drop_from_query(query, key) do
    query
    |> then(fn q -> if f = q["filter"], do: put_or_delete(q, "filter", drop_from_filter(f, key)), else: q end)
    |> then(fn q -> if s = q["sort"], do: put_or_delete(q, "sort", Enum.reject(s, &(&1["field"] == key))), else: q end)
  end

  defp drop_from_filter(%{"field" => field}, key) when field == key, do: nil

  defp drop_from_filter(%{} = filter, key) when map_size(filter) == 1 do
    case Map.to_list(filter) do
      [{op, list}] when op in ["and", "or"] and is_list(list) ->
        case list |> Enum.map(&drop_from_filter(&1, key)) |> Enum.reject(&is_nil/1) do
          [] -> nil
          list -> %{op => list}
        end

      _ ->
        filter
    end
  end

  defp drop_from_filter(filter, _key), do: filter

  defp put_or_delete(map, name, value) when value in [nil, []], do: Map.delete(map, name)
  defp put_or_delete(map, name, value), do: Map.put(map, name, value)

  defp drop_from_options(options, key) do
    Map.new(options, fn
      {name, value} when value == key -> {name, nil}
      {name, list} when is_list(list) -> {name, Enum.reject(list, &(&1 == key))}
      {"widths", %{} = widths} -> {"widths", Map.delete(widths, key)}
      other -> other
    end)
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new()
  end
end
