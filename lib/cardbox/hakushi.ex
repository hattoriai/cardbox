if Code.ensure_loaded?(Hakushi.Graph) do
  defmodule Cardbox.Hakushi do
    @moduledoc """
    A collection as a Hakushi canvas: each record a node, where people put
    it, and the links of a relation of the collection to itself as edges.
    A person who draws an edge links two records; who deletes one unlinks
    them; who moves a node moves it in the view, for everyone who opens it.

        <Cardbox.Hakushi.canvas cardbox={MyApp.Cardbox} collection={@collection} view={@view}
          records={@records} actor={@user} class="h-[40rem]">
          <:record :let={record}>{record.data["title"]}</:record>
        </Cardbox.Hakushi.canvas>

    The view is a saved `Cardbox.View` of type `canvas`: its `edges` option
    names the relation whose links are the edges, and its `layout` keeps
    where each record is (`%{"7" => %{"x" => 120, "y" => 40}}`). Records it
    has no place for yet are laid out in layers, along their links, as the
    canvas opens.

    An edge goes from a record to the record whose relation links to it: on
    a "Blocked by" relation, from the blocking record to the one it blocks.
    A node is not deleted on the canvas: records are deleted where people
    see all of them.
    """

    use Phoenix.Component

    alias Cardbox.{Collection, Record, View}

    attr(:cardbox, :atom, required: true, doc: "your Cardbox module")
    attr(:collection, Collection, required: true)
    attr(:view, View, required: true)
    attr(:records, :list, required: true, doc: "the records to show (`list/3` of the view)")
    attr(:actor, :any, default: nil)
    attr(:id, :string, default: nil)

    attr(:rest, :global,
      include: ~w(class background grid snap minimap controls fit wheel readonly)
    )

    slot(:record, doc: "a record's node, given the record as `:let`; its title by default")

    @doc "A collection as a canvas of its records, joined by a relation's links."
    def canvas(assigns) do
      %{cardbox: mod, collection: collection, view: view, actor: actor} = assigns
      layout = view.options["layout"] || %{}

      assigns =
        assign(assigns,
          canvas_id: assigns.id || "cardbox-canvas-#{view.id}",
          graph: graph(collection, view, assigns.records),
          by_id: Map.new(assigns.records, &{to_string(&1.id), &1}),
          title: Collection.title_field(collection),
          tidy: layout == %{},
          on_change: &change(mod, collection, view, &1, &2, actor: actor)
        )

      ~H"""
      <Hakushi.Components.canvas
        id={@canvas_id}
        graph={@graph}
        on_change={@on_change}
        tidy={@tidy}
        label={@view.name}
        {@rest}
      >
        <:node :let={node} type="record">
          <div class="cardbox-node">
            <Hakushi.Components.handle kind={:target} side={:left} />
            <%= if @record != [] do %>
              {render_slot(@record, @by_id[node.id])}
            <% else %>
              {@title && @by_id[node.id].data[@title.key]}
            <% end %>
            <Hakushi.Components.handle kind={:source} side={:right} />
          </div>
        </:node>
      </Hakushi.Components.canvas>
      """
    end

    @doc """
    The graph of a canvas view: a node for each record, at its place in the
    view (or in a column, for the layout to place), and an edge for each link
    of the view's relation between two of them.
    """
    @spec graph(Collection.t(), View.t(), [Record.t()]) :: Hakushi.Graph.t()
    def graph(%Collection{} = collection, %View{options: options}, records) do
      layout = options["layout"] || %{}
      shown = MapSet.new(records, & &1.id)

      nodes =
        records
        |> Enum.with_index()
        |> Enum.map(fn {record, i} ->
          place = layout[to_string(record.id)] || %{"x" => 0, "y" => i * 120}
          %{id: to_string(record.id), type: "record", x: place["x"], y: place["y"]}
        end)

      edges =
        case options["edges"] && Collection.field(collection, options["edges"]) do
          nil ->
            []

          field ->
            for record <- records,
                linked <- List.wrap(record.data[field.key]),
                MapSet.member?(shown, linked) do
              %{
                id: edge_id(field.key, linked, record.id),
                source: to_string(linked),
                target: to_string(record.id)
              }
            end
        end

      Hakushi.Graph.new(nodes: nodes, edges: edges)
    end

    defp edge_id(key, source, target), do: "#{key}:#{source}:#{target}"

    @doc """
    Saves a change of the canvas: places into the view's layout, edges
    drawn and deleted as links of its relation. The `on_change` of a canvas
    of your own (`Hakushi.Components.canvas/1`).
    """
    @spec change(module(), Collection.t(), View.t(), Hakushi.Change.t(), map(), keyword()) ::
            :ok | {:error, String.t()}
    def change(mod, collection, view, %Hakushi.Change{op: op} = change, _context, opts) do
      field = view.options["edges"] && Collection.field(collection, view.options["edges"])

      cond do
        op == :move ->
          place(mod, collection, view, change.nodes, opts)

        op == :delete and change.nodes != [] ->
          {:error, "Records are deleted in the table, not on the canvas."}

        op == :add ->
          {:error, "Add records in the table, then place them here."}

        field != nil ->
          links(mod, collection, field, links_of(change), opts)

        true ->
          :ok
      end
    end

    # The links a change of edges adds and removes, in order.
    defp links_of(%Hakushi.Change{op: :connect, edges: edges}),
      do: for(edge <- edges, do: {edge.source, edge.target, :add})

    defp links_of(%Hakushi.Change{op: :reconnect, edges: edges}) do
      Enum.flat_map(edges, fn %{id: id} = edge ->
        {source, target} = ends(id)

        [
          {source, target, :remove},
          {Map.get(edge, :source, source), Map.get(edge, :target, target), :add}
        ]
      end)
    end

    defp links_of(%Hakushi.Change{op: :delete, edges: edges}) do
      for id <- edges, {source, target} = ends(id), do: {source, target, :remove}
    end

    defp links_of(_change), do: []

    # Each link written, until one fails.
    defp links(mod, collection, field, links, opts) do
      Enum.reduce_while(links, :ok, fn {source, target, action}, :ok ->
        case link(mod, collection, field, source, target, action, opts) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end

    defp ends(edge_id) do
      [_key, source, target] = String.split(edge_id, ":")
      {source, target}
    end

    # The view's layout with the nodes' new places, kept as integers.
    defp place(mod, collection, view, nodes, opts) do
      fresh = mod.get_view(collection, view.id) || view
      layout = fresh.options["layout"] || %{}

      layout =
        Enum.reduce(nodes, layout, fn node, layout ->
          Map.put(layout, to_string(node.id), %{"x" => round(node.x), "y" => round(node.y)})
        end)

      case mod.update_view(
             collection,
             fresh,
             %{options: Map.put(fresh.options, "layout", layout)},
             actor: opts[:actor]
           ) do
        {:ok, _view} -> :ok
        {:error, error} -> {:error, error.message}
      end
    end

    # Adds or removes a link: the target record's relation gets or loses the
    # source record.
    defp link(mod, collection, field, source, target, action, opts) do
      {source, target} = {to_int(source), to_int(target)}

      case mod.get(collection, target) do
        %Record{} = record ->
          ids = List.wrap(record.data[field.key])
          ids = if action == :add, do: Enum.uniq(ids ++ [source]), else: List.delete(ids, source)

          case mod.update(collection, record, %{field.key => ids}, actor: opts[:actor]) do
            {:ok, _record} -> :ok
            {:error, error} -> {:error, error.message}
          end

        nil ->
          {:error, "That record is gone."}
      end
    end

    defp to_int(id) when is_integer(id), do: id
    defp to_int(id) when is_binary(id), do: String.to_integer(id)
  end
end
