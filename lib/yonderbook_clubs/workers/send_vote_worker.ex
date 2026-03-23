defmodule YonderbookClubs.Workers.SendVoteWorker do
  @moduledoc """
  Oban worker that sends vote blurbs and Signal polls to a group.

  The heavy work (cover downloads, Signal sends, poll creation) runs here
  with automatic retry on failure. Validation (voting state, suggestion
  count) happens before enqueueing so the user gets immediate feedback.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  alias YonderbookClubs.Bot.Formatter
  alias YonderbookClubs.Bot.Router.Helpers
  alias YonderbookClubs.Clubs
  alias YonderbookClubs.Polls
  alias YonderbookClubs.Suggestions

  require Logger

  @max_poll_options 12

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"club_id" => club_id, "group_id" => group_id, "vote_budget" => vote_budget, "suggestion_ids" => suggestion_ids}}) do
    Sentry.Context.set_tags_context(%{
      club_id: club_id,
      group_id: group_id,
      worker: "SendVoteWorker"
    })
    Sentry.Context.set_extra_context(%{
      vote_budget: vote_budget,
      suggestion_count: length(suggestion_ids)
    })

    signal = YonderbookClubs.Signal.impl()
    club = Clubs.get_club!(club_id)
    suggestions = Suggestions.get_suggestions_by_ids(suggestion_ids)

    chunks = Enum.chunk_every(suggestions, @max_poll_options)
    total_polls = length(chunks)
    blurbs = Formatter.format_blurbs(suggestions, vote_budget, total_polls)
    cover_paths = Helpers.download_covers(suggestions)

    try do
      case signal.send_message(group_id, blurbs, cover_paths) do
        :ok ->
          send_polls(signal, group_id, club, chunks, vote_budget, total_polls)

        {:error, reason} ->
          Logger.error("Failed to send blurbs to group #{group_id}: #{inspect(reason)}")
          Clubs.set_voting_active(club, false)
          {:error, reason}
      end
    after
      Helpers.cleanup_covers(cover_paths)
    end
  end

  defp send_polls(signal, group_id, club, chunks, vote_budget, total_polls) do
    result =
      chunks
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {chunk, poll_num}, {:ok, created_polls} ->
        question = Formatter.format_poll_question(vote_budget, poll_num, total_polls)
        options = Formatter.format_poll_options(chunk)

        case signal.send_poll(group_id, question, options) do
          {:ok, poll_timestamp} when is_integer(poll_timestamp) ->
            case Polls.create_poll(club, poll_timestamp, vote_budget, chunk) do
              {:ok, poll} ->
                {:cont, {:ok, [poll | created_polls]}}

              {:error, reason} ->
                {:halt, {:error, reason, created_polls}}
            end

          {:error, reason} ->
            {:halt, {:error, reason, created_polls}}
        end
      end)

    case result do
      {:ok, _polls} ->
        Suggestions.archive_all_suggestions(club)
        :ok

      {:error, reason, created_polls} ->
        Logger.error("Failed to send poll to group #{group_id}: #{inspect(reason)}")
        Enum.each(created_polls, &Polls.delete_poll/1)
        Clubs.set_voting_active(club, false)
        {:error, reason}
    end
  end
end
