defmodule YonderbookClubs.Bot.Router do
  @moduledoc """
  Inbound message routing for the Yonderbook Clubs bot.

  Receives parsed signal-cli messages and dispatches to the appropriate handler
  based on whether the message is a group message or a DM, and the command text.
  """

  alias YonderbookClubs.Bot.Formatter
  alias YonderbookClubs.Clubs
  alias YonderbookClubs.Polls
  alias YonderbookClubs.Suggestions

  require Logger

  @max_poll_options 12
  @title_by_author_regex ~r/^(.+?)\s+by\s+(.+)$/i
  @author_comma_title_regex ~r/^(.+?),\s+(.+)$/
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

  @doc """
  Handles an incoming poll vote notification from signal-cli.
  """
  def handle_poll_vote(%{"targetSentTimestamp" => timestamp} = msg) do
    case Polls.get_poll_by_timestamp(timestamp) do
      nil -> :noop
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

  # --- Group Commands ---

  defp handle_group_message(group_id, text) do
    case text |> strip_slash() |> String.downcase() do
      "start vote " <> rest ->
        n = parse_vote_budget(rest)
        handle_start_vote(group_id, n)

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
      {n, ""} when n > 0 and n <= 50 -> n
      _ -> 1
    end
  end

  defp handle_start_vote(group_id, vote_budget) do
    signal = YonderbookClubs.Signal.impl()

    with {:ok, club} <- get_or_create_club_for_group(group_id),
         :ok <- check_not_already_voting(club, group_id),
         {:ok, suggestions} <- get_suggestions_for_vote(club, group_id),
         :ok <- check_enough_suggestions(suggestions, signal, group_id) do
      {:ok, club} = Clubs.set_voting_active(club, true)
      send_vote(signal, group_id, club, suggestions, vote_budget)
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
    cover_paths = download_covers(suggestions)

    case signal.send_message(group_id, blurbs, cover_paths) do
      :ok ->
        result =
          chunks
          |> Enum.with_index(1)
          |> Enum.reduce_while({:ok, []}, fn {chunk, poll_num}, {:ok, created_polls} ->
            question = Formatter.format_poll_question(vote_budget, poll_num, total_polls)
            options = Formatter.format_poll_options(chunk)

            case signal.send_poll(group_id, question, options) do
              {:ok, poll_timestamp} ->
                {:ok, poll} = Polls.create_poll(club, poll_timestamp, vote_budget, chunk)
                {:cont, {:ok, [poll | created_polls]}}

              {:error, reason} ->
                {:halt, {:error, reason, created_polls}}
            end
          end)

        case result do
          {:ok, _polls} ->
            Suggestions.archive_all_suggestions(club)
            cleanup_covers(cover_paths)
            :ok

          {:error, reason, created_polls} ->
            Logger.error("Failed to send poll to group #{group_id}: #{inspect(reason)}")
            Enum.each(created_polls, &Polls.delete_poll/1)
            Clubs.set_voting_active(club, false)
            cleanup_covers(cover_paths)
            :ok
        end

      {:error, reason} ->
        Logger.error("Failed to send blurbs to group #{group_id}: #{inspect(reason)}")
        Clubs.set_voting_active(club, false)
        cleanup_covers(cover_paths)
        :ok
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

        Polls.get_latest_active_polls(club)
        |> Enum.each(&Polls.close_poll/1)

        YonderbookClubs.Signal.impl().send_message(group_id, "Vote closed.")
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

          polls ->
            status = hd(polls).status
            results = Polls.get_combined_results(polls)
            signal.send_message(group_id, Formatter.format_results(results, status))
            :ok
        end
    end
  end

  # --- DM Commands ---

  defp handle_dm(sender_uuid, sender_name, text) do
    signal = YonderbookClubs.Signal.impl()
    stripped = strip_slash(text)

    case String.downcase(stripped) do
      "help" ->
        signal.send_message(sender_uuid, Formatter.format_help())
        :ok

      "remove" ->
        handle_remove(sender_uuid)

      "suggestions" ->
        handle_suggestions(sender_uuid)

      "suggest " <> _ ->
        handle_suggest(sender_uuid, sender_name, stripped)

      _ ->
        signal.send_message(sender_uuid, "I didn't catch that. Say /help for help.")
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

  defp handle_suggestions(sender_uuid) do
    signal = YonderbookClubs.Signal.impl()

    case resolve_club(sender_uuid) do
      {:ok, club} ->
        suggestions = Suggestions.list_suggestions(club)
        signal.send_message(sender_uuid, Formatter.format_suggestions_list(suggestions))
        :ok

      {:error, :no_clubs} ->
        signal.send_message(sender_uuid, "I'm not in any of your group chats yet. Add me to a group first.")
        :ok

      {:error, :signal_unavailable} ->
        signal.send_message(sender_uuid, "Something went wrong. Try again in a minute.")
        :ok

      {:error, :multiple_clubs, clubs} ->
        signal.send_message(sender_uuid, Formatter.format_club_list(clubs))
        :ok
    end
  end

  defp handle_suggest(sender_uuid, sender_name, text) do
    # Strip the "suggest " prefix (case-insensitive)
    suggestion_text = String.slice(text, 8..-1//1) |> String.trim()

    # Check for #N club prefix
    {club_number, suggestion_text} = extract_club_prefix(suggestion_text)

    case resolve_club(sender_uuid, club_number) do
      {:ok, club} ->
        process_suggestion(sender_uuid, sender_name, club, suggestion_text)

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

  defp process_suggestion(sender_uuid, sender_name, club, text) do
    process_suggestion_input(sender_uuid, sender_name, club, text)
  end

  defp process_suggestion_input(sender_uuid, sender_name, club, text) do
    cond do
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
    Regex.match?(~r/^\d+$/, stripped) and String.length(stripped) in [10, 13]
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
        cover_paths = download_covers([suggestion])

        signal.send_message(sender_uuid, confirmation, cover_paths)
        cleanup_covers(cover_paths)

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

  defp strip_slash("/" <> rest), do: rest
  defp strip_slash(text), do: text

  defp download_covers(suggestions) do
    suggestions
    |> Enum.filter(& &1.cover_url)
    |> Task.async_stream(
      fn suggestion ->
        case Req.get(suggestion.cover_url, receive_timeout: 10_000) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            path = Path.join(System.tmp_dir!(), "cover_#{suggestion.id}.jpg")

            case File.write(path, body) do
              :ok -> path
              {:error, reason} ->
                Logger.warning("Failed to write cover for #{suggestion.title}: #{inspect(reason)}")
                nil
            end

          _ ->
            Logger.warning("Failed to download cover for #{suggestion.title}")
            nil
        end
      end,
      max_concurrency: 6,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, path} when is_binary(path) -> [path]
      _ -> []
    end)
  end

  defp cleanup_covers(paths) do
    Enum.each(paths, fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Failed to clean up cover #{path}: #{inspect(reason)}")
      end
    end)
  end
end
