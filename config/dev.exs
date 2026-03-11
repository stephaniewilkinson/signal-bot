import Config

config :yonderbook_clubs, YonderbookClubs.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "yonderbook_clubs_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
