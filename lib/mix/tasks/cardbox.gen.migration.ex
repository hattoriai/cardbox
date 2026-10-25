defmodule Mix.Tasks.Cardbox.Gen.Migration do
  @shortdoc "Writes the migration of Cardbox's tables, or of their next version"

  @moduledoc """
  Writes the migration that takes Cardbox's tables to their latest
  version (`Cardbox.Migrations`).

      $ mix cardbox.gen.migration
      $ mix cardbox.gen.migration --migrations-path priv/other_repo/migrations

  Then run `mix ecto.migrate`.

  The first time, the migration makes the tables:

      def up, do: Cardbox.Migrations.up(version: 1)
      def down, do: Cardbox.Migrations.down(to: 0)

  After an upgrade of Cardbox whose tables have a new version, it writes
  the migration from the version your migrations pin, read from their
  files (so it needs no database), to the new one. When they pin the
  latest already, it writes nothing.

  ## Options

    * `--migrations-path` - where the migrations are, `priv/repo/migrations`
      unless given.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: [migrations_path: :string])
    dir = Keyword.get(opts, :migrations_path, "priv/repo/migrations")
    write(dir, Mix.Project.config()[:app], timestamp())
  end

  @doc false
  # Writes the migration to `dir`, and returns its path, or nil when the
  # migrations there pin the latest version.
  @spec write(Path.t(), atom(), String.t()) :: Path.t() | nil
  def write(dir, app, timestamp) do
    from = pinned_version(dir)
    to = Cardbox.Migrations.latest_version()

    if from >= to do
      Mix.shell().info("Cardbox's tables are at version #{to}, the latest. Nothing to write.")
      nil
    else
      {name, source} = migration(app, from, to)
      path = Path.join(dir, "#{timestamp}_#{name}.exs")
      File.mkdir_p!(dir)
      File.write!(path, source)
      Mix.shell().info("* creating #{path}")
      path
    end
  end

  @doc false
  # The highest version that `Cardbox.Migrations.up(version: n)` pins in
  # the migrations of `dir`, 0 when none does.
  @spec pinned_version(Path.t()) :: non_neg_integer()
  def pinned_version(dir) do
    dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&File.read!/1)
    |> pinned_in()
  end

  @doc false
  # The highest version pinned in the sources of migrations.
  @spec pinned_in([String.t()]) :: non_neg_integer()
  def pinned_in(sources) do
    sources |> Enum.flat_map(&versions/1) |> Enum.max(fn -> 0 end)
  end

  defp versions(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        ast
        |> Macro.prewalker()
        |> Enum.flat_map(fn
          {{:., _, [{:__aliases__, _, [:Cardbox, :Migrations]}, :up]}, _, args} ->
            pinned(args)

          _node ->
            []
        end)

      {:error, _error} ->
        []
    end
  end

  defp pinned([opts]) when is_list(opts) do
    case Keyword.get(opts, :version) do
      version when is_integer(version) ->
        [version]

      _other ->
        Mix.raise("""
        a migration calls Cardbox.Migrations.up/1 with no version: pin it, as in
        Cardbox.Migrations.up(version: #{Cardbox.Migrations.latest_version()}), so it runs the same with every Cardbox
        """)
    end
  end

  defp pinned(_args) do
    Mix.raise("""
    a migration calls Cardbox.Migrations.up/0: pin the version, as in
    Cardbox.Migrations.up(version: #{Cardbox.Migrations.latest_version()}), so it runs the same with every Cardbox
    """)
  end

  @doc false
  # The name and the source of the migration from version `from` to `to`.
  @spec migration(atom(), non_neg_integer(), pos_integer()) :: {String.t(), String.t()}
  def migration(app, from, to) do
    app_module = app |> to_string() |> Macro.camelize()
    name = name(from, to)

    source = """
    defmodule #{app_module}.Repo.Migrations.#{Macro.camelize(name)} do
      use Ecto.Migration

    #{body(from, to) |> String.replace(~r/^(?=.)/m, "  ")}end
    """

    {name, source}
  end

  @doc false
  # The name of the migration from version `from` to `to`.
  @spec name(non_neg_integer(), pos_integer()) :: String.t()
  def name(0, _to), do: "add_cardbox"
  def name(_from, to), do: "upgrade_cardbox_to_v#{to}"

  @doc false
  # The body of the migration from version `from` to `to`.
  @spec body(non_neg_integer(), pos_integer()) :: String.t()
  def body(from, to) do
    comment =
      if from == 0,
        do: "Cardbox's tables (Cardbox.Migrations), at version #{to}.",
        else: "Cardbox's tables (Cardbox.Migrations), from version #{from} to #{to}."

    """
    # #{comment}
    def up, do: Cardbox.Migrations.up(version: #{to})
    def down, do: Cardbox.Migrations.down(to: #{from})
    """
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, hh, mm, ss]) |> to_string()
  end
end
