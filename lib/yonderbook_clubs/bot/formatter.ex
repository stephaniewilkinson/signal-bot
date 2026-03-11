defmodule YonderbookClubs.Bot.Formatter do
  @moduledoc """
  Outbound message formatting for the Yonderbook Clubs bot.

  Pure functions that take data and return formatted strings. No side effects.
  """

  @max_description_length 200

  @doc """
  Formats the blurbs message listing all book candidates for a vote.

  Returns a string like:

      📚 This month's candidates — choose up to 2:

      Piranesi — Susanna Clarke
      A man lives alone in a labyrinthine house of infinite halls and...

      Babel — RF Kuang
      Dark academia fantasy about translation and colonial empire...
  """
  def format_blurbs(suggestions, vote_budget) do
    header = "📚 This month's candidates — choose up to #{vote_budget}:"

    blurbs =
      suggestions
      |> Enum.map(&format_single_blurb/1)
      |> Enum.join("\n\n")

    header <> "\n\n" <> blurbs
  end

  defp format_single_blurb(suggestion) do
    title_line = "#{suggestion.title} — #{suggestion.author}"

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
      |> Kernel.<>("...")
    end
  end

  @doc """
  Formats the poll question string.

  Returns "Choose up to N — we're picking N months of reading".
  """
  def format_poll_question(vote_budget) do
    "Choose up to #{vote_budget} — we're picking #{vote_budget} months of reading"
  end

  @doc """
  Formats suggestion titles into a list of poll option strings.

  Returns a list like `["Piranesi", "Babel", "The Dispossessed"]`.
  """
  def format_poll_options(suggestions) do
    Enum.map(suggestions, & &1.title)
  end

  @doc """
  Formats the help/onboarding message sent via DM.
  """
  def format_help do
    """
    👋 Welcome to your book club!

    To suggest a book, DM me:

    📖 suggest Piranesi by Susanna Clarke
    🔗 suggest https://goodreads.com/book/show/...
    🔢 suggest 978-1635575996

    🤖 Want to describe it loosely?
       suggest ai: that infinite house book everyone was talking about
       Note: this option uses AI to interpret your message.

    To undo: remove
    Type 'help' anytime to see this again.\
    """
  end

  @doc """
  Formats a confirmation message after a suggestion is added.

  Returns "Added Title by Author! Say 'remove' to undo."
  """
  def format_confirmation(title, author) do
    "Added #{title} by #{author}! Say 'remove' to undo."
  end

  @doc """
  Formats a numbered list of clubs for disambiguation.

  Returns a string like:

      Which club?
      1) Book Lovers
      2) Sci-Fi Circle
  """
  def format_club_list(clubs) do
    lines =
      clubs
      |> Enum.with_index(1)
      |> Enum.map(fn {club, index} -> "#{index}) #{club.name}" end)
      |> Enum.join("\n")

    "Which club?\n" <> lines
  end
end
