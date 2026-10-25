if Code.ensure_loaded?(Koyomi.Live) do
  defmodule Cardbox.Koyomi do
    @moduledoc """
    A collection as a Koyomi calendar: each record on the day of the view's
    date field, a mark for each, and the records of the day a person picks.

        <Cardbox.Koyomi.calendar id="due" view={@view} on_change="day" months={2} />

        def handle_event("koyomi:days", %{"id" => "due"} = params, socket),
          do: Cardbox.Koyomi.handle_days(socket, params, MyApp.Cardbox, socket.assigns.collection, socket.assigns.view)

        def handle_event("day", %{"value" => day}, socket) do
          {:ok, records} = Cardbox.Koyomi.on_day(MyApp.Cardbox, socket.assigns.collection, socket.assigns.view, day)
          {:noreply, assign(socket, day_records: records)}
        end

    The view is a saved `Cardbox.View` of type `calendar`: its `date_field`
    names the date field (a day, or a moment), and its query which records.
    The calendar asks for the days it shows a month or a few at a time, and
    the database reads only the records of those days.

    A day's marks are a dot for each record (four at most), toned by the
    group of the record's status when the collection has one: to do muted,
    doing in the accent, done in green. Its title, read by screen readers
    and shown on hover, has the records' titles.

    When records change (`Cardbox.Event`), `Koyomi.Live.refresh_days/2`
    asks the calendar for its days again (Koyomi 0.2.1 and later, which
    Cardbox requires: before it, a refresh emptied the calendar).
    """

    use Phoenix.Component

    alias Cardbox.{Choice, Collection, Field, Record, Type, View}

    @max_records 2000
    @max_marks 4

    attr(:id, :string, required: true)
    attr(:view, View, required: true, doc: "a view of type `calendar`")

    attr(:on_change, :string,
      default: nil,
      doc: "the event of a day picked: `%{\"value\" => \"2026-10-25\"}`"
    )

    attr(:months, :integer, default: 1)
    attr(:label, :string, default: nil)
    attr(:rest, :global, include: ~w(value locale first_day week_numbers holidays class))

    @doc "A calendar of a view's records, on the days of its date field."
    def calendar(assigns) do
      ~H"""
      <Koyomi.Components.calendar
        id={@id}
        label={@label || @view.name}
        select="date"
        on_change={@on_change}
        months={@months}
        days
        typing={false}
        {@rest}
      />
      """
    end

    @doc """
    Answers the calendar's `koyomi:days` event with the days of the view's
    records (`Koyomi.Live.handle_days/4`). `opts` are those of a query
    (`:me`, `:time_zone`, `:now`).
    """
    @spec handle_days(
            Phoenix.LiveView.Socket.t(),
            map(),
            module(),
            Collection.t(),
            View.t(),
            keyword()
          ) ::
            {:reply, map(), Phoenix.LiveView.Socket.t()}
    def handle_days(socket, params, mod, collection, view, opts \\ []) do
      Koyomi.Live.handle_days(socket, params, &days(mod, collection, view, &1, opts))
    end

    @doc """
    The content of the days of a range: for each day with records, their
    marks and their titles, as `Koyomi.Live.handle_days/4` takes them.
    """
    @spec days(module(), Collection.t(), View.t(), Date.Range.t(), keyword()) :: %{
            Date.t() => keyword()
          }
    def days(mod, %Collection{} = collection, %View{} = view, %Date.Range{} = range, opts \\ []) do
      field = date_field!(collection, view)
      status = Enum.find(collection.fields, &(&1.type == "status"))
      title = Collection.title_field(collection)

      mod
      |> records_between(collection, view, field, range.first, range.last, opts)
      |> Enum.group_by(&day(&1, field, opts))
      |> Map.new(fn {day, records} ->
        marks = records |> Enum.take(@max_marks) |> Enum.map(&tone(&1, status))

        titles =
          Enum.map_join(records, "; ", &((title && Map.get(&1.data, title.key)) || "Untitled"))

        {day, [marks: marks, title: titles]}
      end)
    end

    @doc "The records of a view on a day (a `Date` or `\"YYYY-MM-DD\"`), in the view's order."
    @spec on_day(module(), Collection.t(), View.t(), Date.t() | String.t(), keyword()) ::
            {:ok, [Record.t()]} | {:error, Cardbox.Error.t()}
    def on_day(mod, collection, view, day, opts \\ [])

    def on_day(mod, collection, view, day, opts) when is_binary(day),
      do: on_day(mod, collection, view, Date.from_iso8601!(day), opts)

    def on_day(mod, %Collection{} = collection, %View{} = view, %Date{} = day, opts) do
      field = date_field!(collection, view)
      {:ok, records_between(mod, collection, view, field, day, day, opts)}
    end

    # The view's records whose date is in the days, read with the view's
    # query and a condition on the date field.
    defp records_between(mod, collection, view, field, from, to, opts) do
      between = %{
        "field" => field.key,
        "op" => "between",
        "value" => [Date.to_iso8601(from), Date.to_iso8601(to)]
      }

      filter = Enum.reject([view.query["filter"], between], &is_nil/1)
      query = Map.put(view.query, "filter", %{"and" => filter})

      case mod.list(collection, query, Keyword.put(opts, :limit, @max_records)) do
        {:ok, records} -> records
        {:error, _error} -> []
      end
    end

    defp date_field!(collection, %View{options: options, name: name}) do
      case Collection.field(collection, options["date_field"]) do
        %Field{} = field ->
          if Type.kind(field) in [:date, :datetime],
            do: field,
            else: raise(ArgumentError, "the view #{inspect(name)} has no date field")

        nil ->
          raise ArgumentError, "the view #{inspect(name)} names no date field (date_field)"
      end
    end

    # The day of a record's date, in the time zone of the query.
    defp day(record, field, opts) do
      case Record.value(record, field) do
        %Date{} = date ->
          date

        %DateTime{} = dt ->
          dt
          |> DateTime.shift_zone!(Keyword.get(opts, :time_zone, "Etc/UTC"))
          |> DateTime.to_date()
      end
    end

    defp tone(_record, nil), do: :accent

    defp tone(record, status) do
      case Choice.find(Field.choices(status), Map.get(record.data, status.key)) do
        %{"group" => "done"} -> :success
        %{"group" => "doing"} -> :accent
        _todo_or_none -> :muted
      end
    end
  end
end
