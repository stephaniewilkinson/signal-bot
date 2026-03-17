defmodule YonderbookClubs.Bot.Router.HelpersTest do
  use ExUnit.Case, async: true

  alias YonderbookClubs.Bot.Router.Helpers

  describe "strip_slash/1" do
    test "strips leading slash" do
      assert Helpers.strip_slash("/help") == "help"
    end

    test "returns text unchanged without slash" do
      assert Helpers.strip_slash("help") == "help"
    end

    test "only strips the first slash" do
      assert Helpers.strip_slash("/suggest /ai: test") == "suggest /ai: test"
    end

    test "handles empty string" do
      assert Helpers.strip_slash("") == ""
    end

    test "handles just a slash" do
      assert Helpers.strip_slash("/") == ""
    end
  end

  describe "download_covers/1" do
    test "returns empty list for empty input" do
      assert Helpers.download_covers([]) == []
    end

    test "skips suggestions without cover_url" do
      suggestions = [
        %{id: Ecto.UUID.generate(), title: "Test", cover_url: nil}
      ]

      assert Helpers.download_covers(suggestions) == []
    end
  end

  describe "fuzzy_match_command/2" do
    test "matches common typos for suggest" do
      assert {:ok, "suggest"} = Helpers.fuzzy_match_command("sugget", :dm)
      assert {:ok, "suggest"} = Helpers.fuzzy_match_command("suggets", :dm)
      assert {:ok, "suggest"} = Helpers.fuzzy_match_command("sugest", :dm)
    end

    test "matches common typos for help" do
      assert {:ok, "help"} = Helpers.fuzzy_match_command("hlep", :dm)
      assert {:ok, "help"} = Helpers.fuzzy_match_command("hepl", :dm)
    end

    test "matches common typos for remove" do
      assert {:ok, "remove"} = Helpers.fuzzy_match_command("reomve", :dm)
      assert {:ok, "remove"} = Helpers.fuzzy_match_command("remvoe", :dm)
    end

    test "does not match distant strings" do
      assert :no_match = Helpers.fuzzy_match_command("hello", :dm)
      assert :no_match = Helpers.fuzzy_match_command("pizza", :dm)
      assert :no_match = Helpers.fuzzy_match_command("what is this", :dm)
    end

    test "matches multi-word group commands" do
      assert {:ok, "start vote"} = Helpers.fuzzy_match_command("strt vote", :group)
      assert {:ok, "close vote"} = Helpers.fuzzy_match_command("clsoe vote", :group)
    end

    test "matches typo followed by extra text" do
      assert {:ok, "suggest"} = Helpers.fuzzy_match_command("sugget piranesi by author", :dm)
    end
  end

  describe "cleanup_covers/1" do
    test "returns :ok for empty list" do
      assert Helpers.cleanup_covers([]) == :ok
    end

    test "deletes existing temp files" do
      path = Path.join(System.tmp_dir!(), "test_cover_#{System.unique_integer([:positive])}.jpg")
      File.write!(path, "fake image data")

      assert Helpers.cleanup_covers([path]) == :ok
      refute File.exists?(path)
    end

    test "handles non-existent files gracefully" do
      # Should not raise
      assert Helpers.cleanup_covers(["/tmp/nonexistent_cover_#{System.unique_integer([:positive])}.jpg"]) == :ok
    end
  end
end
