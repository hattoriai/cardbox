defmodule CardboxTest.DataCase do
  @moduledoc "Tests with the database (Ecto's sandbox), and a collection to start from."
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import CardboxTest.DataCase
      alias Cardbox.{Collection, Error, Event, Field, Query, Record, View}
      alias CardboxTest.Cardbox, as: Box
    end
  end

  setup _tags do
    pid = Sandbox.start_owner!(test_repo(), shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  def test_repo, do: CardboxTest.Cardbox.__cardbox__(:repo)

  @doc "A collection of tasks, with a field of each kind."
  def tasks!(extra \\ []) do
    {:ok, collection} =
      CardboxTest.Cardbox.create_collection(%{
        name: "Tasks",
        owner: {"workspace", 1},
        fields:
          [
            %{name: "Title", type: "text"},
            %{name: "Status", type: "status"},
            %{name: "Priority", type: "select", options: %{choices: ["Low", "Medium", "High"]}},
            %{name: "Tags", type: "multi_select", options: %{choices: ["Bug", "Docs", "UI"]}},
            %{name: "Points", type: "number"},
            %{name: "Done", type: "checkbox"},
            %{name: "Due", type: "date"},
            %{name: "Owner", type: "person"},
            %{name: "Link", type: "url"}
          ] ++ extra
      })

    collection
  end

  def insert!(collection, values, opts \\ []) do
    {:ok, record} = CardboxTest.Cardbox.insert(collection, values, opts)
    record
  end

  def titles(collection, query, opts \\ []) do
    {:ok, records} = CardboxTest.Cardbox.list(collection, query, opts)
    Enum.map(records, & &1.data["title"])
  end
end
