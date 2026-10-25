defmodule Cardbox.JSONSchema do
  @moduledoc false
  # The JSON Schema of the values a collection's records take
  # (Cardbox.json_schema/1): what insert/3 and update/4 take, by field key,
  # in the forms they keep.

  alias Cardbox.{Collection, Field, Type}

  @dialect "https://json-schema.org/draft/2020-12/schema"

  @spec schema(Collection.t()) :: map()
  def schema(%Collection{} = collection) do
    properties =
      for field <- collection.fields, not Type.system?(field.type), into: %{} do
        {field.key, property(field)}
      end

    %{
      "$schema" => @dialect,
      "title" => collection.name,
      "type" => "object",
      "properties" => properties,
      "additionalProperties" => false
    }
    |> put("description", collection.description)
  end

  # A field's value, or null, which empties it.
  defp property(%Field{} = field) do
    value = field |> value() |> put("description", field.description)
    %{"title" => field.name, "anyOf" => [value, %{"type" => "null"}]}
  end

  defp value(%Field{type: "text"}), do: %{"type" => "string", "maxLength" => 100_000}

  defp value(%Field{type: "number", options: %{"format" => "integer"}}),
    do: %{"type" => "integer"}

  defp value(%Field{type: "number"}), do: %{"type" => "number"}
  defp value(%Field{type: "checkbox"}), do: %{"type" => "boolean"}

  defp value(%Field{type: "date", options: options}) do
    if options["time"],
      do: %{"type" => "string", "format" => "date-time"},
      else: %{"type" => "string", "format" => "date"}
  end

  defp value(%Field{type: type} = field) when type in ~w(select status), do: choice(field)

  defp value(%Field{type: "multi_select"} = field),
    do: %{"type" => "array", "items" => choice(field), "uniqueItems" => true}

  defp value(%Field{type: "person", options: options}) do
    person = %{"type" => "string", "description" => "the id of a person or an agent"}

    if options["multiple"],
      do: %{"type" => "array", "items" => person, "uniqueItems" => true},
      else: person
  end

  defp value(%Field{type: "url"}),
    do: %{"type" => "string", "format" => "uri", "pattern" => "^(https?|mailto):"}

  defp value(%Field{type: "email"}), do: %{"type" => "string", "format" => "email"}

  defp value(%Field{type: "phone"}),
    do: %{"type" => "string", "pattern" => "^\\+?[0-9][0-9 ()\\-.]{1,30}$"}

  defp value(%Field{type: "relation", options: options}) do
    %{
      "type" => "array",
      "items" => %{"type" => "integer", "minimum" => 1},
      "uniqueItems" => true,
      "description" => "the ids of records of the collection #{options["collection_id"]}"
    }
    |> put("maxItems", options["limit"])
  end

  # A choice by its id, each with its name as its title; none for a field
  # with no choices yet.
  defp choice(field) do
    case Field.choices(field) do
      [] ->
        %{"not" => %{}}

      choices ->
        %{
          "type" => "string",
          "oneOf" => for(c <- choices, do: %{"const" => c["id"], "title" => c["name"]})
        }
    end
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
