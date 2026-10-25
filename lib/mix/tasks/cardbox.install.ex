# The task with Igniter when the app has it, else the plain one: the choice
# is made as the file compiles, since `use Igniter.Mix.Task` does not expand
# in an app without Igniter.
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Cardbox.Install do
    @shortdoc "Adds Cardbox to a Phoenix app"

    @moduledoc """
    Sets up Cardbox in a Phoenix application.

        $ mix igniter.install cardbox

    or, with Cardbox already in the deps, `mix cardbox.install`.
    [Igniter](https://hexdocs.pm/igniter) shows each change as a diff and
    asks before it writes (`--dry-run` only shows them, `--yes` does not
    ask). Running the task again changes nothing.

      * `lib/my_app/cardbox.ex` - your module of Cardbox's, with your repo
        and your PubSub, and the callbacks to write as comments: your file,
        written once;
      * the migration of Cardbox's tables (`mix cardbox.gen.migration`), in
        the migrations of your repo, unless one pins the latest version
        already.

    Then run `mix ecto.migrate`, and draw a view: see the Quickstart.

    ## Options

      * `--repo` - the repo of the tables, when the app has several.
    """

    use Igniter.Mix.Task

    alias Igniter.Libs.Ecto, as: IgniterEcto
    alias Igniter.Project.Module, as: Mod
    alias Mix.Tasks.Cardbox.Gen.Migration

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{group: :cardbox, schema: [repo: :string], aliases: [r: :repo]}
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      prefix = Mod.module_name_prefix(igniter)
      {igniter, repo} = repo(igniter, prefix)
      cardbox = Module.concat(prefix, Cardbox)

      igniter
      |> create_once(cardbox, Cardbox.Install.module_body(repo, Module.concat(prefix, PubSub)))
      |> migration(repo)
      |> Igniter.add_notice(Cardbox.Install.notice(cardbox))
    end

    # The repo given, else the app's only one, else the one chosen, else
    # MyApp.Repo.
    defp repo(igniter, prefix) do
      case igniter.args.options[:repo] do
        nil ->
          case IgniterEcto.select_repo(igniter, label: "Which repo keeps Cardbox's tables?") do
            {igniter, nil} -> {igniter, Module.concat(prefix, Repo)}
            {igniter, repo} -> {igniter, repo}
          end

        repo ->
          {igniter, Mod.parse(repo)}
      end
    end

    # Written once: the app's own after that.
    defp create_once(igniter, module, contents) do
      case Mod.module_exists(igniter, module) do
        {true, igniter} -> igniter
        {false, igniter} -> Mod.create_module(igniter, module, contents)
      end
    end

    # The migration from the version the repo's migrations pin, unless they
    # pin the latest.
    defp migration(igniter, repo) do
      dir = Cardbox.Install.migrations_path(repo)
      igniter = Igniter.include_glob(igniter, Path.join(dir, "*.exs"))

      sources =
        for source <- Rewrite.sources(igniter.rewrite),
            Path.dirname(source.path) == dir,
            do: Rewrite.Source.get(source, :content)

      latest = Cardbox.Migrations.latest_version()

      try do
        case Migration.pinned_in(sources) do
          ^latest ->
            igniter

          from ->
            IgniterEcto.gen_migration(igniter, repo, Migration.name(from, latest),
              body: Migration.body(from, latest),
              on_exists: :skip
            )
        end
      rescue
        error in Mix.Error -> Igniter.add_issue(igniter, error.message)
      end
    end
  end
else
  defmodule Mix.Tasks.Cardbox.Install do
    @shortdoc "Adds Cardbox to a Phoenix app"

    @moduledoc """
    Sets up Cardbox in a Phoenix application.

        $ mix cardbox.install

    writes, when they are missing:

      * `lib/my_app/cardbox.ex` - your module of Cardbox's, with your repo
        and your PubSub, and the callbacks to write as comments;
      * the migration of Cardbox's tables (`mix cardbox.gen.migration`),
        unless one pins the latest version already.

    Then run `mix ecto.migrate`. With [Igniter](https://hexdocs.pm/igniter)
    in the app, the task shows each change as a diff before it writes:
    `mix igniter.install cardbox`.

    ## Options

      * `--repo` - the repo of the tables, `MyApp.Repo` unless given.
    """

    use Mix.Task

    @impl Mix.Task
    def run(argv), do: Cardbox.Install.run(argv)
  end
end
