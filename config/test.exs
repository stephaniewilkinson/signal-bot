import Config

config :yonderbook_clubs, YonderbookClubs.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "yonderbook_clubs_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :yonderbook_clubs, :signal_impl, YonderbookClubs.Signal.Mock

config :yonderbook_clubs, Oban, testing: :inline

config :logger, level: :warning
