if Code.ensure_loaded?(Masu.Source) do
  defmodule Cardbox.Masu do
    @moduledoc """
    A collection as a Masu grid: its fields as columns, its records as rows
    that the database sorts, filters and searches as the person asks, and
    each edit, new row and deletion written through your Cardbox module (its
    checks, its `c:Cardbox.allow?/3`, its events).

        <Cardbox.Masu.table cardbox={MyApp.Cardbox} collection={@collection} view={@view}
          actor={@user} people={@people} searchable height="100%" />

    `table/1` draws choices as chips in their colors, people by name and
    relations by the titles of the records they link to. `grid/3` gives the
    plain attributes of `Masu.Components.data_grid/1` instead, for a grid of
    your own `:col` slots. Their options:

      * `view` - a saved `Cardbox.View`: its query is the grid's own, which
        the person's sorts and filters narrow, and its options its columns
        (`columns`, `hidden`, `widths`);
      * `actor` - who edits, for the writes (and `"me"` in the view's query);
      * `people` - the people a person field picks from, `%{id, name}` (and a
        `color`); without them, a person is their id;
      * `id` - the grid's id, `"cardbox-<collection id>"` unless given;
      * `time_zone` - where the days of the view's date filters are.

    A grid shows other people's changes when its LiveView passes the
    collection's events on (`relay/2`):

        def handle_info({:cardbox, event}, socket) do
          Cardbox.Masu.relay(event, "cardbox-\#{socket.assigns.collection.id}")
          {:noreply, socket}
        end

    ## Columns

    | Field | Column |
    | --- | --- |
    | text, url, email, phone | `:text` |
    | number | `:integer` (format `integer`) or `:number` |
    | checkbox | `:boolean` |
    | date | `:date`, or `:datetime` with a time |
    | select, status | `:enum` of the choices' names, in their order |
    | person | `:enum` of the people's names, or `:text` of ids |
    | multi-select, relation, several people | the names or titles, read-only |
    | created at, updated at, by | read-only |

    A cell takes what a person types as Cardbox takes a value: a choice by
    its name, a date as the grid's editor gives it.

    `table/1` draws chips as `<span class="cardbox-choice" data-color="blue">`
    (Erabi's nine colors), links as `<span class="cardbox-link">` and people
    as `<span class="cardbox-person">`, for your style sheet.
    """

    use Phoenix.Component

    alias Cardbox.{Choice, Collection, Field, Record, Type, View}

    ## The component

    attr(:cardbox, :atom, required: true, doc: "your Cardbox module")
    attr(:collection, Collection, required: true)
    attr(:view, View, default: nil)
    attr(:actor, :any, default: nil)
    attr(:people, :list, default: [])
    attr(:id, :string, default: nil)
    attr(:time_zone, :string, default: nil)

    attr(:rest, :global,
      include: ~w(searchable height max_height wheel url history issho user scope locale),
      doc: "attributes of `Masu.Components.data_grid/1`"
    )

    @doc "A collection as a Masu grid, with chips for choices, people and relations."
    def table(assigns) do
      opts =
        [
          view: assigns.view,
          actor: assigns.actor,
          people: assigns.people,
          id: assigns.id,
          time_zone: assigns.time_zone
        ]
        |> Enum.reject(fn {_k, v} -> v in [nil, []] end)

      {columns, grid} = assigns.cardbox |> grid(assigns.collection, opts) |> Keyword.pop(:columns)
      fields = Map.new(assigns.collection.fields, &{&1.key, &1})
      {rich, plain} = Enum.split_with(columns, &rich?(fields[&1[:key]]))
      order = Enum.map_join(columns, ",", & &1[:key])

      assigns =
        assign(assigns,
          grid: grid ++ [view: %{"cols" => order}],
          rich: rich,
          plain: plain,
          fields: fields,
          people_by_id: Map.new(assigns.people, &{to_string(&1.id), &1})
        )

      ~H"""
      <Masu.Components.data_grid {@grid} {@rest}>
        <:col
          :for={c <- @plain}
          key={c[:key]}
          field={c[:field]}
          label={c[:label]}
          type={c[:type]}
          values={c[:values]}
          editable={c[:editable]}
          hidden={c[:hidden]}
          width={c[:width]}
          decimals={c[:decimals]}
        />
        <:col
          :for={c <- @rich}
          :let={row}
          key={c[:key]}
          field={c[:field]}
          label={c[:label]}
          type={c[:type]}
          values={c[:values]}
          editable={c[:editable]}
          hidden={c[:hidden]}
          width={c[:width]}
        >
          <.cell field={@fields[c[:key]]} row={row} people={@people_by_id} />
        </:col>
      </Masu.Components.data_grid>
      """
    end

    defp rich?(%Field{type: type}),
      do: type in ~w(select status multi_select person relation created_by updated_by)

    defp rich?(_field), do: false

    attr(:field, Field, required: true)
    attr(:row, :map, required: true)
    attr(:people, :map, required: true)

    defp cell(%{field: %Field{type: type}} = assigns)
         when type in ~w(select status multi_select) do
      ids = assigns.row["__data"] |> Map.get(assigns.field.key) |> List.wrap()

      assigns =
        assign(
          assigns,
          :choices,
          for(id <- ids, c = Choice.find(Field.choices(assigns.field), id), do: c)
        )

      ~H"""
      <span :for={c <- @choices} class="cardbox-choice" data-color={c["color"]}>{c["name"]}</span>
      """
    end

    defp cell(%{field: %Field{type: "relation"}} = assigns) do
      assigns = assign(assigns, :titles, assigns.row["__titles"][assigns.field.key] || [])

      ~H"""
      <span :for={title <- @titles} class="cardbox-link">{title}</span>
      """
    end

    defp cell(assigns) do
      ids =
        case assigns.field.type do
          type when type in ~w(created_by updated_by) -> List.wrap(assigns.row[assigns.field.key])
          _ -> assigns.row["__data"] |> Map.get(assigns.field.key) |> List.wrap()
        end

      assigns =
        assign(
          assigns,
          :persons,
          for(id <- ids, do: Map.get(assigns.people, id, %{id: id, name: id}))
        )

      ~H"""
      <span :for={p <- @persons} class="cardbox-person" style={p[:color] && "--cardbox-person: #{p.color}"}>
        <i>{initials(p.name)}</i>{p.name}
      </span>
      """
    end

    defp initials(name),
      do:
        name
        |> to_string()
        |> String.split()
        |> Enum.map_join(&String.first/1)
        |> String.slice(0, 2)

    ## The attributes

    @doc "The attributes of a `<.data_grid>` of a collection."
    @spec grid(module(), Collection.t(), keyword()) :: keyword()
    def grid(mod, %Collection{} = collection, opts \\ []) do
      view = opts[:view]
      people = opts[:people] || []
      write_opts = [actor: opts[:actor], people: people]
      id = opts[:id] || "cardbox-#{collection.id}"

      [
        id: id,
        label: if(view, do: "#{collection.name}: #{view.name}", else: collection.name),
        source:
          {__MODULE__.Source,
           mod: mod,
           collection: collection,
           view: view,
           people: people,
           opts: read_opts(mod, opts)},
        columns: columns(collection, view, people),
        on_update: &update(mod, collection, &1, write_opts),
        on_create: &create(mod, collection, &1, write_opts),
        on_delete: &delete(mod, collection, &1, write_opts),
        deletable: true,
        # The grid follows a topic of its own, which nobody broadcasts on:
        # relay/2 sends the collection's changes to it in this process.
        live: if(pubsub = mod.__cardbox__(:pubsub), do: {pubsub, topic(id)})
      ]
    end

    # "me" in the view's query is the actor, by its id (`c:Cardbox.actor_id/1`).
    defp read_opts(mod, opts) do
      opts
      |> Keyword.take([:time_zone, :now])
      |> Keyword.put(:me, mod.actor_id(opts[:actor]))
    end

    @doc """
    Passes a collection's event (`Cardbox.Event`) to the grid of that id in
    this LiveView, which reads its rows again.
    """
    @spec relay(Cardbox.Event.t(), String.t()) :: :ok
    def relay(%Cardbox.Event{type: type, record: record}, grid)
        when type in [:record_inserted, :record_updated, :record_moved] do
      send(self(), {Masu.Live, topic(grid), {:upsert, %{"id" => record.id}}})
      :ok
    end

    def relay(%Cardbox.Event{type: :record_deleted, record: record}, grid) do
      send(self(), {Masu.Live, topic(grid), {:delete, record.id}})
      :ok
    end

    def relay(%Cardbox.Event{}, _grid), do: :ok

    defp topic(grid), do: "cardbox-masu:" <> grid

    @doc "The columns of a collection's fields, in the view's order and with its widths."
    @spec columns(Collection.t(), View.t() | nil, list()) :: [keyword()]
    def columns(%Collection{fields: fields}, view, people \\ []) do
      options = (view && view.options) || %{}
      order = options["columns"] || []
      hidden = MapSet.new(options["hidden"] || [])
      widths = options["widths"] || %{}
      rank = order |> Enum.with_index() |> Map.new()

      fields
      |> Enum.sort_by(&Map.get(rank, &1.key, length(order)))
      |> Enum.map(fn field ->
        [
          key: field.key,
          field: field.key,
          label: field.name,
          editable: editable?(field, people),
          hidden: MapSet.member?(hidden, field.key)
        ]
        |> Keyword.merge(type(field, people))
        |> then(&if(w = widths[field.key], do: Keyword.put(&1, :width, w), else: &1))
      end)
    end

    defp type(%Field{type: type} = field, people) do
      case {type, Type.kind(field)} do
        {"number", _} ->
          [type: if(field.options["format"] == "integer", do: :integer, else: :number)] ++
            decimals(field)

        {_, :boolean} ->
          [type: :boolean]

        {_, :date} ->
          [type: :date]

        {_, :datetime} ->
          [type: :datetime]

        {t, :choice} when t in ~w(select status) ->
          [type: :enum, values: Enum.map(Field.choices(field), & &1["name"])]

        {"person", :choice} when people != [] ->
          [type: :enum, values: Enum.map(people, & &1.name)]

        _ ->
          [type: :text]
      end
    end

    defp decimals(%Field{options: %{"decimals" => d}}) when is_integer(d), do: [decimals: d]
    defp decimals(_field), do: []

    defp editable?(%Field{type: "person"} = field, people),
      do: people != [] and Type.kind(field) == :choice

    defp editable?(%Field{} = field, _people),
      do: not Type.system?(field.type) and Type.kind(field) != :list

    @doc """
    A record as a grid's row: the value of each field, by key, as its column
    sorts and shows it (a choice's name, a person's name, the titles of
    linked records). `titles` are the titles of the records relations link
    to, by id.
    """
    @spec row(Collection.t(), Record.t(), map(), list()) :: map()
    def row(%Collection{fields: fields}, %Record{} = record, titles \\ %{}, people \\ []) do
      names = Map.new(people, &{to_string(&1.id), &1.name})

      values = Map.new(fields, &{&1.key, cell_value(&1, record, titles, names)})

      relation_titles =
        for %Field{type: "relation", key: key} <- fields, into: %{} do
          {key,
           record.data |> Map.get(key) |> List.wrap() |> Enum.map(&Map.get(titles, &1, "##{&1}"))}
        end

      Map.merge(values, %{
        "id" => record.id,
        "__data" => record.data,
        "__titles" => relation_titles
      })
    end

    # A field's value in a row, as its column sorts and shows it.
    defp cell_value(field, record, titles, names) do
      raw = Map.get(record.data, field.key)

      case {field.type, Type.kind(field)} do
        {"relation", _} ->
          joined(raw, &Map.get(titles, &1, "##{&1}"))

        {"person", _} ->
          joined(raw, &Map.get(names, &1, &1))

        {_, :list} ->
          field |> Type.plain(raw) |> joined(& &1)

        {_, kind} when kind in [:date, :datetime, :boolean] ->
          Record.value(record, field)

        _ ->
          if Type.system?(field.type),
            do: Record.value(record, field),
            else: Type.plain(field, raw)
      end
    end

    defp joined(values, name), do: values |> List.wrap() |> Enum.map_join(", ", name) |> blank()

    @doc false
    # The rows of records, with the titles of the records their relations
    # link to, read once for all of them.
    def rows(mod, %Collection{fields: fields} = collection, records, people) do
      titles =
        for %Field{type: "relation", key: key, options: %{"collection_id" => target}} <- fields,
            reduce: %{} do
          acc ->
            ids = Enum.flat_map(records, &List.wrap(Map.get(&1.data, key)))
            Map.merge(acc, mod.titles(target, ids))
        end

      Enum.map(records, &row(collection, &1, titles, people))
    end

    defp blank(""), do: nil
    defp blank(text), do: text

    ## Writes

    defp update(mod, collection, write, opts) do
      Masu.Write.each(write, fn change ->
        params = people_ids(collection, change.params, opts[:people])

        expect =
          people_ids(collection, Map.take(change.before, Map.keys(change.params)), opts[:people])

        case mod.update(collection, change.row["id"], params, actor: opts[:actor], expect: expect) do
          {:ok, record} -> {:ok, hd(rows(mod, collection, [record], opts[:people]))}
          {:error, error} -> {:error, reason(error)}
        end
      end)
    end

    defp create(mod, collection, write, opts) do
      Masu.Write.each(write, fn change ->
        case mod.insert(collection, people_ids(collection, change.params, opts[:people]),
               actor: opts[:actor]
             ) do
          {:ok, record} -> {:ok, hd(rows(mod, collection, [record], opts[:people]))}
          {:error, error} -> {:error, reason(error)}
        end
      end)
    end

    defp delete(mod, collection, write, opts) do
      Masu.Write.each(write, fn change ->
        case mod.delete(collection, change.row["id"], actor: opts[:actor]) do
          {:ok, _record} -> :ok
          {:error, error} -> {:error, error.message}
        end
      end)
    end

    # The names a person field's cell shows, as the ids Cardbox keeps.
    defp people_ids(_collection, params, people) when people in [nil, []], do: params

    defp people_ids(collection, params, people) do
      ids = Map.new(people, &{&1.name, to_string(&1.id)})

      Map.new(params, fn {key, value} ->
        case Collection.field(collection, key) do
          %Field{type: "person"} -> {key, Map.get(ids, value, value)}
          _ -> {key, value}
        end
      end)
    end

    defp reason(%Cardbox.Error{errors: errors, message: message}) do
      case for {key, msg} <- errors, is_binary(key), do: {key, msg} do
        [] -> message
        keyed -> keyed
      end
    end
  end

  defmodule Cardbox.Masu.Source do
    @moduledoc false
    # A Masu.Source over a collection: the grid's query (sorts, filters,
    # search) turned into Cardbox's, inside the view's, and run in the
    # database a block at a time.
    @behaviour Masu.Source

    alias Cardbox.{Collection, Type}

    @impl true
    def init(input, _opts) do
      input = Map.new(input)
      Map.merge(input, %{query: base(input)})
    end

    @impl true
    def prepare(state, %Masu.Query{} = query, _columns) do
      base = base(state)
      filters = for filter <- query.filters, condition = condition(state, filter), do: condition
      filter = Enum.reject([base["filter"] | filters], &is_nil/1)

      sorts =
        for %Masu.Sort{key: key, direction: dir} <- query.sorts,
            do: %{"field" => key, "dir" => Atom.to_string(dir)}

      wire =
        base
        |> Map.delete("filter")
        |> then(&if(filter != [], do: Map.put(&1, "filter", %{"and" => filter}), else: &1))
        |> then(&if(sorts != [], do: Map.put(&1, "sort", sorts), else: &1))
        |> then(&if(query.search, do: Map.put(&1, "search", query.search), else: &1))

      %{state | query: wire}
    end

    defp base(%{view: nil}), do: %{}
    defp base(%{view: view}), do: view.query

    @impl true
    def count(%{mod: mod, collection: collection, query: query, opts: opts}) do
      case mod.count(collection, query, opts) do
        {:ok, n} -> n
        {:error, _} -> 0
      end
    end

    @impl true
    def rows(
          %{mod: mod, collection: collection, query: query, opts: opts, people: people},
          offset,
          limit
        ) do
      case mod.list(collection, query, Keyword.merge(opts, offset: offset, limit: limit)) do
        {:ok, records} -> Cardbox.Masu.rows(mod, collection, records, people)
        {:error, error} -> {:error, error.message}
      end
    end

    @impl true
    def fetch(%{mod: mod, collection: collection, people: people}, ids, _id_fun) do
      records = for id <- ids, record = mod.get(collection, id), do: record
      Cardbox.Masu.rows(mod, collection, records, people)
    end

    @impl true
    def id?(_state, id), do: is_integer(id) or (is_binary(id) and id =~ ~r/^\d{1,18}$/)

    @impl true
    def supports?(%{collection: collection}, column) do
      case Collection.field(collection, column.key) do
        nil -> false
        field -> Type.kind(field) != :list
      end
    end

    @impl true
    def filters(%{collection: collection}, column) do
      case Collection.field(collection, column.key) do
        nil -> []
        field -> field |> Type.operators() |> Enum.flat_map(&masu_op/1) |> Enum.uniq()
      end
    end

    # Cardbox's operators as Masu's.
    defp masu_op(:is_empty), do: [:is_nil]
    defp masu_op(:is_not_empty), do: [:not_nil]
    defp masu_op(:before), do: [:lt]
    defp masu_op(:after), do: [:gt]
    defp masu_op(:on_or_before), do: [:lte]
    defp masu_op(:on_or_after), do: [:gte]

    defp masu_op(op) when op in [:within, :in_group, :not_in, :has_any, :has_all, :has_none],
      do: []

    defp masu_op(op), do: [op]

    # A Masu filter as a Cardbox condition.
    defp condition(%{collection: collection, people: people}, %Masu.Filter{
           key: key,
           op: op,
           value: value
         }) do
      field = Collection.field(collection, key)
      date? = field && Type.kind(field) in [:date, :datetime]

      op = wire_op(op, date?)

      value = if field && field.type == "person", do: person_ids(value, people), else: value
      field && %{"field" => key, "op" => op, "value" => wire_value(value)}
    end

    defp wire_op(:is_nil, _date?), do: "is_empty"
    defp wire_op(:not_nil, _date?), do: "is_not_empty"
    defp wire_op(:lt, true), do: "before"
    defp wire_op(:gt, true), do: "after"
    defp wire_op(:lte, true), do: "on_or_before"
    defp wire_op(:gte, true), do: "on_or_after"
    defp wire_op(op, _date?), do: Atom.to_string(op)

    defp person_ids(value, people) do
      ids = Map.new(people, &{&1.name, to_string(&1.id)})

      if is_list(value),
        do: Enum.map(value, &Map.get(ids, &1, &1)),
        else: Map.get(ids, value, value)
    end

    defp wire_value(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()
    defp wire_value(%Date{} = d), do: Date.to_iso8601(d)
    defp wire_value(%Decimal{} = d), do: Decimal.to_string(d)
    defp wire_value(list) when is_list(list), do: Enum.map(list, &wire_value/1)
    defp wire_value(value), do: value
  end
end
