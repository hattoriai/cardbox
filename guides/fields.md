# Fields

A field is a `name`, a `type` and that type's `options`. Its `key` is made
from its name when it is added (`"Due date"` is `due_date`) and never
changes: records keep their values under it, and saved views name fields
by it, so a field renamed is renamed everywhere at once. Every function
takes a field by key or by name.

```elixir
{:ok, tasks} = Box.add_field(tasks, %{name: "Estimate", type: "number", options: %{format: "integer"}})
{:ok, tasks} = Box.update_field(tasks, "Estimate", %{name: "Points"})
{:ok, tasks} = Box.move_field(tasks, "Points", after: "Title")
{:ok, tasks} = Box.delete_field(tasks, "Points")
```

Each returns the collection as it is after, with its fields.

## The types

| Type | A value | Options |
| --- | --- | --- |
| `text` | a text | `long` |
| `number` | an integer or a number | `format`: `number`, `integer`, `percent`, `currency`; `decimals`; `currency` (`"EUR"`) |
| `checkbox` | `true` or `false` | |
| `date` | a day, or a moment | `time`: a day and a time, kept in UTC |
| `select` | one choice | `choices` |
| `multi_select` | some choices | `choices` |
| `status` | one choice, of a group | `choices`, each with a `group`: `todo`, `doing`, `done` |
| `person` | a person's or an agent's id | `multiple` |
| `url`, `email`, `phone` | a text of that form | |
| `relation` | records of a collection | `collection_id`; `limit`; `two_way` and `reverse_name` |
| `created_at`, `updated_at` | when the record was made, changed | read-only |
| `created_by`, `updated_by` | who made it, changed it | read-only |

Options are checked: an option a type does not take, or a value it does
not, is an error that says what the type takes.

## Values

A value goes in as a form posts it, as an agent sends it, or as Elixir
has it: `"12.5"` or `12.5`, `"2026-10-25"` or `~D[2026-10-25]`, a
choice's id or its name, a list of record ids or of their texts. Each is
checked against its field, and every error of a write comes back at once,
each with what its field takes:

```elixir
{:error, %Cardbox.Error{errors: [{"points", "is a number, got: \"many\""}, {"status", "is one of the choices (\"Not started\", \"In progress\", \"Done\"), got: \"Later\""}]}}
```

An empty value is kept as nothing: no text, no list, an unticked box.
`Cardbox.get/3` reads a value for Elixir (a `Date`, `false`, `[]`);
`Cardbox.Record.to_map/2` gives every value by field name, as JSON takes
them.

## Choices

```elixir
Box.update_field(tasks, "Priority", %{options: %{choices: [
  %{name: "Low", color: "gray"},
  %{name: "Urgent", id: "high", color: "red"}
]}})
```

A choice is an `id`, a `name` and a `color`, one of Erabi's nine (`gray`,
`brown`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `red`).
Records keep the id: rename or recolour a choice and every record has it
at once. A choice given with the id or the name of one before keeps its
id; a choice left out is removed from every record that had it.

`Cardbox.Choice.to_options/1` gives the choices as Erabi's pickers take
them.

## A change of type

Change a field's type and its values are converted: each read as words or
numbers and given to the new type. A text that becomes a number keeps
`"3"` as `3` and leaves out `"a lot"`; a multi-select that becomes a text
joins its names; a text that becomes a select gets a choice for each of
its values. A value the new type does not take is left out.

## Relations

```elixir
Box.add_field(projects, %{name: "Client", type: "relation", options: %{collection_id: clients.id, limit: 1, two_way: true}})
Box.add_field(projects, %{name: "Blocked by", type: "relation", options: %{collection_id: projects.id, two_way: true, reverse_name: "Blocks"}})
```

A relation's links are rows of `cardbox_links`, with foreign keys to the
field and to both records: the database keeps them whole, and a link goes
when either record does. A record's value of a relation is a list of ids,
in the order they were given.

A two-way relation gives the other collection a field of the same links,
seen from their targets: a client's "Projects", a project's "Blocks".
Write either side and the other follows. Deleting a relation deletes its
other side.

A relation keeps its collection: to link to another one, add a field.

## Search text

Each record keeps the words of its texts and of its choices' names,
without case and accents, in its `search_text` column, written with its
values. A search looks there (see [Queries](queries.md)).
