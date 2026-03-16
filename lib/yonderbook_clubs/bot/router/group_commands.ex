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
        case Clubs.get_club_by_group_id(group_id) do
          %{voting_active: true} ->
            YonderbookClubs.Signal.impl().send_message(
              group_id,
              "A vote is already open. Say \"close vote\" to end it."
            )
            {:error, :already_voting}

          _ ->
            YonderbookClubs.Signal.impl().send_message(
              group_id,
              "How many books should win? Reply \"/start vote 1\" or \"/start vote 2\", etc."
            )
            :ok
        end

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
            :ok ->
              suggestion_ids = Enum.map(suggestions, & &1.id)
              capped_budget = min(vote_budget, length(suggestions))

              %{club_id: club.id, group_id: group_id, vote_budget: capped_budget, suggestion_ids: suggestion_ids}
              |> YonderbookClubs.Workers.SendVoteWorker.new()
              |> Oban.insert()

              :ok

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
