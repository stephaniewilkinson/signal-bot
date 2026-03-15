defmodule YonderbookClubs.BooksPropertyTest do
  @moduledoc """
  Property-based tests for ISBN normalization using StreamData.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YonderbookClubs.Books

  describe "normalize_isbn/1" do
    property "ISBN-13 input always round-trips unchanged" do
      check all digits <- string(?0..?9, length: 13) do
        assert Books.normalize_isbn(digits) == digits
      end
    end

    property "ISBN-10 input always produces a 13-digit string starting with 978" do
      check all first_9 <- string(?0..?9, length: 9),
                check_char <- one_of([string(?0..?9, length: 1), constant("X")]) do
        isbn10 = first_9 <> check_char
        result = Books.normalize_isbn(isbn10)

        assert is_binary(result)
        assert String.length(result) == 13
        assert String.starts_with?(result, "978")
        assert Regex.match?(~r/^\d{13}$/, result)
      end
    end

    property "output is always nil or a valid 13-digit string" do
      check all input <- string(:printable, max_length: 20) do
        result = Books.normalize_isbn(input)
        assert is_nil(result) or (String.length(result) == 13 and Regex.match?(~r/^\d{13}$/, result))
      end
    end

    property "hyphens don't affect the result" do
      check all digits <- string(?0..?9, length: 13) do
        # Insert random hyphens
        hyphenated = digits |> String.graphemes() |> Enum.intersperse("-") |> Enum.join()
        assert Books.normalize_isbn(hyphenated) == Books.normalize_isbn(digits)
      end
    end

    property "ISBN-13 check digit is valid for generated ISBN-10 conversions" do
      check all first_9 <- string(?0..?9, length: 9) do
        isbn10 = first_9 <> "0"
        result = Books.normalize_isbn(isbn10)

        # Verify ISBN-13 check digit: weighted sum mod 10 == 0
        digits =
          result
          |> String.graphemes()
          |> Enum.map(&String.to_integer/1)

        weighted_sum =
          digits
          |> Enum.with_index()
          |> Enum.reduce(0, fn {d, i}, acc ->
            weight = if rem(i, 2) == 0, do: 1, else: 3
            acc + d * weight
          end)

        assert rem(weighted_sum, 10) == 0
      end
    end
  end
end
