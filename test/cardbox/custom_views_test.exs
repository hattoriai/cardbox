defmodule Cardbox.CustomViewsTest do
  use CardboxTest.DataCase

  defmodule Timelines do
    use Cardbox, views: ["timeline"]

    def repo, do: Application.fetch_env!(:cardbox, :test_repo)

    @impl Cardbox
    def check_view("timeline", options, collection) do
      case Cardbox.Collection.field(collection, options["start"]) do
        %Cardbox.Field{type: "date", key: key} -> {:ok, Map.put(options, "start", key)}
        _ -> {:error, "a timeline starts at a date field"}
      end
    end
  end

  test "an app's own type of view is saved, checked and queried as any" do
    collection = tasks!()
    insert!(collection, %{"Title" => "Soon", "Due" => "2026-11-01"})
    insert!(collection, %{"Title" => "Undated"})

    {:ok, view} =
      Timelines.save_view(collection, %{
        name: "Roadmap",
        type: "timeline",
        query: %{"filter" => %{"field" => "Due", "op" => "is_not_empty"}},
        options: %{start: "Due"}
      })

    assert view.type == "timeline"
    assert view.options == %{"start" => "due"}
    assert {:ok, [%{data: %{"title" => "Soon"}}]} = Timelines.list(collection, view)

    assert {:error, %Error{message: "options a timeline starts at a date field"}} =
             Timelines.save_view(collection, %{
               name: "Bad",
               type: "timeline",
               options: %{start: "Title"}
             })
  end

  test "a module takes only Cardbox's types and its own" do
    collection = tasks!()

    assert {:error, %Error{message: message}} =
             Box.save_view(collection, %{name: "Roadmap", type: "timeline"})

    assert message =~ "type is one of table, board, list, calendar, chart, canvas"
  end

  test "a type of one's own is a key, and not one of Cardbox's" do
    assert_raise ArgumentError, ~r/lowercase/, fn -> Cardbox.View.check_types!(["Time Line"]) end

    assert_raise ArgumentError, ~r/of Cardbox's own/, fn ->
      Cardbox.View.check_types!(["board"])
    end
  end
end
