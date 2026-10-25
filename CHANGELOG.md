# Changelog

All notable changes to Cardbox are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Cardbox follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-25

### Added

- Collections (`use Cardbox`): records of one kind in your database, on
  PostgreSQL or SQLite, with an owner of your app's (`{type, id}`), made
  by `mix cardbox.gen.migration`'s tables.
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
- `Cardbox.Hakushi`: a collection as a Hakushi canvas, its edges a
  relation's links, its places kept in the view.
- `Cardbox.describe/1`: a collection as an agent reads it.
- The development app (`mix dev`).
