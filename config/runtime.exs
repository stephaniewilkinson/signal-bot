import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :yonderbook_clubs, YonderbookClubs.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  config :yonderbook_clubs,
    signal_cli_host: System.get_env("SIGNAL_CLI_HOST") || "localhost",
    signal_cli_port: String.to_integer(System.get_env("SIGNAL_CLI_PORT") || "7583"),
    signal_bot_number:
      System.get_env("SIGNAL_BOT_NUMBER") ||
        raise("environment variable SIGNAL_BOT_NUMBER is missing."),
    anthropic_api_key:
      System.get_env("ANTHROPIC_API_KEY") ||
        raise("environment variable ANTHROPIC_API_KEY is missing.")
end
