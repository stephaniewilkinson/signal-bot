defmodule YonderbookClubs.Bot.Router.GroupCommands do
  @moduledoc """
  Handles group chat commands: start vote, close vote, results, schedule.
  """

  alias YonderbookClubs.Bot.Formatter
  alias YonderbookClubs.Bot.PendingCommands
  alias YonderbookClubs.Bot.Router.Helpers
  alias YonderbookClubs.Clubs
  alias YonderbookClubs.Polls
  alias YonderbookClubs.Readings
  alias YonderbookClubs.Suggestions

  require Logger

  @schedule_with_author_regex ~r/^(.+)\s+by\s+(.+)\s+for\s+(.+)$/i
  @schedule_without_author_regex ~r/^(.+)\s+for\s+(.+)$/i

  @spec handle(String.t(), String.t(), String.t() | nil) :: :ok | :noop | {:error, atom()}
  def handle(group_id, text, sender_uuid \\ nil) do
    stripped = Helpers.strip_slash(text)
    downcased = String.downcase(stripped)

    result =
      case downcased do
        "start vote " <> rest ->
          handle_start_vote_with_budget(group_id, sender_uuid, rest)

        "start poll " <> rest ->
          handle_start_vote_with_budget(group_id, sender_uuid, rest)

        cmd when cmd in ["start vote", "start poll"] ->
          handle_start_vote_prompt(group_id, sender_uuid)

        cmd when cmd in ["close vote", "close poll"] ->
          handle_close_vote(group_id)

        "results" ->
          handle_results(group_id)

        "schedule " <> _ ->
          schedule_text = String.slice(stripped, 9..-1//1) |> String.trim()
          handle_schedule(group_id, sender_uuid, schedule_text)

        "schedule" ->
          handle_show_schedule(group_id)

        "unschedule " <> _ ->
          unschedule_text = String.slice(stripped, 11..-1//1) |> String.trim()
          handle_unschedule(group_id, sender_uuid, unschedule_text)

        "unschedule" ->
          PendingCommands.store({:group, group_id, sender_uuid}, :unschedule)
          YonderbookClubs.Signal.impl().send_message(
            group_id,
            "Which book would you like to remove? Reply with the title."
          )
          :ok

        cmd when cmd in ["suggest", "remove", "help"] ->
          YonderbookClubs.Signal.impl().send_message(
            group_id,
            "That one works in DMs! Send me a direct message to #{cmd}."
          )
          :ok

        "suggest " <> _ ->
          YonderbookClubs.Signal.impl().send_message(
            group_id,
            "Suggestions are kept secret until voting! Send me a DM instead."
          )
          :ok

        _ ->
          maybe_resume_group_pending(group_id, sender_uuid, stripped)
      end

    if result != :noop, do: maybe_send_welcome(group_id)

    result
  end

  defp handle_start_vote_with_budget(group_id, sender_uuid, rest) do
    case parse_vote_budget(rest) do
      {:ok, n} ->
        handle_start_vote(group_id, n)

      {:error, _} ->
        PendingCommands.store({:group, group_id, sender_uuid}, :start_vote)
        YonderbookClubs.Signal.impl().send_message(
          group_id,
          "Hmm, that doesn't look like a number! Pick something between 1 and 50."
        )
        :ok
    end
  end

  defp handle_start_vote_prompt(group_id, sender_uuid) do
    case Clubs.get_club_by_group_id(group_id) do
      %{voting_active: true} ->
        YonderbookClubs.Signal.impl().send_message(
          group_id,
          "There's already a vote going! Say \"close vote\" to end it first."
        )
        {:error, :already_voting}

      _ ->
        PendingCommands.store({:group, group_id, sender_uuid}, :start_vote)
        YonderbookClubs.Signal.impl().send_message(
          group_id,
          "How many books should win? Reply with a number!"
        )
        :ok
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
        "Only one suggestion so far! DM me another one and I'll be ready to kick off the poll."
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
          "There's already a vote going! Say \"close vote\" to end it first."
        )
        {:error, :already_voting}
    end
  end

  defp get_suggestions_for_vote(club, group_id) do
    case Suggestions.list_suggestions(club) do
      [] ->
        YonderbookClubs.Signal.impl().send_message(
          group_id,
          "No suggestions yet! DM me to add one: \"suggest Title by Author\""
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
        case Clubs.deactivate_voting(club) do
          {:ok, _club} ->
            Polls.get_latest_active_polls(club)
            |> Enum.each(&Polls.close_poll/1)

            YonderbookClubs.Signal.impl().send_message(group_id, "Vote closed! Say /results to see how it turned out.")

          {:error, :not_voting} ->
            YonderbookClubs.Signal.impl().send_message(group_id, "There's no vote going on right now.")
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
            signal.send_message(group_id, "No polls yet! Get things started with /start vote.")
            :ok

          [first | _] = polls ->
            results = Polls.get_combined_results(polls)
            signal.send_message(group_id, Formatter.format_results(results, first.status))
            :ok
        end
    end
  end

  # --- Schedule ---

  @title_by_author_regex ~r/^(.+?)\s+by\s+(.+)$/i

  defp handle_schedule(group_id, sender_uuid, text) do
    signal = YonderbookClubs.Signal.impl()

    cond do
      Regex.match?(@schedule_with_author_regex, text) ->
        [_, title, author, time_label] = Regex.run(@schedule_with_author_regex, text)
        save_reading(group_id, String.trim(title), String.trim(author), String.trim(time_label))

      Regex.match?(@schedule_without_author_regex, text) ->
        [_, title, time_label] = Regex.run(@schedule_without_author_regex, text)
        save_reading(group_id, String.trim(title), nil, String.trim(time_label))

      true ->
        # Missing "for <time>" — extract what we have and ask for the time
        {title, author} = extract_title_author(text)
        PendingCommands.store({:group, group_id, sender_uuid}, {:schedule, title, author})
        signal.send_message(group_id, "For when? Reply with the time (e.g., January, March\u2013April)!")
        :ok
    end
  end

  defp extract_title_author(text) do
    case Regex.run(@title_by_author_regex, text) do
      [_, title, author] -> {String.trim(title), String.trim(author)}
      nil -> {String.trim(text), nil}
    end
  end

  defp save_reading(group_id, title, author, time_label) do
    signal = YonderbookClubs.Signal.impl()

    case get_or_create_club_for_group(group_id) do
      {:ok, club} ->
        attrs = %{title: title, author: author, time_label: time_label}

        case Readings.create_reading(club, attrs) do
          {:ok, reading} ->
            signal.send_message(group_id, Formatter.format_schedule_confirmation(reading))
            :ok

          {:error, :limit_reached} ->
            signal.send_message(group_id, "The schedule is full (50 max)! Remove one first with /unschedule to make room.")
            :ok

          {:error, changeset} ->
            Sentry.capture_message("Reading save failed",
              extra: %{group_id: group_id, title: title, changeset: inspect(changeset)}
            )
            signal.send_message(group_id, "Oops, something went wrong! Give it another try in a minute.")
            :ok
        end

      {:error, reason} ->
        Sentry.capture_message("Club creation failed during schedule",
          extra: %{group_id: group_id, reason: inspect(reason)}
        )
        signal.send_message(group_id, "Oops, something went wrong! Give it another try in a minute.")
        :ok
    end
  end

  defp handle_show_schedule(group_id) do
    signal = YonderbookClubs.Signal.impl()

    case Clubs.get_club_by_group_id(group_id) do
      nil ->
        signal.send_message(group_id, Formatter.format_schedule([]))
        :ok

      club ->
        readings = Readings.list_readings(club)
        signal.send_message(group_id, Formatter.format_schedule(readings))
        :ok
    end
  end

  defp handle_unschedule(group_id, sender_uuid, "") do
    PendingCommands.store({:group, group_id, sender_uuid}, :unschedule)
    YonderbookClubs.Signal.impl().send_message(
      group_id,
      "Which book would you like to remove? Reply with the title."
    )
    :ok
  end

  defp handle_unschedule(group_id, _sender_uuid, title) do
    signal = YonderbookClubs.Signal.impl()

    case Clubs.get_club_by_group_id(group_id) do
      nil ->
        signal.send_message(group_id, "Nothing on the schedule yet!")
        :ok

      club ->
        case Readings.remove_reading(club, title) do
          {:ok, reading} ->
            signal.send_message(group_id, "Got it! Removed #{reading.title} from the schedule.")
            :ok

          {:error, :not_found} ->
            signal.send_message(group_id, "Hmm, I couldn't find \"#{title}\" on the schedule. Check the title and try again!")
            :ok
        end
    end
  end

  defp maybe_resume_group_pending(group_id, sender_uuid, text) do
    case PendingCommands.pop({:group, group_id, sender_uuid}) do
      result when result in [:miss, :expired] ->
        :noop

      {:ok, :start_vote} ->
        case parse_vote_budget(text) do
          {:ok, n} -> handle_start_vote(group_id, n)
          {:error, _} -> :noop
        end

      {:ok, :unschedule} ->
        handle_unschedule(group_id, sender_uuid, String.trim(text))

      {:ok, {:schedule, title, author}} ->
        save_reading(group_id, title, author, String.trim(text))
    end
  end

  defp maybe_send_welcome(group_id) do
    case Clubs.get_club_by_group_id(group_id) do
      %{onboarded: false} = club ->
        Clubs.mark_onboarded(club)
        YonderbookClubs.Signal.impl().send_message(group_id, Formatter.format_welcome())

      _ ->
        :ok
    end
  end
end
