defmodule YonderbookClubs.Bot.Router do
  @moduledoc """
  Inbound message routing for the Yonderbook Clubs bot.

  Receives parsed signal-cli messages and dispatches to the appropriate handler
  based on whether the message is a group message or a DM, and the command text.
  """

  alias YonderbookClubs.Bot.Formatter
  alias YonderbookClubs.Clubs
  alias YonderbookClubs.Suggestions

  require Logger

  # ISBN pattern: 10 or 13 digits, optionally separated by hyphens, 13-digit may start with 978/979
  @isbn_regex ~r/^[\d\-]{10,17}$/
  @title_by_author_regex ~r/^(.+?)\s+by\s+(.+)$/i
  @club_prefix_regex ~r/^#(\d+)\s+/

  @doc """
  Main entry point. Receives a signal-cli message map and routes it.

  Returns `:ok` or `:noop`.
  """
  def handle_message(%{"groupInfo" => %{"groupId" => group_id}} = msg) do
    text = (msg["message"] || "") |> String.trim()
    handle_group_message(group_id, text)
  end

  def handle_message(%{"sourceUuid" => sender_uuid} = msg) do
    text = (msg["message"] || "") |> String.trim()
    sender_name = msg["sourceName"] || "there"
    handle_dm(sender_uuid, sender_name, text)
  end

  def handle_message(_msg) do
    Logger.warning("Received message with no groupInfo or sourceUuid, ignoring")
    :noop
  end

  # --- Group Commands ---

  defp handle_group_message(group_id, text) do
    case String.downcase(text) do
      "start vote " <> rest ->
        n = parse_vote_budget(rest)
        handle_start_vote(group_id, n)

      "start vote" ->
        handle_start_vote(group_id, 1)

      "close vote" ->
        handle_close_vote(group_id)

      _ ->
        :noop
    end
  end

  defp parse_vote_budget(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp handle_start_vote(group_id, vote_budget) do
    signal = YonderbookClubs.Signal.impl()
    Logger.info("START_VOTE group_id from message: #{inspect(group_id)}")

    with {:ok, club} <- get_or_create_club_for_group(group_id),
         _ = Logger.info("START_VOTE club_id=#{club.id} group_id=#{club.signal_group_id}"),
         :ok <- check_not_already_voting(club, group_id),
         {:ok, suggestions} <- get_suggestions_for_vote(club, group_id) do
      {:ok, club} = Clubs.set_voting_active(club, true)

      blurbs = Formatter.format_blurbs(suggestions, vote_budget)
      question = Formatter.format_poll_question(vote_budget)
      options = Formatter.format_poll_options(suggestions)

      with :ok <- signal.send_message(group_id, blurbs),
           :ok <- signal.send_poll(group_id, question, options) do
        Suggestions.archive_all_suggestions(club)
        :ok
      else
        {:error, reason} ->
          Logger.error("Failed to send vote messages to group #{group_id}: #{inspect(reason)}")
          Clubs.set_voting_active(club, false)
          :ok
      end
    end
  end

  defp get_or_create_club_for_group(group_id) do
    case Clubs.get_club_by_group_id(group_id) do
      nil -> Clubs.get_or_create_club(group_id, "Book Club")
      club -> {:ok, club}
    end
  end

  defp check_not_already_voting(club, group_id) do
    if club.voting_active do
      YonderbookClubs.Signal.impl().send_message(
        group_id,
        "A vote is already open. Say \"close vote\" to end it."
      )
      {:error, :already_voting}
    else
      :ok
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
        Clubs.set_voting_active(club, false)
        YonderbookClubs.Signal.impl().send_message(group_id, "Vote closed.")
        :ok
    end
  end

  # --- DM Commands ---

  defp handle_dm(sender_uuid, _sender_name, text) do
    signal = YonderbookClubs.Signal.impl()

    case String.downcase(text) do
      "help" ->
        signal.send_message(sender_uuid, Formatter.format_help())
        :ok

      "remove" ->
        handle_remove(sender_uuid)

      "suggest " <> _ ->
        handle_suggest(sender_uuid, text)

      _ ->
        signal.send_message(sender_uuid, Formatter.format_help())
        :ok
    end
  end

  defp handle_remove(sender_uuid) do
    signal = YonderbookClubs.Signal.impl()

    case resolve_club(sender_uuid) do
      {:ok, club} ->
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

      {:error, :no_clubs} ->
        signal.send_message(
          sender_uuid,
          "I'm not in any of your group chats yet. Add me to a group first."
        )

        :ok

      {:error, :signal_unavailable} ->
        signal.send_message(
          sender_uuid,
          "Something went wrong. Try again in a minute."
        )

        :ok

      {:error, :multiple_clubs, clubs} ->
        signal.send_message(sender_uuid, Formatter.format_club_list(clubs))
        :ok
    end
  end

  defp handle_suggest(sender_uuid, text) do
    # Strip the "suggest " prefix (case-insensitive)
    suggestion_text = String.slice(text, 8..-1//1) |> String.trim()

    # Check for #N club prefix
    {club_number, suggestion_text} = extract_club_prefix(suggestion_text)

    case resolve_club(sender_uuid, club_number) do
      {:ok, club} ->
        process_suggestion(sender_uuid, club, suggestion_text)

      {:error, :no_clubs} ->
        YonderbookClubs.Signal.impl().send_message(
          sender_uuid,
          "I'm not in any of your group chats yet. Add me to a group first."
        )

        :ok

      {:error, :signal_unavailable} ->
        YonderbookClubs.Signal.impl().send_message(
          sender_uuid,
          "Something went wrong. Try again in a minute."
        )

        :ok

      {:error, :multiple_clubs, clubs} ->
        YonderbookClubs.Signal.impl().send_message(
          sender_uuid,
          Formatter.format_club_list(clubs)
        )

        :ok

      {:error, :invalid_club_number} ->
        YonderbookClubs.Signal.impl().send_message(
          sender_uuid,
          "That club number doesn't exist. Say \"suggest\" to see the list."
        )

        :ok
    end
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

  defp process_suggestion(sender_uuid, club, text) do
    signal = YonderbookClubs.Signal.impl()

    cond do
      String.starts_with?(String.downcase(text), "ai:") ->
        ai_text = String.slice(text, 3..-1//1) |> String.trim()
        handle_ai_suggestion(sender_uuid, club, ai_text)

      isbn?(text) ->
        isbn = YonderbookClubs.Books.normalize_isbn(text)
        handle_isbn_suggestion(sender_uuid, club, isbn)

      Regex.match?(@title_by_author_regex, text) ->
        [_, title, author] = Regex.run(@title_by_author_regex, text)
        handle_title_author_suggestion(sender_uuid, club, String.trim(title), String.trim(author))

      true ->
        signal.send_message(sender_uuid, Formatter.format_help())
        :ok
    end
  end

  defp isbn?(text) do
    stripped = String.replace(text, "-", "")
    Regex.match?(@isbn_regex, text) and String.length(stripped) in [10, 13]
  end

  defp handle_ai_suggestion(sender_uuid, club, text) do
    signal = YonderbookClubs.Signal.impl()

    case YonderbookClubs.Books.search_ai(text) do
      {:ok, book_data} ->
        save_suggestion(sender_uuid, club, book_data)

      {:error, _reason} ->
        signal.send_message(
          sender_uuid,
          "Couldn't find that book. Try the exact title:\n\"suggest Piranesi by Susanna Clarke\""
        )

        :ok
    end
  end

  defp handle_isbn_suggestion(sender_uuid, club, isbn) do
    signal = YonderbookClubs.Signal.impl()

    case YonderbookClubs.Books.search_isbn(isbn) do
      {:ok, book_data} ->
        save_suggestion(sender_uuid, club, book_data)

      {:error, _reason} ->
        signal.send_message(
          sender_uuid,
          "Couldn't find that ISBN. Check the number and try again."
        )
        :ok
    end
  end

  defp handle_title_author_suggestion(sender_uuid, club, title, author) do
    signal = YonderbookClubs.Signal.impl()

    case YonderbookClubs.Books.search(title, author) do
      {:ok, book_data} ->
        save_suggestion(sender_uuid, club, book_data)

      {:error, _reason} ->
        signal.send_message(
          sender_uuid,
          "Couldn't find that book. Check the spelling and try again."
        )

        :ok
    end
  end

  defp save_suggestion(sender_uuid, club, book_data) do
    signal = YonderbookClubs.Signal.impl()

    attrs =
      book_data
      |> Map.put(:signal_sender_uuid, sender_uuid)

    Logger.info("SAVE_SUGGESTION club_id=#{club.id} group_id=#{club.signal_group_id}")

    case Suggestions.create_suggestion(club, attrs) do
      {:ok, :duplicate} ->
        signal.send_message(sender_uuid, "That one's already on the list.")
        :ok

      {:ok, suggestion} ->
        signal.send_message(
          sender_uuid,
          Formatter.format_confirmation(suggestion.title, suggestion.author)
        )

        :ok

      {:error, _changeset} ->
        signal.send_message(sender_uuid, "Something went wrong. Try again in a minute.")
        :ok
    end
  end

  # --- Club Resolution ---

  defp resolve_club(_sender_uuid, club_number \\ nil) do
    case YonderbookClubs.Signal.impl().list_groups() do
      {:ok, groups} when groups != [] ->
        Logger.info("RESOLVE_CLUB list_groups returned IDs: #{inspect(Enum.map(groups, & &1["id"]))}")

        clubs =
          groups
          |> Enum.map(fn group ->
            case Clubs.get_club_by_group_id(group["id"]) do
              nil ->
                {:ok, club} = Clubs.get_or_create_club(group["id"], group["name"] || "Book Club")
                club

              club ->
                club
            end
          end)

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
