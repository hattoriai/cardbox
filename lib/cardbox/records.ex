defmodule Cardbox.Records do
  @moduledoc false
  # Records: read through a query, and written through one path that checks
  # each value against its field, compares what the writer expected, keeps
  # the order and who changed what, and broadcasts the change.

  import Ecto.Query

  alias Cardbox.{Collection, Collections, Condition, Error, Field, Query, Record, SQL, Store, Type, View, Views}

  ## Reading

  def get(mod, %Collection{id: id}, record_id) do
    Store.repo(mod).one(from(r in Record, where: r.collection_id == ^id and r.id == ^record_id))
  end

  def list(mod, %Collection{} = collection, query, opts) do
    with {:ok, query} <- parse(collection, query) do
      ecto =
        collection
        |> SQL.query(query, Store.dialect(mod), opts)
        |> then(&if(limit = opts[:limit], do: limit(&1, ^limit), else: &1))
        |> then(&if(offset = opts[:offset], do: offset(&1, ^offset), else: &1))

      {:ok, Store.repo(mod).all(ecto)}
    end
  end

  def count(mod, %Collection{} = collection, query, opts) do
    with {:ok, query} <- parse(collection, query) do
      ecto = SQL.where_query(collection, query, Store.dialect(mod), opts)
      {:ok, Store.repo(mod).aggregate(ecto, :count)}
    end
  end

  def meets?(%Collection{} = collection, query, %Record{} = record, opts) do
    with {:ok, query} <- parse(collection, query) do
      {:ok, query |> Condition.lower(collection, Condition.context(opts)) |> Condition.meets?(record)}
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
      Store.broadcast(mod, Store.event(:record_inserted, collection.id, opts, mod, record: record))
      {:ok, record}
    end
  end

  def insert_all(mod, %Collection{} = collection, list, opts) do
    with :ok <- Store.allow(mod, opts, :insert, collection),
         {:ok, records} <-
           Store.transaction(mod, fn repo ->
             list
             |> Enum.with_index()
             |> Enum.reduce_while({:ok, []}, fn {values, i}, {:ok, acc} ->
               case do_insert(mod, repo, collection, values, opts) do
                 {:ok, record} -> {:cont, {:ok, [record | acc]}}
                 {:error, error} -> {:halt, {:error, %{error | message: "record #{i + 1}: " <> error.message}}}
               end
             end)
           end) do
      records = Enum.reverse(records)
      for record <- records, do: Store.broadcast(mod, Store.event(:record_inserted, collection.id, opts, mod, record: record))
      {:ok, records}
    end
  end

  defp do_insert(mod, repo, collection, values, opts) do
    actor = Store.actor_id(mod, opts)

    with {:ok, changes} <- cast_values(mod, repo, collection, values, opts) do
      data = for {key, value} <- changes, value != nil, into: %{}, do: {key, value}

      %Record{
        collection_id: collection.id,
        data: data,
        position: insert_position(repo, collection, opts),
        created_by: actor,
        updated_by: actor
      }
      |> repo.insert()
    end
  end

  defp insert_position(repo, collection, opts) do
    place = place(repo, collection, opts)

    neighbours =
      case place do
        :last -> last_records(repo, collection)
        :first -> first_records(repo, collection)
        {_side, record} -> around(repo, collection, record)
      end

    Collections.position(neighbours, place)
  end

  def update(mod, %Collection{} = collection, record_ref, changes, opts) do
    with :ok <- Store.allow(mod, opts, :update, collection),
         {:ok, {record, changed}} <-
           Store.transaction(mod, fn repo -> do_update(mod, repo, collection, record_ref, changes, opts) end) do
      if changed != [] do
        Store.broadcast(mod, Store.event(:record_updated, collection.id, opts, mod, record: record, changed: changed))
      end

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
        {:ok, {record, []}}
      else
        record
        |> Ecto.Changeset.change(data: data, updated_by: Store.actor_id(mod, opts))
        |> Ecto.Changeset.force_change(:data, data)
        |> repo.update()
        |> case do
          {:ok, record} -> {:ok, {record, changed}}
          error -> error
        end
      end
    end
  end

  # The record, locked for the transaction on PostgreSQL (SQLite has one
  # writer at a time).
  defp lock(mod, repo, collection, %Record{id: id}), do: lock(mod, repo, collection, id)

  defp lock(mod, repo, %Collection{id: collection_id}, id) do
    query = from(r in Record, where: r.collection_id == ^collection_id and r.id == ^id)
    query = if Store.dialect(mod) == :postgres, do: lock(query, "FOR UPDATE"), else: query

    case repo.one(query) do
      nil -> {:error, Error.not_found("the record #{inspect(id)}")}
      record -> {:ok, record}
    end
  end

  # The values a writer expected the record to have (`:expect`), as the
  # record has them: or a conflict, with the record as it is.
  defp expected(mod, repo, collection, record, opts) do
    case opts[:expect] do
      nil ->
        :ok

      expect ->
        with {:ok, expect} <- cast_values(mod, repo, collection, expect, Keyword.put(opts, :relations, false)) do
          conflicts = for {key, value} <- expect, Map.get(record.data, key) != value, do: key

          if conflicts == [] do
            :ok
          else
            names = Enum.map_join(conflicts, ", ", &Collection.field(collection, &1).name)

            {:error,
             %Error{
               reason: :conflict,
               message: "#{names} changed meanwhile",
               errors: Enum.map(conflicts, &{&1, "changed meanwhile"}),
               current: record
             }}
          end
        end
    end
  end

  def delete(mod, %Collection{} = collection, record_ref, opts) do
    with :ok <- Store.allow(mod, opts, :delete, collection),
         {:ok, record} <-
           Store.transaction(mod, fn repo ->
             with {:ok, record} <- lock(mod, repo, collection, record_ref) do
               repo.delete!(record)
               unlink(mod, repo, collection, record)
               {:ok, record}
             end
           end) do
      Store.broadcast(mod, Store.event(:record_deleted, collection.id, opts, mod, record: record))
      {:ok, record}
    end
  end

  # The links to a deleted record, removed from the relations of every
  # collection that links to its collection.
  defp unlink(mod, repo, collection, record) do
    fields =
      from(f in Field, where: f.type == "relation")
      |> repo.all()
      |> Enum.filter(&(&1.options["collection_id"] == collection.id))

    dialect = Store.dialect(mod)

    for field <- fields do
      condition = SQL.condition({:has, {:data, field.key, :list}, record.id}, dialect)

      from(r in Record, as: :record, where: r.collection_id == ^field.collection_id)
      |> where(^condition)
      |> repo.all()
      |> Enum.each(fn linked ->
        ids = Enum.reject(Map.get(linked.data, field.key, []), &(&1 == record.id))
        data = if ids == [], do: Map.delete(linked.data, field.key), else: Map.put(linked.data, field.key, ids)
        linked |> Ecto.Changeset.change(data: data) |> repo.update!()
      end)
    end
  end

  def move(mod, %Collection{} = collection, record_ref, opts) do
    with :ok <- Store.allow(mod, opts, :move, collection),
         {:ok, record} <-
           Store.transaction(mod, fn repo ->
             with {:ok, record} <- lock(mod, repo, collection, record_ref) do
               place = place(repo, collection, opts)

               neighbours =
                 case place do
                   :last -> last_records(repo, collection)
                   :first -> first_records(repo, collection)
                   {_side, target} -> around(repo, collection, target)
                 end

               position = Collections.position(Enum.reject(neighbours, &(&1.id == record.id)), place)
               record |> Ecto.Changeset.change(position: position) |> repo.update()
             end
           end) do
      Store.broadcast(mod, Store.event(:record_moved, collection.id, opts, mod, record: record))
      {:ok, record}
    end
  end

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

    case repo.one(from(r in Record, where: r.collection_id == ^collection_id and r.id == ^id, select: struct(r, [:id, :position]))) do
      nil -> :last
      record -> {side, record}
    end
  end

  defp last_records(repo, %Collection{id: id}) do
    from(r in Record, where: r.collection_id == ^id, order_by: [desc: r.position, desc: r.id], limit: 1, select: struct(r, [:id, :position]))
    |> repo.all()
  end

  defp first_records(repo, %Collection{id: id}) do
    from(r in Record, where: r.collection_id == ^id, order_by: [asc: r.position, asc: r.id], limit: 1, select: struct(r, [:id, :position]))
    |> repo.all()
  end

  # A record and its neighbours on both sides, in the collection's order.
  defp around(repo, %Collection{id: id}, record) do
    before =
      from(r in Record,
        where: r.collection_id == ^id and (r.position < ^record.position or (r.position == ^record.position and r.id < ^record.id)),
        order_by: [desc: r.position, desc: r.id],
        limit: 1,
        select: struct(r, [:id, :position])
      )
      |> repo.all()

    later =
      from(r in Record,
        where: r.collection_id == ^id and (r.position > ^record.position or (r.position == ^record.position and r.id > ^record.id)),
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
      Enum.reduce(values, {%{}, []}, fn {ref, value}, {changes, errors} ->
        case Collection.field(collection, ref) do
          nil ->
            {changes, [{to_string(ref), "is not a field of the collection"} | errors]}

          %Field{} = field ->
            case Type.cast(field, value, opts) do
              {:ok, value} -> {Map.put(changes, field.key, value), errors}
              {:error, message} -> {changes, [{field.key, message} | errors]}
            end
        end
      end)

    errors =
      if errors == [] and Keyword.get(opts, :relations, true),
        do: relations(mod, repo, collection, changes),
        else: Enum.reverse(errors)

    if errors == [], do: {:ok, changes}, else: {:error, Error.invalid(errors, collection.fields)}
  end

  defp cast_values(_mod, _repo, collection, values, _opts),
    do: {:error, Error.invalid([{nil, "values are a map of fields and values, got: #{inspect(values)}"}], collection.fields)}

  # The records a relation links to, which must be of its collection.
  defp relations(_mod, repo, collection, changes) do
    for %Field{type: "relation", key: key, options: %{"collection_id" => target}} <- collection.fields,
        ids = Map.get(changes, key),
        is_list(ids) and ids != [],
        found = repo.all(from(r in Record, where: r.collection_id == ^target and r.id in ^ids, select: r.id)),
        missing = ids -- found,
        missing != [] do
      {key, "links to records that are not in its collection: #{Enum.join(missing, ", ")}"}
    end
  end
end
