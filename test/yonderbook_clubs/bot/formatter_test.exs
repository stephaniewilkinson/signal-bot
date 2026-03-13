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
        cover_url: "https://covers.openlibrary.org/b/id/10520612-M.jpg",
        open_library_work_id: "OL20846689W"
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

    test "numbers the suggestions" do
      suggestions = [
        build_suggestion(),
        build_suggestion(%{title: "Babel", author: "RF Kuang", description: "Dark academia."})
      ]

      result = Formatter.format_blurbs(suggestions, 2)

      assert result =~ "1. Piranesi — Susanna Clarke"
      assert result =~ "2. Babel — RF Kuang"
    end

    test "includes count and vote budget in header" do
      suggestions = [build_suggestion(), build_suggestion(%{title: "Babel", author: "RF Kuang"})]
      result = Formatter.format_blurbs(suggestions, 3)

      assert result =~ "2 books"
      assert result =~ "pick up to 3"
    end

    test "truncates descriptions longer than 400 characters with Open Library link" do
      long_description = String.duplicate("a", 450)
      suggestions = [build_suggestion(%{description: long_description})]
      result = Formatter.format_blurbs(suggestions, 1)

      assert result =~ "…"
      assert result =~ "openlibrary.org/works/OL20846689W"
      refute result =~ long_description
    end

    test "handles suggestions without descriptions" do
      suggestions = [build_suggestion(%{description: nil})]
      result = Formatter.format_blurbs(suggestions, 1)

      assert result =~ "Piranesi — Susanna Clarke"
    end

    test "handles suggestions with empty string descriptions" do
      suggestions = [build_suggestion(%{description: ""})]
      result = Formatter.format_blurbs(suggestions, 1)

      assert result =~ "Piranesi — Susanna Clarke"
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
    test "formats with single vote budget" do
      assert Formatter.format_poll_question(1) == "What should we read next? (Pick 1)"
    end

    test "formats with multi vote budget" do
      assert Formatter.format_poll_question(3) == "What should we read next? (Pick 3)"
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
      assert result =~ "ai:"
    end
  end

  describe "format_confirmation/2" do
    test "includes title, author, and club name" do
      suggestion = build_suggestion()
      result = Formatter.format_confirmation(suggestion, "Book Nerds")

      assert result =~ "Piranesi by Susanna Clarke"
      assert result =~ "Book Nerds"
      assert result =~ "remove"
    end

    test "includes description blurb" do
      suggestion = build_suggestion(%{description: "A mysterious house."})
      result = Formatter.format_confirmation(suggestion, "Book Nerds")

      assert result =~ "A mysterious house."
    end

    test "handles nil description" do
      suggestion = build_suggestion(%{description: nil})
      result = Formatter.format_confirmation(suggestion, "Book Nerds")

      assert result =~ "Piranesi by Susanna Clarke"
      refute result =~ "\n\n\n"
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

    test "includes re-send instruction" do
      clubs = [%YonderbookClubs.Clubs.Club{name: "Book Nerds"}]
      result = Formatter.format_club_list(clubs)

      assert result =~ "number"
    end
  end
end
