defmodule YonderbookClubs.SuggestionsTest do
  use YonderbookClubs.DataCase, async: true

  alias YonderbookClubs.Suggestions
  alias YonderbookClubs.Suggestions.Suggestion

  @valid_attrs %{
    title: "Piranesi",
    author: "Susanna Clarke",
    isbn: "9781635575996",
    open_library_work_id: "/works/OL20893680W",
    cover_url: "https://covers.openlibrary.org/b/id/10520612-M.jpg",
    description: "A man lives in a labyrinthine house...",
    signal_sender_uuid: "uuid-alice-123"
  }

  setup do
    {:ok, club} = YonderbookClubs.Clubs.get_or_create_club("group.test123", "Test Club")
    %{club: club}
  end

  describe "create_suggestion/2" do
    test "successfully creates a suggestion with valid attrs", %{club: club} do
      assert {:ok, %Suggestion{} = suggestion} = Suggestions.create_suggestion(club, @valid_attrs)

      assert suggestion.title == "Piranesi"
      assert suggestion.author == "Susanna Clarke"
      assert suggestion.isbn == "9781635575996"
      assert suggestion.open_library_work_id == "/works/OL20893680W"
      assert suggestion.cover_url == "https://covers.openlibrary.org/b/id/10520612-M.jpg"
      assert suggestion.description == "A man lives in a labyrinthine house..."
      assert suggestion.signal_sender_uuid == "uuid-alice-123"
      assert suggestion.club_id == club.id
    end

    test "returns {:ok, :duplicate} for same work_id in same club", %{club: club} do
      assert {:ok, %Suggestion{}} = Suggestions.create_suggestion(club, @valid_attrs)
      assert {:ok, :duplicate} = Suggestions.create_suggestion(club, @valid_attrs)
    end

    test "allows same work_id in different clubs", %{club: club} do
      {:ok, other_club} = YonderbookClubs.Clubs.get_or_create_club("group.other456", "Other Club")

      assert {:ok, %Suggestion{}} = Suggestions.create_suggestion(club, @valid_attrs)
      assert {:ok, %Suggestion{}} = Suggestions.create_suggestion(other_club, @valid_attrs)
    end

    test "returns error changeset with missing required fields", %{club: club} do
      assert {:error, %Ecto.Changeset{} = changeset} = Suggestions.create_suggestion(club, %{})

      assert %{title: ["can't be blank"]} = errors_on(changeset)
      assert %{author: ["can't be blank"]} = errors_on(changeset)
      assert %{open_library_work_id: ["can't be blank"]} = errors_on(changeset)
      assert %{signal_sender_uuid: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list_suggestions/1" do
    test "returns all suggestions for a club", %{club: club} do
      {:ok, _first} =
        Suggestions.create_suggestion(club, %{
          @valid_attrs
          | title: "Piranesi",
            open_library_work_id: "/works/OL1"
        })

      {:ok, _second} =
        Suggestions.create_suggestion(club, %{
          @valid_attrs
          | title: "Babel",
            open_library_work_id: "/works/OL2"
        })

      suggestions = Suggestions.list_suggestions(club)

      assert length(suggestions) == 2
      titles = Enum.map(suggestions, & &1.title)
      assert "Piranesi" in titles
      assert "Babel" in titles
    end

    test "returns empty list when no suggestions", %{club: club} do
      assert Suggestions.list_suggestions(club) == []
    end
  end

  describe "remove_latest_suggestion/2" do
    test "removes the sender's most recent suggestion", %{club: club} do
      {:ok, _first} =
        Suggestions.create_suggestion(club, %{
          @valid_attrs
          | title: "Piranesi",
            open_library_work_id: "/works/OL1"
        })

      Process.sleep(10)

      {:ok, second} =
        Suggestions.create_suggestion(club, %{
          @valid_attrs
          | title: "Babel",
            open_library_work_id: "/works/OL2"
        })

      assert {:ok, removed} = Suggestions.remove_latest_suggestion(club.id, "uuid-alice-123")
      assert removed.id == second.id

      remaining = Suggestions.list_suggestions(club)
      assert length(remaining) == 1
      assert hd(remaining).title == "Piranesi"
    end

    test "returns {:error, :not_found} when no suggestions exist", %{club: club} do
      assert {:error, :not_found} =
               Suggestions.remove_latest_suggestion(club.id, "uuid-nobody-000")
    end

    test "only removes suggestions from the specified sender", %{club: club} do
      {:ok, _alice_suggestion} = Suggestions.create_suggestion(club, @valid_attrs)

      {:ok, _bob_suggestion} =
        Suggestions.create_suggestion(club, %{
          @valid_attrs
          | title: "Babel",
            open_library_work_id: "/works/OL2",
            signal_sender_uuid: "uuid-bob-456"
        })

      assert {:ok, removed} = Suggestions.remove_latest_suggestion(club.id, "uuid-bob-456")
      assert removed.signal_sender_uuid == "uuid-bob-456"

      remaining = Suggestions.list_suggestions(club)
      assert length(remaining) == 1
      assert hd(remaining).signal_sender_uuid == "uuid-alice-123"
    end
  end

  describe "delete_all_suggestions/1" do
    test "deletes all suggestions for a club", %{club: club} do
      {:ok, _} =
        Suggestions.create_suggestion(club, %{
          @valid_attrs
          | open_library_work_id: "/works/OL1"
        })

      {:ok, _} =
        Suggestions.create_suggestion(club, %{
          @valid_attrs
          | title: "Babel",
            open_library_work_id: "/works/OL2"
        })

      assert {2, nil} = Suggestions.delete_all_suggestions(club)
      assert Suggestions.list_suggestions(club) == []
    end
  end
end
