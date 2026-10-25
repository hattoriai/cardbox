defmodule Cardbox.Collections do
  @moduledoc false
  # Collections and their fields: made, changed and deleted, with the
  # records' values kept in step (a field deleted leaves no values behind, a
  # type changed converts them, a choice removed is removed from records)
  # and the saved views too.

  import Ecto.Query

  alias Cardbox.{Collection, Error, Field, Key, Record, Store, Type, View, Views}
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
    from(c in Collection, where: is_nil(c.owner_type), order_by: [asc: c.name, asc: c.id], preload: :fields)
    |> Store.repo(mod).all()
  end

  def create(mod, attrs, opts) do
    attrs = attrs |> stringify() |> owner()
    {fields, attrs} = Map.pop(attrs, "fields", [])

    with :ok <- Store.allow(mod, opts, :create_collection, attrs) do
      Store.transaction(mod, fn repo ->
        with {:ok, collection} <- insert(repo, attrs) do
          collection = %{collection | fields: []}

          Enum.reduce_while(fields, {:ok, collection}, fn field, {:ok, collection} ->
            case do_add_field(mod, repo, collection, stringify(field)) do
              {:ok, collection, _field} -> {:cont, {:ok, collection}}
              error -> {:halt, error}
            end
          end)
        end
      end)
    end
  end

  defp insert(repo, attrs) do
    case %Collection{} |> Collection.changeset(attrs) |> repo.insert() do
      {:ok, collection} -> {:ok, collection}
      {:error, changeset} -> {:error, Error.from_changeset(changeset)}
    end
  end

  defp owner(%{"owner" => {type, id}} = attrs),
    do: attrs |> Map.delete("owner") |> Map.merge(%{"owner_type" => to_string(type), "owner_id" => to_string(id)})

  defp owner(attrs), do: Map.delete(attrs, "owner")

  def update(mod, %Collection{} = collection, attrs, opts) do
    attrs = attrs |> stringify() |> Map.take(~w(name description icon))

    with :ok <- Store.allow(mod, opts, :update_collection, collection) do
      case collection |> Collection.changeset(attrs) |> Store.repo(mod).update() do
        {:ok, collection} ->
          Store.broadcast(mod, Store.event(:collection_updated, collection.id, opts, mod, collection: collection))
          {:ok, collection}

        {:error, changeset} ->
          {:error, Error.from_changeset(changeset)}
      end
    end
  end

  def delete(mod, %Collection{} = collection, opts) do
    with :ok <- Store.allow(mod, opts, :delete_collection, collection),
         {:ok, collection} <- Store.repo(mod).delete(collection) do
      Store.broadcast(mod, Store.event(:collection_deleted, collection.id, opts, mod, collection: collection))
      {:ok, collection}
    end
  end

  ## Fields

  def add_field(mod, %Collection{} = collection, attrs, opts) do
    with :ok <- Store.allow(mod, opts, :change_fields, collection),
         {:ok, {collection, field}} <-
           Store.transaction(mod, fn repo ->
             case do_add_field(mod, repo, collection, stringify(attrs)) do
               {:ok, collection, field} -> {:ok, {collection, field}}
               error -> error
             end
           end) do
      Store.broadcast(mod, Store.event(:field_added, collection.id, opts, mod, collection: collection, field: field))
      {:ok, collection}
    end
  end

  defp do_add_field(mod, repo, collection, attrs) do
    {options, attrs} = Map.pop(attrs, "options", %{})
    changeset = Field.changeset(%Field{collection_id: collection.id}, attrs)
    name = Ecto.Changeset.get_field(changeset, :name)
    type = Ecto.Changeset.get_field(changeset, :type)

    with :ok <- changeset_ok(changeset),
         :ok <- unique_name(collection, name, nil),
         {:ok, options} <- options(type, options || %{}, %{}),
         :ok <- relation_target(mod, type, options) do
      key = Key.from_name(name, Enum.map(collection.fields, & &1.key), "field")
      position = position(collection.fields, Map.get(attrs, "position"))

      changeset
      |> Ecto.Changeset.put_change(:options, options)
      |> Ecto.Changeset.put_change(:key, key)
      |> Ecto.Changeset.put_change(:position, position)
      |> repo.insert()
      |> case do
        {:ok, field} -> {:ok, with_fields(collection, [field | collection.fields]), field}
        {:error, changeset} -> {:error, Error.from_changeset(changeset)}
      end
    end
  end

  def update_field(mod, %Collection{} = collection, ref, attrs, opts) do
    attrs = stringify(attrs)

    with {:ok, field} <- field(collection, ref),
         :ok <- Store.allow(mod, opts, :change_fields, collection),
         {:ok, {collection, field}} <-
           Store.transaction(mod, fn repo -> do_update_field(mod, repo, collection, field, attrs) end) do
      Store.broadcast(mod, Store.event(:field_updated, collection.id, opts, mod, collection: collection, field: field))
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
      cond do
        retyped? -> convert(mod, repo, collection, field, updated)
        field.type in ~w(select multi_select status) -> drop_choices(mod, repo, collection, field, updated)
        true -> :ok
      end

      fields = Enum.map(collection.fields, &if(&1.id == field.id, do: updated, else: &1))
      {:ok, {with_fields(collection, fields), updated}}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, Error.from_changeset(changeset)}
      error -> error
    end
  end

  # The options of a field after a change: those given, checked with the
  # field's options before; for a field that becomes a select, a
  # multi-select or a status with no choices given, a choice for each value
  # its records have.
  defp new_options(mod, repo, collection, field, type, given) do
    cond do
      given != nil and type == field.type ->
        options(type, given, field.options)

      given != nil ->
        options(type, given, %{})

      type == field.type ->
        {:ok, field.options}

      type in ~w(select multi_select status) ->
        options(type, %{"choices" => choices_from_values(mod, repo, collection, field, type)}, %{})

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
      else: {:error, Error.invalid([{"options", "a relation's collection_id names a collection, got: #{id}"}])}
  end

  defp relation_target(_mod, _type, _options), do: :ok

  # Each record's value of a field that changed its type, read as words or
  # numbers and given to the new type; a value the new type does not take
  # is left out.
  defp convert(mod, repo, collection, old, new) do
    each_record(repo, collection.id, fn record ->
      plain = Type.plain(old, Map.get(record.data, old.key))

      value =
        cond do
          Type.system?(new.type) or plain == nil ->
            nil

          is_list(plain) and Type.kind(new) != :list ->
            plain |> Enum.map_join(", ", &to_string/1) |> cast_or_nil(new)

          true ->
            cast_or_nil(plain, new)
        end

      put_value(record, new.key, value)
    end)

    _ = mod
    :ok
  end

  defp cast_or_nil(value, field) do
    case Type.cast(field, value) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  # The records' values of choices a field no longer has, left out.
  defp drop_choices(_mod, repo, collection, old, new) do
    kept = MapSet.new(Field.choices(new), & &1["id"])
    removed = for %{"id" => id} <- Field.choices(old), not MapSet.member?(kept, id), do: id

    if removed != [] do
      each_record(repo, collection.id, fn record ->
        case Map.get(record.data, old.key) do
          ids when is_list(ids) -> put_value(record, old.key, Enum.reject(ids, &(&1 in removed)))
          id -> if id in removed, do: put_value(record, old.key, nil), else: record.data
        end
      end)
    end

    :ok
  end

  def delete_field(mod, %Collection{} = collection, ref, opts) do
    with {:ok, field} <- field(collection, ref),
         :ok <- Store.allow(mod, opts, :change_fields, collection),
         {:ok, collection} <-
           Store.transaction(mod, fn repo ->
             repo.delete!(field)
             remove_key(repo, Store.dialect(mod), collection.id, field.key)
             Views.drop_field(repo, collection.id, field.key)
             {:ok, with_fields(collection, Enum.reject(collection.fields, &(&1.id == field.id)))}
           end) do
      Store.broadcast(mod, Store.event(:field_deleted, collection.id, opts, mod, collection: collection, field: field))
      {:ok, collection}
    end
  end

  defp remove_key(repo, :postgres, collection_id, key) do
    from(r in Record, where: r.collection_id == ^collection_id, update: [set: [data: fragment("? - ?", r.data, ^key)]])
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
          Store.broadcast(mod, Store.event(:field_moved, collection.id, opts, mod, collection: collection, field: moved))
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
        field.id != id and is_binary(name) and String.downcase(field.name) == String.downcase(name)
      end)

    if taken?, do: {:error, Error.invalid([{"name", "is taken by another field: #{inspect(name)}"}])}, else: :ok
  end

  defp changeset_ok(%Ecto.Changeset{valid?: true}), do: :ok
  defp changeset_ok(changeset), do: {:error, Error.from_changeset(changeset)}

  defp with_fields(collection, fields), do: %{collection | fields: Enum.sort_by(fields, &{&1.position, &1.id})}

  defp records_query(collection_id), do: from(r in Record, where: r.collection_id == ^collection_id, order_by: r.id)

  # Calls the function on each record of a collection, a hundred at a time,
  # and writes the data it returns when it changed.
  defp each_record(repo, collection_id, fun, after_id \\ 0) do
    batch =
      from(r in Record, where: r.collection_id == ^collection_id and r.id > ^after_id, order_by: r.id, limit: 100)
      |> repo.all()

    for record <- batch do
      data = fun.(record)

      if data != record.data do
        record |> Ecto.Changeset.change(data: data) |> repo.update!()
      end
    end

    if length(batch) == 100, do: each_record(repo, collection_id, fun, List.last(batch).id)
    :ok
  end

  defp put_value(record, key, value) when value in [nil, "", []], do: Map.delete(record.data, key)
  defp put_value(record, key, value), do: Map.put(record.data, key, value)

  @doc false
  def stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  def stringify(list) when is_list(list), do: list |> Map.new() |> stringify()

  @doc false
  def views_of(repo, collection_id), do: repo.all(from(v in View, where: v.collection_id == ^collection_id))
end
