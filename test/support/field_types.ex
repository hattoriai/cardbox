defmodule CardboxTest.Rating do
  @moduledoc "A type of the tests' own: a rating from 1 to 5, in stars."
  @behaviour Cardbox.FieldType

  @impl true
  def name, do: "rating"

  @impl true
  def kind(_options), do: :number

  @impl true
  def check_options(%{"of" => of} = options, _previous, collection) do
    if Cardbox.Collection.field(collection, of),
      do: {:ok, options},
      else: {:error, "a rating is of a field of the collection, got: #{inspect(of)}"}
  end

  def check_options(options, _previous, _collection), do: {:ok, options}

  @impl true
  def cast(value, _field, _opts) when value in 1..5, do: {:ok, value}
  def cast(value, field, opts) when is_binary(value), do: cast(String.length(value), field, opts)
  def cast(value, _field, _opts), do: {:error, "is from 1 to 5, got: #{inspect(value)}"}

  @impl true
  def text(stars, _field), do: String.duplicate("★", stars)

  @impl true
  def json_schema(_field), do: %{"type" => "integer", "minimum" => 1, "maximum" => 5}

  @impl true
  def words(stars, _field), do: ["#{stars}stars"]
end

defmodule CardboxTest.Mood do
  @moduledoc "The least a type is: its name and its cast."
  @behaviour Cardbox.FieldType

  @impl true
  def name, do: "mood"

  @impl true
  def cast(value, _field, _opts) when is_binary(value), do: {:ok, String.downcase(value)}
  def cast(value, _field, _opts), do: {:error, "is a mood, got: #{inspect(value)}"}
end

defmodule CardboxTest.Shadow do
  @moduledoc "A type that takes a name of Cardbox's."
  @behaviour Cardbox.FieldType

  @impl true
  def name, do: "text"

  @impl true
  def cast(value, _field, _opts), do: {:ok, value}
end
