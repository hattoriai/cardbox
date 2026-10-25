defmodule Cardbox.JSONSchemaTest do
  use CardboxTest.DataCase

  setup do
    c = tasks!([%{name: "Notes", type: "text", description: "Anything else"}])

    {:ok, c} =
      Box.add_field(c, %{
        name: "Parent",
        type: "relation",
        options: %{collection_id: c.id, limit: 1}
      })

    {:ok, c} = Box.add_field(c, %{name: "Created", type: "created_at"})
    {:ok, c} = Box.add_field(c, %{name: "Reviewers", type: "person", options: %{multiple: true}})
    %{collection: c}
  end

  test "a property for each field but the read-only ones", %{collection: c} do
    schema = Cardbox.json_schema(c)

    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["title"] == "Tasks"
    assert schema["additionalProperties"] == false
    refute Map.has_key?(schema["properties"], "created")

    assert Enum.sort(Map.keys(schema["properties"])) ==
             Enum.sort(
               ~w(title status priority tags points done due owner link notes parent reviewers)
             )

    assert %{"title" => "Status", "anyOf" => [status, %{"type" => "null"}]} =
             schema["properties"]["status"]

    assert %{"const" => "in_progress", "title" => "In progress"} in status["oneOf"]

    assert value(schema, "tags")["type"] == "array"
    assert value(schema, "due") == %{"type" => "string", "format" => "date"}
    assert value(schema, "notes")["description"] == "Anything else"
    assert value(schema, "parent")["maxItems"] == 1
    assert value(schema, "reviewers")["items"]["type"] == "string"
    assert JSON.decode!(JSON.encode!(schema)) == schema
  end

  test "the values of records, as kept, are valid", %{collection: c} do
    schema = Cardbox.json_schema(c)
    a = insert!(c, %{"Title" => "Design", "Status" => "Done"})

    b =
      insert!(c, %{
        "Title" => "Build",
        "Status" => "In progress",
        "Priority" => "High",
        "Tags" => ["UI", "Bug"],
        "Points" => "3.5",
        "Done" => true,
        "Due" => ~D[2026-10-25],
        "Owner" => "ada",
        "Link" => "https://example.com/build",
        "Parent" => [a.id],
        "Reviewers" => ["ada", "grace"]
      })

    for record <- [a, b] do
      assert valid?(schema, record.data), inspect(record.data)
    end

    refute valid?(schema, %{"status" => "Done"})
    refute valid?(schema, %{"parent" => [a.id, b.id]})
    refute valid?(schema, %{"unknown" => 1})
    assert valid?(schema, %{"status" => nil})
  end

  defp value(schema, key), do: hd(schema["properties"][key]["anyOf"])

  # A check of the parts of JSON Schema the schema has.
  defp valid?(%{"type" => "object"} = schema, data) do
    Enum.all?(data, fn {key, value} ->
      case schema["properties"][key] do
        nil -> schema["additionalProperties"] != false
        property -> valid?(property, value)
      end
    end)
  end

  defp valid?(%{"anyOf" => schemas}, value), do: Enum.any?(schemas, &valid?(&1, value))

  defp valid?(%{"not" => %{}}, _value), do: false

  defp valid?(%{"type" => type} = schema, value) do
    type?(type, value) and
      Enum.all?(schema, fn
        {"oneOf", options} -> Enum.count(options, &(&1["const"] == value)) == 1
        {"items", items} -> Enum.all?(value, &valid?(items, &1))
        {"uniqueItems", true} -> Enum.uniq(value) == value
        {"maxItems", max} -> length(value) <= max
        {"minimum", min} -> value >= min
        {"maxLength", max} -> String.length(value) <= max
        {"pattern", pattern} -> value =~ Regex.compile!(pattern)
        _other -> true
      end)
  end

  defp type?("null", value), do: is_nil(value)
  defp type?("string", value), do: is_binary(value)
  defp type?("integer", value), do: is_integer(value)
  defp type?("number", value), do: is_number(value)
  defp type?("boolean", value), do: is_boolean(value)
  defp type?("array", value), do: is_list(value)
end
