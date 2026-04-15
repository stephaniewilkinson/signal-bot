defmodule YonderbookClubs.Books do
  @moduledoc """
  Book metadata lookup via Open Library API (primary) and AI-assisted extraction
  via Anthropic Claude API (opt-in), with Gemini as a hot fallback.
  """

  require Logger

  @open_library_base "https://openlibrary.org"
  @covers_base "https://covers.openlibrary.org/b/id"
  @anthropic_base "https://api.anthropic.com/v1/messages"
  @gemini_base "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
  @http_timeout_ms 15_000
  @ai_timeout_ms 30_000

  @ai_system_prompt "You are a book identification assistant. Given a user's description, extract the exact book title " <>
                      "and author. The input may contain misspellings, partial names, or approximate titles — " <>
                      "do your best to identify the intended book. Return the EXACT, COMPLETE title as published " <>
                      "(e.g. \"Babylonia\" not \"Babylon\"). Return ONLY valid JSON (no markdown, no code fences) " <>
                      "with keys \"title\" and \"author\" using correct spelling. " <>
                      "If you truly cannot identify any plausible book, return {\"error\": \"unrecognized\"}."

  @type book_data :: %{
          title: String.t() | nil,
          author: String.t() | nil,
          isbn: String.t() | nil,
          open_library_work_id: String.t() | nil,
          cover_url: String.t() | nil,
          description: String.t() | nil
        }

  @doc """
  Searches Open Library by title and author.

  Returns `{:ok, book_map}` with title, author, isbn, open_library_work_id,
  cover_url, and description. Returns `{:error, :not_found}` if no results.
  """
  @spec search(String.t(), String.t()) :: {:ok, book_data()} | {:error, :not_found}
  def search(title, author) do
    timed(:search, %{type: :title_author}, fn ->
      url = "#{@open_library_base}/search.json"

      case Req.get(url, params: [title: title, author: author, language: "eng", limit: 1], receive_timeout: @http_timeout_ms, retry: :safe_transient) do
        {:ok, %{status: 200, body: %{"docs" => [first | _]}}} ->
          build_from_search_result(first)

        _ ->
          do_general_search("#{title} #{author}")
      end
    end)
  end

  @doc """
  General free-text search on Open Library. Used as a fallback when no
  structured pattern (title by author, ISBN, etc.) matches the input.
  """
  @spec search_general(String.t()) :: {:ok, book_data()} | {:error, :not_found}
  def search_general(query) do
    timed(:search, %{type: :general}, fn ->
      do_general_search(query)
    end)
  end

  @type search_preview :: %{title: String.t() | nil, author: String.t() | nil, doc: map()}

  @doc """
  Like `search/2` but returns up to 5 results. The top match is fully resolved;
  the rest are lightweight previews that can be resolved later with `resolve_preview/1`.
  """
  @spec search_multi(String.t(), String.t()) :: {:ok, book_data(), [search_preview()]} | {:error, :not_found}
  def search_multi(title, author) do
    timed(:search, %{type: :title_author_multi}, fn ->
      url = "#{@open_library_base}/search.json"

      case Req.get(url, params: [title: title, author: author, language: "eng", limit: 5], receive_timeout: @http_timeout_ms, retry: :safe_transient) do
        {:ok, %{status: 200, body: %{"docs" => [first | rest]}}} ->
          case build_from_search_result(first) do
            {:ok, book_data} ->
              {:ok, book_data, Enum.map(rest, &preview_from_doc/1)}

            {:error, :not_found} ->
              do_general_search_multi("#{title} #{author}")
          end

        _ ->
          do_general_search_multi("#{title} #{author}")
      end
    end)
  end

  @doc """
  Like `search_general/1` but returns up to 5 results.
  """
  @spec search_general_multi(String.t()) :: {:ok, book_data(), [search_preview()]} | {:error, :not_found}
  def search_general_multi(query) do
    timed(:search, %{type: :general_multi}, fn ->
      do_general_search_multi(query)
    end)
  end

  @doc """
  Resolves a lightweight search preview into full book data (fetches description, etc.).
  """
  @spec resolve_preview(search_preview()) :: {:ok, book_data()} | {:error, :not_found}
  def resolve_preview(%{doc: doc}) do
    build_from_search_result(doc)
  end

  defp do_general_search_multi(query) do
    url = "#{@open_library_base}/search.json"

    case Req.get(url, params: [q: query, language: "eng", limit: 5], receive_timeout: @http_timeout_ms, retry: :safe_transient) do
      {:ok, %{status: 200, body: %{"docs" => [first | rest]}}} ->
        case build_from_search_result(first) do
          {:ok, book_data} ->
            {:ok, book_data, Enum.map(rest, &preview_from_doc/1)}

          {:error, :not_found} ->
            {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp preview_from_doc(doc) do
    %{
      title: doc["title"],
      author: List.first(doc["author_name"] || []),
      doc: doc
    }
  end

  defp do_general_search(query) do
    url = "#{@open_library_base}/search.json"

    case Req.get(url, params: [q: query, language: "eng", limit: 1], receive_timeout: @http_timeout_ms, retry: :safe_transient) do
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
  @spec search_isbn(String.t()) :: {:ok, book_data()} | {:error, :not_found}
  def search_isbn(isbn) do
    timed(:search, %{type: :isbn}, fn ->
      clean = String.replace(isbn, "-", "")
      lookup_isbn = normalize_isbn(clean)
      url = "#{@open_library_base}/isbn/#{lookup_isbn}.json"

      case Req.get(url, receive_timeout: @http_timeout_ms, retry: :safe_transient) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          build_from_edition(body, clean)

        _error ->
          {:error, :not_found}
      end
    end)
  end

  @doc """
  AI-assisted book extraction. Sends free text to Claude to extract a title
  and author, then searches Open Library with the result.

  Requires `:anthropic_api_key` to be configured. Returns `{:error, :ai_not_configured}`
  if the key is missing, `{:error, :unrecognized}` if Claude cannot identify a book.
  """
  @spec search_ai(String.t()) :: {:ok, book_data()} | {:error, term()}
  def search_ai(text) do
    case Application.get_env(:yonderbook_clubs, :anthropic_api_key) do
      nil ->
        {:error, :ai_not_configured}

      "" ->
        {:error, :ai_not_configured}

      api_key ->
        case do_ai_extraction(text, api_key) do
          {:ok, _} = result ->
            result

          {:error, {tag, _}} = anthropic_error when tag in [:ai_transport_error, :ai_http_error] ->
            Logger.warning("Anthropic unavailable (#{tag}), trying Gemini fallback")

            case try_gemini_fallback(text) do
              {:ok, _} = result -> result
              {:error, _} -> anthropic_error
            end

          {:error, reason} ->
            Logger.warning("AI extraction failed (#{inspect(reason)}), falling back to general search")

            case search_general(text) do
              {:ok, _} = result -> result
              {:error, _} -> {:error, reason}
            end
        end
    end
  end

  # --- Search result helpers ---

  defp build_from_search_result(doc) do
    work_key = doc["key"]
    work_id = extract_work_id(work_key)

    if is_nil(work_id) do
      {:error, :not_found}
    else
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
  end

  defp build_from_edition(edition, input_isbn) do
    work_key =
      case edition["works"] do
        [%{"key" => key} | _] -> key
        _ -> nil
      end

    work_id = extract_work_id(work_key)

    if is_nil(work_id) do
      {:error, :not_found}
    else
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
  end

  # --- Work / author fetching ---

  defp fetch_work_description(nil), do: nil

  defp fetch_work_description(work_key) do
    url = "#{@open_library_base}#{work_key}.json"

    case Req.get(url, receive_timeout: @http_timeout_ms, retry: :safe_transient) do
      {:ok, %{status: 200, body: %{"description" => desc}}} ->
        case extract_description(desc) do
          nil -> fetch_english_edition_description(work_key)
          text -> text
        end

      _other ->
        nil
    end
  end

  defp fetch_english_edition_description(work_key) do
    url = "#{@open_library_base}#{work_key}/editions.json?limit=20"

    case Req.get(url, receive_timeout: @http_timeout_ms, retry: :safe_transient) do
      {:ok, %{status: 200, body: %{"entries" => editions}}} ->
        editions
        |> Enum.find_value(fn edition ->
          if english_edition?(edition), do: extract_description(edition["description"])
        end)

      _other ->
        nil
    end
  end

  defp english_edition?(edition) do
    case edition["languages"] do
      [%{"key" => "/languages/eng"} | _] -> true
      _ -> false
    end
  end

  defp extract_description(desc) when is_binary(desc), do: if(english?(desc), do: desc)
  defp extract_description(%{"value" => value}) when is_binary(value), do: if(english?(value), do: value)
  defp extract_description(_), do: nil

  # Simple heuristic: English text is mostly ASCII. If more than 10% of bytes
  # are non-ASCII, it's likely not English.
  defp english?(text) do
    total = byte_size(text)
    non_ascii = count_non_ascii(text, 0)
    non_ascii / max(total, 1) < 0.1
  end

  defp count_non_ascii(<<c, rest::binary>>, acc) when c < 128, do: count_non_ascii(rest, acc)
  defp count_non_ascii(<<_, rest::binary>>, acc), do: count_non_ascii(rest, acc + 1)
  defp count_non_ascii(<<>>, acc), do: acc

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

    case Req.get(url, receive_timeout: @http_timeout_ms, retry: :safe_transient) do
      {:ok, %{status: 200, body: %{"authors" => [%{"author" => %{"key" => key}} | _]}}} ->
        fetch_author_name(key)

      _other ->
        nil
    end
  end

  defp fetch_author_name(nil), do: nil

  defp fetch_author_name(author_key) do
    url = "#{@open_library_base}#{author_key}.json"

    case Req.get(url, receive_timeout: @http_timeout_ms, retry: :safe_transient) do
      {:ok, %{status: 200, body: %{"name" => name}}} -> name
      _other -> nil
    end
  end

  # --- AI extraction ---

  defp do_ai_extraction(text, api_key) do
    body =
      Jason.encode!(%{
        model: "claude-sonnet-4-20250514",
        max_tokens: 200,
        system: @ai_system_prompt,
        messages: [
          %{role: "user", content: text}
        ]
      })

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    req_options =
      [
        body: body,
        headers: headers,
        receive_timeout: @ai_timeout_ms,
        retry: :transient,
        max_retries: 1
      ] ++ anthropic_req_options()

    case Req.post(@anthropic_base, req_options) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => response_text} | _]}}} ->
        parse_ai_response(response_text)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("AI extraction failed: HTTP #{status} — #{inspect(body)}")
        {:error, {:ai_http_error, status}}

      {:error, %{reason: reason}} ->
        Logger.warning("AI extraction failed: #{inspect(reason)}")
        {:error, {:ai_transport_error, reason}}

      other ->
        Logger.warning("AI extraction failed: #{inspect(other)}")
        {:error, :ai_unknown_error}
    end
  end

  defp try_gemini_fallback(text) do
    case Application.get_env(:yonderbook_clubs, :gemini_api_key) do
      key when key in [nil, ""] ->
        {:error, :gemini_not_configured}

      api_key ->
        do_gemini_extraction(text, api_key)
    end
  end

  defp do_gemini_extraction(text, api_key) do
    body =
      Jason.encode!(%{
        model: "gemini-2.0-flash",
        max_tokens: 200,
        messages: [
          %{role: "system", content: @ai_system_prompt},
          %{role: "user", content: text}
        ]
      })

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    req_options =
      [body: body, headers: headers, receive_timeout: @ai_timeout_ms] ++
        gemini_req_options()

    case Req.post(@gemini_base, req_options) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
        parse_ai_response(content)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Gemini fallback failed: HTTP #{status} — #{inspect(body)}")
        {:error, {:gemini_http_error, status}}

      {:error, %{reason: reason}} ->
        Logger.warning("Gemini fallback failed: #{inspect(reason)}")
        {:error, {:gemini_transport_error, reason}}

      other ->
        Logger.warning("Gemini fallback failed: #{inspect(other)}")
        {:error, :gemini_unknown_error}
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
  @spec normalize_isbn(String.t() | nil) :: String.t() | nil
  def normalize_isbn(nil), do: nil

  def normalize_isbn(isbn) do
    digits = String.replace(isbn, ~r/[^0-9Xx]/, "")

    case String.length(digits) do
      10 -> isbn10_to_isbn13(digits)
      13 -> digits
      _ -> nil
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

  defp anthropic_req_options do
    case Application.get_env(:yonderbook_clubs, :anthropic_req_options) do
      nil -> []
      opts when is_list(opts) -> opts
      {key, value} -> [{key, value}]
    end
  end

  defp gemini_req_options do
    case Application.get_env(:yonderbook_clubs, :gemini_req_options) do
      nil -> []
      opts when is_list(opts) -> opts
      {key, value} -> [{key, value}]
    end
  end

  defp timed(event, metadata, fun) do
    start_time = System.monotonic_time()
    result = fun.()

    :telemetry.execute(
      [:yonderbook_clubs, :books, event],
      %{duration: System.monotonic_time() - start_time},
      Map.put(metadata, :result, elem(result, 0))
    )

    result
  end
end
