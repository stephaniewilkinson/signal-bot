defmodule YonderbookClubs.Bot.Formatter do
  @moduledoc """
  Outbound message formatting for the Yonderbook Clubs bot.

  Pure functions that take data and return formatted strings. No side effects.
  """

  @max_description_length 200

  def format_blurbs(suggestions, vote_budget) do
    n = length(suggestions)
    header = "📚 #{n} books nominated — pick up to #{vote_budget}:\n"

    blurbs =
      suggestions
      |> Enum.with_index(1)
      |> Enum.map(fn {s, i} -> format_single_blurb(s, i) end)
      |> Enum.join("\n\n")

    header <> "\n" <> blurbs
  end

  defp format_single_blurb(suggestion, index) do
    title_line = "#{index}. #{suggestion.title} — #{suggestion.author}"

    case suggestion.description do
      nil -> title_line
      "" -> title_line
      description -> title_line <> "\n" <> truncate(description, @max_description_length)
    end
  end

  defp truncate(text, max_length) do
    if String.length(text) <= max_length do
      text
    else
      text
      |> String.slice(0, max_length)
      |> String.trim_trailing()
      |> Kernel.<>("…")
    end
  end

  def format_poll_question(vote_budget) do
    case vote_budget do
      1 -> "Vote for your next read"
      n -> "Pick up to #{n} — we're choosing #{n} months of reading"
    end
  end

  def format_poll_options(suggestions) do
    Enum.map(suggestions, & &1.title)
  end

  def format_help do
    """
    📚 Yonderbook Clubs

    Suggest a book:
    suggest Piranesi by Susanna Clarke
    suggest 978-1635575996
    suggest ai: that book about the infinite house

    Undo your last suggestion:
    remove

    The ai: option uses AI to identify your book.\
    """
  end

  def format_confirmation(title, author) do
    "✅ #{title} by #{author}\nSay 'remove' to undo."
  end

  def format_club_list(clubs) do
    lines =
      clubs
      |> Enum.with_index(1)
      |> Enum.map(fn {club, index} -> "#{index}) #{club.name}" end)
      |> Enum.join("\n")

    "Which club? Re-send with #N:\n" <> lines
  end
end
