defmodule Cardbox.Type do
  @moduledoc """
  The types of fields: what each takes, how it keeps a value, and how it
  filters.

  | Type | A value | Options |
  | --- | --- | --- |
  | `text` | a text | `long`: a text of several lines |
  | `number` | an integer or a number | `format`: `number`, `integer`, `percent` or `currency`; `decimals`; `currency` (`"EUR"`) |
  | `checkbox` | `true` or `false` | |
  | `date` | a day, or a moment with `time` | `time`: a day and a time, kept in UTC |
  | `select` | one of the choices | `choices` (`Cardbox.Choice`) |
  | `multi_select` | some of the choices | `choices` |
  | `status` | one of the choices, each of a group (to do, doing, done) | `choices` |
  | `person` | the id of a person or an agent of your app | `multiple`: several |
  | `url`, `email`, `phone` | a text of that form | |
  | `file` | files your app stored: each its `key`, `url`, `name`, `content_type`, `bytes` (and a `preview`) | |
  | `relation` | records of a collection | `collection_id` (required); `limit`: at most so many; `two_way`: the other collection shows the links too, in a field named `reverse_name` (its own name unless given) |
  | `created_at`, `updated_at` | when the record was made, changed | read-only |
  | `created_by`, `updated_by` | who made it, changed it last | read-only |

  ## How values are kept

  A record's values are one JSON map, by field key (`Cardbox.Record`).
  An empty value is no key at all: a text of no characters, an empty
  list and an unticked checkbox are kept as nothing, so "is empty" is one
  question whatever the type. A day is `"2026-10-25"`, a moment
  `"2026-10-25T14:30:00Z"`, both of which sort as text; a choice is its id;
  a relation a list of record ids; a file a list of maps, each where your
  app keeps the file (Cardbox keeps no bytes: store them with Storehouse,
  say, and give the field what it returns).

  The four read-only types are the record's own columns, and are not in
  its values.

  ## Values given

  `cast/3` takes what a form posts, what an agent sends and what Elixir
  code has: `"12.5"` and `12.5` for a number, `"2026-10-25"` and a
  `Date` for a date, a choice's id or its name for a select. Each value
  is checked against its field, and an error says what the field takes.
  """

  alias Cardbox.Choice

  @types ~w(text number checkbox date select multi_select status person url email phone file relation created_at updated_at created_by updated_by)
  @system ~w(created_at updated_at created_by updated_by)
  @formats ~w(number integer percent currency)

  @text_ops ~w(eq neq contains not_contains starts_with ends_with is_empty is_not_empty)a
  @number_ops ~w(eq neq gt gte lt lte between is_empty is_not_empty)a
  @date_ops ~w(eq before after on_or_before on_or_after between within is_empty is_not_empty)a
  @choice_ops ~w(eq neq in not_in is_empty is_not_empty)a
  @list_ops ~w(has_any has_all has_none is_empty is_not_empty)a

  @max_text 100_000
  @max_files 20

  # The kinds of the types whose kind is not in their options.
  @kinds Map.merge(
           Map.new(~w(text url email phone), &{&1, :text}),
           %{
             "number" => :number,
             "checkbox" => :boolean,
             "select" => :choice,
             "status" => :choice,
             "multi_select" => :list,
             "relation" => :list,
             "file" => :list,
             "created_at" => :datetime,
             "updated_at" => :datetime,
             "created_by" => :choice,
             "updated_by" => :choice
           }
         )

  @typedoc "How a type's values compare, in Elixir and in SQL."
  @type kind :: :text | :number | :boolean | :date | :datetime | :choice | :list

  @doc "The types, by name."
  @spec names() :: [String.t()]
  def names, do: @types

  @doc "Whether a type is one of the record's own columns, which nobody writes."
  @spec system?(String.t()) :: boolean()
  def system?(type), do: type in @system

  @doc """
  How a field's values compare: `:text`, `:number`, `:boolean`, `:date`
  (a day), `:datetime`, `:choice` (one id) or `:list` (several).
  """
  @spec kind(map()) :: kind()
  def kind(%{type: "date", options: options}), do: if(options["time"], do: :datetime, else: :date)

  def kind(%{type: "person", options: options}),
    do: if(options["multiple"], do: :list, else: :choice)

  def kind(%{type: type}), do: Map.fetch!(@kinds, type)

  @doc "The filter operators of a field (`Cardbox.Filter`)."
  @spec operators(map()) :: [atom()]
  def operators(%{type: type} = field), do: operators(kind(field), type)

  defp operators(:text, _type), do: @text_ops
  defp operators(:number, _type), do: @number_ops
  defp operators(:boolean, _type), do: [:eq]

  defp operators(kind, type) when kind in [:date, :datetime] and type in @system,
    do: @date_ops -- [:is_empty, :is_not_empty]

  defp operators(kind, _type) when kind in [:date, :datetime], do: @date_ops
  defp operators(:choice, "status"), do: @choice_ops ++ [:in_group]
  defp operators(:choice, _type), do: @choice_ops
  defp operators(:list, "file"), do: [:is_empty, :is_not_empty]
  defp operators(:list, _type), do: @list_ops

  @doc "Whether a field sorts: every field but those of several values."
  @spec sortable?(map()) :: boolean()
  def sortable?(field), do: kind(field) != :list

  @doc """
  Checks a type's options, with `previous`, the field's options before (so a
  choice renamed keeps its id). Returns them as they are kept.
  """
  @spec check_options(String.t(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def check_options(type, options, previous \\ %{})

  def check_options(type, options, previous) when is_map(options) do
    options = Map.new(options, fn {k, v} -> {to_string(k), v} end)

    with :ok <- known_options(type, options) do
      options(type, options, previous)
    end
  end

  def check_options(_type, options, _previous),
    do: {:error, "options are a map, got: #{inspect(options)}"}

  @option_keys %{
    "text" => ~w(long),
    "number" => ~w(format decimals currency),
    "date" => ~w(time),
    "select" => ~w(choices),
    "multi_select" => ~w(choices),
    "status" => ~w(choices),
    "person" => ~w(multiple),
    "relation" => ~w(collection_id limit two_way reverse_name reverse_of)
  }

  defp known_options(type, options) do
    allowed = Map.get(@option_keys, type, [])

    case Map.keys(options) -- allowed do
      [] ->
        :ok

      [key | _] when allowed == [] ->
        {:error, "a #{type} field takes no options, got: #{inspect(key)}"}

      [key | _] ->
        {:error,
         "a #{type} field's options are #{Enum.join(allowed, ", ")}, got: #{inspect(key)}"}
    end
  end

  defp options("text", options, _previous), do: boolean_option(options, "long")

  defp options("number", options, _previous) do
    format = options["format"] || "number"

    with :ok <- format(format),
         :ok <- decimals(options["decimals"]),
         :ok <- currency(format, options["currency"]) do
      {:ok, Map.put(options, "format", format)}
    end
  end

  defp options("date", options, _previous), do: boolean_option(options, "time")

  defp options(type, options, previous) when type in ~w(select multi_select status) do
    status? = type == "status"
    given = options["choices"] || if(status?, do: Choice.default_status(), else: [])

    with {:ok, choices} <- Choice.normalize(given, status?, previous["choices"] || []) do
      {:ok, %{"choices" => choices}}
    end
  end

  defp options("person", options, _previous), do: boolean_option(options, "multiple")

  defp options("relation", options, _previous) do
    case {options["collection_id"], options["limit"]} do
      {id, _limit} when not is_integer(id) ->
        {:error, "a relation names its collection: collection_id, got: #{inspect(id)}"}

      {_id, limit} when not (is_nil(limit) or (is_integer(limit) and limit > 0)) ->
        {:error, "a relation's limit is a positive integer, got: #{inspect(limit)}"}

      _ ->
        boolean_option(options, "two_way")
    end
  end

  defp options(_type, options, _previous), do: {:ok, options}

  defp format(format) when format in @formats, do: :ok

  defp format(format),
    do:
      {:error,
       "a number's format is one of #{Enum.join(@formats, ", ")}, got: #{inspect(format)}"}

  defp decimals(decimals) when is_nil(decimals) or (is_integer(decimals) and decimals in 0..10),
    do: :ok

  defp decimals(decimals),
    do: {:error, "a number's decimals are from 0 to 10, got: #{inspect(decimals)}"}

  defp currency("currency", currency) do
    if is_binary(currency) and currency =~ ~r/^[A-Z]{3}$/,
      do: :ok,
      else:
        {:error,
         "a currency number names its currency in ISO 4217 (\"EUR\"), got: #{inspect(currency)}"}
  end

  defp currency(_format, nil), do: :ok
  defp currency(_format, _currency), do: {:error, "only a currency number has a currency"}

  defp boolean_option(options, key) do
    case options[key] do
      value when is_boolean(value) or is_nil(value) -> {:ok, options}
      value -> {:error, "#{key} is true or false, got: #{inspect(value)}"}
    end
  end

  @doc """
  Checks a value given for a field, and returns it as it is kept: `nil` for
  an empty value.

  `opts`: `:time_zone`, where a day and a time given without an offset are
  (UTC unless given).
  """
  @spec cast(map(), term(), keyword()) :: {:ok, term()} | {:error, String.t()}
  def cast(field, value, opts \\ [])

  def cast(%{type: type}, _value, _opts) when type in @system,
    do: {:error, "is read-only"}

  def cast(_field, nil, _opts), do: {:ok, nil}

  def cast(%{type: type} = field, value, opts) do
    case do_cast(type, field, value, opts) do
      {:ok, value} when value in ["", []] -> {:ok, nil}
      other -> other
    end
  end

  defp do_cast("text", _field, value, _opts) do
    with {:ok, text} <- text(value) do
      if byte_size(text) > @max_text,
        do: {:error, "is at most #{@max_text} bytes"},
        else: {:ok, text}
    end
  end

  defp do_cast("number", %{options: options}, value, _opts) do
    with {:ok, number} <- number(value) do
      if options["format"] == "integer", do: whole(number, value), else: {:ok, number}
    end
  end

  defp do_cast("checkbox", _field, value, _opts) do
    case value do
      v when v in [true, "true", "on", "1", 1] -> {:ok, true}
      v when v in [false, "false", "off", "0", 0, ""] -> {:ok, nil}
      v -> {:error, "is true or false, got: #{inspect(v)}"}
    end
  end

  defp do_cast("date", %{options: options}, value, opts) do
    if options["time"], do: datetime(value, opts), else: date(value)
  end

  defp do_cast(type, %{options: options}, value, _opts) when type in ~w(select status) do
    choice(options["choices"], value)
  end

  defp do_cast("multi_select", %{options: options}, value, _opts) do
    choices = options["choices"]

    with {:ok, values} <- list(value),
         {:ok, ids} <- map_ok(values, &choice(choices, &1)) do
      ids = MapSet.new(ids)
      {:ok, for(%{"id" => id} <- choices, MapSet.member?(ids, id), do: id)}
    end
  end

  defp do_cast("person", %{options: options}, value, _opts) do
    if options["multiple"] do
      with {:ok, values} <- list(value), {:ok, ids} <- map_ok(values, &person/1) do
        {:ok, ids |> Enum.reject(&(&1 == "")) |> Enum.uniq()}
      end
    else
      person(value)
    end
  end

  defp do_cast("url", _field, value, _opts) do
    with {:ok, text} <- text(value) do
      text = String.trim(text)
      uri = URI.parse(text)

      cond do
        text == "" -> {:ok, nil}
        byte_size(text) > 2048 -> {:error, "is at most 2048 bytes"}
        uri.scheme in ~w(http https) and is_binary(uri.host) and uri.host != "" -> {:ok, text}
        uri.scheme == "mailto" -> {:ok, text}
        true -> {:error, "is a link that starts with https://, got: #{inspect(text)}"}
      end
    end
  end

  defp do_cast("email", _field, value, _opts) do
    with {:ok, text} <- text(value) do
      text = String.trim(text)

      cond do
        text == "" -> {:ok, nil}
        byte_size(text) <= 320 and text =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/ -> {:ok, text}
        true -> {:error, "is an email address, got: #{inspect(text)}"}
      end
    end
  end

  defp do_cast("phone", _field, value, _opts) do
    with {:ok, text} <- text(value) do
      text = String.trim(text)

      cond do
        text == "" -> {:ok, nil}
        text =~ ~r/^\+?[0-9][0-9 ()\-.]{1,30}$/ -> {:ok, text}
        true -> {:error, "is a phone number, got: #{inspect(text)}"}
      end
    end
  end

  defp do_cast("relation", %{options: options}, value, _opts) do
    with {:ok, values} <- list(value),
         {:ok, ids} <- map_ok(values, &record_id/1) do
      ids = Enum.uniq(ids)
      limit = options["limit"]

      if limit && length(ids) > limit,
        do: {:error, "links to at most #{limit} #{if limit == 1, do: "record", else: "records"}"},
        else: {:ok, ids}
    end
  end

  defp do_cast("file", _field, value, _opts) do
    with {:ok, values} <- list(value),
         {:ok, files} <- map_ok(values, &file/1) do
      if length(files) > @max_files,
        do: {:error, "holds at most #{@max_files} files"},
        else: {:ok, Enum.uniq_by(files, & &1["key"])}
    end
  end

  defp whole(number, _value) when is_integer(number), do: {:ok, number}
  defp whole(number, _value) when number == trunc(number), do: {:ok, trunc(number)}
  defp whole(_number, value), do: {:error, "is a whole number, got: #{inspect(value)}"}

  defp text(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, "is not valid UTF-8"}
  end

  defp text(value) when is_number(value) or is_atom(value), do: {:ok, to_string(value)}
  defp text(value), do: {:error, "is a text, got: #{inspect(value)}"}

  defp number(value) when is_integer(value), do: {:ok, value}

  defp number(value) when is_float(value), do: {:ok, value}

  defp number(%{__struct__: Decimal} = value) do
    if Decimal.integer?(value),
      do: {:ok, Decimal.to_integer(value)},
      else: {:ok, Decimal.to_float(value)}
  end

  defp number(value) when is_binary(value) do
    text = value |> String.trim() |> String.replace("_", "")

    cond do
      text == "" ->
        {:ok, nil}

      text =~ ~r/^[+-]?\d+$/ ->
        {:ok, String.to_integer(text)}

      match?({_, ""}, Float.parse(text)) and text =~ ~r/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/ ->
        {number, ""} = Float.parse(text)
        {:ok, number}

      true ->
        {:error, "is a number, got: #{inspect(value)}"}
    end
  end

  defp number(value), do: {:error, "is a number, got: #{inspect(value)}"}

  defp date(%Date{} = date), do: {:ok, Date.to_iso8601(date)}
  defp date(%DateTime{} = dt), do: {:ok, dt |> DateTime.to_date() |> Date.to_iso8601()}
  defp date(%NaiveDateTime{} = dt), do: {:ok, dt |> NaiveDateTime.to_date() |> Date.to_iso8601()}
  defp date(""), do: {:ok, nil}

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(String.slice(value, 0, 10)) do
      {:ok, date} when byte_size(value) == 10 -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, "is a day as YYYY-MM-DD, got: #{inspect(value)}"}
    end
  end

  defp date(value), do: {:error, "is a day as YYYY-MM-DD, got: #{inspect(value)}"}

  defp datetime(%DateTime{} = dt, _opts), do: {:ok, utc(dt)}

  defp datetime(%NaiveDateTime{} = dt, opts) do
    case DateTime.from_naive(dt, Keyword.get(opts, :time_zone, "Etc/UTC")) do
      {:ok, dt} -> {:ok, utc(dt)}
      {:ambiguous, dt, _later} -> {:ok, utc(dt)}
      {:gap, _before, dt} -> {:ok, utc(dt)}
      {:error, reason} -> {:error, "is not a moment of the time zone: #{inspect(reason)}"}
    end
  end

  defp datetime(%Date{} = date, opts), do: datetime(NaiveDateTime.new!(date, ~T[00:00:00]), opts)
  defp datetime("", _opts), do: {:ok, nil}

  defp datetime(value, opts) when is_binary(value) do
    with {:error, _} <- DateTime.from_iso8601(value),
         {:error, _} <- NaiveDateTime.from_iso8601(value),
         {:error, _} <- Date.from_iso8601(value) do
      {:error, "is a day and a time as ISO 8601 (2026-10-25T14:30:00Z), got: #{inspect(value)}"}
    else
      {:ok, dt, _offset} -> datetime(dt, opts)
      {:ok, other} -> datetime(other, opts)
    end
  end

  defp datetime(value, _opts),
    do: {:error, "is a day and a time as ISO 8601 (2026-10-25T14:30:00Z), got: #{inspect(value)}"}

  defp utc(dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp choice(_choices, ""), do: {:ok, nil}

  defp choice(choices, value) when is_binary(value) do
    case Choice.find(choices, value) do
      %{"id" => id} ->
        {:ok, id}

      nil ->
        names = Enum.map_join(choices, ", ", &inspect(&1["name"]))
        {:error, "is one of the choices (#{names}), got: #{inspect(value)}"}
    end
  end

  defp choice(choices, value) when is_atom(value) and not is_boolean(value),
    do: choice(choices, Atom.to_string(value))

  defp choice(_choices, value), do: {:error, "is a choice's name or id, got: #{inspect(value)}"}

  defp person(value) when is_binary(value), do: {:ok, String.trim(value)}
  defp person(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp person(%{id: id}), do: person(id)
  defp person(%{"id" => id}), do: person(id)
  defp person(value), do: {:error, "is the id of a person, got: #{inspect(value)}"}

  # A file as your app stored it: where it is and what it is, checked, with
  # nothing kept that a page could not show safely.
  defp file(%{__struct__: _} = file), do: file |> Map.from_struct() |> file()

  defp file(%{} = file) do
    file = Map.new(file, fn {k, v} -> {to_string(k), v} end)
    content_type = file["content_type"] || file["contentType"] || "application/octet-stream"

    with {:ok, key} <- file_text(file["key"], "key", 1024),
         {:ok, url} <- file_url(file["url"], "url"),
         {:ok, name} <- file_name(file["name"]),
         {:ok, content_type} <- content_type(content_type),
         {:ok, bytes} <- file_bytes(file["bytes"]),
         {:ok, preview} <-
           if(file["preview"], do: file_url(file["preview"], "preview"), else: {:ok, nil}) do
      {:ok,
       %{"key" => key, "url" => url, "name" => name, "content_type" => content_type}
       |> put_present("bytes", bytes)
       |> put_present("preview", preview)}
    end
  end

  defp file(value),
    do: {:error, "is a file: a map with its key, url and name, got: #{inspect(value)}"}

  defp file_text(value, what, max) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, "is a file whose #{what} is not empty"}
      byte_size(value) > max -> {:error, "is a file whose #{what} is at most #{max} bytes"}
      not String.valid?(value) -> {:error, "is a file whose #{what} is valid UTF-8"}
      true -> {:ok, value}
    end
  end

  defp file_text(value, what, _max),
    do: {:error, "is a file with its #{what}, a text, got: #{inspect(value)}"}

  # A path of your app ("/uploads/..."), or an address on the web.
  defp file_url(value, what) do
    with {:ok, url} <- file_text(value, what, 2048) do
      uri = URI.parse(url)

      cond do
        String.starts_with?(url, "/") and not String.starts_with?(url, "//") and
            not String.contains?(url, "\\") ->
          {:ok, url}

        uri.scheme in ~w(http https) and is_binary(uri.host) and uri.host != "" ->
          {:ok, url}

        true ->
          {:error,
           "is a file whose #{what} is a path (/...) or starts with https://, got: #{inspect(url)}"}
      end
    end
  end

  defp file_name(value) do
    with {:ok, name} <- file_text(value, "name", 1024) do
      case name |> String.replace(~r/[\p{Cc}\p{Cf}]/u, "") |> String.slice(0, 200) do
        "" -> {:error, "is a file whose name is not empty"}
        name -> {:ok, name}
      end
    end
  end

  defp content_type(value) when is_binary(value) do
    if value =~ ~r"^[a-zA-Z0-9.+-]{1,127}/[a-zA-Z0-9.+-]{1,127}$",
      do: {:ok, String.downcase(value)},
      else:
        {:error,
         "is a file whose content_type is a media type (\"application/pdf\"), got: #{inspect(value)}"}
  end

  defp content_type(value),
    do: {:error, "is a file whose content_type is a media type, got: #{inspect(value)}"}

  defp file_bytes(nil), do: {:ok, nil}
  defp file_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: {:ok, bytes}

  defp file_bytes(bytes),
    do: {:error, "is a file whose bytes are a whole number, got: #{inspect(bytes)}"}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp record_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp record_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "is a list of record ids, got: #{inspect(id)}"}
    end
  end

  defp record_id(%{id: id}), do: record_id(id)
  defp record_id(id), do: {:error, "is a list of record ids, got: #{inspect(id)}"}

  defp list(values) when is_list(values), do: {:ok, values}
  defp list(""), do: {:ok, []}
  defp list(value), do: {:ok, [value]}

  defp map_ok(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc """
  A value as it is kept, read for Elixir: a `Date` or a `DateTime` for a
  date, `false` for an unticked checkbox, `[]` for an empty list.
  """
  @spec load(map(), term()) :: term()
  def load(%{type: "checkbox"}, value), do: value == true

  def load(%{type: "date", options: options}, value) when is_binary(value) do
    if options["time"] do
      {:ok, dt, _offset} = DateTime.from_iso8601(value)
      dt
    else
      Date.from_iso8601!(value)
    end
  end

  def load(field, nil) do
    if kind(field) == :list, do: [], else: nil
  end

  def load(_field, value), do: value

  @doc false
  # A value as plain words or numbers, for a field that changes its type:
  # a choice's name, a day as text, a list as its items.
  @spec plain(map(), term()) :: term()
  def plain(_field, nil), do: nil

  def plain(%{type: type, options: options}, id) when type in ~w(select status) do
    case Choice.find(options["choices"], id) do
      %{"name" => name} -> name
      nil -> nil
    end
  end

  def plain(%{type: "file"}, files), do: Enum.map(files, & &1["name"])

  def plain(%{type: "multi_select", options: options}, ids) do
    for id <- ids, %{"name" => name} <- [Choice.find(options["choices"], id)], do: name
  end

  def plain(_field, value), do: value
end
