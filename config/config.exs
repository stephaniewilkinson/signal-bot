import Config

config :yonderbook_clubs,
  ecto_repos: [YonderbookClubs.Repo]

config :yonderbook_clubs, YonderbookClubs.Repo, migration_timestamps: [type: :utc_datetime_usec]

config :yonderbook_clubs,
  json_library: Jason

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :sentry,
  dsn: "https://993a30714786883d624863b727d5aa46@o4510085954666496.ingest.us.sentry.io/4511034997211136",
  environment_name: config_env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()]

import_config "#{config_env()}.exs"
