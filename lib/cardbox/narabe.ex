if Code.ensure_loaded?(Narabe.Components) do
  defmodule Cardbox.Narabe do
    @moduledoc """
    A collection as a Narabe board: a column for each group of the view's
    field, its records as cards, which people move within a column and
    across them.

        <Cardbox.Narabe.board id="board" collection={@collection} view={@view}
          records={@records} on_move="move">
          <:card :let={record}>{record.data["title"]}</:card>
        </Cardbox.Narabe.board>

        def handle_event("move", params, socket),
          do: Cardbox.Narabe.handle_move(socket, params, MyApp.Cardbox, socket.assigns.collection,
                socket.assigns.view, actor: socket.assigns.current_user.id)

    The view is a saved `Cardbox.View` of type `board`, whose options say
    what it shows:

      * `group_by` - the field of the columns: a select or a status (a
        column for each choice, in their order and their colours), a person
        (a column for each person of `people`, and each one a record
        names), or a checkbox (Yes and No);
      * `hidden_groups` - the ids of the columns not shown;
      * `card_fields` - the fields a card shows under its title, unless the
        `card` slot draws it.

    Records with no value are in a last column ("No status") when there
    are some. A card moved to another column takes that column's value, and
    its place among the records (`move/3` of your module): a person who
    may not change the record (`allow?/3`) sees the card go back, with the
    reason. When the view sorts its records, a card keeps its place in that
    order, and only its column changes.

    The records are those of the view (`list/3`); the board reads no more.
    Load them again on a `Cardbox.Event` of the collection, as for every
    view: who moved the card sees it there already.
    """

    use Phoenix.Component

    alias Cardbox.{Choice, Collection, Field, Record, Type, View}

    @builtin Type.builtin()

    @none "none"

    # The columns of a checkbox.
    @yes %{id: "yes", name: "Yes", color: "green"}
    @no %{id: "no", name: "No", color: "gray"}

    attr(:id, :string, required: true)
    attr(:collection, Collection, required: true)
    attr(:view, View, required: true, doc: "a view of type `board`")
    attr(:records, :list, required: true, doc: "the records to show (`list/3` of the view)")
    attr(:people, :list, default: [], doc: "`%{id, name}`, for the columns of a person field")
    attr(:on_move, :string, default: nil, doc: "the event of a move; without it, nothing moves")

    attr(:rest, :global,
      include: ~w(multiple handle readonly locale messages issho user class phx-target)
    )

    slot(:column, doc: "a column's header, given the column (`%{id, name, color}`) as `:let`")
    slot(:card, doc: "a card, given the record as `:let`; its title and `card_fields` by default")
    slot(:footer, doc: "the end of each column, given the column as `:let`")

    @doc "A board of a view's records, in a column for each group of its field."
    def board(assigns) do
      %{collection: collection, view: view, records: records, people: people} = assigns
      field = group_field!(collection, view)
      hidden = MapSet.new(view.options["hidden_groups"] || [], &to_string/1)
      columns = Enum.reject(columns(field, records, people), &MapSet.member?(hidden, &1.id))
      shown = MapSet.new(columns, & &1.id)

      assigns =
        assign(assigns,
          field: field,
          columns: columns,
          cards: Enum.filter(records, &MapSet.member?(shown, column_of(&1, field))),
          title: Collection.title_field(collection),
          card_fields: card_fields(collection, view),
          people_names: Map.new(people, &{to_string(&1.id), &1.name}),
          movable: not Type.system?(field.type)
        )

      ~H"""
      <Narabe.Components.board
        id={@id}
        label={@view.name}
        columns={@columns}
        column_label={:name}
        cards={@cards}
        card_column={&column_of(&1, @field)}
        item_label={&title(&1, @title)}
        on_move={if @movable, do: @on_move}
        {@rest}
      >
        <:column :let={column}>
          <%= if @column != [] do %>
            {render_slot(@column, column)}
          <% else %>
            <span class="cardbox-choice" data-color={column.color}>{column.name}</span>
          <% end %>
        </:column>
        <:card :let={record}>
          <%= if @card != [] do %>
            {render_slot(@card, record)}
          <% else %>
            <div class="cardbox-card">
              <strong>{title(record, @title)}</strong>
              <span :for={{card_field, text} <- values(record, @card_fields, @people_names)} title={card_field.name}>
                {text}
              </span>
            </div>
          <% end %>
        </:card>
        <:footer :let={column} :if={@footer != []}>{render_slot(@footer, column)}</:footer>
      </Narabe.Components.board>
      """
    end

    @doc """
    The columns of a board: `%{id, name, color}`, in their order, with the
    last for the records with no value when there are some.
    """
    @spec columns(Field.t(), [Record.t()], [map()]) :: [map()]
    def columns(%Field{} = field, records, people \\ []) do
      columns =
        case field.type do
          "checkbox" ->
            [@yes, @no]

          type when type in ~w(person created_by updated_by) ->
            named = Enum.map(people, &%{id: to_string(&1.id), name: &1.name, color: "gray"})
            known = MapSet.new(named, & &1.id)

            others =
              for record <- records,
                  id = column_of(record, field),
                  id != @none and not MapSet.member?(known, id),
                  uniq: true,
                  do: %{id: id, name: id, color: "gray"}

            named ++ others

          _choice ->
            for c <- Field.choices(field), do: %{id: c["id"], name: c["name"], color: c["color"]}
        end

      if field.type != "checkbox" and Enum.any?(records, &(column_of(&1, field) == @none)),
        do: columns ++ [%{id: @none, name: "No #{String.downcase(field.name)}", color: "gray"}],
        else: columns
    end

    @doc "The id of the column of a record."
    @spec column_of(Record.t(), Field.t()) :: String.t()
    def column_of(%Record{} = record, %Field{type: "checkbox"} = field),
      do: if(Record.value(record, field), do: @yes.id, else: @no.id)

    def column_of(%Record{} = record, %Field{} = field) do
      case Record.value(record, field) do
        nil -> @none
        value -> to_string(value)
      end
    end

    @doc """
    Answers the board's move event: `move/5`, and its reply for the board
    (`Narabe.Live.reply/1`), which puts a refused card back.
    """
    @spec handle_move(
            Phoenix.LiveView.Socket.t(),
            map(),
            module(),
            Collection.t(),
            View.t(),
            keyword()
          ) :: {:reply, map(), Phoenix.LiveView.Socket.t()}
    def handle_move(socket, params, mod, collection, view, opts \\ []) do
      {:reply, Narabe.Live.reply(move(mod, collection, view, params, opts)), socket}
    end

    @doc """
    Saves a move of the board: each card moved takes the value of its new
    column, and its place after or before the card the move names. `opts`:
    `:actor`.
    """
    @spec move(module(), Collection.t(), View.t(), map(), keyword()) ::
            :ok | {:error, String.t() | atom()}
    def move(mod, %Collection{} = collection, %View{} = view, params, opts \\ []) do
      field = group_field!(collection, view)

      with {:ok, move} <- Narabe.Move.parse(params, :string),
           :ok <- movable(field, params),
           {:ok, ids} <- ids(move.ids),
           {:ok, place} <- place(move) do
        # The cards after the first go after the one before them.
        places = [place | Enum.map(Enum.drop(ids, -1), &[after: &1])]
        column = move.parent || @none

        ids
        |> Enum.zip(places)
        |> Enum.reduce_while(:ok, fn {id, place}, :ok ->
          halt_on_error(move_card(mod, collection, field, id, column, place, opts[:actor]))
        end)
      end
    end

    defp halt_on_error(:ok), do: {:cont, :ok}
    defp halt_on_error(error), do: {:halt, error}

    defp movable(%Field{type: type}, _params) when type in ~w(created_by updated_by),
      do: {:error, "Nobody writes who made or changed a record: its cards stay in their column."}

    defp movable(_field, %{"columns" => true}),
      do: {:error, "The columns are the field's groups: change their order in the field."}

    defp movable(_field, _params), do: :ok

    defp ids(ids) do
      Enum.reduce_while(Enum.reverse(ids), {:ok, []}, fn id, {:ok, acc} ->
        case Integer.parse(id) do
          {n, ""} -> {:cont, {:ok, [n | acc]}}
          _other -> {:halt, {:error, :invalid_move}}
        end
      end)
    end

    defp place(%Narabe.Move{after: nil, before: nil}), do: {:ok, to: :last}

    defp place(%Narabe.Move{after: id, before: before}) do
      {side, id} = if id, do: {:after, id}, else: {:before, before}

      case Integer.parse(id) do
        {n, ""} -> {:ok, [{side, n}]}
        _other -> {:error, :invalid_move}
      end
    end

    # The value of a column: a choice's or a person's id, a checkbox's
    # tick, nothing for the column of none.
    defp value(_field, column) when column in [nil, @none], do: nil
    defp value(%Field{type: "checkbox"}, column), do: column == @yes.id
    defp value(_field, column), do: column

    defp move_card(mod, collection, field, id, column, place, actor) do
      with %Record{} = record <- mod.get(collection, id) || {:error, "That record is gone."},
           {:ok, _record} <- change(mod, collection, field, record, column, actor),
           {:ok, _record} <- mod.move(collection, id, [{:actor, actor} | place]) do
        :ok
      else
        {:error, %Cardbox.Error{message: message}} -> {:error, message}
        {:error, message} -> {:error, message}
      end
    end

    # The column's value, written only when the column is another: a move
    # within a column is a move alone.
    defp change(mod, collection, field, record, column, actor) do
      if column_of(record, field) == column,
        do: {:ok, record},
        else: mod.update(collection, record, %{field.key => value(field, column)}, actor: actor)
    end

    defp group_field!(collection, %View{options: options, name: name}) do
      case Collection.field(collection, options["group_by"]) do
        %Field{} = field -> field
        nil -> raise ArgumentError, "the view #{inspect(name)} names no field (group_by)"
      end
    end

    defp card_fields(collection, %View{options: options}) do
      for ref <- options["card_fields"] || [],
          field = Collection.field(collection, ref),
          do: field
    end

    defp title(record, nil), do: "Record #{record.id}"
    defp title(record, field), do: Map.get(record.data, field.key) || "Untitled"

    # A card's values, as words: those it has.
    # A type of the app's is told its value as it is kept, as everywhere.
    defp value_of(record, %Field{type: type} = field) when type not in @builtin,
      do: {:kept, Map.get(record.data, field.key)}

    defp value_of(record, field), do: Record.value(record, field)

    defp values(record, fields, people) do
      for field <- fields,
          text = text(field, value_of(record, field), people),
          text not in [nil, ""],
          do: {field, text}
    end

    defp text(_field, value, _people) when value in [nil, false, []], do: nil

    defp text(%Field{type: type} = field, id, _people) when type in ~w(select status) do
      case Choice.find(Field.choices(field), id) do
        %{"name" => name} -> name
        nil -> nil
      end
    end

    defp text(%Field{type: "multi_select"} = field, ids, _people) do
      choices = Field.choices(field)
      Enum.map_join(ids, ", ", &(Choice.find(choices, &1)["name"] || &1))
    end

    defp text(%Field{type: "person"}, ids, people) when is_list(ids),
      do: Enum.map_join(ids, ", ", &Map.get(people, &1, &1))

    defp text(%Field{type: "person"}, id, people), do: Map.get(people, id, id)
    defp text(%Field{type: "checkbox"} = field, true, _people), do: field.name

    defp text(%Field{type: "file"}, files, _people), do: Enum.map_join(files, ", ", & &1["name"])

    defp text(%Field{type: type} = field, {:kept, value}, _people) when type not in @builtin,
      do: Cardbox.FieldType.text(Type.app_type(type), field, value)

    defp text(%Field{type: "relation"}, ids, _people),
      do: "#{length(ids)} linked"

    defp text(_field, %Date{} = date, _people), do: Calendar.strftime(date, "%-d %b %Y")

    defp text(_field, %DateTime{} = dt, _people),
      do: Calendar.strftime(dt, "%-d %b %Y %H:%M")

    defp text(_field, value, _people), do: to_string(value)
  end
end
