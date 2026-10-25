defmodule Cardbox.BindingsTest do
  use CardboxTest.DataCase

  setup do
    collection = tasks!()
    {:ok, collection} = Box.add_field(collection, %{name: "Blocked by", type: "relation", options: %{collection_id: collection.id, two_way: true, reverse_name: "Blocks"}})
    a = insert!(collection, %{"Title" => "Design", "Status" => "Done", "Owner" => "ada", "Tags" => ["UI"]})
    b = insert!(collection, %{"Title" => "Build", "Status" => "In progress", "Blocked by" => [a.id]})
    %{collection: Box.get_collection(collection.id), a: a, b: b}
  end

  describe "Cardbox.Masu" do
    test "a source reads the grid's query inside the view's, in the database", %{collection: c} do
      {:ok, view} = Box.save_view(c, %{name: "Open", query: %{"filter" => %{"field" => "status", "op" => "in_group", "value" => ["todo", "doing"]}}})
      people = [%{id: "ada", name: "Ada Lovelace"}]
      source = Cardbox.Masu.Source.init([mod: Box, collection: c, view: view, people: people, opts: []], [])

      state = Cardbox.Masu.Source.prepare(source, %Masu.Query{}, [])
      assert Cardbox.Masu.Source.count(state) == 1
      assert [%{"title" => "Build", "status" => "In progress", "blocked_by" => "Design"}] = Cardbox.Masu.Source.rows(state, 0, 10)

      everything = Cardbox.Masu.Source.init([mod: Box, collection: c, view: nil, people: people, opts: []], [])
      query = %Masu.Query{filters: [%Masu.Filter{key: "owner", op: :eq, value: "Ada Lovelace"}], sorts: [%Masu.Sort{key: "title"}]}
      assert [%{"title" => "Design", "owner" => "Ada Lovelace", "tags" => "UI"}] = everything |> Cardbox.Masu.Source.prepare(query, []) |> Cardbox.Masu.Source.rows(0, 10)
    end

    test "columns follow the fields, the view's order and its hidden ones", %{collection: c} do
      view = %View{options: %{"columns" => ["status", "title"], "hidden" => ["points"]}}
      [status, title | rest] = Cardbox.Masu.columns(c, view, [%{id: "ada", name: "Ada Lovelace"}])
      assert status[:type] == :enum and status[:values] == ["Not started", "In progress", "Done"]
      assert title[:key] == "title"
      assert Enum.find(rest, &(&1[:key] == "points"))[:hidden]
      assert Enum.find(rest, &(&1[:key] == "owner"))[:values] == ["Ada Lovelace"]
      refute Enum.find(rest, &(&1[:key] == "blocked_by"))[:editable]
    end
  end

  describe "Cardbox.Hakushi" do
    setup %{collection: c} do
      {:ok, view} = Box.save_view(c, %{name: "Graph", type: "canvas", options: %{edges: "Blocked by"}})
      %{view: view}
    end

    test "a graph has a node for each record and an edge for each link", %{collection: c, view: view, a: a, b: b} do
      {:ok, records} = Box.list(c, view)
      graph = Cardbox.Hakushi.graph(c, view, records)
      assert graph.nodes |> Map.keys() |> Enum.sort() == Enum.sort([to_string(a.id), to_string(b.id)])
      assert [%{source: source, target: target}] = Map.values(graph.edges)
      assert {source, target} == {to_string(a.id), to_string(b.id)}
    end

    test "edges drawn and deleted are links; moves are the view's layout; nodes stay", %{collection: c, view: view, a: a, b: b} do
      c3 = insert!(c, %{"Title" => "Ship"})
      connect = %Hakushi.Change{op: :connect, edges: [%Hakushi.Edge{id: "new", source: to_string(b.id), target: to_string(c3.id)}]}
      assert Cardbox.Hakushi.change(Box, c, view, connect, %{}, []) == :ok
      assert Box.get(c, c3.id).data["blocked_by"] == [b.id]
      assert Box.get(c, b.id).data["blocks"] == [c3.id]

      delete = %Hakushi.Change{op: :delete, nodes: [], edges: ["blocked_by:#{a.id}:#{b.id}"]}
      assert Cardbox.Hakushi.change(Box, c, view, delete, %{}, []) == :ok
      refute Map.has_key?(Box.get(c, b.id).data, "blocked_by")

      move = %Hakushi.Change{op: :move, nodes: [%{id: to_string(a.id), x: 120.4, y: -40}]}
      assert Cardbox.Hakushi.change(Box, c, view, move, %{}, []) == :ok
      assert Box.get_view(c, view.id).options["layout"] == %{to_string(a.id) => %{"x" => 120, "y" => -40}}

      assert {:error, _} = Cardbox.Hakushi.change(Box, c, view, %Hakushi.Change{op: :delete, nodes: [to_string(a.id)], edges: []}, %{}, [])
    end
  end
end
