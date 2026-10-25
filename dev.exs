# The Cardbox development server: `mix dev`, then http://localhost:4099.
#
# One Phoenix endpoint with a small app ("Atelier", a studio's work, kept in
# collections): Projects, with a field of each kind, and Clients, linked to
# them both ways. Each collection has saved views: a table (Masu), a board
# (Narabe), "My work" (whoever you are), "Due soon" (a range of days read
# when the view opens). Records, fields and views are kept in SQLite, in
# tmp/cardbox_dev.db, made anew each time the server starts.
#
# Query params of every page: `as` - who you are: `ada` (the default),
# `kenji` or `ines`; `view` - a view's id; `dark=1`, or `theme=sumi`.
# Open a page in two windows as two people: each change shows in the other.
#
# Environment:
#
#   * PORT - the HTTP port (4099).

port = "PORT" |> System.get_env("4099") |> String.to_integer()
database = Path.expand("tmp/cardbox_dev.db", __DIR__)

Application.put_env(:phoenix, :json_library, JSON)
Logger.configure(level: :info)

File.mkdir_p!(Path.dirname(database))
for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)

Application.put_env(:cardbox, CardboxDev.Repo, database: database, pool_size: 5, log: false)

Application.put_env(:cardbox, CardboxDev.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  check_origin: false,
  debug_errors: true,
  http: [ip: {127, 0, 0, 1}, port: port],
  live_view: [signing_salt: "cardbox-dev-live-view-salt"],
  pubsub_server: CardboxDev.PubSub,
  render_errors: [formats: [html: CardboxDev.ErrorHTML], layout: false],
  secret_key_base: String.duplicate("cardbox-development-secret-", 3),
  server: true,
  url: [host: "localhost"]
)

defmodule CardboxDev.Repo do
  use Ecto.Repo, otp_app: :cardbox, adapter: Ecto.Adapters.SQLite3
end

defmodule CardboxDev.Cardbox do
  @moduledoc "The app's Cardbox: its repo, its PubSub, and a person by their id."
  use Cardbox, repo: CardboxDev.Repo, pubsub: CardboxDev.PubSub
end

defmodule CardboxDev.People do
  @moduledoc "The people of the studio, who you can be (`?as=`)."

  @people [
    %{id: "ada", name: "Ada Lovelace", short: "Ada", color: "#2e6b5c"},
    %{id: "kenji", name: "Kenji Sato", short: "Kenji", color: "#b4543a"},
    %{id: "ines", name: "Inês Duarte", short: "Inês", color: "#5b5fc7"}
  ]

  def all, do: @people
  def get(id), do: Enum.find(@people, &(&1.id == id)) || hd(@people)
  def initials(%{name: name}), do: name |> String.split() |> Enum.map_join(&String.first/1)
end

