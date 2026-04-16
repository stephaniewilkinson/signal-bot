defmodule YonderbookClubs.Bot.RouterTest do
  use YonderbookClubs.DataCase, async: false
  use Oban.Testing, repo: YonderbookClubs.Repo

  import Mox

  alias YonderbookClubs.Bot.Router
  alias YonderbookClubs.Clubs
  alias YonderbookClubs.Suggestions

  setup do
    YonderbookClubs.Bot.PendingCommands.clear()
    :ok
  end

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
    {:ok, club} = Clubs.mark_onboarded(club)
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

      assert :ok = Router.handle_message(group_message("group.abc123", "/start vote 1"))

      assert_enqueued worker: YonderbookClubs.Workers.SendVoteWorker
      assert %{success: 1} = Oban.drain_queue(queue: :default)

      assert Suggestions.list_suggestions(club) == []

      updated_club = Clubs.get_club_by_group_id("group.abc123")
      assert updated_club.voting_active == true
    end

    test "start vote without number prompts for vote budget" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "How many books"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/start vote"))
    end

    test "start vote without number says already open when voting is active" do
      club = create_club()
      Clubs.set_voting_active(club, true)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "already a vote going"
        :ok
      end)

      assert {:error, :already_voting} =
               Router.handle_message(group_message("group.abc123", "/start vote"))
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

      assert :ok = Router.handle_message(group_message("group.abc123", "/start vote 3"))

      assert_enqueued worker: YonderbookClubs.Workers.SendVoteWorker
      assert %{success: 1} = Oban.drain_queue(queue: :default)
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

      assert :ok = Router.handle_message(group_message("group.abc123", "/start vote 5"))

      assert_enqueued worker: YonderbookClubs.Workers.SendVoteWorker
      assert %{success: 1} = Oban.drain_queue(queue: :default)
    end

    test "start vote with no suggestions replies and does not activate voting" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "No suggestions yet"
        :ok
      end)

      assert {:error, :no_suggestions} =
               Router.handle_message(group_message("group.abc123", "/start vote 1"))

      updated_club = Clubs.get_club_by_group_id("group.abc123")
      assert updated_club.voting_active == false
    end

    test "start vote when already voting replies accordingly" do
      club = create_club()
      Clubs.set_voting_active(club, true)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "already a vote going"
        :ok
      end)

      assert {:error, :already_voting} =
               Router.handle_message(group_message("group.abc123", "/start vote 1"))
    end

    test "start poll is an alias for start vote" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")
      add_suggestion(club, "Babel", "RF Kuang")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", _body, _attachments -> :ok end)

      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", _question, _options ->
        {:ok, 1234567890}
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/start poll 1"))

      assert_enqueued worker: YonderbookClubs.Workers.SendVoteWorker
      assert %{success: 1} = Oban.drain_queue(queue: :default)
    end

    test "start vote is case insensitive" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")
      add_suggestion(club, "Babel", "RF Kuang")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", _body, _attachments -> :ok end)

      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", _question, _options ->
        {:ok, 1234567890}
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/START VOTE 1"))

      assert_enqueued worker: YonderbookClubs.Workers.SendVoteWorker
      assert %{success: 1} = Oban.drain_queue(queue: :default)
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

      assert :ok = Router.handle_message(group_message("group.abc123", "/start vote 9"))

      assert_enqueued worker: YonderbookClubs.Workers.SendVoteWorker
      assert %{success: 1} = Oban.drain_queue(queue: :default)

      assert Suggestions.list_suggestions(club) == []
    end
  end

  describe "group messages - start vote rollback" do
    test "start vote with only one suggestion rolls back voting_active" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Only one suggestion so far"
        :ok
      end)

      assert {:error, :not_enough_suggestions} =
               Router.handle_message(group_message("group.abc123", "/start vote 1"))

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
        assert body =~ "/results"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/close vote"))

      updated_club = Clubs.get_club_by_group_id("group.abc123")
      assert updated_club.voting_active == false
    end

    test "close poll is an alias for close vote" do
      club = create_club()
      Clubs.set_voting_active(club, true)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Vote closed"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/close poll"))

      updated_club = Clubs.get_club_by_group_id("group.abc123")
      assert updated_club.voting_active == false
    end

    test "close vote when no vote is active tells the user" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "no vote going on right now"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/close vote"))
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

      # Step 1: confirmation prompt
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Piranesi"
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Piranesi by Susanna Clarke"))

      # Step 2: confirm with "yes"
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Piranesi"
        assert body =~ "Test Club"
        assert body =~ "remove"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("yes"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
      assert hd(suggestions).title =~ "Piranesi"
    end

    test "suggest Author, Title format works (integration)" do
      club = create_club()

      mock_list_groups_with_club()

      # Step 1: confirmation prompt
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Piranesi"
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Susanna Clarke, Piranesi"))

      # Step 2: confirm
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Piranesi"
        assert body =~ "Susanna Clarke"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("y"))

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
        assert body =~ "What would you like to suggest?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest"))
    end

    test "suggest with overly long text is rejected" do
      _club = create_club()
      mock_list_groups_with_club()

      long_text = String.duplicate("a", 501)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "a bit long"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest #{long_text}"))
    end

    test "suggest with free text that finds no results gives error" do
      _club = create_club()

      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "couldn't find that one"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest asdfghjkl nonsense"))
    end

    test "suggest with free text that matches Open Library (integration)" do
      club = create_club()

      mock_list_groups_with_club()

      # Step 1: confirmation prompt
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Piranesi"
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Piranesi Susanna Clarke"))

      # Step 2: confirm
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("yes"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
    end
  end

  describe "DM messages - unrecognized" do
    test "unrecognized DM from new user sends help text" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "suggest"
        assert body =~ "remove"
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

      assert :ok = Router.handle_message(group_message("group.abc123", "/results"))
    end

    test "results with no polls tells the user" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "No polls yet"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/results"))
    end
  end

  # --- Schedule Tests ---

  describe "group messages - schedule" do
    test "schedule with title and author creates a reading" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "on the schedule"
        assert body =~ "Piranesi by Susanna Clarke"
        assert body =~ "Jan"
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
        assert body =~ "on the schedule"
        assert body =~ "Piranesi"
        assert body =~ "Jan"
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
        assert body =~ "Jan — Piranesi by Susanna Clarke"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/schedule"))
    end

    test "schedule with no entries shows empty message" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Nothing on the schedule yet"
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

    test "schedule without 'for' keyword asks for time" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "For when?"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/schedule Piranesi")
               )
    end

    test "schedule works with leading slash" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "on the schedule"
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/schedule Piranesi for January")
               )
    end

    test "schedule auto-creates club if none exists" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.new789", body ->
        assert body =~ "on the schedule"
        :ok
      end)

      # Welcome message also sent since this is a new club
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.new789", body ->
        assert body =~ "I'm Yonderbook Clubs"
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
        assert body =~ "Jan"
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
        assert body =~ "on the schedule"
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
        assert body =~ "couldn't find"
        :ok
      end)

      assert :ok =
               Router.handle_message(
                 group_message("group.abc123", "/unschedule Nonexistent")
               )
    end

    test "unschedule with no args gives help" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Which book"
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
        assert body =~ "Jan — Piranesi by Susanna Clarke"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("schedule"))
    end

    test "schedule DM with no entries shows empty message" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Nothing on the schedule yet"
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

  # --- Onboarding Tests ---

  describe "group onboarding" do
    test "first recognized command sends welcome message" do
      {:ok, _club} = Clubs.get_or_create_club("group.abc123", "Test Club")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Nothing on the schedule yet"
        :ok
      end)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "I'm Yonderbook Clubs"
        assert body =~ "DM me"
        :ok
      end)

      Router.handle_message(group_message("group.abc123", "/schedule"))
    end

    test "welcome is not sent on subsequent commands" do
      club = create_club()
      Clubs.set_voting_active(club, true)

      # Mark as already onboarded
      YonderbookClubs.Clubs.mark_onboarded(club)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Vote closed"
        :ok
      end)

      # Only one send_message call — no welcome
      Router.handle_message(group_message("group.abc123", "/close vote"))
    end

    test "unrecognized group messages do not trigger welcome" do
      {:ok, _club} = Clubs.get_or_create_club("group.abc123", "Test Club")

      # No send_message expectations — nothing should be sent
      assert :noop = Router.handle_message(group_message("group.abc123", "hello everyone"))
    end
  end

  describe "DM onboarding" do
    test "first unrecognized DM from new user sends help text" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-newbie", body ->
        assert body =~ "suggest"
        assert body =~ "remove"
        assert body =~ "ai:"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("hello", sender: "uuid-newbie"))
    end

    test "unrecognized DM from user with suggestions sends short fallback" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke", sender: "uuid-veteran")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-veteran", body ->
        assert body =~ "/help"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("what is this", sender: "uuid-veteran"))
    end
  end

  describe "wrong context commands" do
    test "group command in DM redirects to group chat" do
      for cmd <- ["/start vote", "/start vote 2", "/start poll", "/start poll 3",
                  "/close vote", "/close poll", "/results"] do
        expect(YonderbookClubs.Signal.Mock, :send_message, fn _uuid, msg ->
          assert msg =~ "group chat"
          :ok
        end)

        assert :ok = Router.handle_message(dm_message(cmd))
      end
    end

    test "group command in DM names the club when sender has suggestions" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke", sender: "uuid-club-member")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-club-member", msg ->
        assert msg =~ "Test Club group chat"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/start vote", sender: "uuid-club-member"))
    end

    test "DM command in group chat redirects to DM" do
      club = create_club()

      for {cmd, expected} <- [
        {"/suggest Piranesi", "secret"},
        {"/suggest", "DMs"},
        {"/remove", "DMs"},
        {"/help", "DMs"}
      ] do
        expect(YonderbookClubs.Signal.Mock, :send_message, fn _gid, msg ->
          assert msg =~ expected
          :ok
        end)

        assert :ok = Router.handle_message(group_message(club.signal_group_id, cmd))
      end
    end
  end

  describe "short aliases" do
    test "/r is an alias for /remove" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "don't have any suggestions"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/r"))
    end

    test "/s is an alias for /suggest" do
      club = create_club()
      mock_list_groups_with_club()

      # Step 1: confirmation prompt
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Piranesi"
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/s Piranesi by Susanna Clarke"))

      # Step 2: confirm
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Piranesi"
        assert body =~ "Test Club"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("yes"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
    end

    test "/s with no text gives guidance" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "What would you like to suggest?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/s"))
    end
  end

  describe "fuzzy match" do
    test "typo in DM suggests the correct command" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Did you mean /suggest?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("sugget"))
    end

    test "hlep suggests help" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Did you mean /help?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("hlep"))
    end
  end

  describe "malformed messages" do
    test "message with no groupInfo or sourceUuid returns :noop" do
      assert :noop = Router.handle_message(%{"message" => "hello"})
    end
  end

  # --- Multi-club selection ---

  describe "DM messages - club selection with #N" do
    setup do
      _club1 = create_club("group.abc123", "Near Wild Heaven")
      _club2 = create_club("group.def456", "Witchy Mamas")
      :ok
    end

    defp mock_list_two_clubs do
      expect(YonderbookClubs.Signal.Mock, :list_groups, fn ->
        {:ok, [
          %{"id" => "group.abc123", "name" => "Near Wild Heaven"},
          %{"id" => "group.def456", "name" => "Witchy Mamas"}
        ]}
      end)
    end

    test "suggestions #2 shows suggestions for the second club" do
      mock_list_two_clubs()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "No suggestions yet"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/suggestions #2"))
    end

    test "suggestions 1 shows suggestions for the first club" do
      mock_list_two_clubs()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "No suggestions yet"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/suggestions 1"))
    end

    test "remove #1 removes from the first club" do
      mock_list_two_clubs()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "don't have any suggestions"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/remove #1"))
    end

    test "r #2 removes from the second club" do
      mock_list_two_clubs()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "don't have any suggestions"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/r #2"))
    end
  end

  describe "DM messages - conversational club selection" do
    setup do
      _club1 = create_club("group.abc123", "Near Wild Heaven")
      _club2 = create_club("group.def456", "Witchy Mamas")
      :ok
    end

    defp mock_list_two_clubs_twice do
      expect(YonderbookClubs.Signal.Mock, :list_groups, 2, fn ->
        {:ok, [
          %{"id" => "group.abc123", "name" => "Near Wild Heaven"},
          %{"id" => "group.def456", "name" => "Witchy Mamas"}
        ]}
      end)
    end

    test "replying with a number after multi-club prompt resumes the command" do
      mock_list_two_clubs_twice()

      # First: /suggestions triggers multi-club prompt
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Which one?"
        assert body =~ "Near Wild Heaven"
        assert body =~ "Witchy Mamas"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/suggestions"))

      # Then: reply with just "2"
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "No suggestions yet"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("2"))
    end

    test "replying with #N after multi-club prompt resumes the command" do
      mock_list_two_clubs_twice()

      # First: /remove triggers multi-club prompt
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Which one?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/remove"))

      # Then: reply with "#1"
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "don't have any suggestions"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("#1"))
    end

    test "replying with a number when no pending command falls through" do
      # No prior multi-club prompt — "42" should be treated as unrecognized
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        # Should get help text since no suggestions exist for this user
        assert body =~ "suggest"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("42"))
    end
  end

  describe "DM messages - bare /suggest follow-up" do
    test "bare /suggest stores pending, next message becomes the suggestion" do
      club = create_club()

      # First: bare /suggest prompts for text
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "What would you like to suggest?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/suggest"))

      # Then: reply with the book — gets confirmation prompt
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Piranesi"
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("Piranesi by Susanna Clarke"))

      # Then: confirm
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Piranesi"
        assert body =~ "Test Club"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("yes"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
    end

    test "bare /s also stores pending" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "What would you like to suggest?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/s"))

      # Then: reply with the book — gets confirmation prompt
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Piranesi"
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("Piranesi by Susanna Clarke"))
    end
  end

  describe "group messages - conversational start vote" do
    test "bare /start vote then number starts the vote" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")
      add_suggestion(club, "Babel", "RF Kuang")

      # First: bare /start vote prompts for number
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "How many"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/start vote"))

      # Then: reply with just "1"
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", _body, _attachments -> :ok end)
      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", _question, _options -> {:ok, 123} end)

      assert :ok = Router.handle_message(group_message("group.abc123", "1"))

      assert_enqueued worker: YonderbookClubs.Workers.SendVoteWorker
      assert %{success: 1} = Oban.drain_queue(queue: :default)
    end

    test "invalid budget then number starts the vote" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")
      add_suggestion(club, "Babel", "RF Kuang")

      # First: invalid budget
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "between 1 and 50"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/start vote abc"))

      # Then: valid number
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", _body, _attachments -> :ok end)
      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", _question, _options -> {:ok, 123} end)

      assert :ok = Router.handle_message(group_message("group.abc123", "2"))

      assert_enqueued worker: YonderbookClubs.Workers.SendVoteWorker
      assert %{success: 1} = Oban.drain_queue(queue: :default)
    end

    test "non-numeric reply after /start vote is ignored" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "How many"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/start vote"))

      # Reply with text, not a number — should be :noop
      assert :noop = Router.handle_message(group_message("group.abc123", "hello"))
    end
  end

  describe "group messages - conversational unschedule" do
    test "bare /unschedule then title removes the reading" do
      club = create_club()

      YonderbookClubs.Readings.create_reading(club, %{
        title: "Piranesi",
        time_label: "January"
      })

      # First: bare /unschedule prompts for title
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Which book"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/unschedule"))

      # Then: reply with title
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Removed"
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "Piranesi"))
    end
  end

  describe "group messages - conversational schedule" do
    test "schedule without 'for' then time saves the reading" do
      _club = create_club()

      # First: /schedule Piranesi — missing "for"
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "For when?"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/schedule Piranesi"))

      # Then: reply with the time
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "on the schedule"
        assert body =~ "Piranesi"
        assert body =~ "Jan"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "January"))
    end

    test "schedule with author but no 'for' then time saves with author" do
      _club = create_club()

      # First: /schedule Piranesi by Susanna Clarke — missing "for"
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "For when?"
        :ok
      end)

      assert :ok = Router.handle_message(
        group_message("group.abc123", "/schedule Piranesi by Susanna Clarke")
      )

      # Then: reply with the time
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "on the schedule"
        assert body =~ "Piranesi by Susanna Clarke"
        assert body =~ "Mar"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "March"))
    end
  end

  describe "removing bot from one club does not break other clubs" do
    test "user can still DM for Club B after bot is removed from Club A" do
      # Setup: bot is in two clubs, user is a member of both
      _club_a = create_club("group.a", "Club A")
      club_b = create_club("group.b", "Club B")
      add_suggestion(club_b, "Piranesi", "Susanna Clarke")

      # Bot is removed from Club A
      bot_number = Application.get_env(:yonderbook_clubs, :signal_bot_number)
      Router.handle_group_quit("group.a", bot_number)

      # User DMs /suggestions — list_groups now only returns Club B
      expect(YonderbookClubs.Signal.Mock, :list_groups, fn ->
        {:ok, [%{"id" => "group.b", "name" => "Club B", "members" => ["uuid-sender"]}]}
      end)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        # Should resolve to Club B and show its suggestions — NOT "not in any clubs"
        refute body =~ "not in any"
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/suggestions"))
    end

    test "groups where bot is no longer a member are excluded from resolve" do
      _club_a = create_club("group.a", "Old Club")
      club_b = create_club("group.b", "Current Club")
      add_suggestion(club_b, "Piranesi", "Susanna Clarke")

      # signal-cli returns both groups, but bot was removed from group.a
      expect(YonderbookClubs.Signal.Mock, :list_groups, fn ->
        {:ok, [
          %{"id" => "group.a", "name" => "Old Club", "isMember" => false},
          %{"id" => "group.b", "name" => "Current Club", "isMember" => true}
        ]}
      end)

      # Should resolve directly to Club B — not prompt "which club?"
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        refute body =~ "Which one"
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/suggestions"))
    end

    test "resolve works when signal-cli returns members as phone numbers" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")

      # signal-cli returns members as phone numbers, not UUIDs —
      # resolve must not filter by member format
      expect(YonderbookClubs.Signal.Mock, :list_groups, fn ->
        {:ok, [%{"id" => "group.abc123", "name" => "Test Club", "members" => ["+14155551234"]}]}
      end)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        refute body =~ "not in any"
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/suggestions"))
    end
  end

  describe "event-driven club deactivation" do
    test "handle_group_quit deactivates a club when the bot leaves" do
      club = create_club("group.removed", "Removed Club")
      assert club.active == true

      # Simulate the bot being removed from the group
      bot_number = Application.get_env(:yonderbook_clubs, :signal_bot_number)
      assert :ok = Router.handle_group_quit("group.removed", bot_number)

      # The club should now be inactive
      updated = YonderbookClubs.Repo.get!(YonderbookClubs.Clubs.Club, club.id)
      assert updated.active == false
      assert updated.voting_active == false
    end

    test "handle_group_quit does NOT deactivate when a regular member leaves" do
      club = create_club("group.still-active", "Active Club")
      assert club.active == true

      # A regular member leaves — NOT the bot
      assert :ok = Router.handle_group_quit("group.still-active", "some-member-uuid")

      # The club should still be active
      updated = YonderbookClubs.Repo.get!(YonderbookClubs.Clubs.Club, club.id)
      assert updated.active == true
    end

    test "handle_group_quit with unknown group is a no-op" do
      bot_number = Application.get_env(:yonderbook_clubs, :signal_bot_number)
      assert :ok = Router.handle_group_quit("group.unknown", bot_number)
    end
  end

  describe "group pending commands - sender scoping" do
    test "different sender's reply does not consume another sender's pending" do
      _club = create_club()

      # Alice says /start vote
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "How many"
        :ok
      end)

      assert :ok = Router.handle_message(
        group_message("group.abc123", "/start vote", sender: "alice-uuid")
      )

      # Bob says "2" — should NOT start a vote (it's Alice's pending, not Bob's)
      assert :noop = Router.handle_message(
        group_message("group.abc123", "2", sender: "bob-uuid")
      )
    end

    test "same sender's reply does consume their pending" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")
      add_suggestion(club, "Babel", "RF Kuang")

      # Alice says /start vote
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "How many"
        :ok
      end)

      assert :ok = Router.handle_message(
        group_message("group.abc123", "/start vote", sender: "alice-uuid")
      )

      # Alice says "1" — should start the vote
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", _body, _attachments -> :ok end)
      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", _q, _o -> {:ok, 123} end)

      assert :ok = Router.handle_message(
        group_message("group.abc123", "1", sender: "alice-uuid")
      )

      assert_enqueued worker: YonderbookClubs.Workers.SendVoteWorker
      assert %{success: 1} = Oban.drain_queue(queue: :default)
    end
  end

  describe "DM messages - club resolution from list_groups" do
    test "resolves to the single club when list_groups returns one group" do
      club = create_club("group.abc123", "Alice's Club")
      add_suggestion(club, "Piranesi", "Susanna Clarke")

      expect(YonderbookClubs.Signal.Mock, :list_groups, fn ->
        {:ok, [%{"id" => "group.abc123", "name" => "Alice's Club"}]}
      end)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/suggestions"))
    end

    test "prompts for club when list_groups returns multiple groups" do
      _club1 = create_club("group.abc123", "Alice's Club")
      _club2 = create_club("group.def456", "Bob's Club")

      expect(YonderbookClubs.Signal.Mock, :list_groups, fn ->
        {:ok, [
          %{"id" => "group.abc123", "name" => "Alice's Club", "members" => ["+1234567890"]},
          %{"id" => "group.def456", "name" => "Bob's Club", "members" => ["+0987654321"]}
        ]}
      end)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Which one"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/suggestions"))
    end
  end

  describe "club list ordering" do
    test "clubs are listed in stable alphabetical order" do
      _club_z = create_club("group.zzz", "Zebra Club")
      _club_a = create_club("group.aaa", "Alpha Club")
      _club_m = create_club("group.mmm", "Mango Club")

      expect(YonderbookClubs.Signal.Mock, :list_groups, fn ->
        {:ok, [
          %{"id" => "group.zzz", "name" => "Zebra Club"},
          %{"id" => "group.aaa", "name" => "Alpha Club"},
          %{"id" => "group.mmm", "name" => "Mango Club"}
        ]}
      end)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Which one?"
        # Verify alphabetical ordering
        alpha_pos = :binary.match(body, "Alpha Club") |> elem(0)
        mango_pos = :binary.match(body, "Mango Club") |> elem(0)
        zebra_pos = :binary.match(body, "Zebra Club") |> elem(0)
        assert alpha_pos < mango_pos
        assert mango_pos < zebra_pos
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("/suggestions"))
    end
  end

  # --- AI Confirmation Flow ---

  describe "DM messages - AI confirmation flow" do
    test "freetext suggestion failure offers AI, yes triggers AI search" do
      _club = create_club()
      mock_list_groups_with_club()

      # First: suggest gibberish — Open Library won't find it
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Want me to use AI to look it up?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest xyzzy flurbo"))

      # Then: reply "yes" — triggers AI search
      # First expect: the progress message
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Looking that up"
        :ok
      end)

      # AI search will also fail for gibberish, so we get the final error
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "still couldn't find"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("yes"))
    end

    test "freetext suggestion failure offers AI, no declines gracefully" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Want me to use AI to look it up?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest xyzzy flurbo"))

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "No worries"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("no"))
    end

    test "freetext suggestion failure offers AI, y works as yes" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Want me to use AI to look it up?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest xyzzy flurbo"))

      # First expect: the progress message
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Looking that up"
        :ok
      end)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "still couldn't find"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("y"))
    end

    test "freetext suggestion failure offers AI, n works as no" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Want me to use AI to look it up?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest xyzzy flurbo"))

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "No worries"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("n"))
    end

    test "freetext suggestion failure offers AI, unrelated reply falls through" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Want me to use AI to look it up?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest xyzzy flurbo"))

      # Reply with something other than yes/no — should fall through to fallback
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        # Falls through to handle_fallback (new user → help text)
        assert body =~ "suggest" or body =~ "help"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("maybe"))
    end

    test "title+author suggestion failure offers AI confirmation" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Want me to use AI to look it up?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Xyzzybook by Flurbo McFake"))
    end
  end

  # --- ISBN Suggestion Flow ---

  describe "DM messages - ISBN suggestion" do
    test "valid ISBN-13 that matches finds the book (integration)" do
      club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest 9781526622426"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
    end

    test "ISBN that doesn't match gives error" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "couldn't find that ISBN"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest 9799999999999"))
    end
  end

  # --- Book Confirmation Flow ---

  describe "DM messages - book confirmation flow" do
    test "user says no, sees alternatives list (integration)" do
      _club = create_club()
      mock_list_groups_with_club()

      # Use freetext (no "by") so Open Library returns multiple results
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest the hobbit"))

      # Say no — gets alternatives list (freetext returns many results)
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Here are some other matches"
        assert body =~ "1."
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("no"))
    end

    test "user says no with no alternatives gets graceful exit" do
      _club = create_club()
      mock_list_groups_with_club()

      # Specific title+author search may return only 1 result
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Piranesi by Susanna Clarke"))

      # Say no — no alternatives, offers AI with rejected title carried through
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "use AI to look it up"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("no"))
    end

    test "user picks an alternative by number (integration)" do
      club = create_club()
      mock_list_groups_with_club()

      # Use freetext for multiple results
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest the hobbit"))

      # Say no — gets alternatives
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Here are some other matches"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("n"))

      # Pick number 1
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Nice! Added"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("1"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
    end

    test "user says yes confirms the top match (integration)" do
      club = create_club()
      mock_list_groups_with_club()

      # Step 1: confirmation prompt
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Piranesi"
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Piranesi by Susanna Clarke"))

      # Step 2: yes
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Nice! Added"
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("y"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
    end

    test "unrelated reply after confirmation prompt falls through" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Piranesi by Susanna Clarke"))

      # Unrelated reply — falls through to fallback
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        # Should get help or fallback, not crash
        assert is_binary(body)
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("hello"))
    end

    test "ISBN suggestions skip confirmation and save immediately" do
      club = create_club()
      mock_list_groups_with_club()

      # ISBN is exact — should save directly with no confirmation step
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body, _attachments ->
        assert body =~ "Nice! Added"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest 9780547928227"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
    end
  end

    @tag :external
    test "freetext 'the moor witch' finds Moorwitch and offers AI after rejection" do
      _club = create_club()
      mock_list_groups_with_club()

      # Step 1: freetext search finds Moorwitch via collapsed query fallback
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Moorwitch"
        assert body =~ "Jessica Khoury"
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest the moor witch"))

      # Step 2: user rejects — offers AI (which might find a different book),
      # with the rejected title carried through so the same book isn't re-suggested
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "use AI to look it up"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("no"))
    end

  # --- Suggest ai: Prefix ---

  describe "DM messages - suggest ai: prefix" do
    test "suggest ai: without API key returns error" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Looking that up"
        :ok
      end)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "still couldn't find"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest ai: that book about the infinite house"))
    end
  end

  # --- Duplicate Suggestion ---

  describe "DM messages - duplicate suggestion" do
    test "suggesting a book already on the list says so" do
      club = create_club()
      # Use the real Open Library work ID for Piranesi
      add_suggestion(club, "Piranesi", "Susanna Clarke", work_id: "OL20893680W")

      mock_list_groups_with_club()

      # Step 1: confirmation prompt (bot doesn't know it's a dupe yet)
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Piranesi"
        assert body =~ "is that right?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Piranesi by Susanna Clarke"))

      # Step 2: confirm — deduplication check fires on save
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Good taste"
        assert body =~ "already on the list"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("yes"))
    end
  end

  # --- Group Redirect from DM ---

  describe "DM messages - group command redirects" do
    test "start vote in DM redirects to group" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "group chat command"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("start vote"))
    end

    test "close vote in DM redirects to group" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "group chat command" or body =~ "DMs"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("close vote"))
    end

    test "unschedule in DM prompts for title" do
      _club = create_club()
      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Which book?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("unschedule"))
    end
  end

  # --- Group DM Redirects ---

  describe "group messages - DM command redirects" do
    test "suggest in group redirects to DM" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "DMs" or body =~ "direct message"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/suggest"))
    end

    test "suggest with text in group redirects to DM" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "secret" or body =~ "DM"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/suggest Piranesi by Susanna Clarke"))
    end

    test "help in group redirects to DM" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "DMs" or body =~ "direct message"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "/help"))
    end
  end

  # --- Edge Cases ---

  describe "edge cases" do
    test "suggest with only whitespace after prefix gives guidance" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "What would you like to suggest?"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest    "))
    end

    test "commands work without leading slash" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Hey there" or body =~ "suggest"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("help"))
    end

    test "commands are case insensitive" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Hey there" or body =~ "suggest"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("HELP"))
    end

    test "close vote with no club is noop" do
      assert :noop = Router.handle_message(group_message("group.nonexistent", "/close vote"))
    end

    test "results with no club is noop" do
      assert :noop = Router.handle_message(group_message("group.nonexistent", "/results"))
    end

    test "message with no groupInfo or sourceUuid is ignored" do
      msg = %{"message" => "hello"}
      assert :noop = Router.handle_message(msg)
    end

    test "schedule limit reached gives friendly message" do
      club = create_club()

      for i <- 1..50 do
        YonderbookClubs.Readings.create_reading(club, %{
          title: "Book #{i}",
          time_label: "Month #{i}"
        })
      end

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "full"
        assert body =~ "50"
        :ok
      end)

      assert :ok = Router.handle_message(
        group_message("group.abc123", "/schedule Another Book for January")
      )
    end
  end

  # --- Unschedule with sender scoping ---

  describe "group messages - unschedule sender scoping" do
    test "bare /unschedule with sender_uuid stores sender-scoped pending" do
      club = create_club()

      YonderbookClubs.Readings.create_reading(club, %{
        title: "Piranesi",
        time_label: "January"
      })

      # Alice says /unschedule
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Which book"
        :ok
      end)

      assert :ok = Router.handle_message(
        group_message("group.abc123", "/unschedule", sender: "alice-uuid")
      )

      # Bob replies — should NOT consume Alice's pending
      assert :noop = Router.handle_message(
        group_message("group.abc123", "Piranesi", sender: "bob-uuid")
      )

      # Alice replies — should consume her pending
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Removed"
        assert body =~ "Piranesi"
        :ok
      end)

      assert :ok = Router.handle_message(
        group_message("group.abc123", "Piranesi", sender: "alice-uuid")
      )
    end

    test "/unschedule with trailing whitespace stores sender-scoped pending" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Which book"
        :ok
      end)

      assert :ok = Router.handle_message(
        group_message("group.abc123", "/unschedule   ", sender: "alice-uuid")
      )
    end
  end
end
