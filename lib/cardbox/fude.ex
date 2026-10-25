if Code.ensure_loaded?(Fude.Chart) do
  defmodule Cardbox.Fude do
    @moduledoc """
    A collection as a Fude chart: a view's records grouped and counted, or
    summed, in the database, and drawn by Fude.

        <Cardbox.Fude.chart id="budget" cardbox={MyApp.Cardbox} collection={@collection} view={@view} />

    The view is a saved `Cardbox.View` of type `chart`, whose options say
    what it draws:

      * `kind` - `bar`, `line`, `area`, `pie`, `donut` or `number`;
      * `x` - the field of the groups (not for a `number`): a select, a
        status, a person, a checkbox, a text, a number or a date;
      * `unit` - for a date, `day`, `month` or `year`;
      * `y` - `count` (the default), or `%{"sum" => field}` (or `mean`,
        `min`, `max`) of a number field;
      * `color` - a second field, whose groups are the bars' colours or
        the lines;
      * `title` - the chart's title, the view's name unless given.

        Box.save_view(projects, %{
          name: "Budget by status",
          type: "chart",
          options: %{kind: "bar", x: "Status", y: %{sum: "Budget"}, color: "Priority"}
        })

    One `GROUP BY` through the view's query reads the groups, not the
    records: a chart of fifty thousand records reads a few rows. Choices
    are in their order, as a board shows them, and a currency number is
    formatted in its currency.
    """

    use Phoenix.Component

    @kinds %{"bar" => :bar, "line" => :line, "area" => :area, "pie" => :pie, "donut" => :donut}
    @units %{"day" => :day, "month" => :month, "year" => :year}
    @aggregates %{"sum" => :sum, "mean" => :mean, "min" => :min, "max" => :max}

    # Erabi's nine colors, as a chart draws them on light and dark alike.
    @colors %{
      "gray" => "#8a857c",
      "brown" => "#9a6b4b",
      "orange" => "#e07b2a",
      "yellow" => "#d9a400",
      "green" => "#2e9d5b",
      "blue" => "#3b74d1",
      "purple" => "#7a5cc7",
      "pink" => "#d65a95",
      "red" => "#d4483b"
    }

    alias Cardbox.{Choice, Collection, Field, View}

    attr(:id, :string, required: true)
    attr(:cardbox, :atom, required: true, doc: "your Cardbox module")
    attr(:collection, Collection, required: true)
    attr(:view, View, required: true, doc: "a view of type `chart`")
    attr(:people, :list, default: [], doc: "`%{id, name}`, for a person field's groups")
    attr(:me, :any, default: nil)
    attr(:time_zone, :string, default: nil)
    attr(:rest, :global, include: ~w(height locale table export class))

    @doc "A chart of a view's records."
    def chart(assigns) do
      opts =
        [people: assigns.people, me: assigns.me, time_zone: assigns.time_zone]
        |> Enum.reject(&(elem(&1, 1) in [nil, []]))

      {:ok, chart} = build(assigns.cardbox, assigns.collection, assigns.view, opts)
      assigns = assign(assigns, :fude, chart)

      ~H"""
      <Fude.Components.chart id={@id} chart={@fude} {@rest} />
      """
    end

    @doc """
    The `Fude.Chart` of a chart view, its data read from the database.
    `opts`: `:people` (`%{id, name}`, for a person's groups), and those of
    a query (`:me`, `:time_zone`, `:now`).
    """
    @spec build(module(), Collection.t(), View.t(), keyword()) ::
            {:ok, Fude.Chart.t()} | {:error, Cardbox.Error.t()}
    def build(mod, %Collection{} = collection, %View{options: options} = view, opts \\ []) do
      kind = options["kind"] || "bar"
      unit = @units[options["unit"]]
      x = options["x"] && Collection.field(collection, options["x"])
      color = options["color"] && Collection.field(collection, options["color"])
      {value, y_name, y_format} = value(collection, options["y"])

      by =
        case {kind, x, color} do
          {"number", _, _} -> []
          {_, x, nil} -> [{x.key, unit}]
          {_, x, color} -> [{x.key, unit}, color.key]
        end

      with {:ok, rows} <- mod.group(collection, view, Keyword.merge(opts, by: by, value: value)) do
        people = Map.new(opts[:people] || [], &{to_string(&1.id), &1.name})
        data = Enum.map(rows, &row(&1, x, unit, color, y_name, people))
        {:ok, draw(kind, data, x, unit, color, y_name, y_format, options["title"] || view.name)}
      end
    end

    defp value(collection, y) do
      case y do
        %{} = agg when map_size(agg) == 1 ->
          [{op, ref}] = Map.to_list(agg)
          field = Collection.field(collection, ref)

          name =
            if op == "sum",
              do: field.name,
              else: "#{String.capitalize(op)} #{String.downcase(field.name)}"

          {{@aggregates[op], field.key}, name, format(field)}

        _count ->
          {:count, "Count", :integer}
      end
    end

    defp format(%Field{options: %{"format" => "currency", "currency" => code}}),
      do: {:currency, code}

    defp format(%Field{options: %{"format" => "percent"}}), do: :percent
    defp format(_field), do: :number

    # A group as a row of the chart's data, its values in words: a choice's
    # name, a person's, a month as its first day.
    defp row(%{"groups" => groups, "value" => value}, x, unit, color, y_name, people) do
      fields = Enum.reject([{x, unit}, {color, nil}], &is_nil(elem(&1, 0)))

      fields
      |> Enum.zip(groups)
      |> Map.new(fn {{field, unit}, raw} -> {field.name, label(field, unit, raw, people)} end)
      |> Map.put(y_name, value || 0)
    end

    defp label(field, nil, nil, _people), do: "No #{String.downcase(field.name)}"

    defp label(%Field{type: type} = field, nil, raw, _people) when type in ~w(select status) do
      case Choice.find(Field.choices(field), raw) do
        %{"name" => name} -> name
        nil -> raw
      end
    end

    defp label(%Field{type: "person"}, nil, raw, people), do: Map.get(people, raw, raw)

    defp label(%Field{type: "checkbox"}, nil, raw, _people),
      do: if(raw in [true, 1], do: "Yes", else: "No")

    defp label(_field, :year, raw, _people), do: Date.new!(String.to_integer(raw), 1, 1)
    defp label(_field, :month, raw, _people), do: Date.from_iso8601!(raw <> "-01")
    defp label(_field, :day, raw, _people), do: Date.from_iso8601!(raw)
    defp label(_field, nil, raw, _people), do: raw

    defp draw("number", data, _x, _unit, _color, y_name, y_format, title) do
      Fude.number(data, value: [field: y_name, format: y_format], title: title)
    end

    defp draw(kind, data, x, _unit, _color, y_name, y_format, title) when kind in ~w(pie donut) do
      apply(Fude, @kinds[kind], [
        data,
        [
          color: categories(x, data),
          value: [field: y_name, format: y_format],
          title: title
        ]
      ])
    end

    defp draw(kind, data, x, unit, color, y_name, y_format, title) do
      x_channel =
        if unit, do: [field: x.name, type: :time], else: [field: x.name, sort: order(x, data)]

      channels =
        [x: x_channel, y: [field: y_name, format: y_format], title: title]
        |> then(&if(color, do: Keyword.put(&1, :color, categories(color, data)), else: &1))

      apply(Fude, @kinds[kind], [data, channels])
    end

    # A field's groups as a channel of colors: a choice field's in the
    # order and the colors of its choices, the empty last in gray.
    defp categories(field, data) do
      case order(field, data) do
        :ascending ->
          [field: field.name]

        names ->
          colors = Map.new(Field.choices(field), &{&1["name"], @colors[&1["color"]]})

          [
            field: field.name,
            sort: names,
            scheme: Enum.map(names, &Map.get(colors, &1, @colors["gray"]))
          ]
      end
    end

    # A choice field's groups in the order of its choices, and the records
    # with none last, when the data has them.
    defp order(%Field{} = field, data) do
      none = "No #{String.downcase(field.name)}"

      case Field.choices(field) do
        [] ->
          :ascending

        choices ->
          Enum.map(choices, & &1["name"]) ++
            if(Enum.any?(data, &(&1[field.name] == none)), do: [none], else: [])
      end
    end
  end
end
