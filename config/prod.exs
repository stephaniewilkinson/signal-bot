import Config

config :logger, level: :info

config :logger,
  backends: [:console, Sentry.LoggerBackend]
