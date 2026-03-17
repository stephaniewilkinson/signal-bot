defmodule YonderbookClubs.Bot.Formatter do
  @moduledoc """
  Outbound message formatting for the Yonderbook Clubs bot.

  Pure functions that take data and return formatted strings. No side effects.
  """

  alias YonderbookClubs.Clubs.Club
  alias YonderbookClubs.Readings.Reading
  alias YonderbookClubs.Suggestions.Suggestion

  @max_description_length 400

  @spec format_blurbs([Suggestion.t()], pos_integer(), pos_integer()) :: String.t()
  def format_blurbs(suggestions, vote_budget, total_polls \\ 1) do
    n = length(suggestions)
    capped = min(vote_budget, n)
    header = "#{n} books — pick up to #{capped}:\n"

    multi_poll_note =
      if total_polls > 1 do
        "\nVote in all #{total_polls} polls below!\n"
      else
        ""
      end

    blurbs =
      suggestions
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {s, i} -> format_single_blurb(s, i) end)

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

  @spec format_poll_question(pos_integer(), pos_integer(), pos_integer()) :: String.t()
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

  @spec format_poll_options([Suggestion.t()]) :: [String.t()]
  def format_poll_options(suggestions) do
    Enum.map(suggestions, & &1.title)
  end

  @spec format_help() :: String.t()
  def format_help, do: format_help(:dm)

  @spec format_help(:dm | :group) :: String.t()
  def format_help(:dm) do
    """
    Suggest a book:
    /suggest Piranesi by Susanna Clarke
    /suggest Toni Morrison, The Bluest Eye
    /suggest 978-1635575996
    /suggest ai: that infinite house book

    /remove (or /r) — undo your last suggestion
    /suggestions — see all suggestions
    /schedule — see the reading schedule
    /help — this message

    In the group chat: /start vote, /close vote, /results, /schedule, /unschedule\
    """
  end

  def format_help(:group) do
    """
    Group commands:
    /start vote N — start a vote (pick up to N)
    /close vote — end the current vote
    /results — see vote results
    /schedule — see the reading schedule
    /schedule <book> for <time> — add to schedule
    /unschedule <book> — remove from schedule

    In a DM with me: /suggest, /remove, /suggestions, /help\
    """
  end

  @spec format_confirmation(Suggestion.t(), String.t()) :: String.t()
  def format_confirmation(suggestion, club_name) do
    blurb =
      case suggestion.description do
        nil -> ""
        "" -> ""
        desc -> "\n\n" <> truncate_with_link(desc, @max_description_length, suggestion.open_library_work_id)
      end

    "Added #{suggestion.title} by #{suggestion.author} to the list of suggestions for #{club_name}.#{blurb}\n\nSay /remove to undo. When everyone's ready, say /start vote in the group."
  end

  @spec format_suggestions_list([Suggestion.t()]) :: String.t()
  def format_suggestions_list([]) do
    "No suggestions yet. DM me /suggest to add one."
  end

  def format_suggestions_list(suggestions) do
    lines =
      suggestions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, i} ->
        name = s.signal_sender_name || "someone"
        "#{i}. #{s.title} — #{s.author} (#{name})"
      end)

    "Current suggestions:\n\n" <> lines
  end

  @spec format_results([{Suggestion.t(), non_neg_integer()}], :active | :closed) :: String.t()
  def format_results(results, status) do
    header = if status == :active, do: "Live results:", else: "Final results:"

    lines =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{suggestion, count}, i} ->
        votes = if count == 1, do: "1 vote", else: "#{count} votes"
        "#{i}. #{suggestion.title} — #{votes}"
      end)

    header <> "\n\n" <> lines
  end

  @spec format_club_list([Club.t()]) :: String.t()
  def format_club_list(clubs) do
    lines =
      clubs
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {club, index} -> "#{index}) #{club.name}" end)

    "Which club? Re-send with the number:\n" <> lines
  end

  @spec format_schedule([Reading.t()]) :: String.t()
  def format_schedule([]) do
    "No readings scheduled yet. In the group chat, try:\n/schedule Piranesi by Susanna Clarke for January"
  end

  def format_schedule(readings) do
    lines =
      Enum.map_join(readings, "\n", fn reading ->
        "#{reading.time_label} — #{format_title_author(reading)}"
      end)

    "Reading schedule:\n\n" <> lines
  end

  @spec format_schedule_confirmation(Reading.t()) :: String.t()
  def format_schedule_confirmation(reading) do
    "Added to the schedule: #{format_title_author(reading)} for #{reading.time_label}."
  end

  @spec format_welcome() :: String.t()
  def format_welcome do
    """
    Hi! I'm Yonderbook Clubs. DM me to suggest books, then use /start vote here to pick your next read.

    Say /help in a DM for the full list of commands.\
    """
  end

  defp format_title_author(reading) do
    case reading.author do
      nil -> reading.title
      "" -> reading.title
      author -> "#{reading.title} by #{author}"
    end
  end
end
