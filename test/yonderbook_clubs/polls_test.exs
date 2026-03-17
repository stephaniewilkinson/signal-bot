defmodule YonderbookClubs.PollsTest do
  use YonderbookClubs.DataCase, async: true

  alias YonderbookClubs.Clubs
  alias YonderbookClubs.Polls
  alias YonderbookClubs.Suggestions

  defp create_club do
    signal_group_id = "group-#{System.unique_integer([:positive])}"
    {:ok, club} = Clubs.get_or_create_club(signal_group_id, "Test Club")
    club
  end

  defp add_suggestion(club, title, author) do
    attrs = %{
      title: title,
      author: author,
      open_library_work_id: "OL#{System.unique_integer([:positive])}W",
      signal_sender_uuid: "uuid-#{System.unique_integer([:positive])}"
    }

    {:ok, suggestion} = Suggestions.create_suggestion(club, attrs)
    suggestion
  end

  describe "create_poll/4" do
    test "creates a poll with options" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      s2 = add_suggestion(club, "Babel", "RF Kuang")

      assert {:ok, poll} = Polls.create_poll(club, 1_000_000, 2, [s1, s2])
      assert poll.vote_budget == 2
      assert poll.status == :active
      assert poll.signal_timestamp == 1_000_000
    end

    test "rejects duplicate timestamps" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")

      assert {:ok, _} = Polls.create_poll(club, 1_000_001, 1, [s1])
      assert {:error, _} = Polls.create_poll(club, 1_000_001, 1, [s1])
    end
  end

  describe "record_vote/4" do
    test "records a valid vote" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      {:ok, poll} = Polls.create_poll(club, 2_000_000, 1, [s1])

      assert {:ok, vote} = Polls.record_vote(poll, "voter-uuid-1", [0], 1)
      assert vote.option_indexes == [0]
      assert vote.vote_count == 1
    end

    test "updates vote on re-vote by same user" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      s2 = add_suggestion(club, "Babel", "RF Kuang")
      {:ok, poll} = Polls.create_poll(club, 2_000_001, 2, [s1, s2])

      {:ok, _} = Polls.record_vote(poll, "voter-uuid-2", [0], 1)
      {:ok, updated} = Polls.record_vote(poll, "voter-uuid-2", [1], 1)

      assert updated.option_indexes == [1]
    end

    test "rejects negative option indexes" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      {:ok, poll} = Polls.create_poll(club, 2_000_002, 1, [s1])

      assert {:error, changeset} = Polls.record_vote(poll, "voter-uuid-3", [-1], 1)
      assert errors_on(changeset)[:option_indexes]
    end

    test "rejects zero vote_count" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      {:ok, poll} = Polls.create_poll(club, 2_000_003, 1, [s1])

      assert {:error, changeset} = Polls.record_vote(poll, "voter-uuid-4", [0], 0)
      assert errors_on(changeset)[:vote_count]
    end

    test "rejects empty option_indexes" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      {:ok, poll} = Polls.create_poll(club, 2_000_004, 1, [s1])

      assert {:error, changeset} = Polls.record_vote(poll, "voter-uuid-5", [], 1)
      assert errors_on(changeset)[:option_indexes]
    end

    test "rejects negative vote_count" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      {:ok, poll} = Polls.create_poll(club, 2_000_005, 1, [s1])

      assert {:error, changeset} = Polls.record_vote(poll, "voter-uuid-6", [0], -1)
      assert errors_on(changeset)[:vote_count]
    end
  end

  describe "close_poll/1" do
    test "transitions poll to closed" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      {:ok, poll} = Polls.create_poll(club, 3_000_000, 1, [s1])

      assert {:ok, closed} = Polls.close_poll(poll)
      assert closed.status == :closed
    end
  end

  describe "get_combined_results/1" do
    test "tallies votes across polls" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      s2 = add_suggestion(club, "Babel", "RF Kuang")
      {:ok, poll} = Polls.create_poll(club, 4_000_000, 2, [s1, s2])

      Polls.record_vote(poll, "voter-1", [0, 1], 1)
      Polls.record_vote(poll, "voter-2", [0], 1)

      results = Polls.get_combined_results([poll])

      assert [{first, first_count}, {second, second_count}] = results
      assert first.id == s1.id
      assert first_count == 2
      assert second.id == s2.id
      assert second_count == 1
    end

    test "returns zero counts when no votes" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      {:ok, poll} = Polls.create_poll(club, 4_000_001, 1, [s1])

      results = Polls.get_combined_results([poll])

      assert [{suggestion, 0}] = results
      assert suggestion.id == s1.id
    end
  end

  describe "get_poll_by_timestamp/1" do
    test "finds poll by signal timestamp" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      {:ok, poll} = Polls.create_poll(club, 6_000_000, 1, [s1])

      found = Polls.get_poll_by_timestamp(6_000_000)
      assert found.id == poll.id
    end

    test "returns nil for unknown timestamp" do
      assert Polls.get_poll_by_timestamp(9_999_999) == nil
    end
  end

  describe "get_latest_active_polls/1" do
    test "returns only active polls" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")

      {:ok, active} = Polls.create_poll(club, 7_000_000, 1, [s1])
      {:ok, closed_poll} = Polls.create_poll(club, 7_000_001, 1, [s1])
      Polls.close_poll(closed_poll)

      result = Polls.get_latest_active_polls(club)
      assert length(result) == 1
      assert hd(result).id == active.id
    end

    test "returns empty list when no active polls" do
      club = create_club()
      assert Polls.get_latest_active_polls(club) == []
    end
  end

  describe "delete_poll/1" do
    test "deletes poll from database" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")
      {:ok, poll} = Polls.create_poll(club, 8_000_000, 1, [s1])

      assert {:ok, _} = Polls.delete_poll(poll)
      assert Polls.get_poll_by_timestamp(8_000_000) == nil
    end
  end

  describe "get_latest_polls/1" do
    test "returns empty list when no polls" do
      club = create_club()
      assert Polls.get_latest_polls(club) == []
    end

    test "returns the most recent batch of polls" do
      club = create_club()
      s1 = add_suggestion(club, "Piranesi", "Susanna Clarke")

      {:ok, _} = Polls.create_poll(club, 5_000_000, 1, [s1])

      polls = Polls.get_latest_polls(club)
      assert length(polls) == 1
    end
  end
end
