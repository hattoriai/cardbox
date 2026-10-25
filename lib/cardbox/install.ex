defmodule Cardbox.Install do
  @moduledoc false
  # `mix cardbox.install` without Igniter: the module and the migration
  # written as files, when they are missing. The task with Igniter
  # (Mix.Tasks.Cardbox.Install) writes the same, and shares module_body/2,
  # migrations_path/1 and notice/1 with this one.

  alias Mix.Tasks.Cardbox.Gen.Migration

  @doc false
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: [repo: :string], aliases: [r: :repo])
    app = Mix.Project.config()[:app]
    prefix = Module.concat([Macro.camelize(to_string(app))])
    repo = if opts[:repo], do: Module.concat([opts[:repo]]), else: Module.concat(prefix, Repo)
    install(app, prefix, repo)
  end

  @doc false
  # The task, for an app, its modules' prefix and its repo.
  @spec install(atom(), module(), module()) :: :ok
  def install(app, prefix, repo) do
    cardbox = Module.concat(prefix, Cardbox)
    path = Path.join(["lib", Macro.underscore(cardbox) <> ".ex"])

    if File.exists?(path) do
      Mix.shell().info([:green, "* unchanged ", :reset, path, " (it exists)"])
    else
      File.mkdir_p!(Path.dirname(path))
      body = module_body(repo, Module.concat(prefix, PubSub))
      File.write!(path, "defmodule #{inspect(cardbox)} do\n#{indent(body)}end\n")
      Mix.shell().info([:green, "* creating ", :reset, path])
    end

    Migration.write(migrations_path(repo), app, timestamp())
    Mix.shell().info("\n" <> notice(cardbox))
  end

  @doc false
  # Where a repo's migrations are, as Ecto and Igniter put them.
  @spec migrations_path(module()) :: Path.t()
  def migrations_path(repo) do
    Path.join(["priv", repo |> Module.split() |> List.last() |> Macro.underscore(), "migrations"])
  end

  @doc false
  # The body of the app's module of Cardbox's.
  @spec module_body(module(), module()) :: String.t()
  def module_body(repo, pubsub) do
    """
    @moduledoc \"\"\"
    The app's collections: records of one kind, with fields people define.
    See `Cardbox`.
    \"\"\"
    use Cardbox, repo: #{inspect(repo)}, pubsub: #{inspect(pubsub)}

    # Who writes: an id each record keeps as who made it and changed it
    # last, and each event carries. By default, the actor's :id as text.
    #
    # @impl Cardbox
    # def actor_id(%{user: %{id: id}}), do: "user:\#{id}"
    # def actor_id(_actor), do: nil

    # Who may write: every write asks, with the actor given as :actor.
    # Reads are not asked: scope the collections a person reads.
    #
    # @impl Cardbox
    # def allow?(_actor, :change_fields, _collection), do: true
    # def allow?(_actor, _action, _subject), do: true
    """
  end

  @doc false
  @spec notice(module()) :: String.t()
  def notice(cardbox) do
    """
    Cardbox: run `mix ecto.migrate`, then make a collection:

        {:ok, books} =
          #{inspect(cardbox)}.create_collection(%{
            name: "Reading list",
            fields: [%{name: "Title", type: "text"}, %{name: "Status", type: "status"}]
          })

    A board comes with Cardbox (Narabe). The other views are each drawn by
    a library your app adds to its deps for the views it shows:
    {:masu, "~> 0.7"} for a table, {:koyomi, "~> 0.2.1"} for a calendar,
    {:fude, "~> 0.7"} for a chart, {:hakushi, "~> 0.6"} for a canvas.
    See https://hexdocs.pm/cardbox/quickstart.html
    """
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "  " <> line
    end)
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, hh, mm, ss]) |> to_string()
  end
end
