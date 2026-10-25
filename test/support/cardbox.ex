defmodule CardboxTest.Cardbox do
  @moduledoc "The Cardbox module of the tests, on the repo test_helper.exs picks."
  use Cardbox, pubsub: CardboxTest.PubSub

  def repo, do: Application.fetch_env!(:cardbox, :test_repo)

  # An actor whose id is not its `:id`, as an app's scope is.
  def actor_id({:scope, id}), do: id
  def actor_id(actor), do: Cardbox.default_actor_id(actor)
end
