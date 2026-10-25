defmodule CardboxTest.SQLiteRepo do
  @moduledoc "The repo of the tests on SQLite, the default."
  use Ecto.Repo, otp_app: :cardbox, adapter: Ecto.Adapters.SQLite3
end

defmodule CardboxTest.PostgresRepo do
  @moduledoc "The repo of the tests on PostgreSQL, with DATABASE_URL."
  use Ecto.Repo, otp_app: :cardbox, adapter: Ecto.Adapters.Postgres
end
