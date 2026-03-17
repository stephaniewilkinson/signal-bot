defmodule YonderbookClubs.Telemetry do
  @moduledoc """
  Telemetry event handler for logging key metrics.

  Attaches to Signal RPC and book search events to log durations.
  """

  require Logger

  @events [
    [:yonderbook_clubs, :signal, :rpc],
    [:yonderbook_clubs, :books, :search]
  ]

  @oban_events [
    [:oban, :job, :exception]
  ]

  @spec attach() :: :ok
  def attach do
    :telemetry.attach_many(
      "yonderbook-clubs-logger",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )

    :telemetry.attach_many(
      "yonderbook-clubs-oban",
      @oban_events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event([:yonderbook_clubs, :signal, :rpc], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info("signal_rpc",
      method: metadata.method,
      duration_ms: duration_ms,
      result: metadata.result
    )
  end

  def handle_event([:yonderbook_clubs, :books, :search], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info("books_search",
      search_type: metadata.type,
      duration_ms: duration_ms,
      result: metadata.result
    )
  end

  def handle_event([:oban, :job, :exception], _measurements, metadata, _config) do
    %{reason: reason, stacktrace: stacktrace, job: job} = metadata

    Sentry.capture_exception(reason,
      stacktrace: stacktrace,
      tags: %{worker: job.worker, queue: job.queue},
      extra: %{attempt: job.attempt, max_attempts: job.max_attempts, args: job.args}
    )
  end
end
