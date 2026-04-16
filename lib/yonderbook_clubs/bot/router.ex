defmodule YonderbookClubs.Bot.Router do
  @moduledoc """
  Inbound message routing for the Yonderbook Clubs bot.

  Receives parsed signal-cli messages and dispatches to the appropriate handler
  based on whether the message is a group message or a DM.
  """

  alias YonderbookClubs.Bot.PendingCommands
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
    sender_uuid = msg["sourceUuid"]

    has_pending = sender_uuid && PendingCommands.has_pending?({:group, group_id, sender_uuid})

    if String.starts_with?(text, "/") or has_pending do
      set_sentry_context(%{group_id: group_id, message_type: "group"})
      GroupCommands.handle(group_id, text, sender_uuid)
    else
      :noop
    end
  end

  def handle_message(%{"sourceUuid" => sender_uuid} = msg) do
    text = (msg["message"] || "") |> String.trim()
    set_sentry_context(%{message_type: "dm"})
    Sentry.Context.set_user_context(%{id: sender_uuid})
    sender_name = msg["sourceName"] || "there"
    DMCommands.handle(sender_uuid, sender_name, text)
  end

  def handle_message(_msg), do: :noop

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

  @doc """
  Handles a group quit/kick event — deactivates the club only when the bot itself is removed.

  `source_number` is the phone number of the member who left/was kicked.
  If it doesn't match the bot's number, the event is ignored.
  """
  @spec handle_group_quit(String.t(), String.t()) :: :ok
  def handle_group_quit(group_id, source_number) do
    bot_number = Application.get_env(:yonderbook_clubs, :signal_bot_number)

    if source_number == bot_number do
      Logger.info("Bot removed from group #{group_id}, deactivating club")

      case YonderbookClubs.Clubs.get_club_by_group_id(group_id) do
        nil -> :ok
        club ->
          YonderbookClubs.Clubs.set_voting_active(club, false)
          YonderbookClubs.Clubs.deactivate_club(club)
          :ok
      end
    else
      Logger.debug("Member #{source_number} left group #{group_id}, ignoring")
      :ok
    end
  end
end
