import Config

config :yonderbook_clubs, YonderbookClubs.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "yonderbook_clubs_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :yonderbook_clubs,
  signal_bot_number: "+14582995422",
  anthropic_api_key: nil
