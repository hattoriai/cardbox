defmodule Cardbox.CalendarChartTest do
  use CardboxTest.DataCase

  setup do
    collection =
      tasks!([%{name: "Cost", type: "number", options: %{format: "currency", currency: "EUR"}}])

    for {title, status, priority, due, cost} <- [
          {"A", "Done", "High", "2026-10-03", 100},
          {"B", "In progress", "High", "2026-10-03", 50},
          {"C", "In progress", "Low", "2026-10-20", 25.5},
          {"D", "Not started", nil, "2026-11-02", nil},
          {"E", nil, "Low", nil, 10}
        ] do
      insert!(collection, %{
        "Title" => title,
        "Status" => status,
        "Priority" => priority,
        "Due" => due,
        "Cost" => cost
      })
    end

    %{collection: collection}
  end

  describe "group/3" do
    test "counts and sums by fields, in the database, through a query", %{collection: c} do
      {:ok, rows} = Box.group(c, nil, by: "Status")

      assert Map.new(rows, &{&1["groups"], &1["value"]}) == %{
               ["done"] => 1,
               ["in_progress"] => 2,
               ["not_started"] => 1,
               [nil] => 1
             }

      {:ok, rows} =
        Box.group(c, %{"filter" => %{"field" => "status", "op" => "is_not_empty"}},
          by: ["Priority"],
          value: {:sum, "Cost"}
        )

      assert Map.new(rows, &{&1["groups"], &1["value"]}) == %{
               ["high"] => 150,
               ["low"] => 25.5,
               [nil] => nil
             }

      {:ok, rows} = Box.group(c, nil, by: [{"Due", :month}, "Priority"])
      assert {["2026-10", "high"], 2} in Enum.map(rows, &{&1["groups"], &1["value"]})

      {:ok, [%{"groups" => [], "value" => 5}]} = Box.group(c, nil, by: [])
    end

    test "refuses what does not group", %{collection: c} do
      assert {:error, %Error{message: message}} = Box.group(c, nil, by: "Tags")
      assert message =~ "holds several values"
      assert {:error, %Error{message: message}} = Box.group(c, nil, by: {"Title", :month})
      assert message =~ "only dates group by month"

      assert {:error, %Error{message: message}} =
               Box.group(c, nil, by: "Status", value: {:sum, "Title"})

      assert message =~ "sum takes a number field"
    end
  end

  describe "Cardbox.Koyomi" do
    test "the days of a range: a mark for each record, toned by its status's group", %{
      collection: c
    } do
      {:ok, view} =
        Box.save_view(c, %{name: "Due", type: "calendar", options: %{date_field: "Due"}})

      days = Cardbox.Koyomi.days(Box, c, view, Date.range(~D[2026-10-01], ~D[2026-10-31]))

      assert Map.keys(days) |> Enum.sort(Date) == [~D[2026-10-03], ~D[2026-10-20]]
      assert days[~D[2026-10-03]][:marks] |> Enum.sort() == [:accent, :success]
      assert days[~D[2026-10-03]][:title] =~ "A"
      assert days[~D[2026-10-20]][:marks] == [:accent]

      assert {:ok, [%{data: %{"title" => "D"}}]} =
               Cardbox.Koyomi.on_day(Box, c, view, "2026-11-02")
    end

    test "the view's query narrows its days", %{collection: c} do
      {:ok, view} =
        Box.save_view(c, %{
          name: "Open",
          type: "calendar",
          options: %{date_field: "Due"},
          query: %{"filter" => %{"field" => "status", "op" => "in_group", "value" => ["doing"]}}
        })

      days = Cardbox.Koyomi.days(Box, c, view, Date.range(~D[2026-10-01], ~D[2026-11-30]))
      assert days[~D[2026-10-03]][:marks] == [:accent]
      refute Map.has_key?(days, ~D[2026-11-02])
    end
  end

  describe "Cardbox.Fude" do
    test "a chart view's options are checked and kept by key", %{collection: c} do
      {:ok, view} =
        Box.save_view(c, %{
          name: "Cost",
          type: "chart",
          options: %{kind: "bar", x: "Status", y: %{sum: "Cost"}, color: "Priority"}
        })

      assert view.options == %{
               "kind" => "bar",
               "x" => "status",
               "y" => %{"sum" => "cost"},
               "color" => "priority"
             }

      {:ok, view} =
        Box.save_view(c, %{name: "By month", type: "chart", options: %{kind: "line", x: "Due"}})

      assert view.options == %{"kind" => "line", "x" => "due", "unit" => "month", "y" => "count"}

      assert {:error, %Error{message: message}} =
               Box.save_view(c, %{name: "Bad", type: "chart", options: %{x: "Tags"}})

      assert message =~ "cannot be \"Tags\""

      assert {:error, %Error{message: message}} =
               Box.save_view(c, %{
                 name: "Bad",
                 type: "chart",
                 options: %{kind: "radar", x: "Status"}
               })

      assert message =~ "kind is one of bar, line"
    end

    test "a chart's data is the groups, in words, choices in their order", %{collection: c} do
      {:ok, view} =
        Box.save_view(c, %{
          name: "Cost by status",
          type: "chart",
          options: %{kind: "bar", x: "Status", y: %{sum: "Cost"}}
        })

      {:ok, chart} = Cardbox.Fude.build(Box, c, view)
      spec = Fude.Spec.dump(chart)
      encoded = JSON.encode!(spec)

      assert encoded =~ "Cost by status"
      assert encoded =~ "currency:EUR"
      assert encoded =~ ~s(["Not started","In progress","Done","No status"])
      assert {:ok, _chart} = Fude.Spec.load(spec)

      rows = chart.datasets["data"]
      assert %{"Status" => "In progress", "Cost" => 75.5} in rows
      assert %{"Status" => "No status", "Cost" => 10} in rows
    end

    test "a number is one aggregate of the view's records", %{collection: c} do
      {:ok, view} =
        Box.save_view(c, %{
          name: "Total",
          type: "chart",
          options: %{kind: "number", y: %{sum: "Cost"}}
        })

      {:ok, chart} = Cardbox.Fude.build(Box, c, view)
      assert chart.datasets["data"] == [%{"Cost" => 185.5}]
    end
  end
end
