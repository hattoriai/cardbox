defmodule Cardbox.FieldType do
  @moduledoc """
  A type of field of your app's own: what its values are, how they are
  checked, how they compare and how they read.

      defmodule MyApp.Cardbox.Rating do
        @behaviour Cardbox.FieldType

        @impl true
        def name, do: "rating"

        @impl true
        def kind(_options), do: :number

        @impl true
        def cast(value, _field, _opts) when value in 1..5, do: {:ok, value}
        def cast(value, _field, _opts), do: {:error, "is from 1 to 5, got: \#{inspect(value)}"}
      end

  and in your config, beside Cardbox's own types:

      config :cardbox, types: [MyApp.Cardbox.Rating]

  The types are your app's config, not your Cardbox module's: a value is
  read in many places that know only its field (a filter, a table's
  column, a board's card, the JSON Schema an agent reads), as Kotoba's
  nodes are. A type's name is never one of Cardbox's (`Cardbox.Type`).

  ## What a type says

  Only `name/0` and `cast/3` are required; the others have defaults.

    * `kind/1`: how values compare, for filters and sorts (`Cardbox.Type.kind/1`):
      `:text` by default. A `:list` does not sort or group.
    * `check_options/3`: the field's options, checked when the field is
      added or changed, with the collection, so that an option may name
      another field. By default a type takes no options.
    * `cast/3`: a value given, checked, as it is kept (JSON): `{:ok, nil}`
      for an empty one.
    * `load/2`: a value kept, read for Elixir (`Cardbox.get/3`). As it is
      by default.
    * `plain/2`: a value as plain words or numbers: what a table sorts and
      shows, what `Cardbox.Record.to_map/2` gives, and what a field that
      changes type converts. As it is by default.
    * `text/2`: a value in words for a person, in a table's cell and on a
      board's card. `plain/2`'s, as text, by default.
    * `operators/1`: the filter operators, those of its kind by default.
    * `json_schema/1`: the JSON Schema of a value, for agents. A string by
      default.
    * `words/2`: the words of a value in the record's search text. None by
      default.
  """

  alias Cardbox.{Collection, Field}

  @callback name() :: String.t()
  @callback kind(options :: map()) :: Cardbox.Type.kind()
  @callback check_options(options :: map(), previous :: map(), Collection.t()) ::
              {:ok, map()} | {:error, String.t()}
  @callback cast(value :: term(), Field.t(), opts :: keyword()) ::
              {:ok, term()} | {:error, String.t()}
  @callback load(value :: term(), Field.t()) :: term()
  @callback plain(value :: term(), Field.t()) :: term()
  @callback text(value :: term(), Field.t()) :: String.t() | nil
  @callback operators(Field.t()) :: [atom()]
  @callback json_schema(Field.t()) :: map()
  @callback words(value :: term(), Field.t()) :: [String.t()]

  @optional_callbacks kind: 1,
                      check_options: 3,
                      load: 2,
                      plain: 2,
                      text: 2,
                      operators: 1,
                      json_schema: 1,
                      words: 2

  @doc "The app's types (`config :cardbox, types: [...]`), by name."
  @spec all() :: %{String.t() => module()}
  def all do
    types = Application.get_env(:cardbox, :types, [])

    # Checked once for each list the config gives, then kept.
    case :persistent_term.get({__MODULE__, types}, nil) do
      nil ->
        :ok = check!(types, Cardbox.Type.builtin())
        by_name = Map.new(types, &{&1.name(), &1})
        :persistent_term.put({__MODULE__, types}, by_name)
        by_name

      by_name ->
        by_name
    end
  end

  @doc "The app's type of a name, or nil (one of Cardbox's, or none)."
  @spec get(String.t() | nil) :: module() | nil
  def get(name) when is_binary(name), do: Map.get(all(), name)
  def get(_name), do: nil

  @doc false
  # The app's types, checked once they are all known: modules of the
  # behaviour, of names not Cardbox's and not each other's.
  @spec check!([module()], [String.t()]) :: :ok
  def check!(types, builtin) do
    _names =
      Enum.reduce(types, MapSet.new(), fn type, seen ->
        Code.ensure_loaded!(type)

        unless function_exported?(type, :name, 0) and function_exported?(type, :cast, 3),
          do:
            raise(
              ArgumentError,
              "#{inspect(type)} is not a Cardbox.FieldType: it needs name/0 and cast/3"
            )

        name = type.name()

        cond do
          name in builtin ->
            raise ArgumentError,
                  "#{inspect(type)}'s name #{inspect(name)} is one of Cardbox's types"

          MapSet.member?(seen, name) ->
            raise ArgumentError, "two field types are named #{inspect(name)}"

          true ->
            MapSet.put(seen, name)
        end
      end)

    :ok
  end

  ## The callbacks, with their defaults

  @doc false
  def kind(type, options), do: call(type, :kind, [options], fn -> :text end)

  @doc false
  def check_options(type, options, previous, collection) do
    call(type, :check_options, [options, previous, collection], fn ->
      if options == %{},
        do: {:ok, options},
        else:
          {:error, "a #{type.name()} field takes no options, got: #{inspect(Map.keys(options))}"}
    end)
  end

  @doc false
  def load(type, field, value), do: call(type, :load, [value, field], fn -> value end)

  @doc false
  def plain(type, field, value), do: call(type, :plain, [value, field], fn -> value end)

  @doc false
  def text(_type, _field, nil), do: nil

  def text(type, field, value) do
    call(type, :text, [value, field], fn ->
      case plain(type, field, value) do
        list when is_list(list) -> Enum.map_join(list, ", ", &to_string/1)
        plain -> to_string(plain)
      end
    end)
  end

  @doc false
  def json_schema(type, field),
    do: call(type, :json_schema, [field], fn -> %{"type" => "string"} end)

  @doc false
  def words(_type, _field, nil), do: []
  def words(type, field, value), do: call(type, :words, [value, field], fn -> [] end)

  @doc false
  def operators(type, field, default), do: call(type, :operators, [field], default)

  defp call(type, fun, args, default) do
    if function_exported?(type, fun, length(args)),
      do: apply(type, fun, args),
      else: default.()
  end
end
