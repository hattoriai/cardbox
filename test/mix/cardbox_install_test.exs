defmodule Mix.Tasks.Cardbox.InstallTest do
  # The task with Igniter, on a project Igniter keeps in memory, and the
  # plain one (Cardbox.Install), in a directory of its own.
  use ExUnit.Case, async: false

  import Igniter.Test

  @repo """
  defmodule Test.Repo do
    use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres
  end
  """

  defp project(files \\ %{}),
    do: test_project(files: Map.merge(%{"lib/test/repo.ex" => @repo}, files))

  defp install(igniter, argv \\ []), do: Igniter.compose_task(igniter, "cardbox.install", argv)

  defp content(igniter, path),
    do: igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)

  defp migration(igniter) do
    Enum.find(Rewrite.sources(igniter.rewrite), &(&1.path =~ ~r{^priv/repo/migrations/.*\.exs$}))
  end

  test "writes the module and the migration" do
    igniter = project() |> install()

    module = content(igniter, "lib/test/cardbox.ex")
    assert module =~ "defmodule Test.Cardbox do"
    assert module =~ "use Cardbox, repo: Test.Repo, pubsub: Test.PubSub"

    migration = Rewrite.Source.get(migration(igniter), :content)
    assert migration(igniter).path =~ ~r{priv/repo/migrations/\d+_add_cardbox\.exs}
    assert migration =~ "defmodule Test.Repo.Migrations.AddCardbox do"
    assert migration =~ "def up, do: Cardbox.Migrations.up(version: 1)"
    assert migration =~ "def down, do: Cardbox.Migrations.down(to: 0)"

    assert_has_notice(igniter, &(&1 =~ "mix ecto.migrate"))
    assert igniter.issues == []
  end

  test "a second run changes nothing" do
    project()
    |> install()
    |> apply_igniter!()
    |> install()
    |> assert_unchanged()
  end

  test "keeps the app's module, and writes no migration when one pins the latest version" do
    pinned = """
    defmodule Test.Repo.Migrations.Cards do
      use Ecto.Migration
      def up, do: Cardbox.Migrations.up(version: 1)
    end
    """

    igniter =
      project(%{
        "lib/test/cardbox.ex" => "defmodule Test.Cardbox do\nend\n",
        "priv/repo/migrations/20260101000000_cards.exs" => pinned
      })
      |> install()

    assert_unchanged(igniter, "lib/test/cardbox.ex")
    assert [_one] = Enum.filter(Rewrite.sources(igniter.rewrite), &(&1.path =~ "migrations/"))
  end

  test "the repo given" do
    igniter = project() |> install(["--repo", "Test.OtherRepo"])
    assert content(igniter, "lib/test/cardbox.ex") =~ "repo: Test.OtherRepo"
    assert migration(igniter) == nil

    assert Enum.any?(
             Rewrite.sources(igniter.rewrite),
             &(&1.path =~ ~r{^priv/other_repo/migrations/\d+_add_cardbox\.exs$})
           )
  end

  describe "without Igniter" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cardbox_install_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Mix.shell(Mix.Shell.Process)

      on_exit(fn ->
        Mix.shell(Mix.Shell.IO)
        File.rm_rf!(dir)
      end)

      %{dir: dir}
    end

    test "writes the module and the migration, once", %{dir: dir} do
      File.cd!(dir, fn ->
        Cardbox.Install.install(:my_app, MyApp, MyApp.Repo)

        module = File.read!("lib/my_app/cardbox.ex")
        assert module =~ "defmodule MyApp.Cardbox do\n  @moduledoc"
        assert module =~ "  use Cardbox, repo: MyApp.Repo, pubsub: MyApp.PubSub\n"
        assert [path] = Path.wildcard("priv/repo/migrations/*_add_cardbox.exs")
        assert {:ok, _ast} = Code.string_to_quoted(File.read!(path))
        assert {:ok, _ast} = Code.string_to_quoted(module)

        Cardbox.Install.install(:my_app, MyApp, MyApp.Repo)
        assert [^path] = Path.wildcard("priv/repo/migrations/*.exs")
        assert_received {:mix_shell, :info, ["* unchanged lib/my_app/cardbox.ex (it exists)"]}
      end)
    end
  end
end
