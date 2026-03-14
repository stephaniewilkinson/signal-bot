defmodule YonderbookClubs.Bot.Formatter do
  @moduledoc """
  Outbound message formatting for the Yonderbook Clubs bot.

  Pure functions that take data and return formatted strings. No side effects.
  """

  @max_description_length 400

  def format_blurbs(suggestions, vote_budget, total_polls \\ 1) do
    n = length(suggestions)
    header = "#{n} books — pick up to #{vote_budget}:\n"

    multi_poll_note =
      if total_polls > 1 do
        "\nVote in all #{total_polls} polls below!\n"
      else
        ""
      end

    blurbs =
      suggestions
      |> Enum.with_index(1)
      |> Enum.map(fn {s, i} -> format_single_blurb(s, i) end)
      |> Enum.join("\n\n")

    header <> multi_poll_note <> "\n" <> blurbs
  end

  defp format_single_blurb(suggestion, index) do
    title_line = "#{index}. #{suggestion.title} — #{suggestion.author}"

    case suggestion.description do
      nil -> title_line
      "" -> title_line
      description ->
        title_line <> "\n" <> truncate_with_link(description, @max_description_length, suggestion.open_library_work_id)
    end
  end

  defp truncate_with_link(text, max_length, work_id) do
    if String.length(text) <= max_length do
      text
    else
      truncated =
        text
        |> String.slice(0, max_length)
        |> String.trim_trailing()

      link = if work_id, do: " (https://openlibrary.org/works/#{work_id})", else: ""
      truncated <> "…" <> link
    end
  end

  def format_poll_question(vote_budget, poll_num \\ 1, total_polls \\ 1) do
    base =
      case vote_budget do
        1 -> "What should we read next? (Pick 1)"
        n -> "What should we read next? (Pick #{n})"
      end

    if total_polls > 1 do
      base <> " — Poll #{poll_num} of #{total_polls}"
    else
      base
    end
  end

  def format_poll_options(suggestions) do
    Enum.map(suggestions, & &1.title)
  end

  def format_help do
    """
    Suggest a book (DM):
    /suggest Piranesi by Susanna Clarke
    /suggest Toni Morrison, The Bluest Eye
    /suggest 978-1635575996
    /suggest ai: that infinite house book

    /remove — undo your last suggestion
    /suggestions — see your suggestions
    /help — this message

    In the group chat:
    /start vote N — start a vote (pick up to N)
    /close vote — end the current vote
    /results — see vote results\
    """
  end

  def format_confirmation(suggestion, club_name) do
    blurb =
      case suggestion.description do
        nil -> ""
        "" -> ""
        desc -> "\n\n" <> truncate_with_link(desc, @max_description_length, suggestion.open_library_work_id)
      end

    "Added #{suggestion.title} by #{suggestion.author} to the list of suggestions for #{club_name}.#{blurb}\n\nSay /remove to undo."
  end

  def format_suggestions_list([]) do
    "No suggestions yet. DM me /suggest to add one."
  end

  def format_suggestions_list(suggestions) do
    lines =
      suggestions
      |> Enum.with_index(1)
      |> Enum.map(fn {s, i} ->
        name = s.signal_sender_name || "someone"
        "#{i}. #{s.title} — #{s.author} (#{name})"
      end)
      |> Enum.join("\n")

    "Current suggestions:\n\n" <> lines
  end

  def format_results(results, status) do
    header = if status == :active, do: "Live results:", else: "Final results:"

    lines =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {{suggestion, count}, i} ->
        votes = if count == 1, do: "1 vote", else: "#{count} votes"
        "#{i}. #{suggestion.title} — #{votes}"
      end)
      |> Enum.join("\n")

    header <> "\n\n" <> lines
  end

  def format_club_list(clubs) do
    lines =
      clubs
      |> Enum.with_index(1)
      |> Enum.map(fn {club, index} -> "#{index}) #{club.name}" end)
      |> Enum.join("\n")

    "Which club? Re-send with the number:\n" <> lines
  end
end
