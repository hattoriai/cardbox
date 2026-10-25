defmodule Cardbox.CollectionsTest do
  use CardboxTest.DataCase

  describe "create_collection/2" do
    test "makes a collection with its fields, keys made from their names, in order" do
      collection = tasks!()

      assert collection.name == "Tasks"
      assert {collection.owner_type, collection.owner_id} == {"workspace", "1"}
      assert Enum.map(collection.fields, & &1.key) == ~w(title status priority tags points done due owner link)
      assert [%{"id" => "low", "color" => "gray"}, %{"id" => "medium"}, %{"id" => "high"}] = Field.choices(Collection.field(collection, "priority"))
      assert Box.get_collection(collection.id).fields |> Enum.map(& &1.key) == Enum.map(collection.fields, & &1.key)
    end

    test "a status has its three groups when no choices are given" do
      status = Collection.field(tasks!(), "Status")
      assert Enum.map(Field.choices(status), &{&1["id"], &1["group"]}) == [{"not_started", "todo"}, {"in_progress", "doing"}, {"done", "done"}]
    end

    test "is all or nothing: a field that does not check makes no collection" do
      assert {:error, %Error{reason: :invalid, message: message}} =
               Box.create_collection(%{name: "Bad", fields: [%{name: "A", type: "text"}, %{name: "B", type: "colour"}]})

      assert message =~ "type is one of text, number"
      assert Box.list_collections(nil) == []
    end

    test "lists the collections of an owner" do
      collection = tasks!()
      {:ok, _other} = Box.create_collection(%{name: "Elsewhere", owner: {"workspace", 2}})
      assert [%{id: id}] = Box.list_collections({"workspace", 1})
      assert id == collection.id
    end
  end

  describe "fields" do
    test "add_field/3 keeps keys unique and names unique without case" do
      collection = tasks!()
      {:ok, collection} = Box.add_field(collection, %{name: "Title 2", type: "text"})
      assert Collection.field(collection, "Title 2").key == "title_2"

      assert {:error, %Error{message: "name is taken by another field: \"title\""}} =
               Box.add_field(collection, %{name: "title", type: "text"})
    end

    test "options are checked for the type, with an error that says what to write" do
      collection = tasks!()

      assert {:error, %Error{message: message}} =
               Box.add_field(collection, %{name: "Cost", type: "number", options: %{format: "currency"}})

      assert message =~ "names its currency in ISO 4217"

      assert {:error, %Error{message: message}} =
               Box.add_field(collection, %{name: "Cost", type: "number", options: %{colour: "red"}})

      assert message =~ "options are format, decimals, currency"
    end

    test "a relation names a collection that exists" do
      collection = tasks!()

      assert {:error, %Error{message: message}} =
               Box.add_field(collection, %{name: "Parent", type: "relation", options: %{collection_id: 999_999}})

      assert message =~ "names a collection"
    end

    test "renaming a field keeps its key and its values" do
      collection = tasks!()
      record = insert!(collection, %{"Title" => "Write docs"})
      {:ok, collection} = Box.update_field(collection, "Title", %{name: "Name"})

      assert Collection.field(collection, "Name").key == "title"
      assert Box.get(collection, record.id) |> Cardbox.get(collection, "Name") == "Write docs"
    end

    test "renaming a choice renames it in every record; removing one empties it" do
      collection = tasks!()
      a = insert!(collection, %{"Priority" => "High", "Tags" => ["Bug", "UI"]})

      {:ok, collection} =
        Box.update_field(collection, "Priority", %{options: %{choices: [%{name: "Low"}, %{name: "Urgent", id: "high"}]}})

      assert Box.get(collection, a.id) |> Record.to_map(collection) |> Map.fetch!("Priority") == "Urgent"

      {:ok, collection} = Box.update_field(collection, "Priority", %{options: %{choices: ["Low"]}})
      {:ok, collection} = Box.update_field(collection, "Tags", %{options: %{choices: ["Bug", "Docs"]}})

      record = Box.get(collection, a.id)
      refute Map.has_key?(record.data, "priority")
      assert record.data["tags"] == ["bug"]
    end

    test "changing a type converts the values: text to number, text to select (making its choices)" do
      collection = tasks!([%{name: "Estimate", type: "text"}, %{name: "Area", type: "text"}])
      a = insert!(collection, %{"Estimate" => "3", "Area" => "Backend"})
      b = insert!(collection, %{"Estimate" => "a lot", "Area" => "Frontend"})
      c = insert!(collection, %{"Area" => "backend"})

      {:ok, collection} = Box.update_field(collection, "Estimate", %{type: "number"})
      assert Box.get(collection, a.id).data["estimate"] == 3
      refute Map.has_key?(Box.get(collection, b.id).data, "estimate")

      {:ok, collection} = Box.update_field(collection, "Area", %{type: "select"})
      area = Collection.field(collection, "Area")
      assert Enum.map(Field.choices(area), & &1["name"]) == ["Backend", "Frontend"]
      assert Box.get(collection, c.id).data["area"] == "backend"

      {:ok, collection} = Box.update_field(collection, "Area", %{type: "text"})
      assert Box.get(collection, b.id).data["area"] == "Frontend"
      assert Collection.field(collection, "Area").options == %{}
    end

    test "a multi-select that becomes text joins its names" do
      collection = tasks!()
      a = insert!(collection, %{"Tags" => ["UI", "Bug"]})
      {:ok, collection} = Box.update_field(collection, "Tags", %{type: "text"})
      assert Box.get(collection, a.id).data["tags"] == "Bug, UI"
    end

    test "deleting a field deletes its values and takes it out of views" do
      collection = tasks!()
      a = insert!(collection, %{"Title" => "A", "Points" => 3})

      {:ok, view} =
        Box.save_view(collection, %{
          name: "Big",
          type: "table",
          query: %{
            "filter" => %{"and" => [%{"field" => "points", "op" => "gt", "value" => 1}, %{"field" => "title", "op" => "is_not_empty"}]},
            "sort" => [%{"field" => "points", "dir" => "desc"}]
          },
          options: %{columns: ["title", "points"], widths: %{"points" => 80}}
        })

      {:ok, collection} = Box.delete_field(collection, "Points")

      assert Box.get(collection, a.id).data == %{"title" => "A"}
      view = Box.get_view(collection, view.id)
      assert view.query == %{"filter" => %{"and" => [%{"field" => "title", "op" => "is_not_empty"}]}}
      assert view.options == %{"columns" => ["title"], "widths" => %{}}
    end

    test "move_field/3 puts a field after another, or first" do
      collection = tasks!()
      {:ok, collection} = Box.move_field(collection, "Link", after: "Title")
      assert collection.fields |> Enum.map(& &1.key) |> Enum.take(3) == ~w(title link status)
      {:ok, collection} = Box.move_field(collection, "Due", to: :first)
      assert hd(collection.fields).key == "due"
      assert Box.get_collection(collection.id).fields |> Enum.map(& &1.key) == Enum.map(collection.fields, & &1.key)
    end
  end
end
