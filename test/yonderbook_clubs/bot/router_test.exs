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

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "Piranesi"
        assert body =~ "Babel"
        assert body =~ "pick up to 1"
        :ok
      end)

      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", question, options ->
        assert question =~ "Vote for your next read"
        assert "Piranesi" in options
        assert "Babel" in options
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "start vote"))

      assert Suggestions.list_suggestions(club) == []

      updated_club = Clubs.get_club_by_group_id("group.abc123")
      assert updated_club.voting_active == true
    end

    test "start vote N parses vote budget" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "pick up to 3"
        :ok
      end)

      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", question, _options ->
        assert question =~ "Pick up to 3"
        assert question =~ "3 months"
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "start vote 3"))
    end

    test "start vote with no suggestions replies and does not activate voting" do
      _club = create_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "No suggestions yet"
        :ok
      end)

      assert {:error, :no_suggestions} =
               Router.handle_message(group_message("group.abc123", "start vote"))

      updated_club = Clubs.get_club_by_group_id("group.abc123")
      assert updated_club.voting_active == false
    end

    test "start vote when already voting replies accordingly" do
      club = create_club()
      Clubs.set_voting_active(club, true)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", body ->
        assert body =~ "already in progress"
        :ok
      end)

      assert {:error, :already_voting} =
               Router.handle_message(group_message("group.abc123", "start vote"))
    end

    test "start vote is case insensitive" do
      club = create_club()
      add_suggestion(club, "Piranesi", "Susanna Clarke")

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "group.abc123", _body -> :ok end)

      expect(YonderbookClubs.Signal.Mock, :send_poll, fn "group.abc123", _question, _options ->
        :ok
      end)

      assert :ok = Router.handle_message(group_message("group.abc123", "START VOTE"))
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
        assert body =~ "Nothing to remove"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("remove"))
    end

    test "remove when not in any clubs tells the user" do
      expect(YonderbookClubs.Signal.Mock, :list_groups, fn ->
        {:ok, []}
      end)

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "add me to a book club"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("remove"))
    end
  end

  describe "DM messages - suggest" do
    test "suggest Title by Author with a well-known book (integration)" do
      club = create_club()

      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "Piranesi"
        assert body =~ "remove"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest Piranesi by Susanna Clarke"))

      suggestions = Suggestions.list_suggestions(club)
      assert length(suggestions) == 1
      assert hd(suggestions).title =~ "Piranesi"
    end

    test "suggest with unrecognized format sends help" do
      _club = create_club()

      mock_list_groups_with_club()

      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "suggest"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("suggest foobar"))
    end
  end

  describe "DM messages - unrecognized" do
    test "unrecognized DM sends help message" do
      expect(YonderbookClubs.Signal.Mock, :send_message, fn "uuid-sender", body ->
        assert body =~ "suggest"
        :ok
      end)

      assert :ok = Router.handle_message(dm_message("what is this"))
    end
  end

  describe "malformed messages" do
    test "message with no groupInfo or sourceUuid returns :noop" do
      assert :noop = Router.handle_message(%{"message" => "hello"})
    end
  end
end
