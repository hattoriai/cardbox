defmodule Cardbox.AgreementTest do
  # The database and meets?/4 answer every query the same way: random
  # records, random filters, and the records each finds compared.
  use CardboxTest.DataCase
  use ExUnitProperties

  @now ~U[2026-10-25 12:00:00Z]

  @texts ["", "alpha", "Alpha beta", "beta", "gamma_1", "100%"]
  @numbers [nil, -1, 0, 2, 2.5, 10]
  @days [nil, "2026-10-20", "2026-10-25", "2026-10-27", "2026-11-25", "2025-01-01"]
  @moments [nil, "2026-10-25T00:00:00Z", "2026-10-25T23:59:59Z", "2026-10-26T00:00:00Z", "2026-10-18T12:00:00Z"]
  @people [nil, "1", "2", "3"]

  defp collection! do
    tasks!([%{name: "When", type: "date", options: %{time: true}}])
  end

  defp record_values do
    fixed_map(%{
      "Title" => member_of(@texts),
      "Status" => member_of([nil, "Not started", "In progress", "Done"]),
      "Priority" => member_of([nil, "Low", "Medium", "High"]),
      "Tags" => list_of(member_of(["Bug", "Docs", "UI"]), max_length: 3),
      "Points" => member_of(@numbers),
      "Done" => boolean(),
      "Due" => member_of(@days),
      "When" => member_of(@moments),
      "Owner" => member_of(@people),
      "Link" => member_of([nil, "https://a.example", "https://b.example"])
    })
  end

  defp condition do
    one_of([
      bind(member_of(~w(eq neq contains not_contains starts_with ends_with is_empty is_not_empty)), fn op ->
        fixed_map(%{"field" => member_of(~w(title link)), "op" => constant(op), "value" => member_of(["a", "Alpha", "%", "1", "beta", "https://a.example"])})
      end),
      bind(member_of(~w(eq neq gt gte lt lte is_empty is_not_empty)), fn op ->
        fixed_map(%{"field" => constant("points"), "op" => constant(op), "value" => member_of([-1, 0, 2, 2.5, 3])})
      end),
      fixed_map(%{"field" => constant("points"), "op" => constant("between"), "value" => member_of([[0, 2.5], [-5, 0], [3, 1]])}),
      fixed_map(%{"field" => constant("done"), "op" => constant("eq"), "value" => boolean()}),
      bind(member_of(~w(eq before after on_or_before on_or_after)), fn op ->
        fixed_map(%{"field" => member_of(~w(due when)), "op" => constant(op), "value" => member_of(["today", "tomorrow", "2026-10-27", "one_week_ago"])})
      end),
      fixed_map(%{"field" => member_of(~w(due when)), "op" => constant("within"), "value" => member_of(Cardbox.Filter.ranges())}),
      fixed_map(%{"field" => member_of(~w(due when)), "op" => member_of(~w(is_empty is_not_empty))}),
      bind(member_of(~w(eq neq)), fn op ->
        fixed_map(%{"field" => member_of(~w(priority status owner)), "op" => constant(op), "value" => member_of(["Low", "High", "Done", "me", "2"])})
      end)
      |> filter(&valid_choice?/1),
      fixed_map(%{"field" => constant("priority"), "op" => member_of(~w(in not_in)), "value" => list_of(member_of(["Low", "Medium", "High"]), max_length: 3)}),
      fixed_map(%{"field" => constant("status"), "op" => constant("in_group"), "value" => list_of(member_of(~w(todo doing done)), min_length: 1, max_length: 2)}),
      fixed_map(%{"field" => constant("tags"), "op" => member_of(~w(has_any has_all has_none)), "value" => list_of(member_of(["Bug", "Docs", "UI"]), max_length: 3)}),
      fixed_map(%{"field" => member_of(~w(tags priority owner)), "op" => member_of(~w(is_empty is_not_empty))})
    ])
  end

  defp valid_choice?(%{"field" => "priority", "value" => v}), do: v in ["Low", "High"]
  defp valid_choice?(%{"field" => "status", "value" => v}), do: v == "Done"
  defp valid_choice?(%{"field" => "owner", "value" => v}), do: v in ["me", "2"]

  # Conditions in groups three deep at most.
  defp filter_tree do
    Enum.reduce(1..2, condition(), fn _level, inner -> one_of([condition(), group(inner)]) end)
  end

  defp group(inner) do
    bind(member_of(["and", "or"]), fn op -> map(list_of(inner, min_length: 1, max_length: 3), &%{op => &1}) end)
  end

  property "the database finds the records meets?/4 finds" do
    collection = collection!()

    check all values <- list_of(record_values(), length: 25), max_runs: 1 do
      {:ok, _} = Box.insert_all(collection, values)
    end

    {:ok, records} = Box.list(collection)
    opts = [now: @now, me: "1"]

    check all filter <- filter_tree(), search <- member_of([nil, nil, nil, "alpha", "progress", "bug"]), max_runs: 400 do
      query = %{"filter" => filter, "search" => search}
      {:ok, found} = Box.list(collection, query, opts)

      expected =
        for record <- records, Box.meets?(collection, query, record, opts) == {:ok, true}, do: record.id

      assert Enum.sort(Enum.map(found, & &1.id)) == Enum.sort(expected), """
      the database and meets?/4 disagree on #{inspect(query, pretty: true)}
      """
    end
  end
end
