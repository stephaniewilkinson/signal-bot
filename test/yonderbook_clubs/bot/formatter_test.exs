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
      result = Formatter.format_blurbs(suggestions, 2)

      assert result =~ "2 books"
      assert result =~ "pick up to 2"
    end

    test "caps vote budget at suggestion count in header" do
      suggestions = [build_suggestion(), build_suggestion(%{title: "Babel", author: "RF Kuang"})]
      result = Formatter.format_blurbs(suggestions, 5)

      assert result =~ "pick up to 2"
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
    test "DM help emphasizes DM commands" do
      result = Formatter.format_help()

      assert result =~ "/suggest"
      assert result =~ "/remove"
      assert result =~ "ai:"
      assert result =~ "/schedule"
      assert result =~ "/r)"
    end

    test "DM help briefly mentions group commands" do
      result = Formatter.format_help(:dm)

      assert result =~ "/start vote"
      assert result =~ "/close vote"
      assert result =~ "/unschedule"
    end

    test "group help emphasizes group commands" do
      result = Formatter.format_help(:group)

      assert result =~ "/start vote N"
      assert result =~ "/close vote"
      assert result =~ "/results"
      assert result =~ "/schedule"
      assert result =~ "/unschedule"
    end

    test "group help briefly mentions DM commands" do
      result = Formatter.format_help(:group)

      assert result =~ "/suggest"
      assert result =~ "/remove"
    end
  end

  describe "format_confirmation/2" do
    test "includes title, author, and club name" do
      suggestion = build_suggestion()
      result = Formatter.format_confirmation(suggestion, "Book Nerds")

      assert result =~ "Piranesi by Susanna Clarke"
      assert result =~ "Book Nerds"
      assert result =~ "remove"
      assert result =~ "/start vote"
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

  describe "format_suggestions_list/1" do
    test "returns no-suggestions message for empty list" do
      result = Formatter.format_suggestions_list([])
      assert result =~ "No suggestions yet"
    end

    test "formats numbered list of suggestions" do
      suggestions = [
        build_suggestion(%{signal_sender_name: "Alice"}),
        build_suggestion(%{title: "Babel", author: "RF Kuang", signal_sender_name: "Bob"})
      ]

      result = Formatter.format_suggestions_list(suggestions)

      assert result =~ "1. Piranesi — Susanna Clarke (Alice)"
      assert result =~ "2. Babel — RF Kuang (Bob)"
    end

    test "uses 'someone' for nil sender name" do
      suggestions = [build_suggestion(%{signal_sender_name: nil})]
      result = Formatter.format_suggestions_list(suggestions)

      assert result =~ "(someone)"
    end
  end

  describe "format_results/2" do
    test "shows 'Live results' header for active polls" do
      results = [{build_suggestion(), 3}]
      result = Formatter.format_results(results, :active)

      assert result =~ "Live results"
    end

    test "shows 'Final results' header for closed polls" do
      results = [{build_suggestion(), 3}]
      result = Formatter.format_results(results, :closed)

      assert result =~ "Final results"
    end

    test "formats numbered results with vote counts" do
      results = [
        {build_suggestion(), 5},
        {build_suggestion(%{title: "Babel"}), 2}
      ]

      result = Formatter.format_results(results, :active)

      assert result =~ "1. Piranesi — 5 votes"
      assert result =~ "2. Babel — 2 votes"
    end

    test "uses singular 'vote' for count of 1" do
      results = [{build_suggestion(), 1}]
      result = Formatter.format_results(results, :active)

      assert result =~ "1 vote"
      refute result =~ "1 votes"
    end
  end

  describe "format_club_list/1" do
    test "formats numbered list of clubs" do
      clubs = [
        %YonderbookClubs.Clubs.Club{name: "Book Nerds"},
        %YonderbookClubs.Clubs.Club{name: "Sci-Fi Circle"}
      ]

      result = Formatter.format_club_list(clubs)

      assert result =~ "Which one?"
      assert result =~ "1) Book Nerds"
      assert result =~ "2) Sci-Fi Circle"
    end

    test "includes re-send instruction" do
      clubs = [%YonderbookClubs.Clubs.Club{name: "Book Nerds"}]
      result = Formatter.format_club_list(clubs)

      assert result =~ "number"
    end
  end

  describe "format_welcome/0" do
    test "includes key onboarding info" do
      result = Formatter.format_welcome()

      assert result =~ "DM me"
      assert result =~ "/start vote"
      assert result =~ "/help"
    end
  end

  describe "format_schedule/1" do
    test "returns empty message for no readings" do
      result = Formatter.format_schedule([])
      assert result =~ "Nothing on the schedule yet!"
    end

    test "formats readings with time label and title + author" do
      readings = [
        %YonderbookClubs.Readings.Reading{
          title: "Piranesi",
          author: "Susanna Clarke",
          time_label: "January"
        },
        %YonderbookClubs.Readings.Reading{
          title: "Babel",
          author: "RF Kuang",
          time_label: "March"
        }
      ]

      result = Formatter.format_schedule(readings)
      assert result =~ "Reading schedule:"
      assert result =~ "Jan — Piranesi by Susanna Clarke"
      assert result =~ "Mar — Babel by RF Kuang"
    end

    test "handles readings without author" do
      readings = [
        %YonderbookClubs.Readings.Reading{
          title: "Piranesi",
          author: nil,
          time_label: "TBD"
        }
      ]

      result = Formatter.format_schedule(readings)
      assert result =~ "TBD — Piranesi"
      refute result =~ " by "
    end

    test "handles readings with empty string author" do
      readings = [
        %YonderbookClubs.Readings.Reading{
          title: "Piranesi",
          author: "",
          time_label: "TBD"
        }
      ]

      result = Formatter.format_schedule(readings)
      assert result =~ "TBD — Piranesi"
      refute result =~ " by "
    end

    test "preserves insertion order in output" do
      readings = [
        %YonderbookClubs.Readings.Reading{
          title: "Piranesi",
          author: "Susanna Clarke",
          time_label: "January"
        },
        %YonderbookClubs.Readings.Reading{
          title: "Babel",
          author: "RF Kuang",
          time_label: "March"
        },
        %YonderbookClubs.Readings.Reading{
          title: "The Dispossessed",
          author: "Ursula K. Le Guin",
          time_label: "TBD"
        }
      ]

      result = Formatter.format_schedule(readings)

      assert result =~ "Jan — Piranesi"
      assert result =~ "Mar — Babel"
      assert result =~ "TBD — The Dispossessed"
    end
  end

  describe "format_schedule_confirmation/1" do
    test "formats confirmation with author" do
      reading = %YonderbookClubs.Readings.Reading{
        title: "Piranesi",
        author: "Susanna Clarke",
        time_label: "January"
      }

      result = Formatter.format_schedule_confirmation(reading)
      assert result =~ "on the schedule"
      assert result =~ "Piranesi by Susanna Clarke"
      assert result =~ "Jan"
    end

    test "formats confirmation without author" do
      reading = %YonderbookClubs.Readings.Reading{
        title: "Piranesi",
        author: nil,
        time_label: "TBD"
      }

      result = Formatter.format_schedule_confirmation(reading)
      assert result =~ "Piranesi is on the schedule for TBD"
      refute result =~ " by "
    end
  end
end
