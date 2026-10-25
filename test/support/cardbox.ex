defmodule CardboxTest.Cardbox do
  @moduledoc "The Cardbox module of the tests, on the repo test_helper.exs picks."
  use Cardbox, pubsub: CardboxTest.PubSub

  def repo, do: Application.fetch_env!(:cardbox, :test_repo)
end
