defmodule YonderbookClubs.BooksTest do
  @moduledoc """
  Integration tests for YonderbookClubs.Books.

  These tests hit the real Open Library API and require network access.
  They are tagged with :external so they can be excluded in CI via
  `ExUnit.configure(exclude: [:external])`.
  """

  use ExUnit.Case, async: true

  alias YonderbookClubs.Books

  @moduletag :external

  describe "search/2" do
    @tag :external
    test "finds a well-known book by title and author" do
      assert {:ok, result} = Books.search("Piranesi", "Susanna Clarke")

      assert result.title != nil
      assert result.author != nil
      assert result.open_library_work_id != nil

      # extract_work_id returns the bare Work ID (e.g. "OL15328717W"),
      # which starts with "OL" after stripping the "/works/" path prefix
      assert result.open_library_work_id =~ ~r/^OL\d+W$/
    end

    @tag :external
    test "returns {:error, :not_found} for nonsense query" do
      assert {:error, :not_found} = Books.search("asdkjhqwkejhqwke", "zzznotanauthor")
    end
  end

  describe "search_isbn/1" do
    @tag :external
    test "finds a book by ISBN-13" do
      # 9780547928227 is The Hobbit by J.R.R. Tolkien
      assert {:ok, result} = Books.search_isbn("9780547928227")

      assert result.title != nil
      assert result.author != nil
    end

    @tag :external
    test "finds a book by ISBN-10" do
      # 0547928227 is the ISBN-10 for The Hobbit
      assert {:ok, result} = Books.search_isbn("0547928227")

      assert result.title != nil
    end

    @tag :external
    test "returns {:error, :not_found} for invalid ISBN" do
      assert {:error, :not_found} = Books.search_isbn("0000000000000")
    end
  end

  describe "search_ai/1" do
    test "returns {:error, :ai_not_configured} when no API key is set" do
      original = Application.get_env(:yonderbook_clubs, :anthropic_api_key)

      try do
        Application.put_env(:yonderbook_clubs, :anthropic_api_key, nil)
        assert {:error, :ai_not_configured} = Books.search_ai("that infinite house book")
      after
        if original do
          Application.put_env(:yonderbook_clubs, :anthropic_api_key, original)
        else
          Application.delete_env(:yonderbook_clubs, :anthropic_api_key)
        end
      end
    end
  end

  describe "normalize_isbn/1" do
    test "converts ISBN-10 to a 13-digit ISBN starting with 978" do
      # ISBN-10 for Piranesi: 1635575990
      result = Books.normalize_isbn("1635575990")

      assert String.length(result) == 13
      assert String.starts_with?(result, "978")
      assert Regex.match?(~r/^\d{13}$/, result)
    end

    test "leaves a valid ISBN-13 unchanged" do
      result = Books.normalize_isbn("9781635575996")

      assert result == "9781635575996"
      assert String.length(result) == 13
    end

    test "strips hyphens before normalizing" do
      result = Books.normalize_isbn("978-1-6355-7599-6")

      assert result == "9781635575996"
    end

    test "returns nil for nil input" do
      assert Books.normalize_isbn(nil) == nil
    end
  end
end
