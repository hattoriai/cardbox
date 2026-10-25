defmodule Cardbox.RelationsTest do
  use CardboxTest.DataCase

  setup do
    {:ok, people} = Box.create_collection(%{name: "People", fields: [%{name: "Name", type: "text"}]})

    {:ok, projects} =
      Box.create_collection(%{
        name: "Projects",
        fields: [%{name: "Title", type: "text"}, %{name: "Team", type: "relation", options: %{collection_id: people.id, two_way: true}}]
      })

    people = Box.get_collection(people.id)
    %{people: people, projects: projects}
  end

  test "a two-way relation gives the other collection a field of the same links", %{people: people, projects: projects} do
    assert %Field{type: "relation", key: "projects", options: %{"collection_id" => id, "reverse_of" => _}} = Collection.field(people, "Projects")
    assert id == projects.id

    ada = insert!(people, %{"Name" => "Ada"})
    grace = insert!(people, %{"Name" => "Grace"})
    apollo = insert!(projects, %{"Title" => "Apollo", "Team" => [ada.id, grace.id]})
    _gemini = insert!(projects, %{"Title" => "Gemini", "Team" => [grace.id]})

    assert apollo.data["team"] == [ada.id, grace.id]
    assert Box.get(people, ada.id).data["projects"] == [apollo.id]
    assert length(Box.get(people, grace.id).data["projects"]) == 2

    # Written from the other side, read from this one.
    {:ok, _} = Box.update(people, ada, %{"Projects" => []})
    assert Box.get(projects, apollo.id).data["team"] == [grace.id]
  end

  test "filters on links run in the database, from both sides", %{people: people, projects: projects} do
    ada = insert!(people, %{"Name" => "Ada"})
    grace = insert!(people, %{"Name" => "Grace"})
    insert!(projects, %{"Title" => "Apollo", "Team" => [ada.id, grace.id]})
    insert!(projects, %{"Title" => "Gemini", "Team" => [grace.id]})
    insert!(projects, %{"Title" => "Mercury"})

    assert titles(projects, %{"filter" => %{"field" => "team", "op" => "has_any", "value" => [ada.id]}}) == ["Apollo"]
    assert titles(projects, %{"filter" => %{"field" => "team", "op" => "has_none", "value" => [ada.id]}}) == ["Gemini", "Mercury"]
    assert titles(projects, %{"filter" => %{"field" => "team", "op" => "is_empty"}}) == ["Mercury"]

    {:ok, busy} = Box.list(people, %{"filter" => %{"field" => "projects", "op" => "is_not_empty"}})
    assert busy |> Enum.map(& &1.data["name"]) |> Enum.sort() == ["Ada", "Grace"]

    {:ok, [record | _]} = Box.list(projects, nil)
    assert Box.meets?(projects, %{"filter" => %{"field" => "team", "op" => "has_all", "value" => [ada.id, grace.id]}}, record) == {:ok, true}
  end

  test "records at the other end hear of their changed links", %{people: people, projects: projects} do
    ada = insert!(people, %{"Name" => "Ada"})
    :ok = Box.subscribe(people)

    apollo = insert!(projects, %{"Title" => "Apollo", "Team" => [ada.id]})
    assert_receive {:cardbox, %Event{type: :record_updated, record: %{id: id, data: %{"projects" => [project]}}, changed: ["projects"]}}
    assert {id, project} == {ada.id, apollo.id}

    {:ok, _} = Box.delete(projects, apollo)
    assert_receive {:cardbox, %Event{type: :record_updated, record: %{id: ^id, data: data}}}
    refute Map.has_key?(data, "projects")
  end

  test "deleting a relation deletes its other side and its links", %{people: people, projects: projects} do
    ada = insert!(people, %{"Name" => "Ada"})
    insert!(projects, %{"Title" => "Apollo", "Team" => [ada.id]})
    {:ok, _projects} = Box.delete_field(projects, "Team")

    people = Box.get_collection(people.id)
    assert Collection.field(people, "Projects") == nil
    assert repo().aggregate(Cardbox.Link, :count) == 0
  end

  test "a relation keeps its collection", %{projects: projects, people: people} do
    assert {:error, %Error{message: message}} = Box.update_field(projects, "Team", %{options: %{collection_id: projects.id}})
    assert message =~ "keeps its collection"
    assert {:ok, _} = Box.update_field(projects, "Team", %{options: %{collection_id: people.id, limit: 3}})
  end

  test "a relation that becomes text keeps the linked ids as text", %{people: people, projects: projects} do
    ada = insert!(people, %{"Name" => "Ada"})
    apollo = insert!(projects, %{"Title" => "Apollo", "Team" => [ada.id]})
    {:ok, projects} = Box.update_field(projects, "Team", %{type: "text"})
    assert Box.get(projects, apollo.id).data["team"] == "#{ada.id}"
    assert Collection.field(Box.get_collection(people.id), "Projects") == nil
  end

  defp repo, do: test_repo()
end
