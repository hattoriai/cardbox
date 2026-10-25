defmodule Cardbox.RecordsTest do
  use CardboxTest.DataCase

  describe "insert/3" do
    test "takes values by field name or key, as forms and agents give them" do
      collection = tasks!()

      {:ok, record} =
        Box.insert(
          collection,
          %{
            "Title" => "Ship it",
            "status" => "In progress",
            "Points" => "5",
            "Done" => "on",
            "Due" => ~D[2026-11-02],
            "Tags" => ["bug", "UI"],
            "Owner" => 7
          }, actor: %{id: 42})

      assert record.data == %{
               "title" => "Ship it",
               "status" => "in_progress",
               "points" => 5,
               "done" => true,
               "due" => "2026-11-02",
               "tags" => ["bug", "ui"],
               "owner" => "7"
             }

      assert record.created_by == "42"
      assert Cardbox.get(record, collection, "Due") == ~D[2026-11-02]
      assert Cardbox.get(record, collection, "Priority") == nil
      assert Cardbox.get(record, collection, "Tags") == ["bug", "ui"]
    end

    test "keeps no key for an empty value" do
      record = insert!(tasks!(), %{"Title" => "", "Done" => false, "Tags" => [], "Points" => nil})
      assert record.data == %{}
    end

    test "says every value that does not check, with what the field takes" do
      collection = tasks!()

      assert {:error, %Error{reason: :invalid, errors: errors, message: message}} =
               Box.insert(collection, %{
                 "Points" => "many",
                 "Priority" => "Critical",
                 "Colour" => "red",
                 "Link" => "nope"
               })

      assert {"points", "is a number, got: \"many\""} in errors

      assert {"priority",
              "is one of the choices (\"Low\", \"Medium\", \"High\"), got: \"Critical\""} in errors

      assert {"Colour", "is not a field of the collection"} in errors
      assert message =~ "Points is a number"
      assert Box.count(collection) == {:ok, 0}
    end

    test "places records last, first, or after another" do
      collection = tasks!()
      insert!(collection, %{"Title" => "b"})
      c = insert!(collection, %{"Title" => "c"})
      insert!(collection, %{"Title" => "a"}, to: :first)
      insert!(collection, %{"Title" => "b2"}, before: c.id)
      assert titles(collection, nil) == ~w(a b b2 c)
    end

    test "insert_all/3 inserts every record or none" do
      collection = tasks!()
      assert {:ok, [_, _]} = Box.insert_all(collection, [%{"Title" => "x"}, %{"Title" => "y"}])

      assert {:error, %Error{message: "record 2: Points is a number, got: \"no\""}} =
               Box.insert_all(collection, [%{"Title" => "z"}, %{"Points" => "no"}])

      assert Box.count(collection) == {:ok, 2}
    end
  end

  describe "update/4" do
    test "changes the values given, and nil empties one" do
      collection = tasks!()
      record = insert!(collection, %{"Title" => "Draft", "Points" => 3})

      {:ok, record} =
        Box.update(collection, record, %{"Points" => nil, "Status" => "Done"}, actor: "agent:1")

      assert record.data == %{"title" => "Draft", "status" => "done"}
      assert record.updated_by == "agent:1"
    end

    test "refuses a value someone changed meanwhile, with the record as it is" do
      collection = tasks!()
      record = insert!(collection, %{"Title" => "Draft", "Status" => "Not started"})
      {:ok, _} = Box.update(collection, record.id, %{"Status" => "In progress"})

      assert {:error,
              %Error{
                reason: :conflict,
                errors: [{"status", "changed meanwhile"}],
                current: current
              }} =
               Box.update(collection, record.id, %{"Status" => "Done"},
                 expect: %{"Status" => "Not started"}
               )

      assert current.data["status"] == "in_progress"

      assert {:ok, _} =
               Box.update(collection, record.id, %{"Status" => "Done"},
                 expect: %{"Status" => "In progress"}
               )
    end

    test "a record of another collection is not found" do
      a = tasks!()
      {:ok, b} = Box.create_collection(%{name: "Other", fields: [%{name: "Title", type: "text"}]})
      record = insert!(b, %{"Title" => "x"})
      assert {:error, %Error{reason: :not_found}} = Box.update(a, record.id, %{"Title" => "y"})
    end
  end

  describe "relations" do
    test "link to records of their collection, and lose the link when the record goes" do
      {:ok, people} =
        Box.create_collection(%{name: "People", fields: [%{name: "Name", type: "text"}]})

      ada = insert!(people, %{"Name" => "Ada"})
      grace = insert!(people, %{"Name" => "Grace"})

      collection =
        tasks!([%{name: "Assignees", type: "relation", options: %{collection_id: people.id}}])

      task = insert!(collection, %{"Assignees" => [ada.id, "#{grace.id}"]})
      assert task.data["assignees"] == [ada.id, grace.id]

      assert {:error, %Error{message: message}} =
               Box.insert(collection, %{"Assignees" => [task.id]})

      assert message =~ "links to records that are not in its collection: #{task.id}"

      {:ok, _} = Box.delete(people, ada)
      assert Box.get(collection, task.id).data["assignees"] == [grace.id]
      {:ok, _} = Box.delete(people, grace)
      refute Map.has_key?(Box.get(collection, task.id).data, "assignees")
    end
  end

  describe "move/3" do
    test "moves a record in the collection's order" do
      collection = tasks!()
      a = insert!(collection, %{"Title" => "a"})
      b = insert!(collection, %{"Title" => "b"})
      c = insert!(collection, %{"Title" => "c"})
      {:ok, _} = Box.move(collection, c, after: a.id)
      assert titles(collection, nil) == ~w(a c b)
      {:ok, _} = Box.move(collection, a, to: :last)
      assert titles(collection, nil) == ~w(c b a)
      {:ok, _} = Box.move(collection, b, before: c)
      assert titles(collection, nil) == ~w(b c a)
    end
  end

  describe "events" do
    test "each change is broadcast to the collection's topic, with who made it" do
      collection = tasks!()
      :ok = Box.subscribe(collection)

      record = insert!(collection, %{"Title" => "a"}, actor: %{id: 1})
      assert_receive {:cardbox, %Event{type: :record_inserted, record: %{id: id}, actor: "1"}}
      assert id == record.id

      {:ok, _} = Box.update(collection, record, %{"Title" => "b", "Points" => 2})
      assert_receive {:cardbox, %Event{type: :record_updated, changed: changed}}
      assert Enum.sort(changed) == ["points", "title"]

      {:ok, _} = Box.update(collection, record, %{"Title" => "b"})
      refute_receive {:cardbox, %Event{type: :record_updated}}, 50

      {:ok, _} = Box.add_field(collection, %{name: "Notes", type: "text"})

      assert_receive {:cardbox,
                      %Event{
                        type: :field_added,
                        field: %{key: "notes"},
                        collection: %{fields: fields}
                      }}

      assert Enum.any?(fields, &(&1.key == "notes"))
    end
  end

  describe "allow?/3" do
    defmodule Strict do
      use Cardbox

      def repo, do: Application.fetch_env!(:cardbox, :test_repo)

      @impl Cardbox
      def allow?(%{role: :viewer}, action, _subject) when action != :create_collection, do: false
      def allow?(_actor, _action, _subject), do: true
    end

    test "is asked before each write" do
      {:ok, collection} =
        Strict.create_collection(%{name: "Locked", fields: [%{name: "Title", type: "text"}]},
          actor: %{id: 1, role: :viewer}
        )

      assert {:error, %Error{reason: :unauthorized, message: "not allowed to insert"}} =
               Strict.insert(collection, %{"Title" => "x"}, actor: %{id: 1, role: :viewer})

      assert {:error, %Error{message: "not allowed to change fields"}} =
               Strict.add_field(collection, %{name: "B", type: "text"},
                 actor: %{id: 1, role: :viewer}
               )

      assert {:ok, _} =
               Strict.insert(collection, %{"Title" => "x"}, actor: %{id: 2, role: :editor})
    end
  end
end
