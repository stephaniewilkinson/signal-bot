import Config

config :logger, level: :info

config :logger, :default_formatter,
  formatter: {LoggerJSON.Formatters.Basic, metadata: [:club_id, :sender_uuid, :command]}

config :yonderbook_clubs, :logger, [
  {:handler, :sentry_handler, Sentry.LoggerHandler,
   %{config: %{capture_log_messages: true, level: :error}}}
]
