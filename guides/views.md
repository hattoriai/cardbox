# Views

A view is how people look at a collection: its `type`, its `query`
(which records, in which order) and the options of its type.

```elixir
{:ok, view} =
  Box.save_view(tasks, %{
    name: "My open tasks",
    type: "table",
    query: %{"filter" => %{"field" => "Owner", "op" => "eq", "value" => "me"}},
    options: %{columns: ["Title", "Status", "Due"], widths: %{"Title" => 320}}
  })

{:ok, records} = Box.list(tasks, view, me: current_user)
```

`list_views/2` gives the shared views and, with `owner:`, someone's own.
A view's query and options are checked when it is saved, and kept with
fields by key and choices by id.

## The types

| Type | Drawn by | Options |
| --- | --- | --- |
| `table` | Masu (`Cardbox.Masu`) | `columns` (in order), `hidden`, `widths` |
| `board` | Narabe | `group_by` (a select, a status, a person or a checkbox), `hidden_groups`, `card_fields` |
| `list` | Narabe | `fields` |
| `calendar` | Koyomi | `date_field` |
| `chart` | Fude | `spec`, a `Fude.Spec` map |
| `canvas` | Hakushi (`Cardbox.Hakushi`) | `edges` (a relation of the collection to itself), `layout` |

## A table

```heex
<Cardbox.Masu.table cardbox={Box} collection={@tasks} view={@view} actor={@user} people={@people} searchable />
```

The grid's query is the view's, which the person's own sorts and filters
narrow. Choices show as chips in their colours, people by name, relations
by the titles of the records they link to (the first text field of their
collection). A cell edits as its field takes values; a write goes through
your module, with `expect:` the value the person saw, so a value someone
changed meanwhile is not overwritten.

## A canvas

```heex
<Cardbox.Hakushi.canvas cardbox={Box} collection={@tasks} view={@view} records={@records} actor={@user}>
  <:record :let={record}>{record.data["title"]}</:record>
</Cardbox.Hakushi.canvas>
```

Each record is a node, and the links of the view's `edges` relation are
edges: from the record linked to the record that links, so a "Blocked
by" canvas points from what blocks to what waits. Drawing an edge links
two records; deleting one unlinks them; moving a node keeps its place in
the view's `layout`, for everyone. With no places yet, the canvas lays
the records out along their links as it opens.

## When fields change

A field deleted leaves every view: its conditions, its sorts, its place
in the options. A view read after a field changed its type keeps what of
its query still holds (`Cardbox.Query.parse/3` with `lenient: true`).

## Live

Every write broadcasts a `Cardbox.Event` to the collection's topic
(`subscribe/1`). A LiveView passes it to its grid (`Cardbox.Masu.relay/2`)
or reads its records again; `meets?/4` says whether a changed record
belongs in a view without asking the database.
