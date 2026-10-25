# Quickstart

From nothing to a collection people edit in a table and on a board, with
every change live in every window. About fifteen minutes.

## Install

Add Cardbox and the libraries of the views you show to `mix.exs`:

```elixir
{:cardbox, "~> 0.1"},
{:masu, "~> 0.7"},    # tables
{:hakushi, "~> 0.6"}, # canvases, if you show them
```

Narabe (boards and the order of records) comes with Cardbox. Add each
view's hook and style sheet as its README says (`import { Masu } from "masu"`,
`import { Narabe } from "narabe"`).

Write the migration of Cardbox's tables, and run it:

```sh
mix deps.get
mix cardbox.gen.migration
mix ecto.migrate
```

It makes five tables, the same on PostgreSQL and SQLite:
`cardbox_collections`, `cardbox_fields`, `cardbox_records`,
`cardbox_links` (the links of relations) and `cardbox_views`.

## Your module

```elixir
defmodule MyApp.Cardbox do
  use Cardbox, repo: MyApp.Repo, pubsub: MyApp.PubSub

  @impl Cardbox
  def actor_id(%MyApp.Accounts.User{id: id}), do: "user:#{id}"

  # Who may change what. Reads are yours to scope, as your app scopes
  # its own records.
  @impl Cardbox
  def allow?(%MyApp.Accounts.User{role: :viewer}, action, _collection) when action != :create_collection, do: false
  def allow?(_user, _action, _subject), do: true
end
```

Each record keeps who made it and who changed it last, as
`actor_id/1` gives them; each event says who made the change.

## A collection

```elixir
{:ok, tasks} =
  MyApp.Cardbox.create_collection(%{
    name: "Tasks",
    owner: {"team", team.id},
    fields: [
      %{name: "Title", type: "text"},
      %{name: "Status", type: "status"},
      %{name: "Owner", type: "person"},
      %{name: "Due", type: "date"}
    ]
  })

{:ok, _} =
  MyApp.Cardbox.save_view(tasks, %{name: "Board", type: "board", options: %{group_by: "Status"}})
```

A status starts with three choices, in three groups: Not started (to do),
In progress (doing) and Done (done). Change them as any choices
(`update_field/4`, see [Fields](fields.md)).

## A LiveView

```elixir
defmodule MyAppWeb.TasksLive do
  use MyAppWeb, :live_view

  alias MyApp.Cardbox, as: Box

  def mount(%{"id" => id}, _session, socket) do
    tasks = Box.get_collection!(id)
    if connected?(socket), do: Box.subscribe(tasks)
    {:ok, assign(socket, tasks: tasks, view: hd(Box.list_views(tasks)))}
  end

  def render(assigns) do
    ~H"""
    <Cardbox.Masu.table
      cardbox={Box}
      collection={@tasks}
      view={@view}
      actor={@current_scope.user}
      people={@people}
      searchable
      height="40rem"
    />
    """
  end

  # Other people's changes, in this grid.
  def handle_info({:cardbox, event}, socket) do
    Cardbox.Masu.relay(event, "cardbox-#{socket.assigns.tasks.id}")
    {:noreply, socket}
  end
end
```

Add `Masu.Live` to the `on_mount` of the LiveView's `live_session`, for
the grid's live rows.

The grid sorts, filters and searches in your database, inside the view's
own query. A person edits a cell, pastes from a spreadsheet, adds and
deletes rows: each write goes through `Box.update/4` (or `insert/3`,
`delete/3`), with its checks, `allow?/3`, a compare of the value the
person saw, and an event.

## A board

A board is Narabe's, with a column for each choice of the view's
`group_by`:

```heex
<.board id="board" columns={@columns} cards={@records} card_column={&(&1.data["status"] || "none")} on_move="move">
  <:card :let={record}>{record.data["title"]}</:card>
</.board>
```

```elixir
def handle_event("move", params, socket) do
  {:ok, move} = Narabe.Move.parse(params, :string)
  [id] = Enum.map(move.ids, &String.to_integer/1)
  place = if move.after, do: [after: String.to_integer(move.after)], else: [to: :last]

  result =
    with {:ok, _} <- Box.update(socket.assigns.tasks, id, %{"status" => move.parent}, actor: user),
         {:ok, _} <- Box.move(socket.assigns.tasks, id, [{:actor, user} | place]),
         do: :ok

  {:reply, Narabe.Live.reply(result), load(socket)}
end
```

The development app (`mix dev`, `dev.exs`) has the whole of it: a table,
a board, a canvas, and live updates between windows.

## Next

* [Fields](fields.md): every type, its options, and what a change of type does.
* [Queries](queries.md): filters, sorts, search, and days said in words.
* [Views](views.md): the six types and their options.
* [Agents](agents.md): a collection described to a model, and its tools.
