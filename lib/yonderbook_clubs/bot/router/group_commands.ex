defmodule YonderbookClubs.Bot.Router.GroupCommands do
  @moduledoc """
  Handles group chat commands: start vote, close vote, results.
  """

  alias YonderbookClubs.Bot.Formatter
  alias YonderbookClubs.Bot.Router.Helpers
  alias YonderbookClubs.Clubs
  alias YonderbookClubs.Polls
  alias YonderbookClubs.Suggestions

  require Logger

  @max_poll_options 12

  @spec handle(String.t(), String.t()) :: :ok | :noop | {:error, atom()}
  def handle(group_id, text) do
    case text |> Helpers.strip_slash() |> String.downcase() do
      "start vote " <> rest ->
        case parse_vote_budget(rest) do
          {:ok, n} ->
            handle_start_vote(group_id, n)

          {:error, _} ->
            YonderbookClubs.Signal.impl().send_message(
              group_id,
              "Pick a number between 1 and 50, like \"/start vote 2\"."
            )
            :ok
        end

      "start vote" ->
        YonderbookClubs.Signal.impl().send_message(
          group_id,
          "How many books should win? Reply \"/start vote 1\" or \"/start vote 2\", etc."
        )
        :ok

      "close vote" ->
        handle_close_vote(group_id)

      "results" ->
        handle_results(group_id)

      _ ->
        :noop
    end
  end

  defp parse_vote_budget(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n > 0 and n <= 50 -> {:ok, n}
      {_, ""} -> {:error, :out_of_range}
      _ -> {:error, :invalid}
    end
  end

  defp handle_start_vote(group_id, vote_budget) do
    signal = YonderbookClubs.Signal.impl()

    with {:ok, club} <- get_or_create_club_for_group(group_id),
         {:ok, club} <- activate_voting(club, group_id) do
      case get_suggestions_for_vote(club, group_id) do
        {:ok, suggestions} ->
          case check_enough_suggestions(suggestions, signal, group_id) do
            :ok -> send_vote(signal, group_id, club, suggestions, vote_budget)
            error ->
              Clubs.set_voting_active(club, false)
              error
          end

        error ->
          Clubs.set_voting_active(club, false)
          error
      end
    end
  end

  defp check_enough_suggestions(suggestions, signal, group_id) do
    if length(suggestions) < 2 do
      signal.send_message(
        group_id,
        "I've only received one suggestion. DM me another suggestion and then I'll be ready to create the poll."
      )
      {:error, :not_enough_suggestions}
    else
      :ok
    end
  end

  defp send_vote(signal, group_id, club, suggestions, vote_budget) do
    chunks = Enum.chunk_every(suggestions, @max_poll_options)
    total_polls = length(chunks)
    blurbs = Formatter.format_blurbs(suggestions, vote_budget, total_polls)
    cover_paths = Helpers.download_covers(suggestions)

    case signal.send_message(group_id, blurbs, cover_paths) do
      :ok ->
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
            Helpers.cleanup_covers(cover_paths)
            :ok

          {:error, reason, created_polls} ->
            Logger.error("Failed to send poll to group #{group_id}: #{inspect(reason)}")
            Enum.each(created_polls, &Polls.delete_poll/1)
            Clubs.set_voting_active(club, false)
            Helpers.cleanup_covers(cover_paths)
            :ok
        end

      {:error, reason} ->
        Logger.error("Failed to send blurbs to group #{group_id}: #{inspect(reason)}")
        Clubs.set_voting_active(club, false)
        Helpers.cleanup_covers(cover_paths)
        :ok
    end
  end

  defp get_or_create_club_for_group(group_id) do
    case Clubs.get_club_by_group_id(group_id) do
      nil -> Clubs.get_or_create_club(group_id, "Book Club")
      club -> {:ok, club}
    end
  end

  defp activate_voting(club, group_id) do
    case Clubs.activate_voting(club) do
      {:ok, club} ->
        {:ok, club}

      {:error, :already_voting} ->
        YonderbookClubs.Signal.impl().send_message(
          group_id,
          "A vote is already open. Say \"close vote\" to end it."
        )
        {:error, :already_voting}
    end
  end

  defp get_suggestions_for_vote(club, group_id) do
    case Suggestions.list_suggestions(club) do
      [] ->
        YonderbookClubs.Signal.impl().send_message(
          group_id,
          "No suggestions yet. DM me: \"suggest Title by Author\""
        )

        {:error, :no_suggestions}

      suggestions ->
        {:ok, suggestions}
    end
  end

  defp handle_close_vote(group_id) do
    case Clubs.get_club_by_group_id(group_id) do
      nil ->
        :noop

      club ->
        if club.voting_active do
          Clubs.set_voting_active(club, false)

          Polls.get_latest_active_polls(club)
          |> Enum.each(&Polls.close_poll/1)

          YonderbookClubs.Signal.impl().send_message(group_id, "Vote closed.")
        else
          YonderbookClubs.Signal.impl().send_message(group_id, "No vote is active right now.")
        end

        :ok
    end
  end

  defp handle_results(group_id) do
    signal = YonderbookClubs.Signal.impl()

    case Clubs.get_club_by_group_id(group_id) do
      nil ->
        :noop

      club ->
        case Polls.get_latest_polls(club) do
          [] ->
            signal.send_message(group_id, "No polls yet. Start one with /start vote.")
            :ok

          [first | _] = polls ->
            results = Polls.get_combined_results(polls)
            signal.send_message(group_id, Formatter.format_results(results, first.status))
            :ok
        end
    end
  end
end
