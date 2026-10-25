defmodule Cardbox.BindingsTest do
  use CardboxTest.DataCase

  alias Cardbox.Masu.Source

  setup do
    collection = tasks!()

    {:ok, collection} =
      Box.add_field(collection, %{
        name: "Blocked by",
        type: "relation",
        options: %{collection_id: collection.id, two_way: true, reverse_name: "Blocks"}
      })

    a =
      insert!(collection, %{
        "Title" => "Design",
        "Status" => "Done",
        "Owner" => "ada",
        "Tags" => ["UI"]
      })

    b =
      insert!(collection, %{"Title" => "Build", "Status" => "In progress", "Blocked by" => [a.id]})

    %{collection: Box.get_collection(collection.id), a: a, b: b}
  end

  describe "Cardbox.Masu" do
    test "a grid's \"me\" is its actor, by the actor's id", %{collection: c} do
      {:ok, view} =
        Box.save_view(c, %{
          name: "Mine",
          query: %{"filter" => %{"field" => "owner", "op" => "eq", "value" => "me"}}
        })

      grid = Cardbox.Masu.grid(Box, c, view: view, actor: {:scope, "ada"})
      {source, opts} = grid[:source]
      state = opts |> source.init([]) |> source.prepare(%Masu.Query{}, [])

      assert source.count(state) == 1
      assert [%{"title" => "Design"}] = source.rows(state, 0, 10)
    end

    test "a source reads the grid's query inside the view's, in the database", %{collection: c} do
      {:ok, view} =
        Box.save_view(c, %{
          name: "Open",
          query: %{
            "filter" => %{"field" => "status", "op" => "in_group", "value" => ["todo", "doing"]}
          }
        })

      people = [%{id: "ada", name: "Ada Lovelace"}]

      source =
        Source.init(
          [mod: Box, collection: c, view: view, people: people, opts: []],
          []
        )

      state = Source.prepare(source, %Masu.Query{}, [])
      assert Source.count(state) == 1

      assert [%{"title" => "Build", "status" => "In progress", "blocked_by" => "Design"}] =
               Source.rows(state, 0, 10)

      everything =
        Source.init(
          [mod: Box, collection: c, view: nil, people: people, opts: []],
          []
        )

      query = %Masu.Query{
        filters: [%Masu.Filter{key: "owner", op: :eq, value: "Ada Lovelace"}],
        sorts: [%Masu.Sort{key: "title"}]
      }

      assert [%{"title" => "Design", "owner" => "Ada Lovelace", "tags" => "UI"}] =
               everything
               |> Source.prepare(query, [])
               |> Source.rows(0, 10)
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
      {:ok, view} =
        Box.save_view(c, %{name: "Graph", type: "canvas", options: %{edges: "Blocked by"}})

      %{view: view}
    end

    test "a graph has a node for each record and an edge for each link", %{
      collection: c,
      view: view,
      a: a,
      b: b
    } do
      {:ok, records} = Box.list(c, view)
      graph = Cardbox.Hakushi.graph(c, view, records)

      assert graph.nodes |> Map.keys() |> Enum.sort() ==
               Enum.sort([to_string(a.id), to_string(b.id)])

      assert [%{source: source, target: target}] = Map.values(graph.edges)
      assert {source, target} == {to_string(a.id), to_string(b.id)}
    end

    test "edges drawn and deleted are links; moves are the view's layout; nodes stay", %{
      collection: c,
      view: view,
      a: a,
      b: b
    } do
      c3 = insert!(c, %{"Title" => "Ship"})

      connect = %Hakushi.Change{
        op: :connect,
        edges: [%Hakushi.Edge{id: "new", source: to_string(b.id), target: to_string(c3.id)}]
      }

      assert Cardbox.Hakushi.change(Box, c, view, connect, %{}, []) == :ok
      assert Box.get(c, c3.id).data["blocked_by"] == [b.id]
      assert Box.get(c, b.id).data["blocks"] == [c3.id]

      delete = %Hakushi.Change{op: :delete, nodes: [], edges: ["blocked_by:#{a.id}:#{b.id}"]}
      assert Cardbox.Hakushi.change(Box, c, view, delete, %{}, []) == :ok
      refute Map.has_key?(Box.get(c, b.id).data, "blocked_by")

      move = %Hakushi.Change{op: :move, nodes: [%{id: to_string(a.id), x: 120.4, y: -40}]}
      assert Cardbox.Hakushi.change(Box, c, view, move, %{}, []) == :ok

      assert Box.get_view(c, view.id).options["layout"] == %{
               to_string(a.id) => %{"x" => 120, "y" => -40}
             }

      assert {:error, _} =
               Cardbox.Hakushi.change(
                 Box,
                 c,
                 view,
                 %Hakushi.Change{op: :delete, nodes: [to_string(a.id)], edges: []},
                 %{},
                 []
               )
    end
  end

  describe "Cardbox.Narabe" do
    import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
    import Phoenix.Component, only: [sigil_H: 2]

    setup %{collection: c} do
      {:ok, view} =
        Box.save_view(c, %{
          name: "Board",
          type: "board",
          options: %{group_by: "Status", card_fields: ["Owner", "Tags"]}
        })

      %{view: view}
    end

    defp move_params(ids, parent, side \\ nil),
      do:
        Map.merge(
          %{"v" => 1, "ids" => Enum.map(ids, &to_string/1), "parent" => parent},
          side || %{}
        )

    test "a column for each choice, and one for the records with none", %{collection: c} do
      field = Cardbox.Collection.field(c, "Status")
      {:ok, records} = Box.list(c, %{})

      assert Enum.map(Cardbox.Narabe.columns(field, records), & &1.id) ==
               ~w(not_started in_progress done)

      none = insert!(c, %{"Title" => "Loose"})
      assert Cardbox.Narabe.column_of(none, field) == "none"

      assert List.last(Cardbox.Narabe.columns(field, [none | records])) ==
               %{id: "none", name: "No status", color: "gray"}

      people = [%{id: "ada", name: "Ada Lovelace"}]
      owner = Cardbox.Collection.field(c, "Owner")

      assert Cardbox.Narabe.columns(owner, records, people) ==
               [%{id: "ada", name: "Ada Lovelace", color: "gray"}] ++
                 [%{id: "none", name: "No owner", color: "gray"}]

      done = Cardbox.Collection.field(c, "Done")
      assert Enum.map(Cardbox.Narabe.columns(done, records), & &1.id) == ~w(yes no)
    end

    test "a card moved to another column takes its value and its place", %{
      collection: c,
      view: view,
      a: a,
      b: b
    } do
      todo = insert!(c, %{"Title" => "Write", "Status" => "Not started"})

      # Build goes to Done, before Design.
      params = move_params([b.id], "done", %{"before" => to_string(a.id)})
      assert Cardbox.Narabe.move(Box, c, view, params, actor: "ada") == :ok
      assert Box.get(c, b.id).data["status"] == "done"
      assert Box.get(c, b.id).updated_by == "ada"
      assert titles(c, view) == ["Build", "Design", "Write"]

      # Write goes to the column of none: no status.
      assert Cardbox.Narabe.move(Box, c, view, move_params([todo.id], "none")) == :ok
      refute Map.has_key?(Box.get(c, todo.id).data, "status")

      # Within a column, only its place changes: no update.
      Box.subscribe(c)
      params = move_params([a.id], "done", %{"before" => to_string(b.id)})
      assert Cardbox.Narabe.move(Box, c, view, params) == :ok
      assert_received {:cardbox, %Cardbox.Event{type: :record_moved}}
      refute_received {:cardbox, %Cardbox.Event{type: :record_updated}}
      assert titles(c, view) == ["Design", "Build", "Write"]
    end

    test "a checkbox's columns tick and untick", %{collection: c, a: a} do
      {:ok, view} =
        Box.save_view(c, %{name: "Done?", type: "board", options: %{group_by: "Done"}})

      assert Cardbox.Narabe.move(Box, c, view, move_params([a.id], "yes")) == :ok
      assert Box.get(c, a.id).data["done"] == true
      assert Cardbox.Narabe.move(Box, c, view, move_params([a.id], "no")) == :ok
      refute Map.has_key?(Box.get(c, a.id).data, "done")
    end

    test "a move that is no move, of columns, or of a record gone is refused", %{
      collection: c,
      view: view
    } do
      assert {:error, :invalid_move} = Cardbox.Narabe.move(Box, c, view, %{"v" => 1})

      assert {:error, :invalid_move} =
               Cardbox.Narabe.move(Box, c, view, move_params(["x"], "done"))

      assert {:error, "The columns are" <> _} =
               Cardbox.Narabe.move(
                 Box,
                 c,
                 view,
                 Map.put(move_params(["done"], nil), "columns", true)
               )

      assert {:error, "That record is gone."} =
               Cardbox.Narabe.move(Box, c, view, move_params([999_999], "done"))

      assert %{error: "refused", message: "That record is gone."} =
               Narabe.Live.reply(
                 Cardbox.Narabe.move(Box, c, view, move_params([999_999], "done"))
               )
    end

    test "the board draws its columns and cards", %{collection: c, view: view} do
      {:ok, records} = Box.list(c, view)
      assigns = %{c: c, view: view, records: records}

      html =
        rendered_to_string(~H"""
        <Cardbox.Narabe.board id="board" collection={@c} view={@view} records={@records}
          people={[%{id: "ada", name: "Ada Lovelace"}]} on_move="move" />
        """)

      assert html =~ ~s(phx-hook="Narabe")
      assert html =~ "Not started"
      assert html =~ "In progress"
      assert html =~ "<strong>Design</strong>"
      assert html =~ "Ada Lovelace"
      assert html =~ "UI"
    end
  end
end
