defmodule YonderbookClubs.Bot.FormatterTest do
  use ExUnit.Case, async: true

  alias YonderbookClubs.Bot.Formatter

  defp build_suggestion(attrs \\ %{}) do
    Map.merge(
      %YonderbookClubs.Suggestions.Suggestion{
        title: "Piranesi",
        author: "Susanna Clarke",
        description:
          "A man lives alone in a labyrinthine house of infinite halls and vast oceans.",
        cover_url: "https://covers.openlibrary.org/b/id/10520612-M.jpg"
      },
      attrs
    )
  end

  describe "format_blurbs/2" do
    test "formats blurb message with title, author, and description" do
      suggestions = [build_suggestion()]
      result = Formatter.format_blurbs(suggestions, 2)

      assert result =~ "Piranesi — Susanna Clarke"

      assert result =~
               "A man lives alone in a labyrinthine house of infinite halls and vast oceans."
    end

    test "truncates descriptions longer than 200 characters" do
      long_description = String.duplicate("a", 250)
      suggestions = [build_suggestion(%{description: long_description})]
      result = Formatter.format_blurbs(suggestions, 1)

      # The truncated description should be 200 chars + "..."
      assert result =~ "..."
      # Should not contain the full 250-char description
      refute result =~ long_description
    end

    test "handles suggestions without descriptions" do
      suggestions = [build_suggestion(%{description: nil})]
      result = Formatter.format_blurbs(suggestions, 1)

      assert result =~ "Piranesi — Susanna Clarke"
      # Title line should appear without a trailing newline for the missing description
      lines = String.split(result, "\n")
      title_line = Enum.find(lines, &(&1 =~ "Piranesi"))
      assert title_line == "Piranesi — Susanna Clarke"
    end

    test "handles suggestions with empty string descriptions" do
      suggestions = [build_suggestion(%{description: ""})]
      result = Formatter.format_blurbs(suggestions, 1)

      assert result =~ "Piranesi — Susanna Clarke"
    end

    test "includes vote budget in header" do
      suggestions = [build_suggestion()]
      result = Formatter.format_blurbs(suggestions, 3)

      assert result =~ "choose up to 3"
    end

    test "formats multiple suggestions separated by blank lines" do
      suggestions = [
        build_suggestion(),
        build_suggestion(%{title: "Babel", author: "RF Kuang", description: "Dark academia."})
      ]

      result = Formatter.format_blurbs(suggestions, 2)

      assert result =~ "Piranesi — Susanna Clarke"
      assert result =~ "Babel — RF Kuang"
      assert result =~ "Dark academia."
    end
  end

  describe "format_poll_question/1" do
    test "formats with vote budget" do
      result = Formatter.format_poll_question(2)

      assert result == "Choose up to 2 — we're picking 2 months of reading"
    end

    test "formats with single vote budget" do
      result = Formatter.format_poll_question(1)

      assert result == "Choose up to 1 — we're picking 1 months of reading"
    end
  end

  describe "format_poll_options/1" do
    test "returns list of titles" do
      suggestions = [
        build_suggestion(%{title: "Piranesi"}),
        build_suggestion(%{title: "Babel"}),
        build_suggestion(%{title: "The Dispossessed"})
      ]

      result = Formatter.format_poll_options(suggestions)

      assert result == ["Piranesi", "Babel", "The Dispossessed"]
    end

    test "returns empty list for no suggestions" do
      assert Formatter.format_poll_options([]) == []
    end
  end

  describe "format_help/0" do
    test "returns help text containing key phrases" do
      result = Formatter.format_help()

      assert result =~ "suggest"
      assert result =~ "remove"
      assert result =~ "help"
      assert result =~ "ai:"
    end
  end

  describe "format_confirmation/2" do
    test "includes title and author" do
      result = Formatter.format_confirmation("Piranesi", "Susanna Clarke")

      assert result == "Added Piranesi by Susanna Clarke! Say 'remove' to undo."
    end
  end

  describe "format_club_list/1" do
    test "formats numbered list of clubs" do
      clubs = [
        %YonderbookClubs.Clubs.Club{name: "Book Nerds"},
        %YonderbookClubs.Clubs.Club{name: "Sci-Fi Circle"}
      ]

      result = Formatter.format_club_list(clubs)

      assert result =~ "Which club?"
      assert result =~ "1) Book Nerds"
      assert result =~ "2) Sci-Fi Circle"
    end

    test "formats single club" do
      clubs = [%YonderbookClubs.Clubs.Club{name: "Book Nerds"}]
      result = Formatter.format_club_list(clubs)

      assert result == "Which club?\n1) Book Nerds"
    end
  end
end
