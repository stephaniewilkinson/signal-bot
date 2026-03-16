defmodule YonderbookClubs.Bot.Router.DMCommands do
  @moduledoc """
  Handles DM commands: help, suggest, remove, suggestions.
  """

  alias YonderbookClubs.Bot.Formatter
  alias YonderbookClubs.Bot.Router.Helpers
  alias YonderbookClubs.Clubs
  alias YonderbookClubs.Readings
  alias YonderbookClubs.Suggestions

  require Logger

  @title_by_author_regex ~r/^(.+?)\s+by\s+(.+)$/i
  @author_comma_title_regex ~r/^(.+?),\s+(.+)$/
  @club_prefix_regex ~r/^#(\d+)\s+/
  @max_input_length 500

  @spec handle(String.t(), String.t(), String.t()) :: :ok | :noop | {:error, atom()}
  def handle(sender_uuid, sender_name, text) do
    signal = YonderbookClubs.Signal.impl()
    stripped = Helpers.strip_slash(text)

    case String.downcase(stripped) do
      "help" ->
        signal.send_message(sender_uuid, Formatter.format_help())
        :ok

      "remove" ->
        handle_remove(sender_uuid)

      "suggestions" ->
        handle_suggestions(sender_uuid)

      "schedule" ->
        handle_show_schedule(sender_uuid)

      "suggest " <> _ ->
        handle_suggest(sender_uuid, sender_name, stripped)

      "suggest" ->
        signal.send_message(sender_uuid, "Suggest what? Try: /suggest Piranesi by Susanna Clarke")
        :ok

      _ ->
        signal.send_message(sender_uuid, "I didn't catch that. Say /help for help.")
        :ok
    end
  end

  defp handle_remove(sender_uuid) do
    with_club(sender_uuid, fn club ->
      signal = YonderbookClubs.Signal.impl()

      case Suggestions.remove_latest_suggestion(club.id, sender_uuid) do
        {:ok, suggestion} ->
          signal.send_message(
            sender_uuid,
            "Removed #{suggestion.title} by #{suggestion.author}."
          )

          :ok

        {:error, :not_found} ->
          signal.send_message(sender_uuid, "You don't have any suggestions to remove.")
          :ok
      end
    end)
  end

  defp handle_suggestions(sender_uuid) do
    with_club(sender_uuid, fn club ->
      suggestions = Suggestions.list_suggestions(club)
      YonderbookClubs.Signal.impl().send_message(sender_uuid, Formatter.format_suggestions_list(suggestions))
      :ok
    end)
  end

  defp handle_show_schedule(sender_uuid) do
    with_club(sender_uuid, fn club ->
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

    with_club(sender_uuid, club_number, fn club ->
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
          "Suggest what? Try: /suggest Piranesi by Susanna Clarke"
        )
        :ok

      String.length(text) > @max_input_length ->
        YonderbookClubs.Signal.impl().send_message(
          sender_uuid,
          "That's too long. Try just the title and author."
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

    case YonderbookClubs.Books.search_general(text) do
      {:ok, book_data} ->
        save_suggestion(sender_uuid, sender_name, club, book_data)

      {:error, _reason} ->
        signal.send_message(
          sender_uuid,
          "Couldn't find that book. Try:\n/suggest Title by Author\n/suggest Author, Title"
        )
        :ok
    end
  end

  defp isbn?(text) do
    stripped = String.replace(text, "-", "")
    Regex.match?(~r/^(\d{10}|\d{9}X|\d{13})$/i, stripped)
  end

  defp handle_ai_suggestion(sender_uuid, sender_name, club, text) do
    signal = YonderbookClubs.Signal.impl()

    case YonderbookClubs.Books.search_ai(text) do
      {:ok, book_data} ->
        save_suggestion(sender_uuid, sender_name, club, book_data)

      {:error, _reason} ->
        signal.send_message(
          sender_uuid,
          "Couldn't find that book. Check the spelling and try again."
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
          "Couldn't find that ISBN. Check the number and try again."
        )
        :ok
    end
  end

  defp handle_title_author_suggestion(sender_uuid, sender_name, club, title, author) do
    signal = YonderbookClubs.Signal.impl()

    case YonderbookClubs.Books.search(title, author) do
      {:ok, book_data} ->
        save_suggestion(sender_uuid, sender_name, club, book_data)

      {:error, _reason} ->
        signal.send_message(
          sender_uuid,
          "Couldn't find that book. Check the spelling and try again."
        )

        :ok
    end
  end

  defp save_suggestion(sender_uuid, sender_name, club, book_data) do
    signal = YonderbookClubs.Signal.impl()

    attrs =
      book_data
      |> Map.put(:signal_sender_uuid, sender_uuid)
      |> Map.put(:signal_sender_name, sender_name)

    case Suggestions.create_suggestion(club, attrs) do
      {:ok, :duplicate} ->
        signal.send_message(sender_uuid, "That one's already on the list.")
        :ok

      {:ok, suggestion} ->
        confirmation = Formatter.format_confirmation(suggestion, club.name)
        cover_paths = Helpers.download_covers([suggestion])

        signal.send_message(sender_uuid, confirmation, cover_paths)
        Helpers.cleanup_covers(cover_paths)

        :ok

      {:error, _changeset} ->
        signal.send_message(sender_uuid, "Something went wrong. Try again in a minute.")
        :ok
    end
  end

  # --- Club Resolution ---

  defp with_club(sender_uuid, fun), do: with_club(sender_uuid, nil, fun)

  defp with_club(sender_uuid, club_number, fun) do
    signal = YonderbookClubs.Signal.impl()

    case resolve_club(sender_uuid, club_number) do
      {:ok, club} ->
        fun.(club)

      {:error, :no_clubs} ->
        signal.send_message(sender_uuid, "I'm not in any of your group chats yet. Add me to a group first.")
        :ok

      {:error, :signal_unavailable} ->
        signal.send_message(sender_uuid, "Something went wrong. Try again in a minute.")
        :ok

      {:error, :multiple_clubs, clubs} ->
        signal.send_message(sender_uuid, Formatter.format_club_list(clubs))
        :ok

      {:error, :invalid_club_number} ->
        signal.send_message(sender_uuid, "That club number doesn't exist. Say \"suggest\" to see the list.")
        :ok
    end
  end

  defp resolve_club(_sender_uuid, club_number) do
    case YonderbookClubs.Signal.impl().list_groups() do
      {:ok, groups} when groups != [] ->
        group_ids = Enum.map(groups, & &1["id"])
        existing = Clubs.get_clubs_by_group_ids(group_ids)
        existing_ids = MapSet.new(existing, & &1.signal_group_id)

        new_clubs =
          groups
          |> Enum.reject(fn g -> MapSet.member?(existing_ids, g["id"]) end)
          |> Enum.map(fn g ->
            {:ok, club} = Clubs.get_or_create_club(g["id"], g["name"] || "Book Club")
            Clubs.Cache.put(g["id"], club)
            club
          end)

        clubs = existing ++ new_clubs
        pick_club(clubs, club_number)

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
end
