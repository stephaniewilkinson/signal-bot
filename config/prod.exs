import Config

config :logger, level: :info

config :yonderbook_clubs, :logger, [
  {:handler, :sentry_handler, Sentry.LoggerHandler,
   %{config: %{capture_log_messages: true, level: :error}}}
]
