defmodule Cardbox.Event do
  @moduledoc """
  A change to a collection, broadcast to everyone who has it open.

      MyApp.Cardbox.subscribe(collection)

      def handle_info({:cardbox, %Cardbox.Event{type: :record_updated, record: record}}, socket)

  `type` is one of `:record_inserted`, `:record_updated`, `:record_moved`,
  `:record_deleted`, `:field_added`, `:field_updated`, `:field_moved`,
  `:field_deleted`, `:view_saved`, `:view_deleted`, `:collection_updated`
  and `:collection_deleted`.

  A record's event has the `record` as it is after (as it was, for a
  deletion) and, for an update, the keys of the fields that `changed`. A
  field's or a collection's event has the `collection` as it is after,
  with its fields, so a view takes the new fields without reading them
  again. `actor` is the id of who made the change.

  Each event is also a `:telemetry` event, `[:cardbox, :change]`, with the
  event in its metadata.
  """

  @type type ::
          :record_inserted
          | :record_updated
          | :record_moved
          | :record_deleted
          | :field_added
          | :field_updated
          | :field_moved
          | :field_deleted
          | :view_saved
          | :view_deleted
          | :collection_updated
          | :collection_deleted

  @type t :: %__MODULE__{
          type: type(),
          collection_id: integer(),
          collection: Cardbox.Collection.t() | nil,
          record: Cardbox.Record.t() | nil,
          field: Cardbox.Field.t() | nil,
          view: Cardbox.View.t() | nil,
          changed: [String.t()],
          actor: String.t() | nil
        }

  @enforce_keys [:type, :collection_id]
  defstruct [:type, :collection_id, :collection, :record, :field, :view, :actor, changed: []]

  @doc "The PubSub topic of a collection's events."
  @spec topic(Cardbox.Collection.t() | integer()) :: String.t()
  def topic(%Cardbox.Collection{id: id}), do: topic(id)
  def topic(id), do: "cardbox:collection:#{id}"
end
