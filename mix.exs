defmodule Cardbox.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hattoriai/cardbox"

  def project do
    [
      app: :cardbox,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/project.plt"}
      ],
      package: package(),
      docs: docs(),
      description: description(),
      name: "Cardbox",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # The collections, their fields, records, links and views: rows of
      # five tables in the app's database, on PostgreSQL or SQLite. The tests run
      # on SQLite, and on PostgreSQL with DATABASE_URL.
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.22", only: [:dev, :test]},
      {:postgrex, "~> 0.19", only: :test},
      # The order of records and fields: Narabe's position keys, the same
      # its boards and lists move.
      {:narabe, "~> 0.1"},
      # Each change broadcast to the collection's topic, for every view
      # that has it open.
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:telemetry, "~> 1.0"},
      # The views, each an optional binding (Cardbox.Masu, ...): the app
      # has the libraries of the views it shows.
      {:masu, "~> 0.7", optional: true},
      {:hakushi, "~> 0.6", optional: true},
      {:koyomi, "~> 0.2.1", optional: true},
      {:fude, "~> 0.7", optional: true},
      # The development app (dev.exs).
      {:bandit, "~> 1.5", only: :dev},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp description do
    "Collections for Phoenix: records of one kind, with fields your users define, seen as a table, a board, a calendar, a chart or a canvas."
  end

  defp package do
    [
      name: "cardbox",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides mix.exs .formatter.exs README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      assets: %{"media" => "media"},
      extras: [
        "README.md",
        "guides/quickstart.md",
        "guides/fields.md",
        "guides/queries.md",
        "guides/views.md",
        "guides/agents.md",
        "guides/design.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/(quickstart|fields|queries|views|agents)/,
        Reference: ~r/guides\/design/
      ],
      groups_for_modules: [
        "Your module": [Cardbox],
        Collections: [Cardbox.Collection, Cardbox.Field, Cardbox.Record, Cardbox.View],
        Types: [Cardbox.Type, Cardbox.Choice],
        Queries: [Cardbox.Query, Cardbox.Filter, Cardbox.Sort],
        Changes: [Cardbox.Event, Cardbox.Error],
        "Drawn by": [Cardbox.Masu, Cardbox.Koyomi, Cardbox.Fude, Cardbox.Hakushi],
        Databases: [Cardbox.SQL]
      ]
    ]
  end

  defp aliases do
    [
      dev: "run --no-halt dev.exs",
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
