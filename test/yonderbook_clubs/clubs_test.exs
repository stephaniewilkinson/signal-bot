defmodule YonderbookClubs.ClubsTest do
  use YonderbookClubs.DataCase, async: true

  alias YonderbookClubs.Clubs
  alias YonderbookClubs.Clubs.Club

  describe "get_or_create_club/2" do
    test "creates a new club when none exists" do
      signal_group_id = "group-#{System.unique_integer([:positive])}"

      assert {:ok, %Club{} = club} = Clubs.get_or_create_club(signal_group_id, "My Book Club")
      assert club.signal_group_id == signal_group_id
      assert club.name == "My Book Club"
      assert club.voting_active == false
      assert club.id != nil
    end

    test "returns existing club on second call with same signal_group_id" do
      signal_group_id = "group-#{System.unique_integer([:positive])}"

      {:ok, first_club} = Clubs.get_or_create_club(signal_group_id, "My Book Club")
      {:ok, second_club} = Clubs.get_or_create_club(signal_group_id, "My Book Club")

      assert first_club.id == second_club.id
    end
  end

  describe "get_club!/1" do
    test "returns club by id" do
      signal_group_id = "group-#{System.unique_integer([:positive])}"
      {:ok, club} = Clubs.get_or_create_club(signal_group_id, "My Book Club")

      found = Clubs.get_club!(club.id)

      assert found.id == club.id
      assert found.signal_group_id == signal_group_id
    end

    test "raises on invalid id" do
      assert_raise Ecto.NoResultsError, fn ->
        Clubs.get_club!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_clubs_by_group_ids/1" do
    test "returns all matching clubs" do
      id1 = "group-#{System.unique_integer([:positive])}"
      id2 = "group-#{System.unique_integer([:positive])}"
      {:ok, club1} = Clubs.get_or_create_club(id1, "Club 1")
      {:ok, club2} = Clubs.get_or_create_club(id2, "Club 2")

      result = Clubs.get_clubs_by_group_ids([id1, id2])

      assert length(result) == 2
      ids = Enum.map(result, & &1.id)
      assert club1.id in ids
      assert club2.id in ids
    end

    test "returns empty list for empty input" do
      assert Clubs.get_clubs_by_group_ids([]) == []
    end

    test "ignores non-existent group ids" do
      id = "group-#{System.unique_integer([:positive])}"
      {:ok, _} = Clubs.get_or_create_club(id, "Club")

      result = Clubs.get_clubs_by_group_ids([id, "nonexistent-group"])
      assert length(result) == 1
    end
  end

  describe "get_club_by_group_id/1" do
    test "returns club when found" do
      signal_group_id = "group-#{System.unique_integer([:positive])}"
      {:ok, club} = Clubs.get_or_create_club(signal_group_id, "My Book Club")

      found = Clubs.get_club_by_group_id(signal_group_id)

      assert found.id == club.id
    end

    test "returns nil when not found" do
      assert Clubs.get_club_by_group_id("nonexistent-group") == nil
    end
  end

  describe "set_voting_active/2" do
    test "sets voting_active to true" do
      signal_group_id = "group-#{System.unique_integer([:positive])}"
      {:ok, club} = Clubs.get_or_create_club(signal_group_id, "My Book Club")
      assert club.voting_active == false

      {:ok, updated} = Clubs.set_voting_active(club, true)

      assert updated.voting_active == true
    end

    test "sets voting_active back to false" do
      signal_group_id = "group-#{System.unique_integer([:positive])}"
      {:ok, club} = Clubs.get_or_create_club(signal_group_id, "My Book Club")
      {:ok, club} = Clubs.set_voting_active(club, true)
      assert club.voting_active == true

      {:ok, updated} = Clubs.set_voting_active(club, false)

      assert updated.voting_active == false
    end
  end

  describe "activate_voting/1" do
    test "activates voting when currently inactive" do
      signal_group_id = "group-#{System.unique_integer([:positive])}"
      {:ok, club} = Clubs.get_or_create_club(signal_group_id, "My Book Club")

      assert {:ok, updated} = Clubs.activate_voting(club)
      assert updated.voting_active == true
    end

    test "returns error when already voting" do
      signal_group_id = "group-#{System.unique_integer([:positive])}"
      {:ok, club} = Clubs.get_or_create_club(signal_group_id, "My Book Club")
      {:ok, _} = Clubs.activate_voting(club)

      assert {:error, :already_voting} = Clubs.activate_voting(club)
    end

    test "only one concurrent activation succeeds" do
      signal_group_id = "group-#{System.unique_integer([:positive])}"
      {:ok, club} = Clubs.get_or_create_club(signal_group_id, "My Book Club")

      results =
        1..5
        |> Enum.map(fn _ ->
          Task.async(fn -> Clubs.activate_voting(club) end)
        end)
        |> Enum.map(&Task.await/1)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, :already_voting}, &1))

      assert successes == 1
      assert failures == 4
    end
  end
end