defmodule CardboxDev.Seeds do
  @moduledoc "The studio's collections, their records and their views."

  alias CardboxDev.Cardbox, as: Box

  def run do
    today = Date.utc_today()
    day = &Date.to_iso8601(Date.add(today, &1))

    {:ok, clients} =
      Box.create_collection(%{
        name: "Clients",
        icon: "building",
        owner: {"studio", 1},
        fields: [
          %{name: "Name", type: "text"},
          %{name: "Industry", type: "select", options: %{choices: ["Publishing", "Retail", "Hospitality", "Culture"]}},
          %{name: "Contact", type: "email"},
          %{name: "Site", type: "url"}
        ]
      })

    {:ok, projects} =
      Box.create_collection(%{
        name: "Projects",
        icon: "folder",
        description: "Everything the studio is making, for whom, and by when.",
        owner: {"studio", 1},
        fields: [
          %{name: "Title", type: "text"},
          %{
            name: "Status",
            type: "status",
            options: %{
              choices: [
                %{name: "Backlog", color: "gray", group: "todo"},
                %{name: "Next up", color: "yellow", group: "todo"},
                %{name: "In progress", color: "blue", group: "doing"},
                %{name: "In review", color: "purple", group: "doing"},
                %{name: "Done", color: "green", group: "done"}
              ]
            }
          },
          %{name: "Priority", type: "select", options: %{choices: [%{name: "Low", color: "gray"}, %{name: "Medium", color: "orange"}, %{name: "High", color: "red"}]}},
          %{name: "Owner", type: "person"},
          %{name: "Due", type: "date"},
          %{name: "Tags", type: "multi_select", options: %{choices: ["Brand", "Web", "Print", "Type", "Motion"]}},
          %{name: "Budget", type: "number", options: %{format: "currency", currency: "EUR", decimals: 0}},
          %{name: "Client", type: "relation", options: %{collection_id: clients.id, limit: 1, two_way: true}},
          %{name: "Signed off", type: "checkbox"},
          %{name: "Updated", type: "updated_at"}
        ]
      })

    # Projects that wait on others: a relation of the collection to itself,
    # whose other side is "Blocks".
    {:ok, projects} =
      Box.add_field(projects, %{name: "Blocked by", type: "relation", options: %{collection_id: projects.id, two_way: true, reverse_name: "Blocks"}})

    {:ok, [kobo, tsuru, lume, ama, sora]} =
      Box.insert_all(clients, [
        %{"Name" => "Kobo Press", "Industry" => "Publishing", "Contact" => "mika@kobo.example", "Site" => "https://kobo.example"},
        %{"Name" => "Tsuru Hotels", "Industry" => "Hospitality", "Contact" => "desk@tsuru.example"},
        %{"Name" => "Lume Lighting", "Industry" => "Retail", "Contact" => "hello@lume.example", "Site" => "https://lume.example"},
        %{"Name" => "Ama Museum", "Industry" => "Culture", "Contact" => "press@ama.example"},
        %{"Name" => "Sora Tea", "Industry" => "Retail"}
      ])

    rows = [
      {"Kobo autumn catalogue", "In progress", "High", "ada", 3, ~w(Print Type), 18_000, kobo, false},
      {"Tsuru booking site", "In review", "High", "kenji", 9, ~w(Web), 42_000, tsuru, false},
      {"Lume product photography", "Next up", "Medium", "ines", 14, ~w(Brand), 9_500, lume, false},
      {"Ama exhibition identity", "In progress", "High", "ines", 6, ~w(Brand Type Print), 36_000, ama, false},
      {"Sora packaging", "Backlog", "Low", nil, 40, ~w(Print), 12_000, sora, false},
      {"Kobo reading app", "Backlog", "Medium", "kenji", 60, ~w(Web Motion), 55_000, kobo, false},
      {"Tsuru menu cards", "Done", "Low", "ada", -5, ~w(Print), 4_000, tsuru, true},
      {"Lume showroom signage", "In progress", "Medium", "kenji", 1, ~w(Print Brand), 7_200, lume, false},
      {"Ama audio guide", "Next up", "Medium", "ada", 21, ~w(Motion Web), 16_000, ama, false},
      {"Studio typeface, weights", "In review", "Low", "ines", 12, ~w(Type), nil, nil, false},
      {"Sora tea house site", "Done", "Medium", "kenji", -12, ~w(Web), 21_000, sora, true},
      {"Kobo author portraits", "Next up", "Low", "ines", 30, ~w(Brand), 6_000, kobo, false}
    ]

    {:ok, inserted} =
      Box.insert_all(
        projects,
        for {title, status, priority, owner, due, tags, budget, client, done} <- rows do
          %{
            "Title" => title,
            "Status" => status,
            "Priority" => priority,
            "Owner" => owner,
            "Due" => day.(due),
            "Tags" => tags,
            "Budget" => budget,
            "Client" => client && [client.id],
            "Signed off" => done
          }
        end,
        actor: "ada"
      )

    by_title = Map.new(inserted, &{&1.data["title"], &1})

    for {title, blockers} <- [
          {"Kobo reading app", ["Kobo autumn catalogue", "Studio typeface, weights"]},
          {"Ama audio guide", ["Ama exhibition identity"]},
          {"Lume showroom signage", ["Lume product photography"]},
          {"Kobo author portraits", ["Kobo autumn catalogue"]},
          {"Sora packaging", ["Sora tea house site"]},
          {"Tsuru booking site", ["Studio typeface, weights"]}
        ] do
      {:ok, _} = Box.update(projects, by_title[title], %{"Blocked by" => Enum.map(blockers, &by_title[&1].id)}, actor: "ada")
    end

    clients = Box.get_collection!(clients.id)

    for attrs <- [
          %{name: "All projects", type: "table", options: %{columns: ~w(title status priority owner due tags budget client blocked_by signed_off updated), hidden: ~w(blocks), widths: %{"title" => 260}}},
          %{name: "Board", type: "board", options: %{group_by: "status"}},
          %{name: "My work", type: "table", query: %{"filter" => %{"and" => [%{"field" => "owner", "op" => "eq", "value" => "me"}, %{"field" => "status", "op" => "in_group", "value" => ["todo", "doing"]}]}, "sort" => [%{"field" => "due"}]}, options: %{hidden: ~w(owner updated)}},
          %{name: "Dependencies", type: "canvas", options: %{edges: "blocked_by"}},
          %{name: "Due dates", type: "calendar", options: %{date_field: "due"}},
          %{name: "Budget by status", type: "chart", options: %{kind: "bar", x: "status", y: %{sum: "budget"}, color: "priority"}},
          %{name: "Work by month", type: "chart", options: %{kind: "bar", x: "due", unit: "month", color: "status"}},
          %{name: "Due soon", type: "table", query: %{"filter" => %{"and" => [%{"field" => "due", "op" => "within", "value" => "next_month"}, %{"field" => "status", "op" => "in_group", "value" => ["todo", "doing"]}]}, "sort" => [%{"field" => "due"}]}}
        ] do
      {:ok, _} = Box.save_view(projects, attrs)
    end

    {:ok, _} = Box.save_view(clients, %{name: "All clients", type: "table", options: %{widths: %{"name" => 220, "projects" => 420}}})
    :ok
  end
