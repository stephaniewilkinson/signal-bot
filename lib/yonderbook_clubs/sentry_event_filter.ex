defmodule YonderbookClubs.SentryEventFilter do
  @moduledoc """
  Sentry `before_send` callback that enriches events with app-specific context.

  Promotes Logger metadata keys into Sentry tags so they appear as filterable
  fields in the Sentry dashboard. Also attaches the OTP app version.
  """

  @logger_metadata_keys [:club_id, :sender_uuid, :command, :group_id]

  @spec before_send(Sentry.Event.t()) :: Sentry.Event.t()
  def before_send(event) do
    event
    |> add_app_version()
    |> promote_logger_metadata()
  end

  defp add_app_version(event) do
    version =
      case :application.get_key(:yonderbook_clubs, :vsn) do
        {:ok, vsn} -> List.to_string(vsn)
        :undefined -> "unknown"
      end

    update_in(event.tags, &Map.put(&1, :app_version, version))
  end

  defp promote_logger_metadata(event) do
    metadata = Logger.metadata()

    tags =
      @logger_metadata_keys
      |> Enum.reduce(%{}, fn key, acc ->
        case Keyword.fetch(metadata, key) do
          {:ok, value} -> Map.put(acc, key, to_string(value))
          :error -> acc
        end
      end)

    if map_size(tags) > 0 do
      update_in(event.tags, &Map.merge(&1, tags))
    else
      event
    end
  end
end
