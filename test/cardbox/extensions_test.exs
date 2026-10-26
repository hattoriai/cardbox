defmodule Cardbox.ExtensionsTest do
  use CardboxTest.DataCase

  setup do
    previous = Application.get_env(:cardbox, :types)
    Application.put_env(:cardbox, :types, [CardboxTest.Rating, CardboxTest.Mood])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:cardbox, :types, previous),
        else: Application.delete_env(:cardbox, :types)
    end)

    {:ok, collection} =
      Box.create_collection(%{
        name: "Teas",
        owner: {"workspace", 1},
        fields: [
          %{name: "Name", type: "text"},
          %{name: "Stars", type: "rating", options: %{of: "Name"}},
          %{name: "Mood", type: "mood"},
          %{name: "Done", type: "checkbox"}
        ]
      })

    %{collection: collection}
  end

  describe "a field type of the app's" do
    test "is a type beside Cardbox's, its values checked by its cast", %{collection: c} do
      assert "rating" in Cardbox.Type.names()
      record = insert!(c, %{"Name" => "Hōjicha", "Stars" => "★★★★", "Mood" => "Calm"})
      assert record.data == %{"name" => "Hōjicha", "stars" => 4, "mood" => "calm"}

      assert {:error, %Error{errors: [{"stars", "is from 1 to 5, got: 9"}]}} =
               Box.insert(c, %{"Stars" => 9})
    end

    test "checks its options with the collection, and takes none by default", %{collection: c} do
      assert {:error,
              %Error{errors: [{"options", "a rating is of a field of the collection" <> _}]}} =
               Box.add_field(c, %{name: "Again", type: "rating", options: %{of: "Nope"}})

      assert {:error, %Error{errors: [{"options", "a mood field takes no options" <> _}]}} =
               Box.add_field(c, %{name: "Feeling", type: "mood", options: %{loud: true}})
    end

    test "filters and sorts by its kind, and searches by its words", %{collection: c} do
      insert!(c, %{"Name" => "Sencha", "Stars" => 2})
      insert!(c, %{"Name" => "Gyokuro", "Stars" => 5})

      assert {:ok, [%{data: %{"name" => "Gyokuro"}}]} =
               Box.list(c, %{"filter" => %{"field" => "Stars", "op" => "gte", "value" => 4}})

      assert {:ok, [%{data: %{"name" => "Sencha"}}, _]} =
               Box.list(c, %{"sort" => [%{"field" => "Stars"}]})

      assert {:ok, [%{data: %{"name" => "Gyokuro"}}]} = Box.list(c, %{"search" => "5stars"})
    end

    test "reads in words in a table and on a board, and in its schema for agents", %{
      collection: c
    } do
      record = insert!(c, %{"Name" => "Sencha", "Stars" => 3, "Mood" => "bright"})

      stars = Enum.find(Cardbox.Masu.columns(c, nil), &(&1[:key] == "stars"))
      assert stars[:type] == :number
      assert Cardbox.Masu.row(c, record)["stars"] == 3
      assert Cardbox.FieldType.text(CardboxTest.Rating, Collection.field(c, "Stars"), 3) == "★★★"

      assert Cardbox.FieldType.text(CardboxTest.Mood, Collection.field(c, "Mood"), "bright") ==
               "bright"

      %{
        "properties" => %{"stars" => %{"anyOf" => [schema, _]}, "mood" => %{"anyOf" => [mood, _]}}
      } =
        Cardbox.JSONSchema.schema(c)

      assert schema == %{"type" => "integer", "minimum" => 1, "maximum" => 5}
      assert mood == %{"type" => "string"}
    end

    test "a type named as one of Cardbox's, or not a type, is refused" do
      assert_raise ArgumentError, ~r/is one of Cardbox's types/, fn ->
        Cardbox.FieldType.check!([CardboxTest.Shadow], Cardbox.Type.builtin())
      end

      assert_raise ArgumentError, ~r/is not a Cardbox.FieldType/, fn ->
        Cardbox.FieldType.check!([Enum], Cardbox.Type.builtin())
      end

      assert_raise ArgumentError, ~r/two field types are named "rating"/, fn ->
        Cardbox.FieldType.check!([CardboxTest.Rating, CardboxTest.Rating], Cardbox.Type.builtin())
      end
    end
  end

  describe "after_update/4" do
    test "inserts what follows an update, in its transaction, broadcast", %{collection: c} do
      tea = insert!(c, %{"Name" => "Sencha"})
      :ok = Box.subscribe(c)

      Process.put(:after_update, fn _collection, before, record, changed ->
        if "done" in changed and record.data["done"] == true and before.data["done"] != true,
          do: {:ok, [%{"Name" => record.data["name"] <> ", again"}]},
          else: {:ok, []}
      end)

      {:ok, _} = Box.update(c, tea.id, %{"Done" => true})
      assert_receive {:cardbox, %Event{type: :record_updated}}

      assert_receive {:cardbox,
                      %Event{
                        type: :record_inserted,
                        record: %{data: %{"name" => "Sencha, again"}}
                      }}

      {:ok, _} = Box.update(c, tea.id, %{"Mood" => "calm"})
      assert Box.count(c, nil) == {:ok, 2}
    end

    test "an error, or a record that does not check, undoes the update", %{collection: c} do
      tea = insert!(c, %{"Name" => "Sencha"})

      Process.put(:after_update, fn _, _, _, _ -> {:error, "not today"} end)
      assert {:error, %Error{message: message}} = Box.update(c, tea.id, %{"Done" => true})
      assert message =~ "not today"

      Process.put(:after_update, fn _, _, _, _ -> {:ok, [%{"Stars" => 9}]} end)

      assert {:error, %Error{message: "after the update: " <> _}} =
               Box.update(c, tea.id, %{"Done" => true})

      assert Box.get(c, tea.id).data == %{"name" => "Sencha"}
      assert Box.count(c, nil) == {:ok, 1}
    end
  end
end
