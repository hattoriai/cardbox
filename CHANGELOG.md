# Changelog

All notable changes to Cardbox are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Cardbox follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-26

Field types of your app's own, a file field, and records that follow an
update.

### Added

- Field types of your app's own (`Cardbox.FieldType`, `config :cardbox,
  types: [...]`): a name and a cast, and if it likes a kind (how it
  filters and sorts), options checked with the collection, words for a
  table and a board, a JSON Schema and search words. A type named as one
  of Cardbox's is refused.
- `c:Cardbox.after_update/4`: after an update that changed a record, in
  its transaction, the records to insert with it, or an error that undoes
  the update. They are inserted by the update's actor and broadcast as
  `:record_inserted`.
- A `file` field: files your app stored (Storehouse's, say), each kept as
  where it is and what it is (`key`, `url`, `name`, `content_type`,
  `bytes`, `preview`), at most 20 to a value. Its `url` and `preview` are a
  path of your app or an `https://` address, its name loses control and
  direction characters. It filters by being empty or not, its files'
  names are in the search text, `Cardbox.Record.to_map/2` gives each file
  whole, a table shows each as a link (`a.cardbox-file`), and a board
  card by name.

### Fixed

- `Cardbox.Masu`: a grid's `"me"` is its actor by `c:Cardbox.actor_id/1`,
  as everywhere else. An actor such as a scope struct no longer crashes
  the grid when its view filters on `"me"`.

## [0.1.0] - 2026-10-25

### Added

- Collections (`use Cardbox`): records of one kind in your database, on
  PostgreSQL or SQLite, with an owner of your app's (`{type, id}`).
- Versioned tables (`Cardbox.Migrations`): your migration pins a version
  (`up(version: 1)`, `down(to: 0)`), the version a database is at is kept
  in `cardbox_schema`, and `mix cardbox.gen.migration` writes the
  migration from the version your migrations pin to the latest.
  `check/1` says whether a database is at the latest.
- `mix cardbox.install`: your module of Cardbox's and the migration, with
  Igniter (`mix igniter.install cardbox`) or without.
- Fields of fourteen types: text, number (and its format), checkbox, date
  (and a time), select, multi-select, status (choices in groups), person,
  URL, email, phone, relation, and who made and changed each record and
  when. Keys made once from names, so a rename changes no data; choices
  kept by id, in Erabi's nine colours; a change of type converts the
  values; a choice removed leaves the records that had it.
- Relations as rows of `cardbox_links`, kept whole by the database, with
  two-way relations whose other side reads the same links.
- One write path: values checked against their fields, every error at
  once with what the field takes, `allow?/3`, a compare-and-swap of the
  values a writer saw (`expect:`), the collection's order (Narabe's
  positions), who changed what, and an event to the collection's topic
  (`Cardbox.Event`) and to telemetry.
- Queries: conditions in groups of `and` and `or`, days said in words read
  when the query runs, "me", status groups, sorts with empty values last,
  and a search without case or accents in a search text column, on every
  database; the same answers in Elixir (`meets?/4`).
- Saved views of six types (table, board, list, calendar, chart, canvas),
  shared or someone's own, kept in step when a field is deleted.
- `Cardbox.Masu`: a collection as a Masu grid, sorted, filtered and
  searched in the database, edited through Cardbox, with chips for
  choices, people by name and relations by title.
- `Cardbox.Narabe`: a collection as a Narabe board, a column for each
  choice, person or tick of the view's field; a card moved to another
  column takes its value, and its place.
- `Cardbox.Hakushi`: a collection as a Hakushi canvas, its edges a
  relation's links, its places kept in the view.
- `Cardbox.Koyomi`: a collection as a Koyomi calendar, each record on the
  day of the view's date field, toned by its status's group, the days read
  a month or a few at a time.
- `Cardbox.Fude`: a collection as a Fude chart (bar, line, area, pie,
  donut, a number), grouped and aggregated in the database through the
  view's query, choices in their order and colours.
- `group/3`: records grouped by fields (dates by day, month or year) and
  counted or aggregated in the database, on PostgreSQL and SQLite.
- Views of an app's own types (`use Cardbox, views: [...]`), their options
  checked by `c:Cardbox.check_view/3`.
- `Cardbox.describe/1`: a collection as an agent reads it, and
  `Cardbox.json_schema/1`: the values of its records as a JSON Schema.
- The development app (`mix dev`).
