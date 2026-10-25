defmodule Cardbox do
  @moduledoc """
  Collections for Phoenix: records of one kind, with fields your users
  define, seen as a table, a board, a calendar, a chart or a canvas.

  Your app has a module of Cardbox's:

      defmodule MyApp.Cardbox do
        use Cardbox, repo: MyApp.Repo, pubsub: MyApp.PubSub
      end

  and makes collections, adds fields, and reads and writes records with it:

      {:ok, books} =
        MyApp.Cardbox.create_collection(%{
          name: "Reading list",
          owner: {"workspace", 42},
          fields: [
            %{name: "Title", type: "text"},
            %{name: "Status", type: "status"},
            %{name: "Rating", type: "number", options: %{format: "integer"}},
            %{name: "Finished", type: "date"}
          ]
        })

      {:ok, dune} = MyApp.Cardbox.insert(books, %{"Title" => "Dune", "Status" => "In progress"})

      {:ok, reading} =
        MyApp.Cardbox.list(books, %{
          "filter" => %{"field" => "status", "op" => "in_group", "value" => "doing"},
          "sort" => [%{"field" => "title"}]
        })

  ## Options of `use Cardbox`

    * `:repo` - the Ecto repo of the tables (`mix cardbox.gen.migration`).
      Without it, the module defines `repo/0`, for a repo known only at
      runtime (a library on Cardbox that takes its host's repo from its
      config).
    * `:pubsub` - a `Phoenix.PubSub`, to broadcast each change to the
      collection's topic (`subscribe/1`, `Cardbox.Event`).
    * `:views` - types of views of your own, beside Cardbox's
      (`Cardbox.View`): `views: ["timeline", "map"]`. A view of one is saved,
      listed and queried as any, and your `c:check_view/3` checks its
      options; your app draws it. See the [Views](views.md) guide.

  ## Options of the functions

  Every function that writes takes `:actor`, who writes: the person or the
  agent of your app, whose id (`c:actor_id/1`) each record keeps as who
  made it and changed it last, each event carries, and `c:allow?/3` is
  asked about.

  Every function that reads takes `:me` (who `"me"` is in a filter; the
  actor's id, or any id), `:time_zone` (where the days of date filters
  are; UTC unless given) and `:now`.

  ## Callbacks

  Three callbacks have defaults, and your module overrides them:

      @impl Cardbox
      def actor_id(%MyApp.Accounts.User{id: id}), do: "user:\#{id}"

      @impl Cardbox
      def allow?(%MyApp.Accounts.User{} = user, :change_fields, collection),
        do: MyApp.Permissions.allowed?(user, :manage, collection)

      def allow?(_actor, _action, _subject), do: true

      @impl Cardbox
      def check_view("timeline", %{"start" => _, "end" => _} = options, _collection), do: {:ok, options}
      def check_view("timeline", _options, _collection), do: {:error, "a timeline names its start and end fields"}
      def check_view(_type, options, _collection), do: {:ok, options}
  """

  alias Cardbox.{Collection, Record}

  @doc """
  The id that records and events keep of an actor: by default, its `:id` as
  text, or the actor itself when it is text, or nil.
  """
  @callback actor_id(actor :: term()) :: String.t() | nil

  @doc """
  Whether an actor may do an action: `:create_collection` (the subject is
  the collection's attributes), `:update_collection`, `:delete_collection`,
  `:change_fields`, `:insert`, `:update`, `:delete`, `:move`, `:save_view`
  and `:delete_view` (the subject is the collection). True by default.
  Reads are not asked: scope the collections a person reads, as your app
  scopes its own records.
  """
  @callback allow?(actor :: term(), action :: atom(), subject :: term()) :: boolean()

  @doc """
  Checks the options of a view of a type of your own (`:views`), when it is
  saved: the options as they are kept, or an error that says what to write.
  The options come with their keys as text. Takes them as they are by
  default.
  """
  @callback check_view(type :: String.t(), options :: map(), collection :: Collection.t()) ::
              {:ok, map()} | {:error, String.t()}

  @doc false
  defmacro __using__(opts) do
    {:__block__, [],
     [
       setup(opts),
       collection_functions(),
       field_functions(),
       record_functions(),
       record_write_functions(),
       view_functions()
     ]}
  end

  # The module's config and the callbacks' defaults.
  defp setup(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Cardbox
      @cardbox_repo Keyword.get(opts, :repo)
      @cardbox_pubsub Keyword.get(opts, :pubsub)
      @cardbox_views Cardbox.View.check_types!(Keyword.get(opts, :views, []))

      @doc false
      if @cardbox_repo do
        def __cardbox__(:repo), do: @cardbox_repo
      else
        def __cardbox__(:repo), do: repo()
      end

      def __cardbox__(:pubsub), do: @cardbox_pubsub
      def __cardbox__(:views), do: Cardbox.View.types() ++ @cardbox_views

      @impl Cardbox
      def actor_id(actor), do: Cardbox.default_actor_id(actor)

      @impl Cardbox
      def allow?(_actor, _action, _subject), do: true

      @impl Cardbox
      def check_view(_type, options, _collection), do: {:ok, options}

      defoverridable actor_id: 1, allow?: 3, check_view: 3
    end
  end

  # The functions of collections and their fields.
  defp collection_functions do
    quote do
      ## Collections

      @doc "Makes a collection, with its `fields` if given. See `Cardbox.Collection`."
      def create_collection(attrs, opts \\ []),
        do: Cardbox.Collections.create(__MODULE__, attrs, opts)

      @doc "The collection with this id, with its fields, or nil."
      def get_collection(id), do: Cardbox.Collections.get(__MODULE__, id)

      @doc "The collection with this id, with its fields, or raises."
      def get_collection!(id),
        do: get_collection(id) || raise(Ecto.NoResultsError, queryable: Cardbox.Collection)

      @doc "The collections of an owner (`{type, id}`), by name; of no owner with nil."
      def list_collections(owner), do: Cardbox.Collections.list(__MODULE__, owner)

      @doc "Changes a collection's name, description or icon."
      def update_collection(collection, attrs, opts \\ []),
        do: Cardbox.Collections.update(__MODULE__, collection, attrs, opts)

      @doc "Deletes a collection, with its fields, records and views."
      def delete_collection(collection, opts \\ []),
        do: Cardbox.Collections.delete(__MODULE__, collection, opts)
    end
  end

  # The functions of fields.
  defp field_functions do
    quote do
      ## Fields

      @doc "Adds a field (`name`, `type`, `options`); returns the collection with it. See `Cardbox.Type`."
      def add_field(collection, attrs, opts \\ []),
        do: Cardbox.Collections.add_field(__MODULE__, collection, attrs, opts)

      @doc """
      Changes a field (by key or name): its `name`, `options`, `description`
      or `type`, whose records' values are converted. Returns the collection.
      """
      def update_field(collection, field, attrs, opts \\ []),
        do: Cardbox.Collections.update_field(__MODULE__, collection, field, attrs, opts)

      @doc "Deletes a field, its values and its place in views; returns the collection."
      def delete_field(collection, field, opts \\ []),
        do: Cardbox.Collections.delete_field(__MODULE__, collection, field, opts)

      @doc "Moves a field `after:` or `before:` another, or `to: :first` or `:last`."
      def move_field(collection, field, opts),
        do: Cardbox.Collections.move_field(__MODULE__, collection, field, opts)

      @doc "Writes the search text of every record of a collection again, after an upgrade of Cardbox that asks for it."
      def reindex(collection), do: Cardbox.Collections.reindex(__MODULE__, collection)
    end
  end

  # The functions that read records.
  defp record_functions do
    quote do
      ## Records

      @doc "The record of the collection with this id, or nil."
      def get(collection, id), do: Cardbox.Records.get(__MODULE__, collection, id)

      @doc """
      The records that meet a query (`Cardbox.Query`, its wire format, or a
      saved `Cardbox.View`), in its order; `:limit` and `:offset` page them.
      """
      def list(collection, query \\ nil, opts \\ []),
        do: Cardbox.Records.list(__MODULE__, collection, query, opts)

      @doc "How many records meet a query."
      def count(collection, query \\ nil, opts \\ []),
        do: Cardbox.Records.count(__MODULE__, collection, query, opts)

      @doc """
      Whether a record meets a query, without the database: for a view that
      gets a change (`Cardbox.Event`) and decides whether to show it.
      """
      def meets?(collection, query, record, opts \\ []),
        do: Cardbox.Records.meets?(collection, query, record, opts)

      @doc """
      The records of a query grouped by fields (`by:`, a field or a list, a
      date with its unit: `{"due", :month}`), and counted or aggregated
      (`value:`, `:count` or `{:sum, "budget"}`), in the database: for a
      chart, or a board's counts.
      """
      def group(collection, query \\ nil, opts),
        do: Cardbox.Records.group(__MODULE__, collection, query, opts)

      @doc "The titles of records of a collection by id: their first text field."
      def titles(collection_id, ids), do: Cardbox.Records.titles(__MODULE__, collection_id, ids)
    end
  end

  # The functions that write records.
  defp record_write_functions do
    quote do
      @doc """
      Adds a record with values by field key or name. `after:` or `before:`
      a record, or `to: :first`, places it; it goes last otherwise.
      """
      def insert(collection, values, opts \\ []),
        do: Cardbox.Records.insert(__MODULE__, collection, values, opts)

      @doc "Adds records, all of them or none."
      def insert_all(collection, list, opts \\ []),
        do: Cardbox.Records.insert_all(__MODULE__, collection, list, opts)

      @doc """
      Changes values of a record (a record or its id); `nil` empties one.
      `expect:` gives the values the writer saw, and a value someone changed
      meanwhile is a conflict (`Cardbox.Error`).
      """
      def update(collection, record, changes, opts \\ []),
        do: Cardbox.Records.update(__MODULE__, collection, record, changes, opts)

      @doc "Deletes a record, and the links to it."
      def delete(collection, record, opts \\ []),
        do: Cardbox.Records.delete(__MODULE__, collection, record, opts)

      @doc "Moves a record in the collection's order: `after:` or `before:` another, or `to: :first` or `:last`."
      def move(collection, record, opts),
        do: Cardbox.Records.move(__MODULE__, collection, record, opts)
    end
  end

  # The functions of views and of changes.
  defp view_functions do
    quote do
      ## Views

      @doc "The views of a collection: the shared ones, and those of `owner:` if given."
      def list_views(collection, opts \\ []), do: Cardbox.Views.list(__MODULE__, collection, opts)

      @doc "The view of the collection with this id, or nil."
      def get_view(collection, id), do: Cardbox.Views.get(__MODULE__, collection, id)

      @doc "Saves a view (`name`, `type`, `query`, `options`, `owner`). See `Cardbox.View`."
      def save_view(collection, attrs, opts \\ []),
        do: Cardbox.Views.save(__MODULE__, collection, attrs, opts)

      @doc "Changes a view."
      def update_view(collection, view, attrs, opts \\ []),
        do: Cardbox.Views.update(__MODULE__, collection, view, attrs, opts)

      @doc "Deletes a view."
      def delete_view(collection, view, opts \\ []),
        do: Cardbox.Views.delete(__MODULE__, collection, view, opts)

      ## Changes

      @doc "Subscribes the process to a collection's changes (`Cardbox.Event`)."
      def subscribe(collection),
        do: Phoenix.PubSub.subscribe(@cardbox_pubsub, Cardbox.Event.topic(collection))

      @doc "Unsubscribes the process from a collection's changes."
      def unsubscribe(collection),
        do: Phoenix.PubSub.unsubscribe(@cardbox_pubsub, Cardbox.Event.topic(collection))
    end
  end

  @doc false
  def default_actor_id(nil), do: nil
  def default_actor_id(%{id: id}), do: to_string(id)
  def default_actor_id(id) when is_binary(id), do: id
  def default_actor_id(id) when is_integer(id), do: Integer.to_string(id)
  def default_actor_id(_actor), do: nil

  @doc """
  A collection as an agent reads it: its name, and each field with its
  key, type, choices and the operators it filters by. Give it to a model
  as the description of a tool that reads or writes the collection.
  """
  @spec describe(Collection.t()) :: map()
  def describe(%Collection{} = collection) do
    %{
      "name" => collection.name,
      "description" => collection.description,
      "fields" =>
        Enum.map(collection.fields, fn field ->
          %{
            "key" => field.key,
            "name" => field.name,
            "type" => field.type,
            "operators" => Enum.map(Cardbox.Type.operators(field), &Atom.to_string/1)
          }
          |> put_if("description", field.description)
          |> put_if(
            "choices",
            field
            |> Cardbox.Field.choices()
            |> Enum.map(&Map.take(&1, ~w(name group)))
            |> nonempty()
          )
          |> put_if("read_only", Cardbox.Type.system?(field.type) || nil)
          |> put_if("options", field.options |> Map.drop(["choices"]) |> nonempty_map())
        end)
    }
    |> put_if("description", collection.description)
  end

  @doc """
  The [JSON Schema](https://json-schema.org) of the values a collection's
  records take, by field key: what `insert/3` and `update/4` take, in the
  forms they keep. For a model's structured output, an agent's tool, or a
  form of your app that checks values before they are sent.

      Cardbox.json_schema(tasks)
      #=> %{
      #     "$schema" => "https://json-schema.org/draft/2020-12/schema",
      #     "title" => "Tasks",
      #     "type" => "object",
      #     "properties" => %{
      #       "title" => %{"title" => "Title", "anyOf" => [%{"type" => "string", ...}, %{"type" => "null"}]},
      #       "status" => %{
      #         "title" => "Status",
      #         "anyOf" => [
      #           %{"type" => "string", "oneOf" => [%{"const" => "not_started", "title" => "Not started"}, ...]},
      #           %{"type" => "null"}
      #         ]
      #       },
      #       ...
      #     },
      #     "additionalProperties" => false
      #   }

  Each value may be `null`, which empties the field. A choice is its id,
  with its name as its title; a day is `"2026-10-25"` (`format: date`), a
  moment ISO 8601 (`format: date-time`); a relation a list of record ids.
  The four read-only types are not in it. Cardbox takes more than the
  schema says (a choice's name, a number as text), and checks every value
  as it writes it, whatever a schema let through.
  """
  @spec json_schema(Collection.t()) :: map()
  def json_schema(%Collection{} = collection), do: Cardbox.JSONSchema.schema(collection)

  defp put_if(map, _key, nil), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  defp put_if(map, key, value),
    do: map |> Map.put(key, value) |> Map.reject(fn {_k, v} -> is_nil(v) end)

  defp nonempty([]), do: nil
  defp nonempty(list), do: list

  defp nonempty_map(map) when map_size(map) == 0, do: nil
  defp nonempty_map(map), do: map

  @doc """
  The value of a field of a record, read for Elixir. See `Cardbox.Record.get/3`.
  """
  @spec get(Record.t(), Collection.t(), term()) :: term()
  defdelegate get(record, collection, field), to: Record
end