end

defmodule CardboxDev.Layouts do
  @moduledoc """
  The root layout (the style sheets, the import map, the LiveSocket) and
  the app's frame: the side bar of collections, the top bar of views, and
  the panel to be someone else or change the theme.
  """
  use Phoenix.Component

  def root(assigns) do
    params = assigns.conn.params
    assigns = assign(assigns, sumi: params["theme"] == "sumi", dark: params["dark"] == "1")

    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme={if @dark, do: "dark", else: "light"} class={@sumi && "sumi"}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Atelier · Cardbox development</title>
        <link
          rel="icon"
          href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 112 112'%3E%3Cpath fill='%23e84a1c' d='M32 22H59L62 13H80V50H32Z'/%3E%3Cpath fill='%230a0a0b' d='M20 55H92Q96 55 96 59V86Q96 96 86 96H26Q16 96 16 86V59Q16 55 20 55Z'/%3E%3C/svg%3E"
        />
        <link rel="stylesheet" href="/vendor/masu/masu.css" />
        <link rel="stylesheet" href="/vendor/narabe/narabe.css" />
        <link rel="stylesheet" href="/vendor/hakushi/hakushi.css" />
        <link rel="stylesheet" href="/vendor/koyomi/koyomi.css" />
        <link rel="stylesheet" href="/vendor/fude/fude.css" />
        <link :if={@sumi} rel="stylesheet" href="/vendor/masu/masu-sumi.css" />
        <link :if={@sumi} rel="stylesheet" href="/vendor/narabe/narabe-sumi.css" />
        <link :if={@sumi} rel="stylesheet" href="/vendor/hakushi/hakushi-sumi.css" />
        <link :if={@sumi} rel="stylesheet" href="/vendor/koyomi/koyomi-sumi.css" />
        <link :if={@sumi} rel="stylesheet" href="/vendor/fude/fude-sumi.css" />
        <style>
          :root { color-scheme: light; --a-accent: #2e6b5c; --a-bg: #faf9f7; --a-side: #f3f1ed; --a-line: #e7e3dc; --a-ink: #1f1d1a; --a-muted: #79736a; --a-card: #fff; --a-col: #f1efea; }
          [data-theme="dark"] { color-scheme: dark; --a-bg: #17161a; --a-side: #1e1d21; --a-line: #2c2a30; --a-ink: #eceae6; --a-muted: #9c968e; --a-accent: #6fbfa5; --a-card: #222126; --a-col: #1c1b1f; }
          * { box-sizing: border-box; }
          body { margin: 0; background: var(--a-bg); color: var(--a-ink); font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; -webkit-font-smoothing: antialiased; }
          .app { display: grid; grid-template-columns: 15rem 1fr; height: 100vh; }
          .side { display: flex; flex-direction: column; gap: 1.25rem; padding: 1rem 0.75rem; background: var(--a-side); border-right: 1px solid var(--a-line); overflow: auto; }
          .studio { display: flex; align-items: center; gap: 0.5rem; padding: 0.25rem 0.5rem; font-weight: 600; }
          .studio span { display: grid; place-items: center; width: 1.5rem; height: 1.5rem; border-radius: 6px; background: var(--a-ink); color: var(--a-bg); font-size: 0.75rem; }
          .side nav { display: flex; flex-direction: column; gap: 1px; }
          .side nav a { display: flex; align-items: center; gap: 0.625rem; padding: 0.4rem 0.5rem; border-radius: 6px; color: var(--a-muted); font-size: 0.875rem; text-decoration: none; }
          .side nav a small { margin-left: auto; font-size: 0.75rem; }
          .side nav a:hover, .side nav a[aria-current] { background: color-mix(in oklab, var(--a-ink) 6%, transparent); color: var(--a-ink); }
          .side h3 { margin: 0 0 0.25rem; padding: 0 0.5rem; color: var(--a-muted); font-size: 0.6875rem; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; }
          .dev { margin-top: auto; padding: 0.75rem; border: 1px dashed var(--a-line); border-radius: 8px; font-size: 0.75rem; color: var(--a-muted); line-height: 1.7; }
          .dev a { color: inherit; margin-right: 0.375rem; }
          .dev a[aria-current] { color: var(--a-ink); font-weight: 600; text-decoration: none; }
          .main { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
          .top { display: flex; align-items: center; gap: 0.75rem; padding: 0.875rem 1.5rem 0; flex: none; }
          .top h1 { margin: 0; font-size: 1.25rem; font-weight: 600; letter-spacing: -0.01em; }
          .top p { margin: 0; color: var(--a-muted); font-size: 0.8125rem; }
          .tabs { display: flex; gap: 0.25rem; padding: 0.625rem 1.5rem 0; border-bottom: 1px solid var(--a-line); flex: none; }
          .tabs a { display: flex; align-items: center; gap: 0.4rem; padding: 0.4rem 0.625rem 0.55rem; margin-bottom: -1px; border-bottom: 2px solid transparent; color: var(--a-muted); font-size: 0.8125rem; font-weight: 500; text-decoration: none; }
          .tabs a[aria-current] { color: var(--a-ink); border-bottom-color: var(--a-ink); }
          .tabs a svg { width: 0.9rem; height: 0.9rem; }
          .bar { display: flex; flex-wrap: wrap; align-items: center; gap: 0.375rem; padding: 0.625rem 1.5rem; flex: none; font-size: 0.75rem; color: var(--a-muted); }
          .bar .chip { display: inline-flex; align-items: center; gap: 0.3rem; padding: 0.15rem 0.55rem; border: 1px solid var(--a-line); border-radius: 99px; background: var(--a-card); color: var(--a-ink); }
          .bar .chip b { font-weight: 500; color: var(--a-muted); }
          .bar .count { margin-left: auto; }
          .stage { position: relative; flex: 1; min-height: 0; display: flex; flex-direction: column; padding: 0 1.5rem 1.25rem; }
          .stage > .masu { flex: 1; min-height: 0; }
          .people { display: flex; }
          .avatar { display: inline-grid; place-items: center; width: 1.5rem; height: 1.5rem; border-radius: 99px; background: var(--c); color: #fff; font-size: 0.625rem; font-weight: 600; flex: none; }
          .people .avatar { margin-left: -5px; border: 2px solid var(--a-bg); width: 1.75rem; height: 1.75rem; }

          /* Cardbox.Masu's cells: choices in Erabi's nine colors, linked records, people. */
          .cardbox-link { display: inline-flex; align-items: center; margin-right: 0.25rem; padding: 0.05rem 0.45rem; border-radius: 5px; background: color-mix(in oklab, var(--a-ink) 6%, transparent); font-size: 0.75rem; }
          .cardbox-link::before { content: "↗"; margin-right: 0.25rem; color: var(--a-muted); font-size: 0.6875rem; }
          .cardbox-person { display: inline-flex; align-items: center; gap: 0.375rem; font-size: 0.8125rem; }
          .cardbox-person i { display: inline-grid; place-items: center; width: 1.25rem; height: 1.25rem; border-radius: 99px; background: var(--cardbox-person, #8a857c); color: #fff; font-size: 0.5625rem; font-style: normal; font-weight: 600; }
          .cardbox-choice { margin-right: 0.25rem; }
          .cardbox-choice { display: inline-flex; align-items: center; padding: 0.05rem 0.45rem; border-radius: 5px; font-size: 0.6875rem; font-weight: 500; background: var(--bg); color: var(--fg); white-space: nowrap; }
          .cardbox-choice[data-color="gray"] { --bg: #ecebe8; --fg: #54504a; }
          .cardbox-choice[data-color="brown"] { --bg: #efe4dc; --fg: #6b4a33; }
          .cardbox-choice[data-color="orange"] { --bg: #fbe6d4; --fg: #8a4612; }
          .cardbox-choice[data-color="yellow"] { --bg: #f8eec4; --fg: #6e5605; }
          .cardbox-choice[data-color="green"] { --bg: #dcefe1; --fg: #22603a; }
          .cardbox-choice[data-color="blue"] { --bg: #dce9f6; --fg: #1d4f80; }
          .cardbox-choice[data-color="purple"] { --bg: #e8e1f5; --fg: #553b8a; }
          .cardbox-choice[data-color="pink"] { --bg: #f6dfea; --fg: #85335c; }
          .cardbox-choice[data-color="red"] { --bg: #f8dcd8; --fg: #8c2a1e; }

          [data-theme="dark"] .cardbox-choice { background: color-mix(in oklab, var(--fg) 55%, #17161a); color: color-mix(in oklab, var(--bg) 90%, white); }

          /* The canvas: a record's card, the same as on the board. */
          .stage > .hakushi { flex: 1; min-height: 0; border: 1px solid var(--a-line); border-radius: 10px; }
          .cardbox-node { position: relative; width: 15.5rem; }
          .cardbox-node .hakushi-handle { opacity: 0; }
          .hakushi-node:hover .hakushi-handle, .hakushi[data-ui-connecting] .hakushi-handle { opacity: 1; }

          /* The calendar: two months, and the records of the day picked. */
          .calendar-view { display: grid; grid-template-columns: auto 1fr; gap: 1.5rem; align-items: start; overflow: auto; }
          .calendar-view .day { display: flex; flex-direction: column; gap: 0.625rem; max-width: 30rem; }
          .calendar-view .day h2 { margin: 0; font-size: 0.9375rem; font-weight: 600; }
          .calendar-view .day p { margin: 0; color: var(--a-muted); font-size: 0.8125rem; }
          .legend { display: flex; gap: 0.875rem; color: var(--a-muted); font-size: 0.75rem; }
          .legend i { display: inline-block; width: 0.5rem; height: 0.5rem; margin-right: 0.3rem; border-radius: 99px; background: var(--c); }

          /* The chart: on a card of its own. */
          .chart-view { padding: 1.25rem 1.5rem; border: 1px solid var(--a-line); border-radius: 10px; background: var(--a-card); }

          /* The board: a column for each choice of the status. */
          .board-wrap { flex: 1; min-height: 0; overflow: auto; }
          .board-wrap .narabe-board { gap: 0.875rem; align-items: flex-start; }
          .board-wrap .narabe-column { width: 16rem; flex: none; padding: 0.5rem; border-radius: 10px; background: var(--a-col); }
          .colhead { display: flex; align-items: center; gap: 0.5rem; padding: 0.25rem 0.375rem 0.5rem; font-size: 0.8125rem; font-weight: 600; }
          .colhead small { color: var(--a-muted); font-weight: 500; }
          .card { display: flex; flex-direction: column; gap: 0.45rem; padding: 0.625rem 0.75rem; border: 1px solid var(--a-line); border-radius: 8px; background: var(--a-card); box-shadow: 0 1px 2px rgba(20, 18, 14, 0.05); font-size: 0.8125rem; }
          .card strong { font-weight: 600; line-height: 1.3; }
          .card .meta { display: flex; flex-wrap: wrap; align-items: center; gap: 0.3rem; }
          .card .foot { display: flex; align-items: center; justify-content: space-between; color: var(--a-muted); font-size: 0.75rem; }
          .card .late { color: #b4382a; font-weight: 500; }
        </style>
        <script type="importmap">
          {
            "imports": {
              "phoenix": "/vendor/phoenix/phoenix.mjs",
              "phoenix_live_view": "/vendor/phoenix_live_view/phoenix_live_view.esm.js",
              "masu": "/vendor/masu/masu.esm.js",
              "narabe": "/vendor/narabe/narabe.esm.js",
              "hakushi": "/vendor/hakushi/hakushi.esm.js",
              "koyomi": "/vendor/koyomi/koyomi.esm.js",
              "fude": "/vendor/fude/fude.esm.js"
            }
          }
        </script>
        <script type="module">
          import { Socket } from "phoenix"
          import { LiveSocket } from "phoenix_live_view"
          import { Masu } from "masu"
          import { Narabe } from "narabe"
          import { Hakushi } from "hakushi"
          import { Koyomi } from "koyomi"
          import { Fude } from "fude"

          const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
          const liveSocket = new LiveSocket("/live", Socket, { hooks: { Masu, Narabe, Hakushi, Koyomi, Fude }, params: { _csrf_token: csrfToken } })
          liveSocket.connect()
          window.liveSocket = liveSocket
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  attr :collections, :list, required: true
  attr :collection, :map, required: true
  attr :me, :map, required: true
  attr :query, :map, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="app">
      <aside class="side">
        <div class="studio"><span>H</span> Hattori Studio</div>
        <nav>
          <h3>Atelier</h3>
          <.link
            :for={c <- @collections}
            navigate={"/c/#{c.id}" <> qs(@query, %{})}
            aria-current={c.id == @collection.id && "page"}
          >
            {icon(c.icon)} {c.name}
          </.link>
        </nav>
        <div class="dev">
          You are {@me.short}. Be:
          <a
            :for={p <- CardboxDev.People.all()}
            href={"?" <> URI.encode_query(Map.put(@query, "as", p.id))}
            aria-current={@me.id == p.id && "true"}
          >{p.short}</a>
          <br /> Theme:
          <a href={"?" <> URI.encode_query(Map.drop(@query, ["theme", "dark"]))} aria-current={!@query["theme"] && !@query["dark"] && "true"}>Cardbox</a>
          <a href={"?" <> URI.encode_query(@query |> Map.put("theme", "sumi") |> Map.delete("dark"))} aria-current={@query["theme"] == "sumi" && "true"}>Sumi</a>
          <a href={"?" <> URI.encode_query(@query |> Map.put("dark", "1") |> Map.delete("theme"))} aria-current={@query["dark"] == "1" && "true"}>Dark</a>
          <br /> Open this page in another window as Kenji: each change shows in both.
        </div>
      </aside>
      <section class="main">
        {render_slot(@inner_block)}
      </section>
    </div>
    """
  end

  def icon(name) do
    path =
      case name do
        "folder" -> "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"
        "building" -> "M4 21V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v16M16 9h2a2 2 0 0 1 2 2v10M8 7h4M8 11h4M8 15h4M3 21h18"
        "table" -> "M4 5h16v14H4zM4 10h16M10 5v14"
        "board" -> "M4 5h4v14H4zM10 5h4v9h-4zM16 5h4v11h-4z"
        "canvas" -> "M5 6h5v4H5zM14 14h5v4h-5zM10 8h2a2 2 0 0 1 2 2v4"
        "calendar" -> "M4 6h16v14H4zM4 10h16M9 3v4M15 3v4"
        "chart" -> "M5 20V10M12 20V4M19 20v-7"
        _ -> "M4 6h16M4 12h16M4 18h16"
      end

    Phoenix.HTML.raw(~s(<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="#{path}"/></svg>))
  end

  def qs(query, extra) do
    case Map.merge(Map.take(query, ["as", "theme", "dark"]), extra) do
      empty when map_size(empty) == 0 -> ""
      query -> "?" <> URI.encode_query(query)
    end
  end
end

defmodule CardboxDev.Page do
  @moduledoc "What every page mounts with: who you are, and the query."
  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    socket =
      Phoenix.LiveView.attach_hook(socket, :query, :handle_params, fn params, _uri, socket ->
        {:cont, assign(socket, query: Map.drop(params, ["id"]), me: CardboxDev.People.get(params["as"]))}
      end)

    {:cont, assign(socket, query: %{}, me: CardboxDev.People.get(nil))}
  end
end

defmodule CardboxDev.CollectionLive do
  @moduledoc """
  A collection, in the view the URL names: a Masu grid for a table, a
  Narabe board for a board, with the view's filter said in words above it.
  """
  use Phoenix.LiveView

  import CardboxDev.Layouts, only: [app: 1, icon: 1, qs: 2]

  alias Cardbox.{Collection, Field}
  alias CardboxDev.Cardbox, as: Box

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    collection = Box.get_collection!(String.to_integer(id))
    if connected?(socket), do: Box.subscribe(collection)

    {:ok, assign(socket, collection: collection, collections: Box.list_collections({"studio", 1}), views: Box.list_views(collection))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    views = socket.assigns.views
    view = Enum.find(views, &(to_string(&1.id) == params["view"])) || List.first(views)
    {:noreply, socket |> assign(view: view) |> load()}
  end

  defp load(%{assigns: %{view: %{type: "board"} = view, collection: collection, me: me}} = socket) do
    {:ok, records} = Box.list(collection, view, me: me.id)
    assign(socket, records: records, count: length(records))
  end

  defp load(%{assigns: %{view: %{type: "canvas"} = view, collection: collection, me: me}} = socket) do
    {:ok, records} = Box.list(collection, view, me: me.id)
    assign(socket, records: records, count: length(records))
  end

  defp load(%{assigns: %{view: %{type: "calendar"} = view, collection: collection, me: me}} = socket) do
    day = socket.assigns[:day] || Date.utc_today()
    {:ok, records} = Cardbox.Koyomi.on_day(Box, collection, view, day, me: me.id)
    assign(socket, day: day, records: records, count: length(records))
  end

  defp load(%{assigns: %{view: view, collection: collection, me: me}} = socket) do
    {:ok, count} = Box.count(collection, view, me: me.id)
    assign(socket, count: count, records: [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app collections={@collections} collection={@collection} me={@me} query={@query}>
      <header class="top">
        <h1>{@collection.name}</h1>
        <span style="flex: 1"></span>
        <div class="people">
          <span :for={p <- CardboxDev.People.all()} class="avatar" style={"--c: #{p.color}"} title={p.name}>{CardboxDev.People.initials(p)}</span>
        </div>
      </header>
      <p :if={@collection.description} class="top" style="padding-top: 0.25rem; color: var(--a-muted); font-size: 0.8125rem;">{@collection.description}</p>
      <nav class="tabs">
        <.link :for={v <- @views} patch={"/c/#{@collection.id}" <> qs(@query, %{"view" => to_string(v.id)})} aria-current={@view && v.id == @view.id && "page"}>
          {icon(v.type)} {v.name}
        </.link>
      </nav>
      <div class="bar">
        <span :for={chip <- chips(@collection, @view)} class="chip"><b>{chip.field}</b> {chip.words}</span>
        <span :if={chips(@collection, @view) == []}>Every record</span>
        <span class="count">{@count} {if @count == 1, do: "record", else: "records"}</span>
      </div>
      <div class="stage">
        <%= if @view && @view.type == "canvas" do %>
          <Cardbox.Hakushi.canvas cardbox={Box} collection={@collection} view={@view} records={@records} actor={@me.id}>
            <:record :let={record}>
              <.card record={record} collection={@collection} />
            </:record>
          </Cardbox.Hakushi.canvas>
        <% end %>
        <%= if @view && @view.type == "calendar" do %>
          <div class="calendar-view">
            <div>
              <Cardbox.Koyomi.calendar id="calendar" view={@view} on_change="day" months={2} value={@day} />
              <div class="legend">
                <span><i style="--c: var(--koyomi-tone-muted, #a8a29a)"></i>To do</span>
                <span><i style="--c: var(--koyomi-tone-accent, #3b6fd9)"></i>Doing</span>
                <span><i style="--c: var(--koyomi-tone-success, #2e7d55)"></i>Done</span>
              </div>
            </div>
            <div class="day">
              <h2>{Calendar.strftime(@day, "%A, %-d %B")}</h2>
              <p :if={@records == []}>Nothing is due on this day. Pick a day with marks.</p>
              <.card :for={record <- @records} record={record} collection={@collection} />
            </div>
          </div>
        <% end %>
        <%= if @view && @view.type == "chart" do %>
          <div class="chart-view">
            <Cardbox.Fude.chart id={"chart-#{@view.id}"} cardbox={Box} collection={@collection} view={@view} people={CardboxDev.People.all()} me={@me.id} height={380} />
          </div>
        <% end %>
        <%= if @view && @view.type == "board" do %>
          <div class="board-wrap">
            <Cardbox.Narabe.board id="board" collection={@collection} view={@view} records={@records} people={CardboxDev.People.all()} on_move="move">
              <:column :let={column}>
                <div class="colhead">
                  <span class="cardbox-choice" data-color={column.color}>{column.name}</span>
                </div>
              </:column>
              <:card :let={record}>
                <.card record={record} collection={@collection} />
              </:card>
            </Cardbox.Narabe.board>
          </div>
        <% end %>
        <%= if @view && @view.type == "table" do %>
          <Cardbox.Masu.table
            cardbox={Box}
            collection={@collection}
            view={@view}
            actor={@me.id}
            people={CardboxDev.People.all()}
            id={"grid-#{@view.id}"}
            searchable
            height="100%"
          />
        <% end %>
      </div>
    </.app>
    """
  end

  attr :record, :map, required: true
  attr :collection, :map, required: true

  defp card(assigns) do
    c = assigns.collection
    r = assigns.record
    priority = choice(c, "priority", r.data["priority"])
    tags = for id <- r.data["tags"] || [], tag = choice(c, "tags", id), do: tag
    owner = r.data["owner"] && CardboxDev.People.get(r.data["owner"])
    due = r.data["due"] && Date.from_iso8601!(r.data["due"])
    assigns = assign(assigns, priority: priority, tags: tags, owner: owner, due: due, title: r.data["title"])

    ~H"""
    <div class="card">
      <strong>{@title}</strong>
      <div class="meta">
        <span :if={@priority} class="cardbox-choice" data-color={@priority["color"]}>{@priority["name"]}</span>
        <span :for={tag <- @tags} class="cardbox-choice" data-color={tag["color"]}>{tag["name"]}</span>
      </div>
      <div class="foot">
        <span class={@due && Date.compare(@due, Date.utc_today()) == :lt && "late"}>{@due && Calendar.strftime(@due, "%-d %b")}</span>
        <span :if={@owner} class="avatar" style={"--c: #{@owner.color}"} title={@owner.name}>{CardboxDev.People.initials(@owner)}</span>
      </div>
    </div>
    """
  end

  defp choice(collection, key, id), do: Cardbox.Choice.find(Field.choices(Collection.field(collection, key)), id)

  # The view's filter, said in words: a chip for each condition.
  defp chips(_collection, nil), do: []

  defp chips(collection, view) do
    filter = view.query["filter"]
    conditions = if filter, do: filter["and"] || filter["or"] || [filter], else: []

    for %{"field" => key, "op" => op} = condition <- conditions, field = Collection.field(collection, key) do
      %{field: field.name, words: words(field, op, condition["value"])}
    end
  end

  defp words(field, op, value) do
    value = value |> List.wrap() |> Enum.map_join(" or ", &value_words(field, &1))

    case op do
      "eq" -> "is #{value}"
      "in_group" -> "is #{value}"
      "within" -> "within the " <> String.replace(value, "_", " ")
      "has_any" -> "has #{value}"
      other -> "#{String.replace(other, "_", " ")} #{value}"
    end
  end

  defp value_words(_field, "me"), do: "me"
  defp value_words(_field, group) when group in ~w(todo doing done), do: %{"todo" => "to do", "doing" => "doing", "done" => "done"}[group]

  defp value_words(field, value) do
    case Cardbox.Choice.find(Field.choices(field), value) do
      %{"name" => name} -> name
      nil -> to_string(value)
    end
  end

  @impl true
  def handle_event("koyomi:days", %{"id" => "calendar"} = params, socket) do
    %{collection: collection, view: view, me: me} = socket.assigns
    Cardbox.Koyomi.handle_days(socket, params, Box, collection, view, me: me.id)
  end

  def handle_event("day", %{"value" => value}, socket) do
    day = with {:ok, day} <- Date.from_iso8601(value || ""), do: day, else: (_ -> Date.utc_today())
    {:noreply, socket |> assign(day: day) |> load()}
  end

  def handle_event("move", params, socket) do
    %{collection: collection, view: view, me: me} = socket.assigns
    {:reply, reply, socket} = Cardbox.Narabe.handle_move(socket, params, Box, collection, view, actor: me.id)
    {:reply, reply, load(socket)}
  end

  @impl true
  def handle_info({:cardbox, %Cardbox.Event{type: type, view: saved}}, socket) when type in [:view_saved, :view_deleted] do
    views = Box.list_views(socket.assigns.collection)
    view = socket.assigns.view && Enum.find(views, &(&1.id == socket.assigns.view.id))
    view = if saved && view && saved.id == view.id, do: saved, else: view
    {:noreply, socket |> assign(views: views, view: view || List.first(views)) |> load()}
  end

  def handle_info({:cardbox, event}, socket) do
    view = socket.assigns.view
    if view, do: Cardbox.Masu.relay(event, "grid-#{view.id}")
    socket = load(socket)

    # A calendar asks for its days again when records change.
    socket = if view && view.type == "calendar", do: Koyomi.Live.refresh_days(socket, "calendar"), else: socket
    {:noreply, socket}
  end
end

defmodule CardboxDev.HomeController do
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params) do
    [first | _] = CardboxDev.Cardbox.list_collections({"studio", 1}) |> Enum.sort_by(&(&1.name != "Projects"))
    redirect(conn, to: "/c/#{first.id}" <> CardboxDev.Layouts.qs(conn.params, %{}))
  end
end

defmodule CardboxDev.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_query_params)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {CardboxDev.Layouts, :root})
  end

  scope "/" do
    pipe_through(:browser)
    get("/", CardboxDev.HomeController, :index)

    live_session :default, on_mount: [CardboxDev.Page, Masu.Live] do
      live("/c/:id", CardboxDev.CollectionLive)
    end
  end
end

defmodule CardboxDev.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule CardboxDev.Endpoint do
  use Phoenix.Endpoint, otp_app: :cardbox

  @session [store: :cookie, key: "_cardbox_dev", signing_salt: "cardbox-dev"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]])

  plug(Plug.Static, at: "/vendor/phoenix", from: {:phoenix, "priv/static"})
  plug(Plug.Static, at: "/vendor/phoenix_live_view", from: {:phoenix_live_view, "priv/static"})
  plug(Plug.Static, at: "/vendor/masu", from: {:masu, "priv/static"})
  plug(Plug.Static, at: "/vendor/narabe", from: {:narabe, "priv/static"})
  plug(Plug.Static, at: "/vendor/hakushi", from: {:hakushi, "priv/static"})
  plug(Plug.Static, at: "/vendor/koyomi", from: {:koyomi, "priv/static"})
  plug(Plug.Static, at: "/vendor/fude", from: {:fude, "priv/static"})

  plug(Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: JSON)
  plug(Plug.Session, @session)
  plug(CardboxDev.Router)
end

# The script's process ends after this file, so the server runs in a task
# that stays alive; `mix run --no-halt` keeps the VM up.
Task.async(fn ->
  {:ok, _pid} =
    Supervisor.start_link(
      [{Phoenix.PubSub, name: CardboxDev.PubSub}, CardboxDev.Repo],
      strategy: :one_for_one,
      name: CardboxDev.Supervisor
    )

  {_name, source} = Mix.Tasks.Cardbox.Gen.Migration.migration(:cardbox_dev, 0, Cardbox.Migrations.latest_version())
  [{migration, _}] = Code.compile_string(source)
  Ecto.Migrator.up(CardboxDev.Repo, 1, migration, log: false)
  :ok = CardboxDev.Seeds.run()

  {:ok, _pid} = Supervisor.start_child(CardboxDev.Supervisor, CardboxDev.Endpoint)
  IO.puts("Cardbox development server: http://localhost:#{port}")
  Process.sleep(:infinity)
end)
