# Queries

A query says which records, in which order: a filter of conditions in
groups of `and` and `or`, sorts, and a search. It is plain maps and
lists, which a saved view keeps, a URL carries and an agent writes:

```elixir
Box.list(tasks, %{
  "filter" => %{
    "and" => [
      %{"field" => "Status", "op" => "in_group", "value" => ["todo", "doing"]},
      %{"or" => [
        %{"field" => "Owner", "op" => "eq", "value" => "me"},
        %{"field" => "Owner", "op" => "is_empty"}
      ]}
    ]
  },
  "sort" => [%{"field" => "Due", "dir" => "asc"}],
  "search" => "invoice"
}, me: current_user, limit: 50)
```

`list/3` gives the records, `count/3` how many there are, `:limit` and
`:offset` page them. Both run in your database, which reads only the
records it returns.

## Conditions

| Operator | Of | Value |
| --- | --- | --- |
| `eq`, `neq` | every type but lists | a value of the field |
| `contains`, `not_contains`, `starts_with`, `ends_with` | texts | a text, without case |
| `gt`, `gte`, `lt`, `lte` | numbers | a number |
| `between` | numbers, dates | `[from, to]`, both included |
| `before`, `after`, `on_or_before`, `on_or_after` | dates | a day |
| `within` | dates | `past_week`, `past_month`, `past_year`, `next_week`, `next_month`, `next_year`, `this_week`, `this_month`, `this_year` |
| `in`, `not_in` | selects, statuses, people | a list |
| `in_group` | statuses | `todo`, `doing`, `done`, or a list of them |
| `has_any`, `has_all`, `has_none` | multi-selects, relations, several people | a list |
| `is_empty`, `is_not_empty` | every type that can be empty | none |

"Is not", "does not contain", "is none of" and "has none of" take the
records with no value too, as a person means them.

### Days said in words

A day is `"2026-10-25"`, or `today`, `tomorrow`, `yesterday`,
`one_week_ago`, `one_week_from_now`, `one_month_ago`,
`one_month_from_now`. They are read when the query runs, so a saved view
of "due within the next week" shows a different week each week. The
days are in `:time_zone` (UTC unless given): on a field of moments, "is
today" is from today's midnight there to the next.

### Me

A person is their id, or `"me"`: whoever runs the query (`:me`). One
shared view of "my tasks" shows each person theirs. With no `:me`,
"is me" matches nothing.

### Choices

A choice is its id or its name; the query keeps its id, so a renamed
choice changes no saved view.

## Sorts

Texts sort without case; selects and statuses in the order of their
choices, as a board shows them; numbers and dates as themselves. Empty
values come last in both directions. After the sorts, records keep the
collection's own order (`move/3`).

## Search

A search finds the records with each of its words in their texts or in
the names of their choices, without case and without accents: "elan"
finds "Élan". It reads each record's search text, which Cardbox writes
with its values, the same way on PostgreSQL and SQLite. On PostgreSQL,
the migration's trigram index (`pg_trgm`) serves it.

## In Elixir

`meets?/4` answers whether a record meets a query without the database:
for a view that gets a change (`Cardbox.Event`) and decides whether to
show it. It answers as the database does: a property test runs random
queries on random records, on both databases, and compares.

## Errors

A query that does not check is an error that says where and what to
write instead, for a person or an agent to correct:

```
the collection has no field "Colour"; its fields are "Title", "Status", "Owner", "Due"
"Points" (number) filters by eq, neq, gt, gte, lt, lte, between, is_empty, is_not_empty, got: "contains"
"Due" takes a day as YYYY-MM-DD or one of today, tomorrow, yesterday, ..., got: "next tuesday"
```

Groups nest four deep, with at most 100 conditions and 10 sorts.
`Cardbox.Query.parse/3` reads a query alone; `to_wire/1` gives it back,
with fields by key and choices by id.
