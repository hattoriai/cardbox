# Agents

A collection describes itself, so an agent reads and writes it as a
person does, through the same checks.

## The description

```elixir
Cardbox.describe(tasks)
```

```elixir
%{
  "name" => "Tasks",
  "fields" => [
    %{"key" => "title", "name" => "Title", "type" => "text", "operators" => ["eq", "neq", "contains", ...]},
    %{"key" => "status", "name" => "Status", "type" => "status",
      "choices" => [%{"name" => "Not started", "group" => "todo"}, ...],
      "operators" => ["eq", "neq", "in", "not_in", "in_group", "is_empty", "is_not_empty"]},
    %{"key" => "updated", "name" => "Updated", "type" => "updated_at", "read_only" => true, ...}
  ]
}
```

Give it to a model as the description of a tool, with the query format of
[Queries](queries.md).

## Tools

Three tools cover most of what an agent does: one that lists records,
one that adds them, one that changes them.

```elixir
def call("list_records", %{"collection" => id, "query" => query}, scope) do
  collection = Box.get_collection!(id)

  with {:ok, records} <- Box.list(collection, query, me: scope.agent, limit: 50) do
    {:ok, Enum.map(records, &Cardbox.Record.to_map(&1, collection))}
  end
end

def call("update_record", %{"collection" => id, "id" => record, "values" => values}, scope) do
  Box.update(Box.get_collection!(id), record, values, actor: scope.agent)
end
```

An agent names fields and choices as people see them ("Status", "In
progress"); Cardbox reads them as keys and ids. An agent's write is
checked as a person's, against its fields and your `allow?/3`, and each
record keeps the agent as who changed it (`actor_id/1`).

## Errors are instructions

Every error says what to write instead: the fields a collection has, the
operators a field takes, the choices of a select, the form of a day.
Give the error's `message` back to the model, and it corrects itself.

## Changing the schema

`add_field/3`, `update_field/4` and `delete_field/3` are tools too: an
agent that files emails into a collection adds the field it needs. Keep
them behind `allow?/3` (`:change_fields`) for the agents you trust with
them.
