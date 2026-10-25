defmodule Cardbox.QueryTest do
  use CardboxTest.DataCase

  @now ~U[2026-10-25 12:00:00Z]

  setup do
    collection = tasks!()

    for values <- [
          %{
            "Title" => "Alpha",
            "Status" => "Done",
            "Priority" => "High",
            "Tags" => ["Bug"],
            "Points" => 8,
            "Done" => true,
            "Due" => "2026-10-20",
            "Owner" => "1"
          },
          %{
            "Title" => "beta",
            "Status" => "In progress",
            "Priority" => "Low",
            "Tags" => ["Bug", "UI"],
            "Points" => 3,
            "Due" => "2026-10-27",
            "Owner" => "2"
          },
          %{
            "Title" => "Gamma",
            "Status" => "Not started",
            "Tags" => ["Docs"],
            "Points" => 5.5,
            "Due" => "2026-11-30"
          },
          %{"Title" => "delta 100%", "Priority" => "Medium", "Owner" => "1"}
        ] do
      insert!(collection, values)
    end

    %{collection: collection}
  end

  defp where(collection, filter, opts \\ []),
    do:
      collection
      |> titles(%{"filter" => filter}, Keyword.put_new(opts, :now, @now))
      |> Enum.sort()

  test "texts: without case, and % taken as itself", %{collection: c} do
    assert where(c, %{"field" => "Title", "op" => "contains", "value" => "ET"}) == ["beta"]

    assert where(c, %{"field" => "title", "op" => "contains", "value" => "100%"}) == [
             "delta 100%"
           ]

    assert where(c, %{"field" => "title", "op" => "starts_with", "value" => "g"}) == ["Gamma"]
    assert where(c, %{"field" => "title", "op" => "not_contains", "value" => "a"}) == []

    assert where(c, %{"field" => "link", "op" => "is_empty"}) == [
             "Alpha",
             "Gamma",
             "beta",
             "delta 100%"
           ]
  end

  test "numbers, and is-not taking the empty ones", %{collection: c} do
    assert where(c, %{"field" => "points", "op" => "gt", "value" => "5"}) == ["Alpha", "Gamma"]

    assert where(c, %{"field" => "points", "op" => "between", "value" => [3, 5.5]}) == [
             "Gamma",
             "beta"
           ]

    assert where(c, %{"field" => "points", "op" => "neq", "value" => 8}) == [
             "Gamma",
             "beta",
             "delta 100%"
           ]
  end

  test "checkboxes", %{collection: c} do
    assert where(c, %{"field" => "done", "op" => "eq", "value" => true}) == ["Alpha"]

    assert where(c, %{"field" => "done", "op" => "eq", "value" => false}) == [
             "Gamma",
             "beta",
             "delta 100%"
           ]
  end

  test "choices by name or id, and a status by its group", %{collection: c} do
    assert where(c, %{"field" => "priority", "op" => "eq", "value" => "high"}) == ["Alpha"]

    assert where(c, %{"field" => "priority", "op" => "not_in", "value" => ["High", "Low"]}) == [
             "Gamma",
             "delta 100%"
           ]

    assert where(c, %{"field" => "status", "op" => "in_group", "value" => ["todo", "doing"]}) == [
             "Gamma",
             "beta"
           ]

    assert where(c, %{"field" => "tags", "op" => "has_any", "value" => ["UI", "Docs"]}) == [
             "Gamma",
             "beta"
           ]

    assert where(c, %{"field" => "tags", "op" => "has_all", "value" => ["Bug", "UI"]}) == ["beta"]

    assert where(c, %{"field" => "tags", "op" => "has_none", "value" => ["Bug"]}) == [
             "Gamma",
             "delta 100%"
           ]
  end

  test "days, as dates or in words read when the query runs", %{collection: c} do
    assert where(c, %{"field" => "due", "op" => "before", "value" => "today"}) == ["Alpha"]
    assert where(c, %{"field" => "due", "op" => "within", "value" => "next_week"}) == ["beta"]

    assert where(c, %{"field" => "due", "op" => "within", "value" => "next_week"},
             now: ~U[2026-11-28 09:00:00Z]
           ) == ["Gamma"]

    assert where(c, %{"field" => "due", "op" => "on_or_after", "value" => "2026-10-27"}) == [
             "Gamma",
             "beta"
           ]

    assert where(c, %{"field" => "due", "op" => "within", "value" => "this_month"}) == [
             "Alpha",
             "beta"
           ]
  end

  test "moments: the days of a field with a time, and of when records were made", %{collection: c} do
    {:ok, c} = Box.add_field(c, %{name: "Meeting", type: "date", options: %{time: true}})
    insert!(c, %{"Title" => "Late", "Meeting" => "2026-10-25T23:30:00Z"})
    insert!(c, %{"Title" => "Early", "Meeting" => "2026-10-26T00:00:00+00:00"})

    assert where(c, %{"field" => "meeting", "op" => "eq", "value" => "today"}) == ["Late"]
    assert where(c, %{"field" => "meeting", "op" => "after", "value" => "today"}) == ["Early"]
    {:ok, c} = Box.add_field(c, %{name: "Created", type: "created_at"})
    today = Date.to_iso8601(Date.utc_today())

    assert length(
             where(c, %{"field" => "created", "op" => "eq", "value" => today},
               now: DateTime.utc_now()
             )
           ) == 6
  end

  test "\"me\" is whoever runs the query", %{collection: c} do
    assert where(c, %{"field" => "owner", "op" => "eq", "value" => "me"}, me: %{id: 1}) == [
             "Alpha",
             "delta 100%"
           ]

    assert where(c, %{"field" => "owner", "op" => "eq", "value" => "me"}, me: "2") == ["beta"]
    assert where(c, %{"field" => "owner", "op" => "eq", "value" => "me"}) == []
    assert length(where(c, %{"field" => "owner", "op" => "neq", "value" => "me"})) == 4
    assert where(c, %{"field" => "owner", "op" => "in", "value" => ["me", "2"]}) == ["beta"]
  end

  test "groups of and and or", %{collection: c} do
    filter = %{
      "or" => [
        %{
          "and" => [
            %{"field" => "points", "op" => "gte", "value" => 5},
            %{"field" => "done", "op" => "eq", "value" => false}
          ]
        },
        %{"field" => "priority", "op" => "eq", "value" => "Low"}
      ]
    }

    assert where(c, filter) == ["Gamma", "beta"]
  end

  test "a search finds the words in texts and in the names of choices", %{collection: c} do
    assert c |> titles(%{"search" => "GAM"}) == ["Gamma"]
    assert c |> titles(%{"search" => "progress"}) == ["beta"]
    assert c |> titles(%{"search" => "docs"}) == ["Gamma"]
    assert c |> titles(%{"search" => "nothing"}) == []
  end

  test "a search finds each of its words, without case or accents, on every database", %{
    collection: c
  } do
    insert!(c, %{"Title" => "Élan vital", "Tags" => ["Docs"]})
    insert!(c, %{"Title" => "ÜBER straße"})
    assert titles(c, %{"search" => "elan"}) == ["Élan vital"]
    assert titles(c, %{"search" => "ÉLAN docs"}) == ["Élan vital"]
    assert titles(c, %{"search" => "über STRASSE"}) == []
    assert titles(c, %{"search" => "uber stra"}) == ["ÜBER straße"]
    assert titles(c, %{"search" => "vital bug"}) == []
  end

  test "the search text follows renamed choices and deleted fields", %{collection: c} do
    {:ok, c} =
      Box.update_field(c, "Priority", %{
        options: %{choices: [%{id: "high", name: "Urgent"}, "Low", "Medium"]}
      })

    assert titles(c, %{"search" => "urgent"}) == ["Alpha"]
    {:ok, c} = Box.delete_field(c, "Title")
    {:ok, records} = Box.list(c, %{"search" => "gamma"})
    assert records == []
  end

  test "sorts: texts without case, choices in their order, empty values last", %{collection: c} do
    assert titles(c, %{"sort" => [%{"field" => "title"}]}) == [
             "Alpha",
             "beta",
             "delta 100%",
             "Gamma"
           ]

    assert titles(c, %{"sort" => [%{"field" => "priority", "dir" => "desc"}]}) == [
             "Alpha",
             "delta 100%",
             "beta",
             "Gamma"
           ]

    assert titles(c, %{"sort" => [%{"field" => "status"}]}) == [
             "Gamma",
             "beta",
             "Alpha",
             "delta 100%"
           ]

    assert titles(c, %{"sort" => [%{"field" => "points", "dir" => "desc"}]}) == [
             "Alpha",
             "Gamma",
             "beta",
             "delta 100%"
           ]

    assert titles(c, %{"sort" => [%{"field" => "due"}]}) == [
             "Alpha",
             "beta",
             "Gamma",
             "delta 100%"
           ]
  end

  test "pages and counts", %{collection: c} do
    assert {:ok, [%{data: %{"title" => "beta"}}]} = Box.list(c, nil, limit: 1, offset: 1)

    assert Box.count(c, %{"filter" => %{"field" => "tags", "op" => "has_any", "value" => ["Bug"]}}) ==
             {:ok, 2}
  end

  test "meets?/4 answers as the database does, for a record that changed", %{collection: c} do
    query = %{"filter" => %{"field" => "status", "op" => "in_group", "value" => "done"}}
    {:ok, [record]} = Box.list(c, query)
    assert Box.meets?(c, query, record) == {:ok, true}

    assert Box.meets?(c, query, %{record | data: Map.delete(record.data, "status")}) ==
             {:ok, false}
  end

  test "errors say where and what to write", %{collection: c} do
    assert {:error, %Error{message: message}} =
             Box.list(c, %{"filter" => %{"field" => "Colour", "op" => "eq", "value" => "red"}})

    assert message =~ ~s(the collection has no field "Colour"; its fields are "Title", "Status")

    assert {:error, %Error{message: message}} =
             Box.list(c, %{"filter" => %{"field" => "points", "op" => "contains", "value" => "1"}})

    assert message =~ ~s("Points" \(number\) filters by eq, neq, gt)

    assert {:error, %Error{message: message}} =
             Box.list(c, %{
               "filter" => %{"field" => "due", "op" => "eq", "value" => "next tuesday"}
             })

    assert message =~ "takes a day as YYYY-MM-DD or one of today, tomorrow"

    assert {:error, %Error{message: message}} = Box.list(c, %{"sort" => [%{"field" => "tags"}]})
    assert message =~ "holds several values and does not sort"

    assert {:error, %Error{message: message}} = Box.list(c, %{"order" => []})
    assert message =~ ~s(a query has "filter", "sort" and "search", got: "order")
  end

  test "the wire format comes back with fields by key and choices by id", %{collection: c} do
    wire = %{
      "filter" => %{
        "and" => [
          %{"field" => "Priority", "op" => "in", "value" => ["High", "low"]},
          %{"field" => "Due", "op" => "is_empty"}
        ]
      },
      "sort" => %{"field" => "Points", "dir" => "desc"},
      "search" => " a "
    }

    {:ok, query} = Query.parse(wire, c)

    assert Query.to_wire(query) == %{
             "filter" => %{
               "and" => [
                 %{"field" => "priority", "op" => "in", "value" => ["high", "low"]},
                 %{"field" => "due", "op" => "is_empty"}
               ]
             },
             "sort" => [%{"field" => "points", "dir" => "desc"}],
             "search" => "a"
           }

    assert Query.parse(Query.to_wire(query), c) == {:ok, query}
  end

  test "a saved view lists its records, and still opens after a field it names goes", %{
    collection: c
  } do
    {:ok, view} =
      Box.save_view(c, %{
        name: "Open bugs",
        type: "board",
        query: %{
          "filter" => %{
            "and" => [
              %{"field" => "Tags", "op" => "has_any", "value" => ["Bug"]},
              %{"field" => "Status", "op" => "in_group", "value" => ["todo", "doing"]}
            ]
          }
        },
        options: %{group_by: "Status"}
      })

    assert view.options == %{"group_by" => "status"}
    assert titles(c, view) == ["beta"]

    {:ok, c} = Box.delete_field(c, "Status")
    assert c |> titles(Box.get_view(c, view.id)) |> Enum.sort() == ["Alpha", "beta"]

    assert {:error, %Error{message: message}} =
             Box.save_view(c, %{name: "Cal", type: "calendar", options: %{date_field: "Title"}})

    assert message =~ ~s(a calendar's date_field cannot be "Title" \(text\))
  end

  test "views are shared, or someone's own", %{collection: c} do
    {:ok, _} = Box.save_view(c, %{name: "All"})
    {:ok, _} = Box.save_view(c, %{name: "Mine", owner: "7"})
    assert c |> Box.list_views() |> Enum.map(& &1.name) == ["All"]
    assert c |> Box.list_views(owner: %{id: 7}) |> Enum.map(& &1.name) == ["All", "Mine"]
  end

  test "describe/1 gives an agent each field, its choices and its operators", %{collection: c} do
    description = Cardbox.describe(c)
    status = Enum.find(description["fields"], &(&1["key"] == "status"))

    assert status["choices"] == [
             %{"name" => "Not started", "group" => "todo"},
             %{"name" => "In progress", "group" => "doing"},
             %{"name" => "Done", "group" => "done"}
           ]

    assert "in_group" in status["operators"]
    assert description["name"] == "Tasks"
  end
end
