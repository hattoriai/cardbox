defmodule Cardbox.Collections do
  @moduledoc false
  # Collections and their fields: made, changed and deleted, with the
  # records' values kept in step (a field deleted leaves no values behind, a
  # type changed converts them, a choice removed is removed from records)
  # and the saved views too.

  import Ecto.Query

  alias Cardbox.{Collection, Error, Field, Key, Links, Record, Search, Store, Type, View, Views}
  alias Narabe.Position

  ## Collections

  def get(mod, id) do
    Collection |> preload(:fields) |> Store.repo(mod).get(id)
  end

  def list(mod, {type, id}) do
    from(c in Collection,
      where: c.owner_type == ^to_string(type) and c.owner_id == ^to_string(id),
      order_by: [asc: c.name, asc: c.id],
      preload: :fields
    )
    |> Store.repo(mod).all()
  end

  def list(mod, nil) do
    from(c in Collection,
      where: is_nil(c.owner_type),
      order_by: [asc: c.name, asc: c.id],
      preload: :fields
    )
    |> Store.repo(mod).all()
  end

  def create(mod, attrs, opts) do
    attrs = attrs |> stringify() |> owner()
    {fields, attrs} = Map.pop(attrs, "fields", [])

    with :ok <- Store.allow(mod, opts, :create_collection, attrs) do
      Store.transaction(mod, &insert_with_fields(mod, &1, attrs, fields))
    end
  end

  defp insert_with_fields(mod, repo, attrs, fields) do
    with {:ok, collection} <- insert(repo, attrs) do
      add_fields(mod, repo, %{collection | fields: []}, fields)
    end
  end

  defp add_fields(mod, repo, collection, fields) do
    Enum.reduce_while(fields, {:ok, collection}, fn field, {:ok, collection} ->
      case do_add_field(mod, repo, collection, stringify(field)) do
        {:ok, collection, _field} -> {:cont, {:ok, collection}}
        error -> {:halt, error}
      end
    end)
  end

  defp insert(repo, attrs) do
    case %Collection{} |> Collection.changeset(attrs) |> repo.insert() do
      {:ok, collection} -> {:ok, collection}
      {:error, changeset} -> {:error, Error.from_changeset(changeset)}
    end
  end

  defp owner(%{"owner" => {type, id}} = attrs),
    do:
      attrs
      |> Map.delete("owner")
      |> Map.merge(%{"owner_type" => to_string(type), "owner_id" => to_string(id)})

  defp owner(attrs), do: Map.delete(attrs, "owner")

  def update(mod, %Collection{} = collection, attrs, opts) do
    attrs = attrs |> stringify() |> Map.take(~w(name description icon))

    with :ok <- Store.allow(mod, opts, :update_collection, collection) do
      case collection |> Collection.changeset(attrs) |> Store.repo(mod).update() do
        {:ok, collection} ->
          Store.broadcast(
            mod,
            Store.event(:collection_updated, collection.id, opts, mod, collection: collection)
          )

          {:ok, collection}

        {:error, changeset} ->
          {:error, Error.from_changeset(changeset)}
      end
    end
  end

  def delete(mod, %Collection{} = collection, opts) do
    with :ok <- Store.allow(mod, opts, :delete_collection, collection),
         {:ok, collection} <- Store.repo(mod).delete(collection) do
      Store.broadcast(
        mod,
        Store.event(:collection_deleted, collection.id, opts, mod, collection: collection)
      )

      {:ok, collection}
    end
  end

  ## Fields

  def add_field(mod, %Collection{} = collection, attrs, opts) do
    with :ok <- Store.allow(mod, opts, :change_fields, collection),
         {:ok, {collection, field}} <-
           Store.transaction(mod, &add_one_field(mod, &1, collection, attrs)) do
      Store.broadcast(
        mod,
        Store.event(:field_added, collection.id, opts, mod, collection: collection, field: field)
      )

      for reverse <- reverse_fields(Store.repo(mod), field),
          do: broadcast_reverse(mod, collection, reverse, opts)

      {:ok, collection}
    end
  end

  defp add_one_field(mod, repo, collection, attrs) do
    case do_add_field(mod, repo, collection, stringify(attrs)) do
      {:ok, collection, field} -> {:ok, {collection, field}}
      error -> error
    end
  end

  # A two-way relation's other side, added to its collection.
  defp broadcast_reverse(mod, collection, reverse, opts) do
    target =
      if reverse.collection_id == collection.id,
        do: collection,
        else: get(mod, reverse.collection_id)

    Store.broadcast(
      mod,
      Store.event(:field_added, target.id, opts, mod, collection: target, field: reverse)
    )
  end

  defp do_add_field(mod, repo, collection, attrs) do
    {options, attrs} = Map.pop(attrs, "options", %{})
    {reverse_of, attrs} = Map.pop(attrs, "__reverse_of")
    options = options |> Kernel.||(%{}) |> stringify() |> Map.delete("reverse_of")

    options =
      if reverse_of,
        do: Map.merge(options, %{"reverse_of" => reverse_of, "two_way" => true}),
        else: options

    changeset = Field.changeset(%Field{collection_id: collection.id}, attrs)
    name = Ecto.Changeset.get_field(changeset, :name)
    type = Ecto.Changeset.get_field(changeset, :type)

    with :ok <- changeset_ok(changeset),
         :ok <- unique_name(collection, name, nil),
         {:ok, options} <- options(type, options, %{}),
         :ok <- relation_target(mod, type, options) do
      key = Key.from_name(name, Enum.map(collection.fields, & &1.key), "field")
      position = position(collection.fields, Map.get(attrs, "position"))

      changeset
      |> Ecto.Changeset.put_change(:options, options)
      |> Ecto.Changeset.put_change(:key, key)
      |> Ecto.Changeset.put_change(:position, position)
      |> repo.insert()
      |> case do
        {:ok, field} ->
          {:ok, with_fields(collection, [field | collection.fields]), field} |> two_way(mod, repo)

        {:error, changeset} ->
          {:error, Error.from_changeset(changeset)}
      end
    end
  end

  # A two-way relation's other side: a relation of its collection back to
  # this one, named after this collection, that reads the same links from
  # their targets.
  defp two_way(
         {:ok, collection,
          %Field{type: "relation", options: %{"two_way" => true} = options} = field},
         mod,
         repo
       )
       when not is_map_key(options, "reverse_of") do
    target_id = options["collection_id"]
    target = if target_id == collection.id, do: collection, else: get(mod, target_id)
    name = free_name(target, options["reverse_name"] || collection.name)

    attrs = %{
      "name" => name,
      "type" => "relation",
      "options" => %{"collection_id" => collection.id},
      "__reverse_of" => field.id
    }

    case do_add_field(mod, repo, target, attrs) do
      {:ok, target, _reverse} when target_id == collection.id -> {:ok, target, field}
      {:ok, _target, _reverse} -> {:ok, collection, field}
      error -> error
    end
  end

  defp two_way(result, _mod, _repo), do: result

  defp free_name(collection, name) do
    taken = MapSet.new(collection.fields, &String.downcase(&1.name))

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn n -> if n == 1, do: name, else: "#{name} #{n}" end)
    |> Enum.find(&(not MapSet.member?(taken, String.downcase(&1))))
  end

  # The other sides of a two-way relation.
  defp reverse_fields(repo, %Field{type: "relation", id: id}) do
    from(f in Field, where: f.type == "relation")
    |> repo.all()
    |> Enum.filter(&(&1.options["reverse_of"] == id))
  end

  defp reverse_fields(_repo, _field), do: []

  def update_field(mod, %Collection{} = collection, ref, attrs, opts) do
    attrs = stringify(attrs)

    with {:ok, field} <- field(collection, ref),
         :ok <- Store.allow(mod, opts, :change_fields, collection),
         {:ok, {collection, field}} <-
           Store.transaction(mod, fn repo ->
             do_update_field(mod, repo, collection, field, attrs)
           end) do
      Store.broadcast(
        mod,
        Store.event(:field_updated, collection.id, opts, mod,
          collection: collection,
          field: field
        )
      )

      {:ok, collection}
    end
  end

  defp do_update_field(mod, repo, collection, field, attrs) do
    changeset = Field.changeset(field, Map.take(attrs, ~w(name type description)))
    name = Ecto.Changeset.get_field(changeset, :name)
    type = Ecto.Changeset.get_field(changeset, :type)
    retyped? = type != field.type

    given = Map.get(attrs, "options")

    with :ok <- changeset_ok(changeset),
         :ok <- unique_name(collection, name, field.id),
         {:ok, options} <- new_options(mod, repo, collection, field, type, given),
         :ok <- relation_target(mod, type, options),
         {:ok, updated} <- repo.update(Ecto.Changeset.put_change(changeset, :options, options)) do
      fields = Enum.map(collection.fields, &if(&1.id == field.id, do: updated, else: &1))
      after_change = with_fields(collection, fields)

      cond do
        retyped? ->
          convert(repo, after_change, field, updated)

        field.type in ~w(select multi_select status) ->
          drop_choices(repo, after_change, field, updated)

        true ->
          :ok
      end

      {:ok, {after_change, updated}}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, Error.from_changeset(changeset)}
      error -> error
    end
  end

  # The options of a field after a change: those given, checked with the
  # field's options before; for a field that becomes a select, a
  # multi-select or a status with no choices given, a choice for each value
  # its records have.
  defp new_options(_mod, _repo, _collection, %Field{type: "relation"} = field, "relation", given)
       when given != nil do
    given = stringify(given)
    kept = Map.take(field.options, ~w(collection_id two_way reverse_name reverse_of))

    if Map.take(given, ~w(collection_id two_way)) |> Enum.all?(fn {k, v} -> kept[k] == v end),
      do: options("relation", Map.merge(given, kept), field.options),
      else:
        {:error,
         Error.invalid([
           {"options",
            "a relation keeps its collection and its sides; add a new field for others"}
         ])}
  end

  defp new_options(mod, repo, collection, field, type, given) do
    cond do
      given != nil and type == field.type ->
        options(type, given, field.options)

      given != nil ->
        options(type, given, %{})

      type == field.type ->
        {:ok, field.options}

      type in ~w(select multi_select status) ->
        options(
          type,
          %{"choices" => choices_from_values(mod, repo, collection, field, type)},
          %{}
        )

      type == "number" and field.type == "number" ->
        {:ok, field.options}

      true ->
        options(type, %{}, %{})
    end
  end

  defp choices_from_values(mod, repo, collection, field, type) do
    names =
      collection.id
      |> records_query()
      |> repo.all()
      |> Enum.flat_map(fn record ->
        case Type.plain(field, Map.get(record.data, field.key)) do
          nil -> []
          list when is_list(list) -> Enum.map(list, &to_string/1)
          value -> [to_string(value)]
        end
      end)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&String.downcase/1)
      |> Enum.take(200)

    _ = mod

    cond do
      names != [] -> names
      type == "status" -> Cardbox.Choice.default_status()
      true -> []
    end
  end

  defp options(type, options, previous) do
    case Type.check_options(type, options, previous) do
      {:ok, options} -> {:ok, options}
      {:error, message} -> {:error, Error.invalid([{"options", message}])}
    end
  end

  defp relation_target(mod, "relation", %{"collection_id" => id}) do
    if Store.repo(mod).exists?(from(c in Collection, where: c.id == ^id)),
      do: :ok,
      else:
        {:error,
         Error.invalid([{"options", "a relation's collection_id names a collection, got: #{id}"}])}
  end

  defp relation_target(_mod, _type, _options), do: :ok

  # Each record's value of a field that changed its type, read as words or
  # numbers and given to the new type; a value the new type does not take
  # is left out.
  defp convert(repo, collection, old, new) do
    links = if old.type == "relation", do: relation_values(repo, collection, old), else: %{}

    each_record(repo, collection, fn record ->
      old_value =
        if old.type == "relation",
          do: Map.get(links, record.id),
          else: Map.get(record.data, old.key)

      put_value(record, new.key, converted(Type.plain(old, old_value), new))
    end)

    if old.type == "relation", do: unrelate(repo, old)
    :ok
  end

  # A value as plain words or numbers, given to a field of another type.
  defp converted(plain, new) do
    cond do
      Type.system?(new.type) or new.type == "relation" or plain == nil ->
        nil

      is_list(plain) and Type.kind(new) != :list ->
        plain |> Enum.map_join(", ", &to_string/1) |> cast_or_nil(new)

      true ->
        cast_or_nil(plain, new)
    end
  end

  # A relation that stops being one: its links and its other sides, gone.
  defp unrelate(repo, field) do
    Links.delete_field_links(repo, field)
    for reverse <- reverse_fields(repo, field), do: repo.delete!(reverse)
  end

  # The links of a relation, by record.
  defp relation_values(repo, collection, field) do
    records =
      repo.all(
        from(r in Record,
          where: r.collection_id == ^collection.id,
          select: struct(r, [:id, :data])
        )
      )

    for record <- Links.fill(repo, %{collection | fields: [field]}, records),
        into: %{},
        do: {record.id, record.data[field.key]}
  end

  defp cast_or_nil(value, field) do
    case Type.cast(field, value) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  # The records' values of choices a field no longer has, left out; and
  # their search text, which has the choices' names.
  defp drop_choices(repo, collection, old, new) do
    kept = MapSet.new(Field.choices(new), & &1["id"])
    removed = for %{"id" => id} <- Field.choices(old), not MapSet.member?(kept, id), do: id

    if removed != [] or Field.choices(old) != Field.choices(new) do
      each_record(repo, collection, &without_choices(&1, old.key, removed))
    end

    :ok
  end

  defp without_choices(record, key, removed) do
    case Map.get(record.data, key) do
      ids when is_list(ids) -> put_value(record, key, Enum.reject(ids, &(&1 in removed)))
      id -> if id in removed, do: put_value(record, key, nil), else: record.data
    end
  end

  def delete_field(mod, %Collection{} = collection, ref, opts) do
    with {:ok, field} <- field(collection, ref),
         :ok <- Store.allow(mod, opts, :change_fields, collection),
         {:ok, collection} <-
           Store.transaction(mod, fn repo -> do_delete_field(mod, repo, collection, field) end) do
      Store.broadcast(
        mod,
        Store.event(:field_deleted, collection.id, opts, mod,
          collection: collection,
          field: field
        )
      )

      {:ok, collection}
    end
  end

  # The field, its other sides, its values and its places in views, gone.
  defp do_delete_field(mod, repo, collection, field) do
    reverses = reverse_fields(repo, field)
    for reverse <- reverses, do: repo.delete!(reverse)
    repo.delete!(field)
    remove_key(repo, Store.dialect(mod), collection.id, field.key)
    Views.drop_field(repo, collection.id, field.key)
    for r <- reverses, do: Views.drop_field(repo, r.collection_id, r.key)

    gone = MapSet.new([field.id | Enum.map(reverses, & &1.id)])

    collection =
      with_fields(collection, Enum.reject(collection.fields, &MapSet.member?(gone, &1.id)))

    if Search.text(%{collection | fields: [field]}, %{field.key => "x"}),
      do: each_record(repo, collection, & &1.data)

    {:ok, collection}
  end

  defp remove_key(repo, :postgres, collection_id, key) do
    from(r in Record,
      where: r.collection_id == ^collection_id,
      update: [set: [data: fragment("? - ?", r.data, ^key)]]
    )
    |> repo.update_all([])
  end

  defp remove_key(repo, :sqlite, collection_id, key) do
    from(r in Record,
      where: r.collection_id == ^collection_id,
      update: [set: [data: fragment("json_remove(?, ?)", r.data, ^("$." <> key))]]
    )
    |> repo.update_all([])
  end

  def move_field(mod, %Collection{} = collection, ref, opts) do
    with {:ok, field} <- field(collection, ref),
         :ok <- Store.allow(mod, opts, :change_fields, collection) do
      others = Enum.reject(collection.fields, &(&1.id == field.id))
      position = position(others, place(collection, opts))

      case field |> Ecto.Changeset.change(position: position) |> Store.repo(mod).update() do
        {:ok, moved} ->
          collection = with_fields(collection, [moved | others])

          Store.broadcast(
            mod,
            Store.event(:field_moved, collection.id, opts, mod,
              collection: collection,
              field: moved
            )
          )

          {:ok, collection}

        {:error, changeset} ->
          {:error, Error.from_changeset(changeset)}
      end
    end
  end

  # Where a field goes: first, last, or after or before another.
  defp place(collection, opts) do
    cond do
      ref = opts[:after] -> {:after, Collection.field(collection, ref)}
      ref = opts[:before] -> {:before, Collection.field(collection, ref)}
      opts[:to] == :first -> :first
      true -> :last
    end
  end

  # A position among fields (or records) in their order.
  @doc false
  def position(items, place) do
    items = Enum.sort_by(items, &{&1.position, &1.id})

    case place do
      :first -> Position.between(nil, items |> List.first() |> pos())
      {:after, %{} = item} -> between_after(items, item)
      {:before, %{} = item} -> between_before(items, item)
      _last -> Position.between(items |> List.last() |> pos(), nil)
    end
  end

  defp between_after(items, item) do
    {_before, rest} = Enum.split_while(items, &(&1.id != item.id))

    case rest do
      [found, next | _] -> Position.between(found.position, next.position)
      [found] -> Position.between(found.position, nil)
      [] -> Position.between(items |> List.last() |> pos(), nil)
    end
  end

  defp between_before(items, item) do
    {before, rest} = Enum.split_while(items, &(&1.id != item.id))

    case rest do
      [found | _] -> Position.between(before |> List.last() |> pos(), found.position)
      [] -> Position.between(nil, items |> List.first() |> pos())
    end
  end

  defp pos(nil), do: nil
  defp pos(item), do: item.position

  ## Helpers

  def field(collection, ref) do
    case Collection.field(collection, ref) do
      nil -> {:error, Error.not_found("the field #{inspect(ref)}")}
      field -> {:ok, field}
    end
  end

  defp unique_name(collection, name, id) do
    taken? =
      Enum.any?(collection.fields, fn field ->
        field.id != id and is_binary(name) and
          String.downcase(field.name) == String.downcase(name)
      end)

    if taken?,
      do: {:error, Error.invalid([{"name", "is taken by another field: #{inspect(name)}"}])},
      else: :ok
  end

  defp changeset_ok(%Ecto.Changeset{valid?: true}), do: :ok
  defp changeset_ok(changeset), do: {:error, Error.from_changeset(changeset)}

  defp with_fields(collection, fields),
    do: %{collection | fields: Enum.sort_by(fields, &{&1.position, &1.id})}

  defp records_query(collection_id),
    do: from(r in Record, where: r.collection_id == ^collection_id, order_by: r.id)

  # Calls the function on each record of a collection, a hundred at a time,
  # and writes the data it returns, and the search text of the collection's
  # fields, when they changed.
  defp each_record(repo, collection, fun, after_id \\ 0) do
    batch =
      from(r in Record,
        where: r.collection_id == ^collection.id and r.id > ^after_id,
        order_by: r.id,
        limit: 100
      )
      |> repo.all()

    for record <- batch do
      data = fun.(record)
      search_text = Search.text(collection, data)

      if data != record.data or search_text != record.search_text do
        record |> Ecto.Changeset.change(data: data, search_text: search_text) |> repo.update!()
      end
    end

    if length(batch) == 100, do: each_record(repo, collection, fun, List.last(batch).id)
    :ok
  end

  @doc false
  # Writes the search text of every record of a collection again: after an
  # upgrade that changes what it holds.
  def reindex(mod, %Collection{} = collection) do
    Store.transaction(mod, fn repo -> {:ok, each_record(repo, collection, & &1.data)} end)
  end

  defp put_value(record, key, value) when value in [nil, "", []], do: Map.delete(record.data, key)
  defp put_value(record, key, value), do: Map.put(record.data, key, value)

  @doc false
  def stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  def stringify(list) when is_list(list), do: list |> Map.new() |> stringify()

  @doc false
  def views_of(repo, collection_id),
    do: repo.all(from(v in View, where: v.collection_id == ^collection_id))
end
