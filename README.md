# Cardbox

![Cardbox — Collections for Phoenix](https://raw.githubusercontent.com/hattoriai/cardbox/main/media/banner.png)

**Collections for Phoenix: records of one kind, with fields your users
define, seen as a table, a board, a calendar, a chart or a canvas.**

A reading list, a CRM's contacts with the fields each customer adds, a
studio's projects, an issue log, recipes. Your users make a collection,
give it fields (a status, a due date, an owner, links to another
collection) and see the same records in the views they save. Your agents
read and write the same records, with the same checks.

Cardbox keeps all of it in your own database, PostgreSQL or SQLite, and
gives the views to the libraries that draw them: Masu's table, Narabe's
board, Koyomi's calendar, Fude's charts and Hakushi's canvas.

![Projects in a Masu table: a status and a priority as chips in their colours, an owner by name, tags, a budget and the client each links to](https://raw.githubusercontent.com/hattoriai/cardbox/main/media/table.png)

> Early release. Before 1.0, a minor version may change the API.

## Install

You need Elixir 1.18+, Ecto 3.13 on PostgreSQL or SQLite, and Phoenix
1.7.14 or 1.8.

Add `{:cardbox, "~> 0.1"}` to the deps in `mix.exs`, and the libraries of
the views you show (`{:masu, "~> 0.7"}` for tables). Then write the
migration of Cardbox's tables, and run it:

```sh
mix deps.get
mix cardbox.gen.migration
mix ecto.migrate
```

## Your first collection

Your app has a module of Cardbox's:

```elixir
defmodule MyApp.Cardbox do
  use Cardbox, repo: MyApp.Repo, pubsub: MyApp.PubSub
end
```

Make a collection, with its fields:

```elixir
{:ok, books} =
  MyApp.Cardbox.create_collection(%{
    name: "Reading list",
    owner: {"workspace", workspace.id},
    fields: [
      %{name: "Title", type: "text"},
      %{name: "Status", type: "status"},
      %{name: "Rating", type: "number", options: %{format: "integer"}},
      %{name: "Finished", type: "date"}
    ]
  })
```

Add records. Values go in by field name or key, as a form or an agent
gives them, and each is checked against its field:

```elixir
{:ok, dune} = MyApp.Cardbox.insert(books, %{"Title" => "Dune", "Status" => "In progress"}, actor: user)

{:error, %Cardbox.Error{message: "Rating is a number, got: \"lots\""}} =
  MyApp.Cardbox.update(books, dune, %{"Rating" => "lots"})
```

Ask for them. The database filters, sorts and searches:

```elixir
{:ok, reading} =
  MyApp.Cardbox.list(books, %{
    "filter" => %{"field" => "status", "op" => "in_group", "value" => "doing"},
    "sort" => [%{"field" => "title"}]
  })
```

Save a view, and show it:

```elixir
{:ok, view} =
  MyApp.Cardbox.save_view(books, %{
    name: "Finished this month",
    query: %{"filter" => %{"field" => "finished", "op" => "within", "value" => "this_month"}}
  })
```

```heex
<Cardbox.Masu.table cardbox={MyApp.Cardbox} collection={@books} view={@view} actor={@user} searchable />
```

The [Quickstart](guides/quickstart.md) continues from here, with a full
LiveView, live updates and a board.

## What you get

* **Fields people define.** Text, numbers, checkboxes, dates (with a time,
  in UTC), selects and multi-selects with coloured choices, statuses in
  groups, people, links, emails, phones, relations between collections
  (two-way, if you like), and who made and changed each record and when.
  Rename a field or a choice and nothing else changes; change a field's
  type and its values are converted. → [Fields](guides/fields.md)
* **Queries that run in your database.** Conditions in groups of `and` and
  `or`, sorts, and search, on PostgreSQL and SQLite alike. Days said in
  words ("within the next week") and "me" are read when the query runs,
  so one saved view shows each person their week. → [Queries](guides/queries.md)
* **Saved views.** A table, a board, a list, a calendar, a chart or a
  canvas, each with its query and its options, shared or someone's own.
  A view whose field was deleted still opens. → [Views](guides/views.md)
* **One way in.** A form, a grid, a board, an import, an email, an agent:
  every write goes through the same checks, your `allow?/3`, a
  compare-and-swap for values someone changed meanwhile, and an event
  that every open view receives.
* **Built for agents.** `Cardbox.describe/1` gives a model each field, its
  choices and the filters it takes, and every error says what to write
  instead. → [Agents](guides/agents.md)
* **Tested both ways.** The database and Elixir answer every query the
  same: a property test runs random queries on random records and compares.

## Try the demo

```sh
mix deps.get
mix dev
```

Open http://localhost:4099. The demo is a studio's work in two
collections, Projects and Clients, linked both ways, with saved views: a
table, a board, "My work" and "Due soon". Open a second window as Kenji
(the panel at the bottom left): a card moved on one board moves in every
window.

![The projects on a Narabe board: a column for each status, cards with their priority, tags, due date and owner](https://raw.githubusercontent.com/hattoriai/cardbox/main/media/board.png)

![The projects on a Hakushi canvas: each blocked project to the right of what blocks it, joined by arrows, laid out along the links](https://raw.githubusercontent.com/hattoriai/cardbox/main/media/canvas.png)

## Guides

[Quickstart](guides/quickstart.md) ·
[Fields](guides/fields.md) ·
[Queries](guides/queries.md) ·
[Views](guides/views.md) ·
[Agents](guides/agents.md) ·
[Design and roadmap](guides/design.md)

## Development

```sh
mix deps.get
mix dev          # the development app at http://localhost:4099
mix test         # the tests, on SQLite
DATABASE_URL=postgres://postgres:postgres@localhost/cardbox_test mix test
mix precommit    # compile, format, credo --strict and test
```

## License

MIT. See `LICENSE`.
