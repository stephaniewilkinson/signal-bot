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
end
