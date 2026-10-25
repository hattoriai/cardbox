defmodule Cardbox.Store do
  @moduledoc false
  # What every write shares: the module's repo and PubSub, who the actor is,
  # whether they may, and the event each change broadcasts.

  alias Cardbox.{Error, Event}

  def repo(mod), do: mod.__cardbox__(:repo)
  def dialect(mod), do: Cardbox.SQL.dialect(repo(mod))

  def actor_id(mod, opts), do: mod.actor_id(Keyword.get(opts, :actor))

  # :ok, or the error of an action the module does not allow.
  def allow(mod, opts, action, subject) do
    if mod.allow?(Keyword.get(opts, :actor), action, subject),
      do: :ok,
      else: {:error, Error.unauthorized(action |> Atom.to_string() |> String.replace("_", " "))}
  end

  # Runs the function in a transaction of the module's repo; its {:error, _}
  # rolls back and is returned as it is.
  def transaction(mod, fun) do
    repo = repo(mod)

    repo.transaction(fn ->
      case fun.(repo) do
        {:ok, result} -> result
        {:error, error} -> repo.rollback(error)
      end
    end)
  end

  def broadcast(mod, %Event{} = event) do
    :telemetry.execute([:cardbox, :change], %{count: 1}, %{event: event, module: mod})

    case mod.__cardbox__(:pubsub) do
      nil ->
        :ok

      pubsub ->
        Phoenix.PubSub.broadcast(pubsub, Event.topic(event.collection_id), {:cardbox, event})
    end
  end

  def event(type, collection_id, opts, mod, fields \\ []) do
    struct!(
      Event,
      [type: type, collection_id: collection_id, actor: actor_id(mod, opts)] ++ fields
    )
  end
end
