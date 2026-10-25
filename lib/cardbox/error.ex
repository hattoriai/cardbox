defmodule Cardbox.Error do
  @moduledoc """
  Why a write or a query did not happen.

  `reason` is one of:

    * `:invalid` - a value, a field or a query that does not check; `errors`
      says which, as `{field_key, message}` (`nil` for the whole of it);
    * `:conflict` - a value someone changed meanwhile (the `:expect` option
      of an update); `current` is the record as it is now;
    * `:not_found` - a record, field or view that is not in the collection;
    * `:unauthorized` - the module's `c:Cardbox.allow?/3` said no.

  `message` says it in words, for a person or an agent.
  """

  defexception [:reason, :message, errors: [], current: nil]

  @type t :: %__MODULE__{
          reason: :invalid | :conflict | :not_found | :unauthorized,
          message: String.t(),
          errors: [{String.t() | nil, String.t()}],
          current: term()
        }

  @doc false
  def invalid(errors, fields \\ []) do
    names = Map.new(fields, &{&1.key, &1.name})

    message =
      Enum.map_join(errors, "; ", fn
        {nil, message} -> message
        {key, message} -> "#{Map.get(names, key, key)} #{message}"
      end)

    %__MODULE__{reason: :invalid, message: message, errors: errors}
  end

  @doc false
  def not_found(what), do: %__MODULE__{reason: :not_found, message: "#{what} is not in the collection"}

  @doc false
  def unauthorized(action), do: %__MODULE__{reason: :unauthorized, message: "not allowed to #{action}"}

  @doc false
  def from_changeset(%Ecto.Changeset{} = changeset) do
    errors =
      Enum.map(changeset.errors, fn {field, {message, opts}} ->
        message =
          Enum.reduce(opts, message, fn {key, value}, acc ->
            String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
          end)

        {Atom.to_string(field), message}
      end)

    invalid(errors)
  end
end
