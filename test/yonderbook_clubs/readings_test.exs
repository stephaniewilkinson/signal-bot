defmodule YonderbookClubs.ReadingsTest do
  use YonderbookClubs.DataCase, async: true

  alias YonderbookClubs.Readings
  alias YonderbookClubs.Readings.Reading

  setup do
    {:ok, club} = YonderbookClubs.Clubs.get_or_create_club("group.test123", "Test Club")
    %{club: club}
  end

  describe "create_reading/2" do
    test "creates a reading with title, author, and time_label", %{club: club} do
      attrs = %{title: "Piranesi", author: "Susanna Clarke", time_label: "January"}
      assert {:ok, %Reading{} = reading} = Readings.create_reading(club, attrs)
      assert reading.title == "Piranesi"
      assert reading.author == "Susanna Clarke"
      assert reading.time_label == "January"
      assert reading.club_id == club.id
    end

    test "creates a reading without author", %{club: club} do
      attrs = %{title: "Piranesi", time_label: "January"}
      assert {:ok, %Reading{} = reading} = Readings.create_reading(club, attrs)
      assert reading.author == nil
    end

    test "returns error changeset without required fields", %{club: club} do
      assert {:error, %Ecto.Changeset{} = changeset} = Readings.create_reading(club, %{})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
      assert %{time_label: ["can't be blank"]} = errors_on(changeset)
    end

    test "updates time_label when scheduling same book again", %{club: club} do
      {:ok, original} = Readings.create_reading(club, %{title: "Piranesi", time_label: "January"})
      {:ok, updated} = Readings.create_reading(club, %{title: "Piranesi", time_label: "February"})

      assert updated.id == original.id
      assert updated.time_label == "February"
      assert length(Readings.list_readings(club)) == 1
    end

    test "updates time_label case-insensitively", %{club: club} do
      {:ok, original} = Readings.create_reading(club, %{title: "Piranesi", time_label: "January"})
      {:ok, updated} = Readings.create_reading(club, %{title: "piranesi", time_label: "March"})

      assert updated.id == original.id
      assert updated.time_label == "March"
    end

    test "returns error when limit reached", %{club: club} do
      for i <- 1..50 do
        {:ok, _} = Readings.create_reading(club, %{title: "Book #{i}", time_label: "TBD"})
      end

      assert {:error, :limit_reached} =
               Readings.create_reading(club, %{title: "Book 51", time_label: "TBD"})
    end

    test "updating existing reading does not count against limit", %{club: club} do
      for i <- 1..50 do
        {:ok, _} = Readings.create_reading(club, %{title: "Book #{i}", time_label: "TBD"})
      end

      assert {:ok, reading} =
               Readings.create_reading(club, %{title: "Book 1", time_label: "January"})

      assert reading.time_label == "January"
    end
  end

  describe "list_readings/1" do
    test "returns readings in insertion order", %{club: club} do
      {:ok, _} = Readings.create_reading(club, %{title: "Piranesi", time_label: "January"})
      Process.sleep(10)
      {:ok, _} = Readings.create_reading(club, %{title: "Babel", time_label: "March"})

      readings = Readings.list_readings(club)
      assert length(readings) == 2
      assert Enum.map(readings, & &1.title) == ["Piranesi", "Babel"]
    end

    test "returns empty list when no readings", %{club: club} do
      assert Readings.list_readings(club) == []
    end

    test "does not return readings from other clubs", %{club: club} do
      {:ok, other_club} = YonderbookClubs.Clubs.get_or_create_club("group.other456", "Other Club")
      {:ok, _} = Readings.create_reading(club, %{title: "Piranesi", time_label: "January"})
      {:ok, _} = Readings.create_reading(other_club, %{title: "Babel", time_label: "March"})

      readings = Readings.list_readings(club)
      assert length(readings) == 1
      assert hd(readings).title == "Piranesi"
    end
  end

  describe "remove_reading/2" do
    test "removes a reading by exact title", %{club: club} do
      {:ok, _} = Readings.create_reading(club, %{title: "Piranesi", time_label: "January"})
      assert {:ok, removed} = Readings.remove_reading(club, "Piranesi")
      assert removed.title == "Piranesi"
      assert Readings.list_readings(club) == []
    end

    test "removes by case-insensitive match", %{club: club} do
      {:ok, _} = Readings.create_reading(club, %{title: "Piranesi", time_label: "January"})
      assert {:ok, _} = Readings.remove_reading(club, "piranesi")
      assert Readings.list_readings(club) == []
    end

    test "returns {:error, :not_found} when title not found", %{club: club} do
      assert {:error, :not_found} = Readings.remove_reading(club, "Nonexistent")
    end

    test "removes by time label when title doesn't match", %{club: club} do
      {:ok, _} = Readings.create_reading(club, %{title: "Piranesi", time_label: "March"})
      assert {:ok, removed} = Readings.remove_reading(club, "March")
      assert removed.title == "Piranesi"
      assert Readings.list_readings(club) == []
    end

    test "removes by time label case-insensitively", %{club: club} do
      {:ok, _} = Readings.create_reading(club, %{title: "Piranesi", time_label: "March"})
      assert {:ok, _} = Readings.remove_reading(club, "march")
      assert Readings.list_readings(club) == []
    end

    test "prefers title match over time label match", %{club: club} do
      {:ok, _} = Readings.create_reading(club, %{title: "March", time_label: "January"})
      {:ok, _} = Readings.create_reading(club, %{title: "Piranesi", time_label: "March"})

      assert {:ok, removed} = Readings.remove_reading(club, "March")
      assert removed.title == "March"
      assert length(Readings.list_readings(club)) == 1
    end

    test "does not remove readings from other clubs with same title", %{club: club} do
      {:ok, other_club} = YonderbookClubs.Clubs.get_or_create_club("group.other456", "Other Club")
      {:ok, _} = Readings.create_reading(club, %{title: "Piranesi", time_label: "January"})
      {:ok, _} = Readings.create_reading(other_club, %{title: "Piranesi", time_label: "March"})

      assert {:ok, _} = Readings.remove_reading(club, "Piranesi")
      assert Readings.list_readings(club) == []
      assert length(Readings.list_readings(other_club)) == 1
    end
  end
end
