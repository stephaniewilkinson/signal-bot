defmodule YonderbookClubs.Books do
  @moduledoc """
  Book metadata lookup via Open Library API (primary) and AI-assisted extraction
  via Anthropic Claude API (opt-in).
  """

  require Logger

  @open_library_base "https://openlibrary.org"
  @covers_base "https://covers.openlibrary.org/b/id"
  @anthropic_base "https://api.anthropic.com/v1/messages"

  @doc """
  Searches Open Library by title and author.

  Returns `{:ok, book_map}` with title, author, isbn, open_library_work_id,
  cover_url, and description. Returns `{:error, :not_found}` if no results.
  """
  def search(title, author) do
    url = "#{@open_library_base}/search.json"

    # Try exact title+author first, fall back to general query
    case Req.get(url, params: [title: title, author: author, limit: 1]) do
      {:ok, %{status: 200, body: %{"docs" => [first | _]}}} ->
        build_from_search_result(first)

      _ ->
        search_general("#{title} #{author}")
    end
  end

  defp search_general(query) do
    url = "#{@open_library_base}/search.json"

    case Req.get(url, params: [q: query, limit: 1]) do
      {:ok, %{status: 200, body: %{"docs" => [first | _]}}} ->
        build_from_search_result(first)

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Looks up a book by ISBN via Open Library.

  Strips hyphens from input, fetches the edition record, then resolves the
  work and author details. Returns the same shape as `search/2`.
  """
  def search_isbn(isbn) do
    clean = String.replace(isbn, "-", "")
    # Normalize to ISBN-13 for the lookup — Open Library handles ISBN-13 more reliably
    lookup_isbn = normalize_isbn(clean)
    url = "#{@open_library_base}/isbn/#{lookup_isbn}.json"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        build_from_edition(body, clean)

      _error ->
        {:error, :not_found}
    end
  end

  @doc """
  AI-assisted book extraction. Sends free text to Claude to extract a title
  and author, then searches Open Library with the result.

  Requires `:anthropic_api_key` to be configured. Returns `{:error, :ai_not_configured}`
  if the key is missing, `{:error, :unrecognized}` if Claude cannot identify a book.
  """
  def search_ai(text) do
    case Application.get_env(:yonderbook_clubs, :anthropic_api_key) do
      nil -> {:error, :ai_not_configured}
      "" -> {:error, :ai_not_configured}
      api_key ->
        case do_ai_extraction(text, api_key) do
          {:ok, _} = result -> result
          {:error, _} -> search_general(text)
        end
    end
  end

  # --- Search result helpers ---

  defp build_from_search_result(doc) do
    work_key = doc["key"]
    work_id = extract_work_id(work_key)
    cover_i = doc["cover_i"]
    raw_isbn = doc["isbn"]

    description = fetch_work_description(work_key)

    isbn =
      case raw_isbn do
        [first | _] -> normalize_isbn(first)
        _ -> nil
      end

    {:ok,
     %{
       title: doc["title"],
       author: List.first(doc["author_name"] || []),
       isbn: isbn,
       open_library_work_id: work_id,
       cover_url: cover_url(cover_i),
       description: description
     }}
  end

  defp build_from_edition(edition, input_isbn) do
    work_key =
      case edition["works"] do
        [%{"key" => key} | _] -> key
        _ -> nil
      end

    work_id = extract_work_id(work_key)
    title = edition["title"]
    description = fetch_work_description(work_key)
    cover_i = List.first(edition["covers"] || [])

    author_name = fetch_author_from_edition(edition) || fetch_author_from_work(work_key)

    isbn =
      case edition["isbn_13"] do
        [first | _] ->
          first

        _ ->
          case edition["isbn_10"] do
            [first | _] -> normalize_isbn(first)
            _ -> normalize_isbn(input_isbn)
          end
      end

    {:ok,
     %{
       title: title,
       author: author_name,
       isbn: isbn,
       open_library_work_id: work_id,
       cover_url: cover_url(cover_i),
       description: description
     }}
  end

  # --- Work / author fetching ---

  defp fetch_work_description(nil), do: nil

  defp fetch_work_description(work_key) do
    url = "#{@open_library_base}#{work_key}.json"

    case Req.get(url) do
      {:ok, %{status: 200, body: %{"description" => desc}}} ->
        extract_description(desc)

      _other ->
        nil
    end
  end

  defp extract_description(desc) when is_binary(desc), do: desc
  defp extract_description(%{"value" => value}) when is_binary(value), do: value
  defp extract_description(_), do: nil

  defp fetch_author_from_edition(edition) do
    author_key =
      case edition["authors"] do
        [%{"key" => key} | _] -> key
        _ -> nil
      end

    fetch_author_name(author_key)
  end

  defp fetch_author_from_work(nil), do: nil

  defp fetch_author_from_work(work_key) do
    url = "#{@open_library_base}#{work_key}.json"

    case Req.get(url) do
      {:ok, %{status: 200, body: %{"authors" => [%{"author" => %{"key" => key}} | _]}}} ->
        fetch_author_name(key)

      _other ->
        nil
    end
  end

  defp fetch_author_name(nil), do: nil

  defp fetch_author_name(author_key) do
    url = "#{@open_library_base}#{author_key}.json"

    case Req.get(url) do
      {:ok, %{status: 200, body: %{"name" => name}}} -> name
      _other -> nil
    end
  end

  # --- AI extraction ---

  defp do_ai_extraction(text, api_key) do
    system_prompt =
      "You are a book identification assistant. Given a user's description, extract the exact book title " <>
        "and author. The input may contain misspellings, partial names, or approximate titles — " <>
        "do your best to identify the intended book. Return the EXACT, COMPLETE title as published " <>
        "(e.g. \"Babylonia\" not \"Babylon\"). Return ONLY valid JSON (no markdown, no code fences) " <>
        "with keys \"title\" and \"author\" using correct spelling. " <>
        "If you truly cannot identify any plausible book, return {\"error\": \"unrecognized\"}."

    body =
      Jason.encode!(%{
        model: "claude-sonnet-4-20250514",
        max_tokens: 200,
        system: system_prompt,
        messages: [
          %{role: "user", content: text}
        ]
      })

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    case Req.post(@anthropic_base, body: body, headers: headers) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => response_text} | _]}}} ->
        Logger.info("AI extraction result: #{response_text}")
        parse_ai_response(response_text)

      other ->
        Logger.error("AI extraction failed: #{inspect(other)}")
        {:error, :unrecognized}
    end
  end

  defp parse_ai_response(text) do
    # Strip markdown code fences if present
    clean =
      text
      |> String.replace(~r/```json\s*/, "")
      |> String.replace(~r/```\s*/, "")
      |> String.trim()

    case Jason.decode(clean) do
      {:ok, %{"error" => _}} ->
        {:error, :unrecognized}

      {:ok, %{"title" => title, "author" => author}} ->
        search(title, author)

      _other ->
        {:error, :unrecognized}
    end
  end

  # --- ISBN helpers ---

  @doc false
  def normalize_isbn(nil), do: nil

  def normalize_isbn(isbn) do
    digits = String.replace(isbn, ~r/[^0-9Xx]/, "")

    case String.length(digits) do
      10 -> isbn10_to_isbn13(digits)
      13 -> digits
      _ -> digits
    end
  end

  defp isbn10_to_isbn13(isbn10) do
    # Take the first 9 digits of the ISBN-10, prepend "978"
    base_9 = String.slice(isbn10, 0, 9)
    partial = "978" <> base_9

    check = isbn13_check_digit(partial)
    partial <> Integer.to_string(check)
  end

  defp isbn13_check_digit(twelve_digits) do
    twelve_digits
    |> String.graphemes()
    |> Enum.map(&String.to_integer/1)
    |> Enum.with_index()
    |> Enum.reduce(0, fn {digit, index}, acc ->
      weight = if rem(index, 2) == 0, do: 1, else: 3
      acc + digit * weight
    end)
    |> then(fn sum -> rem(10 - rem(sum, 10), 10) end)
  end

  # --- Utilities ---

  defp extract_work_id(nil), do: nil

  defp extract_work_id(work_key) do
    work_key
    |> String.split("/")
    |> List.last()
  end

  defp cover_url(nil), do: nil
  defp cover_url(cover_id), do: "#{@covers_base}/#{cover_id}-M.jpg"

end
