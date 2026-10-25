defmodule Cardbox.Records do
  @moduledoc false
  # Records: read through a query, and written through one path that checks
  # each value against its field, compares what the writer expected, keeps
  # the order and who changed what, and broadcasts the change.

  import Ecto.Query

  alias Cardbox.{
    Collection,
    Collections,
    Condition,
    Error,
    Field,
    Links,
    Query,
    Record,
    Search,
    SQL,
    Store,
    Type,
    View,
    Views
  }

  ## Reading

  def get(mod, %Collection{id: id} = collection, record_id) do
    repo = Store.repo(mod)

    case repo.one(from(r in Record, where: r.collection_id == ^id and r.id == ^record_id)) do
      nil -> nil
      record -> hd(Links.fill(repo, collection, [record]))
    end
  end

  def list(mod, %Collection{} = collection, query, opts) do
    with {:ok, query} <- parse(collection, query) do
      ecto =
        collection
        |> SQL.query(query, Store.dialect(mod), opts)
        |> then(&if(limit = opts[:limit], do: limit(&1, ^limit), else: &1))
        |> then(&if(offset = opts[:offset], do: offset(&1, ^offset), else: &1))

      repo = Store.repo(mod)
      {:ok, Links.fill(repo, collection, repo.all(ecto))}
    end
  end

  def count(mod, %Collection{} = collection, query, opts) do
    with {:ok, query} <- parse(collection, query) do
      ecto = SQL.where_query(collection, query, Store.dialect(mod), opts)
      {:ok, Store.repo(mod).aggregate(ecto, :count)}
    end
  end

  @doc false
  # The titles of records of a collection (Collection.title_field/1), by id:
  # what a relation shows of the records it links to.
  def titles(mod, collection_id, ids) do
    ids = Enum.uniq(ids)

    with true <- ids != [],
         %Collection{} = collection <- Collections.get(mod, collection_id),
         %Field{key: key} <- Collection.title_field(collection) do
      from(r in Record,
        where: r.collection_id == ^collection_id and r.id in ^ids,
        select: {r.id, r.data}
      )
      |> Store.repo(mod).all()
      |> Map.new(fn {id, data} -> {id, data[key] || "Untitled"} end)
    else
      _ -> Map.new(ids, &{&1, "##{&1}"})
    end
  end

  def meets?(%Collection{} = collection, query, %Record{} = record, opts) do
    with {:ok, query} <- parse(collection, query) do
      {:ok,
       query |> Condition.lower(collection, Condition.context(opts)) |> Condition.meets?(record)}
    end
  end

  @doc false
  def parse(collection, %View{} = view), do: Views.query(collection, view)

  def parse(collection, query) do
    case Query.parse(query, collection) do
      {:ok, query} -> {:ok, query}
      {:error, message} -> {:error, Error.invalid([{nil, message}], collection.fields)}
    end
  end

  ## Writing

  def insert(mod, %Collection{} = collection, values, opts) do
    with :ok <- Store.allow(mod, opts, :insert, collection),
         {:ok, record} <-
           Store.transaction(mod, fn repo -> do_insert(mod, repo, collection, values, opts) end) do
      {record, linked} = record

      Store.broadcast(
        mod,
        Store.event(:record_inserted, collection.id, opts, mod, record: record)
      )

      broadcast_linked(mod, linked, opts)
      {:ok, record}
    end
  end

  def insert_all(mod, %Collection{} = collection, list, opts) do
    with :ok <- Store.allow(mod, opts, :insert, collection),
         {:ok, records} <-
           Store.transaction(mod, &do_insert_all(mod, &1, collection, list, opts)) do
      {records, linked} = records |> Enum.reverse() |> Enum.unzip()

      for record <- records,
          do:
            Store.broadcast(
              mod,
              Store.event(:record_inserted, collection.id, opts, mod, record: record)
            )

      broadcast_linked(mod, Enum.concat(linked), opts)
      {:ok, records}
    end
  end

  # Each record inserted, or the error of the first that is not, which says
  # which it is.
  defp do_insert_all(mod, repo, collection, list, opts) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {values, i}, {:ok, acc} ->
      case do_insert(mod, repo, collection, values, opts) do
        {:ok, inserted} ->
          {:cont, {:ok, [inserted | acc]}}

        {:error, error} ->
          {:halt, {:error, %{error | message: "record #{i + 1}: " <> error.message}}}
      end
    end)
  end

  defp do_insert(mod, repo, collection, values, opts) do
    actor = Store.actor_id(mod, opts)

    with {:ok, changes} <- cast_values(mod, repo, collection, values, opts) do
      data = for {key, value} <- changes, value != nil, into: %{}, do: {key, value}

      record =
        repo.insert!(%Record{
          collection_id: collection.id,
          data: stored(collection, data),
          search_text: Search.text(collection, data),
          position: insert_position(repo, collection, opts),
          created_by: actor,
          updated_by: actor
        })

      linked = put_links(repo, collection, record.id, data, Map.keys(data))
      {:ok, {%{record | data: data}, linked}}
    end
  end

  # A record's data as its row keeps it: without its relations, which are
  # links.
  defp stored(collection, data) do
    Map.drop(data, for(field <- collection.fields, Links.relation?(field), do: field.key))
  end

  # The links of the relations among the keys, written; the records at
  # their other ends whose links changed.
  defp put_links(repo, collection, record_id, data, keys) do
    for field <- collection.fields,
        Links.relation?(field),
        field.key in keys,
        linked <- Links.put(repo, field, record_id, Map.get(data, field.key)),
        do: linked
  end

  # A record update for each record whose links changed at the other end of
  # a relation, with the key of the field that shows them there.
  defp broadcast_linked(_mod, [], _opts), do: :ok

  defp broadcast_linked(mod, linked, opts) do
    repo = Store.repo(mod)
    records = repo.all(from(r in Record, where: r.id in ^Enum.map(linked, &elem(&1, 0))))

    collections =
      records
      |> Enum.map(& &1.collection_id)
      |> Enum.uniq()
      |> Map.new(&{&1, Collections.get(mod, &1)})

    for record <- records,
        collection = collections[record.collection_id],
        changed = linked_keys(linked, record, collection),
        changed != [] do
      [record] = Links.fill(repo, collection, [record])

      Store.broadcast(
        mod,
        Store.event(:record_updated, collection.id, opts, mod,
          record: record,
          changed: Enum.uniq(changed)
        )
      )
    end

    :ok
  end

  # The keys of the fields of a record whose links changed at their other end.
  defp linked_keys(linked, record, collection) do
    for {id, field, side} <- linked,
        id == record.id,
        key <- Links.keys(collection.fields, field, side),
        do: key
  end

  defp insert_position(repo, collection, opts) do
    place = place(repo, collection, opts)
    Collections.position(neighbours(repo, collection, place), place)
  end

  def update(mod, %Collection{} = collection, record_ref, changes, opts) do
    with :ok <- Store.allow(mod, opts, :update, collection),
         {:ok, {record, changed, linked}} <-
           Store.transaction(mod, fn repo ->
             do_update(mod, repo, collection, record_ref, changes, opts)
           end) do
      if changed != [] do
        Store.broadcast(
          mod,
          Store.event(:record_updated, collection.id, opts, mod, record: record, changed: changed)
        )
      end

      broadcast_linked(mod, linked, opts)
      {:ok, record}
    end
  end

  defp do_update(mod, repo, collection, record_ref, changes, opts) do
    with {:ok, record} <- lock(mod, repo, collection, record_ref),
         {:ok, changes} <- cast_values(mod, repo, collection, changes, opts),
         :ok <- expected(mod, repo, collection, record, opts) do
      data =
        Enum.reduce(changes, record.data, fn
          {key, nil}, data -> Map.delete(data, key)
          {key, value}, data -> Map.put(data, key, value)
        end)

      changed = for {key, _} <- changes, Map.get(data, key) != Map.get(record.data, key), do: key

      if changed == [] do
        {:ok, {record, [], []}}
      else
        updated =
          record
          |> Ecto.Changeset.change(
            data: stored(collection, data),
            search_text: Search.text(collection, data),
            updated_by: Store.actor_id(mod, opts)
          )
          |> Ecto.Changeset.force_change(:data, stored(collection, data))
          |> repo.update!()

        linked = put_links(repo, collection, record.id, data, changed)
        {:ok, {%{updated | data: data}, changed, linked}}
      end
    end
  end

  # The record, locked for the transaction on PostgreSQL (SQLite has one
  # writer at a time).
  defp lock(mod, repo, collection, %Record{id: id}), do: lock(mod, repo, collection, id)

  defp lock(mod, repo, %Collection{id: collection_id} = collection, id) do
    query = from(r in Record, where: r.collection_id == ^collection_id and r.id == ^id)
    query = if Store.dialect(mod) == :postgres, do: lock(query, "FOR UPDATE"), else: query

    case repo.one(query) do
      nil -> {:error, Error.not_found("the record #{inspect(id)}")}
      record -> {:ok, hd(Links.fill(repo, collection, [record]))}
    end
  end

  # The values a writer expected the record to have (`:expect`), as the
  # record has them: or a conflict, with the record as it is.
  defp expected(mod, repo, collection, record, opts) do
    case opts[:expect] do
      nil ->
        :ok

      expect ->
        with {:ok, expect} <-
               cast_values(mod, repo, collection, expect, Keyword.put(opts, :relations, false)) do
          collection
          |> conflicts(record, expect)
          |> conflict(collection, record)
        end
    end
  end

  defp conflicts(_collection, record, expect),
    do: for({key, value} <- expect, Map.get(record.data, key) != value, do: key)

  defp conflict([], _collection, _record), do: :ok

  defp conflict(keys, collection, record) do
    names = Enum.map_join(keys, ", ", &Collection.field(collection, &1).name)

    {:error,
     %Error{
       reason: :conflict,
       message: "#{names} changed meanwhile",
       errors: Enum.map(keys, &{&1, "changed meanwhile"}),
       current: record
     }}
  end

  def delete(mod, %Collection{} = collection, record_ref, opts) do
    with :ok <- Store.allow(mod, opts, :delete, collection),
         {:ok, {record, linked}} <-
           Store.transaction(mod, &do_delete(mod, &1, collection, record_ref)) do
      Store.broadcast(mod, Store.event(:record_deleted, collection.id, opts, mod, record: record))
      broadcast_linked(mod, linked, opts)
      {:ok, record}
    end
  end

  # The record deleted (its links go with it), and the records it was
  # linked to.
  defp do_delete(mod, repo, collection, record_ref) do
    with {:ok, record} <- lock(mod, repo, collection, record_ref) do
      linked = Links.around(repo, record.id)
      repo.delete!(%{record | data: stored(collection, record.data)})
      {:ok, {record, Enum.reject(linked, &(elem(&1, 0) == record.id))}}
    end
  end

  def move(mod, %Collection{} = collection, record_ref, opts) do
    with :ok <- Store.allow(mod, opts, :move, collection),
         {:ok, record} <-
           Store.transaction(mod, &do_move(mod, &1, collection, record_ref, opts)) do
      Store.broadcast(mod, Store.event(:record_moved, collection.id, opts, mod, record: record))
      {:ok, record}
    end
  end

  defp do_move(mod, repo, collection, record_ref, opts) do
    with {:ok, record} <- lock(mod, repo, collection, record_ref) do
      place = place(repo, collection, opts)
      others = repo |> neighbours(collection, place) |> Enum.reject(&(&1.id == record.id))

      record
      |> Ecto.Changeset.change(position: Collections.position(others, place))
      |> repo.update()
    end
  end

  # The records around a place in the collection's order.
  defp neighbours(repo, collection, :last), do: last_records(repo, collection)
  defp neighbours(repo, collection, :first), do: first_records(repo, collection)
  defp neighbours(repo, collection, {_side, record}), do: around(repo, collection, record)

  # Where a record goes, from the options: after or before another record,
  # first, or last.
  defp place(repo, collection, opts) do
    cond do
      id = opts[:after] -> side(repo, collection, :after, id)
      id = opts[:before] -> side(repo, collection, :before, id)
      opts[:to] == :first -> :first
      true -> :last
    end
  end

  defp side(repo, %Collection{id: collection_id}, side, ref) do
    id = if is_struct(ref, Record), do: ref.id, else: ref

    case repo.one(
           from(r in Record,
             where: r.collection_id == ^collection_id and r.id == ^id,
             select: struct(r, [:id, :position])
           )
         ) do
      nil -> :last
      record -> {side, record}
    end
  end

  defp last_records(repo, %Collection{id: id}) do
    from(r in Record,
      where: r.collection_id == ^id,
      order_by: [desc: r.position, desc: r.id],
      limit: 1,
      select: struct(r, [:id, :position])
    )
    |> repo.all()
  end

  defp first_records(repo, %Collection{id: id}) do
    from(r in Record,
      where: r.collection_id == ^id,
      order_by: [asc: r.position, asc: r.id],
      limit: 1,
      select: struct(r, [:id, :position])
    )
    |> repo.all()
  end

  # A record and its neighbours on both sides, in the collection's order.
  defp around(repo, %Collection{id: id}, record) do
    before =
      from(r in Record,
        where:
          r.collection_id == ^id and
            (r.position < ^record.position or
               (r.position == ^record.position and r.id < ^record.id)),
        order_by: [desc: r.position, desc: r.id],
        limit: 1,
        select: struct(r, [:id, :position])
      )
      |> repo.all()

    later =
      from(r in Record,
        where:
          r.collection_id == ^id and
            (r.position > ^record.position or
               (r.position == ^record.position and r.id > ^record.id)),
        order_by: [asc: r.position, asc: r.id],
        limit: 1,
        select: struct(r, [:id, :position])
      )
      |> repo.all()

    before ++ [record] ++ later
  end

  ## Values

  # The values given, by field key or name, checked against their fields:
  # each as it is kept (nil for empty), or every error at once.
  defp cast_values(mod, repo, collection, values, opts) when is_map(values) or is_list(values) do
    {changes, errors} =
      Enum.reduce(values, {%{}, []}, fn {ref, value}, acc ->
        cast_value(Collection.field(collection, ref), ref, value, opts, acc)
      end)

    errors =
      if errors == [] and Keyword.get(opts, :relations, true),
        do: relations(mod, repo, collection, changes),
        else: Enum.reverse(errors)

    if errors == [], do: {:ok, changes}, else: {:error, Error.invalid(errors, collection.fields)}
  end

  defp cast_values(_mod, _repo, collection, values, _opts),
    do:
      {:error,
       Error.invalid(
         [{nil, "values are a map of fields and values, got: #{inspect(values)}"}],
         collection.fields
       )}

  defp cast_value(nil, ref, _value, _opts, {changes, errors}),
    do: {changes, [{to_string(ref), "is not a field of the collection"} | errors]}

  defp cast_value(%Field{} = field, _ref, value, opts, {changes, errors}) do
    case Type.cast(field, value, opts) do
      {:ok, value} -> {Map.put(changes, field.key, value), errors}
      {:error, message} -> {changes, [{field.key, message} | errors]}
    end
  end

  # The records a relation links to, which must be of its collection.
  defp relations(_mod, repo, collection, changes) do
    for %Field{type: "relation", key: key, options: %{"collection_id" => target}} <-
          collection.fields,
        ids = Map.get(changes, key),
        is_list(ids) and ids != [],
        found =
          repo.all(
            from(r in Record, where: r.collection_id == ^target and r.id in ^ids, select: r.id)
          ),
        missing = ids -- found,
        missing != [] do
      {key, "links to records that are not in its collection: #{Enum.join(missing, ", ")}"}
    end
  end
end
