defmodule YonderbookClubs.Bot.Router.DMCommands do
  @moduledoc """
  Handles DM commands: help, suggest, remove, suggestions.
  """

  alias YonderbookClubs.Bot.Formatter
  alias YonderbookClubs.Bot.PendingCommands
  alias YonderbookClubs.Bot.Router.Helpers
  alias YonderbookClubs.Clubs
  alias YonderbookClubs.Readings
  alias YonderbookClubs.Suggestions

  require Logger

  @title_by_author_regex ~r/^(.+?)\s+by\s+(.+)$/i
  @author_comma_title_regex ~r/^(.+?),\s+(.+)$/
  @club_prefix_regex ~r/^#(\d+)\s+/
  @max_input_length 500

  @fallback_messages [
    "Hmm, I'm not sure what you mean. Try /help to see what I can do!",
    "I didn't quite get that — say /help if you need a hand!",
    "Not sure I follow! /help has the full list of things I can do."
  ]

  @spec handle(String.t(), String.t(), String.t()) :: :ok | :noop | {:error, atom()}
  def handle(sender_uuid, sender_name, text) do
    signal = YonderbookClubs.Signal.impl()
    stripped = Helpers.strip_slash(text)

    case String.downcase(stripped) do
      "help" ->
        signal.send_message(sender_uuid, Formatter.format_help(:dm))
        :ok

      cmd when cmd in ["remove", "r"] ->
        handle_remove(sender_uuid)

      "remove " <> rest ->
        handle_remove(sender_uuid, parse_club_number(rest))

      "r " <> rest ->
        handle_remove(sender_uuid, parse_club_number(rest))

      "suggestions" ->
        handle_suggestions(sender_uuid)

      "suggestions " <> rest ->
        handle_suggestions(sender_uuid, parse_club_number(rest))

      "schedule " <> _ ->
        handle_schedule(sender_uuid, stripped)

      "schedule" ->
        handle_show_schedule(sender_uuid)

      "unschedule " <> _ ->
        handle_unschedule(sender_uuid, stripped)

      "unschedule" ->
        handle_unschedule(sender_uuid, "unschedule")

      "suggest " <> _ ->
        handle_suggest(sender_uuid, sender_name, stripped)

      "s " <> _ ->
        expanded = "suggest" <> String.slice(stripped, 1..-1//1)
        handle_suggest(sender_uuid, sender_name, expanded)

      cmd when cmd in ["suggest", "s"] ->
        PendingCommands.store(sender_uuid, {:suggest_text, sender_name})
        signal.send_message(sender_uuid, "What would you like to suggest? Send me a title, like \"Piranesi by Susanna Clarke\".")
        :ok

      cmd when cmd in ["start vote", "start poll", "close vote", "close poll",
                       "results"] ->
        redirect_to_group(signal, sender_uuid)
        :ok

      "start vote " <> _ ->
        redirect_to_group(signal, sender_uuid)
        :ok

      "start poll " <> _ ->
        redirect_to_group(signal, sender_uuid)
        :ok

      _ ->
        case maybe_resume_pending(sender_uuid, sender_name, stripped) do
          :no_pending ->
            handle_fallback(signal, sender_uuid, String.downcase(stripped))
            :ok

          result ->
            result
        end
    end
  end

  defp redirect_to_group(signal, sender_uuid) do
    club_hint =
      case Suggestions.sender_club_name(sender_uuid) do
        nil -> "the group chat"
        name -> "the #{name} group chat"
      end

    signal.send_message(
      sender_uuid,
      "That one's a group chat command! Head over to #{club_hint} to use it. Say /help to see what works here."
    )
  end

  defp handle_fallback(signal, sender_uuid, downcased) do
    case Helpers.fuzzy_match_command(downcased, :dm) do
      {:ok, command} ->
        signal.send_message(sender_uuid, "Did you mean /#{command}?")

      :no_match ->
        if Suggestions.has_suggestions_from?(sender_uuid) do
          signal.send_message(sender_uuid, Enum.random(@fallback_messages))
        else
          signal.send_message(sender_uuid, Formatter.format_help(:dm))
        end
    end
  end

  defp handle_remove(sender_uuid, club_number \\ nil) do
    with_club(sender_uuid, club_number, :remove, fn club ->
      signal = YonderbookClubs.Signal.impl()

      case Suggestions.remove_latest_suggestion(club.id, sender_uuid) do
        {:ok, suggestion} ->
          signal.send_message(
            sender_uuid,
            "Done! Removed #{suggestion.title} by #{suggestion.author}."
          )

          :ok

        {:error, :not_found} ->
          signal.send_message(sender_uuid, "You don't have any suggestions to remove right now.")
          :ok
      end
    end)
  end

  defp handle_suggestions(sender_uuid, club_number \\ nil) do
    with_club(sender_uuid, club_number, :suggestions, fn club ->
      suggestions = Suggestions.list_suggestions(club)
      YonderbookClubs.Signal.impl().send_message(sender_uuid, Formatter.format_suggestions_list(suggestions))
      :ok
    end)
  end

  @schedule_with_author_regex ~r/^(.+)\s+by\s+(.+)\s+for\s+(.+)$/i
  @schedule_without_author_regex ~r/^(.+)\s+for\s+(.+)$/i

  defp handle_schedule(sender_uuid, text) do
    schedule_text = String.slice(text, 9..-1//1) |> String.trim()

    with_club(sender_uuid, nil, {:dm_schedule, schedule_text}, fn club ->
      handle_schedule_for_club(sender_uuid, club, schedule_text)
    end)
  end

  defp handle_schedule_for_club(sender_uuid, club, schedule_text) do
    signal = YonderbookClubs.Signal.impl()

    cond do
      Regex.match?(@schedule_with_author_regex, schedule_text) ->
        [_, title, author, time_label] = Regex.run(@schedule_with_author_regex, schedule_text)
        save_reading(sender_uuid, club, String.trim(title), String.trim(author), String.trim(time_label))

      Regex.match?(@schedule_without_author_regex, schedule_text) ->
        [_, title, time_label] = Regex.run(@schedule_without_author_regex, schedule_text)
        save_reading(sender_uuid, club, String.trim(title), nil, String.trim(time_label))

      true ->
        {title, author} = extract_title_author(schedule_text)
        PendingCommands.store(sender_uuid, {:dm_schedule_time, club.id, title, author})
        signal.send_message(sender_uuid, "For when? Reply with the time (e.g., January, March\u2013April)!")
        :ok
    end
  end

  defp handle_unschedule(sender_uuid, text) do
    unschedule_text =
      case text do
        "unschedule" -> ""
        _ -> String.slice(text, 11..-1//1) |> String.trim()
      end

    with_club(sender_uuid, nil, {:dm_unschedule, unschedule_text}, fn club ->
      signal = YonderbookClubs.Signal.impl()

      if unschedule_text == "" do
        PendingCommands.store(sender_uuid, {:dm_unschedule_title, club.id})
        signal.send_message(sender_uuid, "Which book? Reply with the title.")
        :ok
      else
        case Readings.remove_reading(club, unschedule_text) do
          {:ok, reading} ->
            signal.send_message(sender_uuid, "Got it! Removed #{reading.title} from the schedule.")
            :ok

          {:error, :not_found} ->
            signal.send_message(sender_uuid, "Hmm, I couldn't find \"#{unschedule_text}\" on the schedule. Check the title and try again!")
            :ok
        end
      end
    end)
  end

  defp handle_unschedule_by_title(sender_uuid, club, title) do
    signal = YonderbookClubs.Signal.impl()

    case Readings.remove_reading(club, title) do
      {:ok, reading} ->
        signal.send_message(sender_uuid, "Got it! Removed #{reading.title} from the schedule.")
        :ok

      {:error, :not_found} ->
        signal.send_message(sender_uuid, "Hmm, I couldn't find \"#{title}\" on the schedule. Check the title and try again!")
        :ok
    end
  end

  defp save_reading(sender_uuid, club, title, author, time_label) do
    signal = YonderbookClubs.Signal.impl()

    case Readings.create_reading(club, %{title: title, author: author, time_label: time_label}) do
      {:ok, reading} ->
        signal.send_message(sender_uuid, Formatter.format_schedule_confirmation(reading))
        :ok

      {:error, :limit_reached} ->
        signal.send_message(sender_uuid, "The schedule is full (50 max)! Remove one first with /unschedule to make room.")
        :ok

      {:error, changeset} ->
        Sentry.capture_message("Reading save failed",
          extra: %{sender_uuid: sender_uuid, title: title, changeset: inspect(changeset)}
        )
        signal.send_message(sender_uuid, "Oops, something went wrong! Give it another try in a minute.")
        :ok
    end
  end

  defp extract_title_author(text) do
    case Regex.run(@title_by_author_regex, text) do
      [_, title, author] -> {String.trim(title), String.trim(author)}
      nil -> {String.trim(text), nil}
    end
  end

  defp handle_show_schedule(sender_uuid) do
    with_club(sender_uuid, nil, :schedule, fn club ->
      readings = Readings.list_readings(club)
      YonderbookClubs.Signal.impl().send_message(sender_uuid, Formatter.format_schedule(readings))
      :ok
    end)
  end

  defp handle_suggest(sender_uuid, sender_name, text) do
    # Strip the "suggest " prefix (case-insensitive)
    suggestion_text = String.slice(text, 8..-1//1) |> String.trim()

    # Check for #N club prefix
    {club_number, suggestion_text} = extract_club_prefix(suggestion_text)

    with_club(sender_uuid, club_number, {:suggest, sender_name, suggestion_text}, fn club ->
      process_suggestion(sender_uuid, sender_name, club, suggestion_text)
    end)
  end

  defp extract_club_prefix(text) do
    case Regex.run(@club_prefix_regex, text) do
      [full_match, number_str] ->
        {n, ""} = Integer.parse(number_str)
        remaining = String.slice(text, String.length(full_match)..-1//1)
        {n, remaining}

      nil ->
        {nil, text}
    end
  end

  defp process_suggestion(sender_uuid, sender_name, club, text) do
    cond do
      text == "" ->
        YonderbookClubs.Signal.impl().send_message(
          sender_uuid,
          "What would you like to suggest? Try something like: /suggest Piranesi by Susanna Clarke"
        )
        :ok

      String.length(text) > @max_input_length ->
        YonderbookClubs.Signal.impl().send_message(
          sender_uuid,
          "That's a bit long! Try just the title and author."
        )
        :ok

      String.starts_with?(String.downcase(text), "ai:") ->
        ai_text = String.slice(text, 3..-1//1) |> String.trim()
        handle_ai_suggestion(sender_uuid, sender_name, club, ai_text)

      isbn?(text) ->
        isbn = YonderbookClubs.Books.normalize_isbn(text)
        handle_isbn_suggestion(sender_uuid, sender_name, club, isbn)

      Regex.match?(@title_by_author_regex, text) ->
        [_, title, author] = Regex.run(@title_by_author_regex, text)
        handle_title_author_suggestion(sender_uuid, sender_name, club, String.trim(title), String.trim(author))

      Regex.match?(@author_comma_title_regex, text) ->
        [_, author, title] = Regex.run(@author_comma_title_regex, text)
        handle_title_author_suggestion(sender_uuid, sender_name, club, String.trim(title), String.trim(author))

      true ->
        handle_freetext_suggestion(sender_uuid, sender_name, club, text)
    end
  end

  defp handle_freetext_suggestion(sender_uuid, sender_name, club, text) do
    signal = YonderbookClubs.Signal.impl()

    case search_freetext_with_fallback(text) do
      {:ok, book_data, alternatives} ->
        PendingCommands.store(sender_uuid, {:book_confirm, sender_name, club.id, book_data, alternatives, text})
        signal.send_message(sender_uuid, Formatter.format_book_confirm(book_data))
        :ok

      {:error, _reason} ->
        PendingCommands.store(sender_uuid, {:ai_confirm, sender_name, club.id, text})
        signal.send_message(
          sender_uuid,
          "I couldn't find that one. Want me to use AI to look it up? Reply yes or no."
        )
        :ok
    end
  end

  defp search_freetext_with_fallback(text) do
    case search_and_check_relevance(text) do
      {:ok, _, _} = result ->
        result

      {:error, _} ->
        collapsed = YonderbookClubs.Books.collapse_title(text)
        if collapsed != text, do: search_and_check_relevance(collapsed), else: {:error, :not_found}
    end
  end

  defp search_and_check_relevance(query) do
    case YonderbookClubs.Books.search_general_multi(query) do
      {:ok, book_data, alternatives} ->
        if title_relevant?(query, book_data.title) do
          {:ok, book_data, alternatives}
        else
          promote_relevant_alternative(query, alternatives)
        end

      error ->
        error
    end
  end

  defp promote_relevant_alternative(query, alternatives) do
    case Enum.split_with(alternatives, fn alt -> title_relevant?(query, alt.title) end) do
      {[match | rest_relevant], non_relevant} ->
        case YonderbookClubs.Books.resolve_preview(match) do
          {:ok, book_data} -> {:ok, book_data, rest_relevant ++ non_relevant}
          {:error, _} -> {:error, :not_relevant}
        end

      {[], _} ->
        {:error, :not_relevant}
    end
  end

  defp title_relevant?(_query, nil), do: false
  defp title_relevant?(query, title) do
    stop_words = ~w(the a an of and in on by for to is it)
    query_words = query |> String.downcase() |> String.split(~r/\s+/) |> MapSet.new() |> MapSet.difference(MapSet.new(stop_words))
    title_words = title |> String.downcase() |> String.split(~r/\s+/) |> MapSet.new() |> MapSet.difference(MapSet.new(stop_words))
    overlap = MapSet.intersection(query_words, title_words) |> MapSet.size()
    overlap > 0
  end

  defp isbn?(text) do
    stripped = String.replace(text, "-", "")
    Regex.match?(~r/^(\d{10}|\d{9}X|\d{13})$/i, stripped)
  end

  defp handle_ai_suggestion(sender_uuid, sender_name, club, text, rejected_titles \\ [], opts \\ []) do
    signal = YonderbookClubs.Signal.impl()

    if Keyword.get(opts, :retry, false) do
      signal.send_message(sender_uuid, "Let me try again...")
    else
      signal.send_message(sender_uuid, "Looking that up for you...")
    end

    case YonderbookClubs.Books.search_ai(text, rejected_titles) do
      {:ok, book_data} ->
        new_rejected = rejected_titles ++ [book_data.title]
        PendingCommands.store(sender_uuid, {:book_confirm, sender_name, club.id, book_data, [], text, new_rejected})
        signal.send_message(sender_uuid, Formatter.format_book_confirm(book_data))
        :ok

      {:error, {tag, detail} = reason} when tag in [:ai_transport_error, :ai_http_error] ->
        Sentry.capture_message("AI book search failed",
          extra: %{sender_uuid: sender_uuid, reason: inspect(reason)},
          tags: %{ai_error_type: to_string(tag), ai_error_detail: inspect(detail)}
        )
        signal.send_message(
          sender_uuid,
          "Something went wrong reaching the AI service. Give it another try in a minute!"
        )
        :ok

      {:error, reason} ->
        {error_type, error_detail} =
          case reason do
            {:ai_http_error, status} -> {"ai_http_error", to_string(status)}
            {:ai_transport_error, detail} -> {"ai_transport_error", inspect(detail)}
            other -> {"other", inspect(other)}
          end

        Sentry.capture_message("AI book search failed",
          extra: %{sender_uuid: sender_uuid, reason: inspect(reason)},
          tags: %{ai_error_type: error_type, ai_error_detail: error_detail}
        )
        signal.send_message(
          sender_uuid,
          "I still couldn't find that one. Try /suggest Title by Author instead!"
        )
        :ok
    end
  end

  defp handle_isbn_suggestion(sender_uuid, sender_name, club, isbn) do
    signal = YonderbookClubs.Signal.impl()

    case YonderbookClubs.Books.search_isbn(isbn) do
      {:ok, book_data} ->
        save_suggestion(sender_uuid, sender_name, club, book_data)

      {:error, _reason} ->
        signal.send_message(
          sender_uuid,
          "I couldn't find that ISBN. Double-check the number and try again!"
        )
        :ok
    end
  end

  defp handle_title_author_suggestion(sender_uuid, sender_name, club, title, author) do
    signal = YonderbookClubs.Signal.impl()

    case YonderbookClubs.Books.search_multi(title, author) do
      {:ok, book_data, alternatives} ->
        PendingCommands.store(sender_uuid, {:book_confirm, sender_name, club.id, book_data, alternatives, "#{title} by #{author}"})
        signal.send_message(sender_uuid, Formatter.format_book_confirm(book_data))
        :ok

      {:error, _reason} ->
        PendingCommands.store(sender_uuid, {:ai_confirm, sender_name, club.id, "#{title} by #{author}"})
        signal.send_message(
          sender_uuid,
          "I couldn't find that one. Want me to use AI to look it up? Reply yes or no."
        )
        :ok
    end
  end

  defp save_suggestion(sender_uuid, sender_name, club, book_data) do
    signal = YonderbookClubs.Signal.impl()

    attrs =
      book_data
      |> YonderbookClubs.Books.enrich_with_description()
      |> Map.put(:signal_sender_uuid, sender_uuid)
      |> Map.put(:signal_sender_name, sender_name)

    case Suggestions.create_suggestion(club, attrs) do
      {:ok, :duplicate} ->
        signal.send_message(sender_uuid, "Good taste! That one's already on the list.")
        :ok

      {:ok, suggestion} ->
        confirmation = Formatter.format_confirmation(suggestion, club.name)
        cover_paths = Helpers.download_covers([suggestion])

        signal.send_message(sender_uuid, confirmation, cover_paths)
        Helpers.cleanup_covers(cover_paths)

        :ok

      {:error, changeset} ->
        Sentry.capture_message("Suggestion save failed",
          extra: %{sender_uuid: sender_uuid, changeset: inspect(changeset)}
        )
        signal.send_message(sender_uuid, "Oops, something went wrong! Give it another try in a minute.")
        :ok
    end
  end

  # --- Club Resolution ---

  defp with_club(sender_uuid, club_number, pending_cmd, fun) do
    signal = YonderbookClubs.Signal.impl()

    case resolve_club(sender_uuid, club_number) do
      {:ok, club} ->
        fun.(club)

      {:error, :no_clubs} ->
        signal.send_message(sender_uuid, "I'm not in any of your group chats yet! Add me to a group first, then you can start suggesting books.")
        :ok

      {:error, :signal_unavailable} ->
        Sentry.capture_message("Signal unavailable during club resolution",
          extra: %{sender_uuid: sender_uuid}
        )
        signal.send_message(sender_uuid, "Oops, something went wrong! Give it another try in a minute.")
        :ok

      {:error, :multiple_clubs, clubs} ->
        if pending_cmd, do: PendingCommands.store(sender_uuid, pending_cmd)
        signal.send_message(sender_uuid, Formatter.format_club_list(clubs))
        :ok

      {:error, :invalid_club_number} ->
        signal.send_message(sender_uuid, "That club number doesn't exist! Say /suggest to see the list.")
        :ok
    end
  end

  defp resolve_club(_sender_uuid, club_number) do
    case YonderbookClubs.Signal.impl().list_groups() do
      {:ok, groups} when groups != [] ->
        # Filter out groups the bot is no longer a member of
        active_groups = Enum.filter(groups, fn g -> g["isMember"] != false end)

        case active_groups do
          [] ->
            {:error, :no_clubs}

          _ ->
            group_ids = Enum.map(active_groups, & &1["id"])
            existing = Clubs.get_clubs_by_group_ids(group_ids)
            existing_ids = MapSet.new(existing, & &1.signal_group_id)

            new_clubs =
              active_groups
              |> Enum.reject(fn g -> MapSet.member?(existing_ids, g["id"]) end)
              |> Enum.map(fn g ->
                {:ok, club} = Clubs.get_or_create_club(g["id"], g["name"] || "Book Club")
                Clubs.Cache.put(g["id"], club)
                club
              end)

            clubs = existing ++ new_clubs
            pick_club(clubs, club_number)
        end

      {:ok, []} ->
        {:error, :no_clubs}

      {:error, reason} ->
        Logger.error("Failed to list Signal groups: #{inspect(reason)}")
        {:error, :signal_unavailable}
    end
  end

  defp pick_club([], _club_number), do: {:error, :no_clubs}
  defp pick_club([club], nil), do: {:ok, club}
  defp pick_club(clubs, nil) when length(clubs) > 1, do: {:error, :multiple_clubs, clubs}

  defp pick_club(clubs, n) when is_integer(n) do
    if n >= 1 and n <= length(clubs) do
      {:ok, Enum.at(clubs, n - 1)}
    else
      {:error, :invalid_club_number}
    end
  end

  defp maybe_resume_pending(sender_uuid, _sender_name, text) do
    case PendingCommands.pop(sender_uuid) do
      :miss ->
        :no_pending

      :expired ->
        :no_pending

      {:ok, {:suggest_text, sender_name}} ->
        # Bare /suggest was sent; treat this entire message as the suggestion
        handle_suggest(sender_uuid, sender_name, "suggest " <> String.trim(text))

      {:ok, {:ai_confirm, sender_name, club_id, original_text, prior_rejected}} ->
        handle_ai_confirm(sender_uuid, sender_name, club_id, original_text, text, prior_rejected)

      {:ok, {:ai_confirm, sender_name, club_id, original_text}} ->
        handle_ai_confirm(sender_uuid, sender_name, club_id, original_text, text, [])

      {:ok, {:book_confirm, sender_name, club_id, book_data, alternatives, original_query, rejected}} ->
        handle_book_confirm(sender_uuid, sender_name, club_id, book_data, alternatives, original_query, text, rejected)

      {:ok, {:book_confirm, sender_name, club_id, book_data, alternatives, original_query}} ->
        handle_book_confirm(sender_uuid, sender_name, club_id, book_data, alternatives, original_query, text, nil)

      {:ok, {:book_pick, sender_name, club_id, alternatives, original_query}} ->
        handle_book_pick(sender_uuid, sender_name, club_id, alternatives, original_query, text)

      {:ok, {:dm_schedule_time, club_id, title, author}} ->
        club = Clubs.get_club!(club_id)
        save_reading(sender_uuid, club, title, author, String.trim(text))

      {:ok, {:dm_unschedule_title, club_id}} ->
        club = Clubs.get_club!(club_id)
        handle_unschedule_by_title(sender_uuid, club, String.trim(text))

      {:ok, pending_cmd} ->
        # All other pending commands expect a club number
        case parse_club_number(String.trim(text)) do
          n when is_integer(n) -> dispatch_pending(sender_uuid, pending_cmd, n)
          nil -> :no_pending
        end
    end
  end

  defp handle_ai_confirm(sender_uuid, sender_name, club_id, original_text, reply, prior_rejected) do
    case String.downcase(String.trim(reply)) do
      yes when yes in ["yes", "y"] ->
        club = Clubs.get_club!(club_id)
        handle_ai_suggestion(sender_uuid, sender_name, club, original_text, prior_rejected)

      no when no in ["no", "n"] ->
        YonderbookClubs.Signal.impl().send_message(
          sender_uuid,
          "No worries! Try /suggest Title by Author instead."
        )
        :ok

      _ ->
        :no_pending
    end
  end

  @max_ai_retries 3

  defp handle_book_confirm(sender_uuid, sender_name, club_id, book_data, alternatives, original_query, reply, rejected) do
    signal = YonderbookClubs.Signal.impl()

    case String.downcase(String.trim(reply)) do
      yes when yes in ["yes", "y"] ->
        club = Clubs.get_club!(club_id)
        save_suggestion(sender_uuid, sender_name, club, book_data)

      no when no in ["no", "n"] ->
        case alternatives do
          [] when is_list(rejected) and length(rejected) < @max_ai_retries ->
            club = Clubs.get_club!(club_id)
            handle_ai_suggestion(sender_uuid, sender_name, club, original_query, rejected, retry: true)

          [] when is_list(rejected) ->
            PendingCommands.store(sender_uuid, {:suggest_text, sender_name})
            signal.send_message(sender_uuid, "I'm stumped! Want to try again? Send me the title and author, like: Piranesi by Susanna Clarke")
            :ok

          [] ->
            PendingCommands.store(sender_uuid, {:ai_confirm, sender_name, club_id, original_query, [book_data.title]})
            signal.send_message(sender_uuid, "No other matches found. Want me to use AI to look it up? Reply yes or no.")
            :ok

          alts ->
            PendingCommands.store(sender_uuid, {:book_pick, sender_name, club_id, alts, original_query})
            signal.send_message(sender_uuid, Formatter.format_book_alternatives(alts))
            :ok
        end

      _ ->
        :no_pending
    end
  end

  defp handle_book_pick(sender_uuid, sender_name, club_id, alternatives, original_query, reply) do
    signal = YonderbookClubs.Signal.impl()
    trimmed = String.trim(reply)

    case Integer.parse(trimmed) do
      {n, ""} when n >= 1 and n <= length(alternatives) ->
        chosen = Enum.at(alternatives, n - 1)

        case YonderbookClubs.Books.resolve_preview(chosen) do
          {:ok, book_data} ->
            club = Clubs.get_club!(club_id)
            save_suggestion(sender_uuid, sender_name, club, book_data)

          {:error, _} ->
            signal.send_message(sender_uuid, "Something went wrong looking that up. Try /suggest again!")
            :ok
        end

      _ ->
        rejected = Enum.map(alternatives, & &1.title) |> Enum.reject(&is_nil/1)
        PendingCommands.store(sender_uuid, {:ai_confirm, sender_name, club_id, original_query, rejected})
        signal.send_message(sender_uuid, "None of those right? Want me to use AI to look it up? Reply yes or no.")
        :ok
    end
  end

  defp dispatch_pending(sender_uuid, :remove, n), do: handle_remove(sender_uuid, n)
  defp dispatch_pending(sender_uuid, :suggestions, n), do: handle_suggestions(sender_uuid, n)
  defp dispatch_pending(sender_uuid, :schedule, n), do: handle_show_schedule_with_club(sender_uuid, n)
  defp dispatch_pending(sender_uuid, {:suggest, name, text}, n), do: handle_suggest_with_club(sender_uuid, name, text, n)
  defp dispatch_pending(sender_uuid, {:dm_schedule, text}, n) do
    with_club(sender_uuid, n, {:dm_schedule, text}, fn club ->
      handle_schedule_for_club(sender_uuid, club, text)
    end)
  end
  defp dispatch_pending(sender_uuid, {:dm_unschedule, text}, n) do
    with_club(sender_uuid, n, {:dm_unschedule, text}, fn club ->
      if text == "" do
        PendingCommands.store(sender_uuid, {:dm_unschedule_title, club.id})
        YonderbookClubs.Signal.impl().send_message(sender_uuid, "Which book? Reply with the title.")
        :ok
      else
        handle_unschedule_by_title(sender_uuid, club, text)
      end
    end)
  end

  defp handle_suggest_with_club(sender_uuid, sender_name, suggestion_text, club_number) do
    with_club(sender_uuid, club_number, {:suggest, sender_name, suggestion_text}, fn club ->
      process_suggestion(sender_uuid, sender_name, club, suggestion_text)
    end)
  end

  defp handle_show_schedule_with_club(sender_uuid, club_number) do
    with_club(sender_uuid, club_number, :schedule, fn club ->
      readings = Readings.list_readings(club)
      YonderbookClubs.Signal.impl().send_message(sender_uuid, Formatter.format_schedule(readings))
      :ok
    end)
  end

  defp parse_club_number(text) do
    trimmed = String.trim(text)

    case Regex.run(~r/^#?(\d+)$/, trimmed) do
      [_, n_str] ->
        {n, ""} = Integer.parse(n_str)
        n

      nil ->
        nil
    end
  end
end
