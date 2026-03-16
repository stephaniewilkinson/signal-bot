defmodule YonderbookClubs.Bot.RouterTest do
  use YonderbookClubs.DataCase, async: false

  import Mox

  alias YonderbookClubs.Bot.Router
  alias YonderbookClubs.Clubs
  alias YonderbookClubs.Suggestions

  setup :verify_on_exit!

  # --- Helpers ---

  defp group_message(group_id, text, opts \\ []) do
    %{
      "sourceUuid" => Keyword.get(opts, :sender, "uuid-sender"),
      "sourceName" => Keyword.get(opts, :sender_name, "Alice"),
      "groupInfo" => %{"groupId" => group_id},
      "message" => text
    }
  end

  defp dm_message(text, opts \\ []) do
    %{
      "sourceUuid" => Keyword.get(opts, :sender, "uuid-sender"),
      "sourceName" => Keyword.get(opts, :sender_name, "Alice"),
      "message" => text
    }
  end

  defp create_club(group_id \\ "group.abc123", name \\ "Test Club") do
    {:ok, club} = Clubs.get_or_create_club(group_id, name)
    club
  end

  defp add_suggestion(club, title, author, opts \\ []) do
    attrs = %{
      title: title,
      author: author,
      open_library_work_id:
        Keyword.get(opts, :work_id, "OL#{System.unique_integer([:positive])}W"),
      signal_sender_uuid: Keyword.get(opts, :sender, "uuid-sender"),
      description: Keyword.get(opts, :description, "A great book.")
    }

    {:ok, suggestion} = Suggestions.create_suggestion(club, attrs)
    suggestion
  end

  defp mock_list_groups_with_club do
    expect(YonderbookClubs.Signal.Mock, :list_groups, fn ->
      {:ok, [%{"id" => "group.abc123", "name" => "Test Club"}]}
    end)
  end

  # --- Group Message Tests ---

  describe "group messages - start vote" do
    test "start vote with suggestions posts blurbs and poll, then deletes suggestions" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")
      add_suggestion(club, "Babel", "RF Kuang")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body, _attachments ->
        assert body =~ "Piranesi"
        assert body =~ "Babel"
        assert body =~ "pick up to 1"
        :ok
      end)

      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", question, options ->
        assert question =~ "What should we read next?"
        assert "Piranesi" in options
        assert "Babel" in options
        {:ok, 1234567890}
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "start vote 1"))

      assert Suggestions.list_suggestions(club) == []

      updated_club = Clubs.get_club_by_group_id("group.abc123")
      assert updated_club.voting_active == true
    end

    test "start vote without number prompts for vote budget" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "How many books"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "start vote"))
    end

    test "start vote without number says already open when voting is active" do
      club = create_club()
      Clubs.set_voting_active(club, true)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "already open"
        :ok
      end)

      assert {:error, :already_voting} =
               Router.handle_message(group_message("group.abc123", "start vote"))
    end

    test "start vote N parses vote budget" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")
      add_suggestion(club, "Babel", "RF Kuang")
      add_suggestion(club, "The Dispossessed", "Ursula K. Le Guin")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body, _attachments ->
        assert body =~ "pick up to 3"
        :ok
      end)

      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", question, _options ->
        assert question =~ "Pick 3"
        {:ok, 1234567890}
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "start vote 3"))
    end

    test "start vote caps budget at suggestion count" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")
      add_suggestion(club, "Babel", "RF Kuang")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body, _attachments ->
        assert body =~ "pick up to 2"
        :ok
      end)

      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", question, _options ->
        assert question =~ "Pick 2"
        {:ok, 1234567890}
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "start vote 5"))
    end

    test "start vote with no suggestions replies and does not activate voting" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "No suggestions yet"
        :ok
      end)

      assert {:error, :no_suggestions} =
               Router.handle_message(group_message("group.abc123", "start vote 1"))

      updated_club = Clubs.get_club_by_group_id("group.abc123")
      assert updated_club.voting_active == false
    end

    test "start vote when already voting replies accordingly" do
      club = create_club()
      Clubs.set_voting_active(club, true)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "already open"
        :ok
      end)

      assert {:error, :already_voting} =
               Router.handle_message(group_message("group.abc123", "start vote 1"))
    end

    test "start vote is case insensitive" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")
      add_suggestion(club, "Babel", "RF Kuang")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", _body, _attachments -> :ok end)

      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", _question, _options ->
        {:ok, 1234567890}
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "START VOTE 1"))
    end

    test "start vote with >12 suggestions splits into two polls" do
      club = create_club()

      for i <- 1..14 do
        add_suggestion(club, "Book #{i}", "Author #{i}")
      end

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body, _attachments ->
        assert body =~ "14 books"
        assert body =~ "Vote in all 2 polls"
        :ok
      end)

      # First poll: 12 options
      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", question, options ->
        assert question =~ "Poll 1 of 2"
        assert length(options) == 12
        {:ok, 1000000001}
      end)

      # Second poll: 2 options
      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", question, options ->
        assert question =~ "Poll 2 of 2"
        assert length(options) == 2
        {:ok, 1000000002}
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "start vote 9"))

      assert Suggestions.list_suggestions(club) == []
    end
  end

  describe "group messages - start vote rollback" do
    test "start vote with only one suggestion rolls back voting_active" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "only received one suggestion"
        :ok
      end)

      assert {:error, :not_enough_suggestions} =
               Router.handle_message(group_message("group.abc123", "start vote 1"))

      updated_club = Clubs.get_club_by_group_id("group.abc123")
      assert updated_club.voting_active == false
    end
  end

  describe "group messages - close vote" do
    test "close vote sets voting_active to false and confirms" do
      club = create_club()
      Clubs.set_voting_active(club, true)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Vote closed"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "close vote"))

      updated_club = Clubs.get_club_by_group_id("group.abc123")
      assert updated_club.voting_active == false
    end

    test "close vote when no vote is active tells the user" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "No vote is active"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "close vote"))
    end
  end

  describe "group messages - unrecognized" do
    test "unrecognized group message returns :noop and sends nothing" do
      _club = create_club()

      assert :noop = Router.handle_message(group_message("group.abc123", "hello everyone"))
    end
  end

  # --- DM Message Tests ---

  describe "DM messages - help" do
    test "help sends help message" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "suggest"
        assert body =~ "remove"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("help"))
    end

    test "help is case insensitive" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "suggest"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("HELP"))
    end
  end

  describe "DM messages - remove" do
    test "remove deletes the sender's most recent suggestion" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke", sender: "uuid-sender")
      Process.sleep(10)
      add_suggestion(club, "Babel", "RF Kuang", sender: "uuid-sender")

      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Removed"
        assert body =~ "Babel"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("remove"))

      remaining = Suggestions.list_suggestions(club)
      assert length(remaining) == 1
      assert hd(remaining).title == "Piranesi"
    end

    test "remove when no suggestions tells the user" do
      _club = create_club()

      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "don't have any suggestions"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("remove"))
    end

    test "remove when not in any clubs tells the user" do
      expect(YonderbookClubs.Signal.Mock, :list_groups, fn ->
        {:ok, []}
      end)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "not in any of your group chats"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("remove"))
    end
  end

  describe "DM messages - suggest" do
    test "suggest Title by Author with a well-known book (integration)" do
      club = create_club()

      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Piranesi"
        assert body =~ "Test Club"
        assert body =~ "remove"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Piranesi by Susanna Clarke"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
      assert hd(suggestions).title =~ "Piranesi"
    end

    test "suggest Author, Title format works (integration)" do
      club = create_club()

      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Piranesi"
        assert body =~ "Susanna Clarke"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Susanna Clarke, Piranesi"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
      assert hd(suggestions).title =~ "Piranesi"
    end

    test "more than 12 suggestions are accepted" do
      club = create_club()

      for i <- 1..13 do
        add_suggestion(club, "Book #{i}", "Author #{i}")
      end

      assert length(Suggestions.list_suggestions(club)) == 13
    end

    test "suggest with no text gives guidance" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Suggest what?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest"))
    end

    test "suggest with overly long text is rejected" do
      _club = create_club()
      mock_list_groups_with_club()

      long_text = String.duplicate("a", 501)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "too long"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest #{long_text}"))
    end

    test "suggest with free text that finds no results gives error" do
      _club = create_club()

      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Couldn't find that book"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest asdfghjkl nonsense"))
    end

    test "suggest with free text that matches Open Library (integration)" do
      club = create_club()

      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Piranesi Susanna Clarke"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
    end
  end

  describe "DM messages - unrecognized" do
    test "unrecognized DM sends fallback message" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "I didn't catch that"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("what is this"))
    end
  end

  # --- Poll Vote Tests ---

  describe "poll votes" do
    test "handle_poll_vote records a vote for an active poll" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      s2 = add_suggestion(club, "Babel", "RF Kuang")

      {:ok, poll} = YonderbookClubs.Polls.create_poll(club, 1234567890, 1, [s1, s2])

      vote_msg = %{
        "sourceUuid" => "uuid-voter",
        "targetSentTimestamp" => 1234567890,
        "optionIndexes" => [0],
        "voteCount" => 1
      }

      assert :ok = Router.handle_poll_vote(vote_msg)

      results = YonderbookClubs.Polls.get_combined_results([poll])
      {_piranesi, count} = Enum.find(results, fn {s, _} -> s.title == "Piranesi" end)
      assert count == 1
    end

    test "handle_poll_vote ignores unknown timestamps" do
      assert :noop = Router.handle_poll_vote(%{
        "sourceUuid" => "uuid-voter",
        "targetSentTimestamp" => 9999999999,
        "optionIndexes" => [0],
        "voteCount" => 1
      })
    end

    test "handle_poll_vote ignores votes on closed polls" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      s2 = add_suggestion(club, "Babel", "RF Kuang")

      {:ok, poll} = YonderbookClubs.Polls.create_poll(club, 5555555555, 1, [s1, s2])
      {:ok, _closed} = YonderbookClubs.Polls.close_poll(poll)

      assert :noop = Router.handle_poll_vote(%{
        "sourceUuid" => "uuid-voter",
        "targetSentTimestamp" => 5555555555,
        "optionIndexes" => [0],
        "voteCount" => 1
      })
    end
  end

  # --- Results Tests ---

  describe "group messages - results" do
    test "results shows vote counts for the latest poll" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      s2 = add_suggestion(club, "Babel", "RF Kuang")

      {:ok, poll} = YonderbookClubs.Polls.create_poll(club, 1234567890, 1, [s1, s2])
      YonderbookClubs.Polls.record_vote(poll, "uuid-voter1", [0], 1)
      YonderbookClubs.Polls.record_vote(poll, "uuid-voter2", [0], 1)
      YonderbookClubs.Polls.record_vote(poll, "uuid-voter3", [1], 1)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Live results"
        assert body =~ "Piranesi"
        assert body =~ "2 votes"
        assert body =~ "Babel"
        assert body =~ "1 vote"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "results"))
    end

    test "results with no polls tells the user" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "No polls yet"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "results"))
    end
  end

  # --- Schedule Tests ---

  describe "group messages - schedule" do
    test "schedule with title and author creates a reading" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Added to the schedule"
        assert body =~ "Piranesi by Susanna Clarke"
        assert body =~ "January"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/schedule Piranesi by Susanna Clarke for January")
               )
    end

    test "schedule without author creates a reading" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Added to the schedule"
        assert body =~ "Piranesi"
        assert body =~ "January"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/schedule Piranesi for January")
               )
    end

    test "schedule with no args shows the schedule" do
      club = create_club()

      YonderbookClubs.Readings.create_reading(club, %{
        title: "Piranesi",
        author: "Susanna Clarke",
        time_label: "January"
      })

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Reading schedule"
        assert body =~ "January — Piranesi by Susanna Clarke"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/schedule"))
    end

    test "schedule with no entries shows empty message" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "No readings scheduled"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/schedule"))
    end

    test "schedule preserves original casing of title and author" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Piranesi by Susanna Clarke"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/SCHEDULE Piranesi by Susanna Clarke for January")
               )
    end

    test "schedule without 'for' keyword gives help" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Try:"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/schedule Piranesi")
               )
    end

    test "schedule works without leading slash" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Added to the schedule"
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "schedule Piranesi for January")
               )
    end

    test "schedule auto-creates club if none exists" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.new789", body ->
        assert body =~ "Added to the schedule"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.new789", "/schedule Piranesi for January")
               )
    end

    test "schedule handles 'for' in book titles" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Waiting for Godot"
        assert body =~ "January"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/schedule Waiting for Godot for January")
               )
    end

    test "schedule handles 'by' in titles with author" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Stand by Me"
        assert body =~ "Stephen King"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/schedule Stand by Me by Stephen King for April")
               )
    end

    test "re-scheduling same book updates the time" do
      club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, 2, fn "group.abc123", body ->
        assert body =~ "Added to the schedule"
        :ok
      end)

      Router.handle_message(
        group_message("group.abc123", "/schedule Piranesi for January")
      )

      Router.handle_message(
        group_message("group.abc123", "/schedule Piranesi for February")
      )

      readings = YonderbookClubs.Readings.list_readings(club)
      assert length(readings) == 1
      assert hd(readings).time_label == "February"
    end
  end

  describe "group messages - unschedule" do
    test "unschedule removes a reading by title" do
      club = create_club()

      YonderbookClubs.Readings.create_reading(club, %{
        title: "Piranesi",
        time_label: "January"
      })

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Removed"
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/unschedule Piranesi")
               )
    end

    test "unschedule with unknown title gives error" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Couldn't find"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/unschedule Nonexistent")
               )
    end

    test "unschedule with no args gives help" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Which book?"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/unschedule")
               )
    end

    test "unschedule by time label removes the reading" do
      club = create_club()

      YonderbookClubs.Readings.create_reading(club, %{
        title: "Piranesi",
        time_label: "March"
      })

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Removed"
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/unschedule March")
               )
    end

    test "unschedule is case-insensitive for book title" do
      club = create_club()

      YonderbookClubs.Readings.create_reading(club, %{
        title: "Piranesi",
        time_label: "January"
      })

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Removed"
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/unschedule piranesi")
               )
    end
  end

  describe "DM messages - schedule" do
    test "schedule DM shows the reading schedule" do
      club = create_club()

      YonderbookClubs.Readings.create_reading(club, %{
        title: "Piranesi",
        author: "Susanna Clarke",
        time_label: "January"
      })

      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Reading schedule"
        assert body =~ "January — Piranesi by Susanna Clarke"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("schedule"))
    end

    test "schedule DM with no entries shows empty message" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "No readings scheduled"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("schedule"))
    end

    test "schedule DM when not in any clubs tells the user" do
      expect(YonderbookClubs.Signal.Mock, :list_groups, fn ->
        {:ok, []}
      end)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "not in any of your group chats"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("schedule"))
    end
  end

  describe "malformed messages" do
    test "message with no groupInfo or sourceUuid returns :noop" do
      assert :noop = Router.handle_message(%{"message" => "hello"})
    end
  end
end
