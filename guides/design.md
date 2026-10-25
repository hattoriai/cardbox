# Design and roadmap

What Cardbox is made of, why, and what comes next.

## A library, not an app

Cardbox owns the shape of the data and its queries; your app owns its
pages. It mounts no screens: its views are components you place
(`Cardbox.Masu.table/1`, `Cardbox.Hakushi.canvas/1`), drawn by the
libraries that draw tables, boards, calendars, charts and canvases.

## Records in your database

A collection's records are rows of one table, `cardbox_records`, their
values a JSON map by field key (`jsonb` on PostgreSQL, JSON text on
SQLite). Fields are rows of `cardbox_fields`: adding one changes no
table, so people and agents add fields as they work. A key never changes
after it is made, so a rename touches no data.

Values are checked in Elixir, by their type, on every write: an empty
value is no key at all, a day is `"YYYY-MM-DD"`, a moment is UTC text
that sorts, a choice is its id. Queries rely on it: each value is read in
SQL only when it is of its field's type.

## One query, two answers

A query is lowered to a few plain conditions, with
days said in words, "me" and the time zone read. The SQL of each
database (`Cardbox.SQL`) and `meets?/4` in Elixir answer the same lowered
conditions; a property test holds them to the same answers, on SQLite
and on PostgreSQL.

## Relations as rows

Links are rows of `cardbox_links` with foreign keys to their field and to
both records: the database keeps them whole, a two-way relation is the
same rows read from the other side, and a filter on links is an `EXISTS`.

## Search as a column

Each record keeps its search text (its texts and choices' names, without
case and accents), written with its values. A search is a `LIKE` on that
column on every database; PostgreSQL adds a trigram index.

## Order as positions

A record's place in its collection is a Narabe position key: moving it
writes that row only, and two people moving at once both land.

## Roadmap

* **More of the views.** Records dragged to another day on the calendar
  (Koyomi's calendar is a picker with marks today; a calendar of events
  is for Koyomi), a gallery, Narabe's list as a component.
* **Editors.** Erabi's pickers in cells and forms (choices you rename and
  recolour in the list, a status's groups), Koyomi's for dates, Kotoba
  for long texts.
* **Collaboration.** An Issho binding: the schema and shared views live
  for everyone, a person's place followed across views, comments on
  records.
* **Formulas and rollups**, computed in the database where they can be.
* **Inboxes.** An address for each collection (Letterbox), each email a
  record.
* **A JSON Schema of a collection**, for agents' tools and APIs.
* **Files** (Storehouse) as a field.
* **MySQL**.
