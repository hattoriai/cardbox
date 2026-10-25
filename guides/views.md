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
| `calendar` | Koyomi (`Cardbox.Koyomi`) | `date_field` |
| `chart` | Fude (`Cardbox.Fude`) | `kind`, `x` (and its `unit`), `y`, `color`, `title` |
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

Each view is drawn by a binding that compiles only when your app has its
library: an app with Masu alone has tables, and nothing of Koyomi, Fude
or Hakushi. A view is data, so an app saves and queries views of any
type, whatever it draws.

## A calendar

```heex
<Cardbox.Koyomi.calendar id="due" view={@view} on_change="day" months={2} />
```

```elixir
def handle_event("koyomi:days", %{"id" => "due"} = params, socket),
  do: Cardbox.Koyomi.handle_days(socket, params, Box, socket.assigns.tasks, socket.assigns.view, me: @user)

def handle_event("day", %{"value" => day}, socket) do
  {:ok, records} = Cardbox.Koyomi.on_day(Box, socket.assigns.tasks, socket.assigns.view, day)
  {:noreply, assign(socket, day_records: records)}
end
```

Each record is on the day of the view's `date_field`, a mark for each,
toned by its status's group (to do, doing, done), and its title on the
day for screen readers and the hover. The calendar asks for the days it
shows, and the database reads only the records of those days, through the
view's query. When records change, `Koyomi.Live.refresh_days/2` asks the
calendar for its days again.

## A chart

```elixir
Box.save_view(projects, %{
  name: "Budget by status",
  type: "chart",
  options: %{kind: "bar", x: "Status", y: %{sum: "Budget"}, color: "Priority"}
})
```

```heex
<Cardbox.Fude.chart id="budget" cardbox={Box} collection={@projects} view={@view} people={@people} />
```

A chart is `bar`, `line`, `area`, `pie`, `donut` or `number`; `x` is the
field of its groups (a date takes a `unit`: `day`, `month` or `year`),
`y` is `count` or the `sum`, `mean`, `min` or `max` of a number field,
and `color` a second field to split by. One `GROUP BY` through the view's
query reads the groups, not the records. Choices keep their order and
their colours, and a currency is formatted in its currency.

`group/3` gives the same groups to your own code: the counts of a board's
columns, a total under a table.

```elixir
{:ok, rows} = Box.group(projects, view, by: [{"Due", :month}, "Status"], value: {:sum, "Budget"})
```

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

## Views of your own

A timeline, a map, a gallery: an app adds types of its own, and draws
them as it likes.

```elixir
defmodule MyApp.Cardbox do
  use Cardbox, repo: MyApp.Repo, views: ["timeline"]

  @impl Cardbox
  def check_view("timeline", options, collection) do
    case Cardbox.Collection.field(collection, options["start"]) do
      %Cardbox.Field{type: "date", key: key} -> {:ok, Map.put(options, "start", key)}
      _ -> {:error, "a timeline starts at a date field"}
    end
  end

  def check_view(_type, options, _collection), do: {:ok, options}
end
```

A view of your type is saved, listed and shared as any; `check_view/3`
checks its options when it is saved (by key, so a rename changes
nothing), and `list/3` of it gives its records, in its order. Your
component draws them.

## When fields change

A field deleted leaves every view: its conditions, its sorts, its place
in the options. A view read after a field changed its type keeps what of
its query still holds (`Cardbox.Query.parse/3` with `lenient: true`).

## Live

Every write broadcasts a `Cardbox.Event` to the collection's topic
(`subscribe/1`). A LiveView passes it to its grid (`Cardbox.Masu.relay/2`)
or reads its records again; `meets?/4` says whether a changed record
belongs in a view without asking the database.
