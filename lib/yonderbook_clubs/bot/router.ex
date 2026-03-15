defmodule YonderbookClubs.Bot.Router do
  @moduledoc """
  Inbound message routing for the Yonderbook Clubs bot.

  Receives parsed signal-cli messages and dispatches to the appropriate handler
  based on whether the message is a group message or a DM.
  """

  alias YonderbookClubs.Bot.Router.{DMCommands, GroupCommands}
  alias YonderbookClubs.Polls

  require Logger

  defp set_sentry_context(metadata) do
    tags = Map.new(metadata, fn {k, v} -> {k, to_string(v)} end)
    Sentry.Context.set_tags_context(tags)
  end

  @doc """
  Main entry point. Receives a signal-cli message map and routes it.

  Returns `:ok` or `:noop`.
  """
  @spec handle_message(map()) :: :ok | :noop | {:error, atom()}
  def handle_message(%{"groupInfo" => %{"groupId" => group_id}} = msg) do
    text = (msg["message"] || "") |> String.trim()
    command = text |> String.downcase() |> String.split(" ") |> Enum.take(2) |> Enum.join(" ")
    Logger.metadata(group_id: group_id, command: command)
    set_sentry_context(%{group_id: group_id, command: command, message_type: "group"})
    GroupCommands.handle(group_id, text)
  end

  def handle_message(%{"sourceUuid" => sender_uuid} = msg) do
    text = (msg["message"] || "") |> String.trim()
    command = text |> String.downcase() |> String.split(" ") |> Enum.take(2) |> Enum.join(" ")
    Logger.metadata(sender_uuid: sender_uuid, command: command)
    set_sentry_context(%{command: command, message_type: "dm"})
    Sentry.Context.set_user_context(%{id: sender_uuid})
    sender_name = msg["sourceName"] || "there"
    DMCommands.handle(sender_uuid, sender_name, text)
  end

  def handle_message(_msg) do
    Logger.warning("Received message with no groupInfo or sourceUuid, ignoring")
    :noop
  end

  @doc """
  Handles an incoming poll vote notification from signal-cli.
  """
  @spec handle_poll_vote(map()) :: :ok | :noop
  def handle_poll_vote(%{"targetSentTimestamp" => timestamp} = msg) do
    case Polls.get_poll_by_timestamp(timestamp) do
      nil ->
        :noop

      %{status: :closed} ->
        :noop

      poll ->
        Polls.record_vote(
          poll,
          msg["sourceUuid"],
          msg["optionIndexes"],
          msg["voteCount"]
        )

        :ok
    end
  end

  def handle_poll_vote(_msg), do: :noop
end
