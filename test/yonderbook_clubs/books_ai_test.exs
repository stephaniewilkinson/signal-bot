defmodule YonderbookClubs.BooksAITest do
  @moduledoc """
  Tests for AI extraction error handling in YonderbookClubs.Books.

  Uses Req's adapter option to stub the Anthropic and Gemini API endpoints
  without hitting the network.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YonderbookClubs.Books

  setup do
    Application.put_env(:yonderbook_clubs, :anthropic_api_key, "test-anthropic-key")

    on_exit(fn ->
      Application.delete_env(:yonderbook_clubs, :anthropic_api_key)
      Application.delete_env(:yonderbook_clubs, :anthropic_req_options)
      Application.delete_env(:yonderbook_clubs, :gemini_api_key)
      Application.delete_env(:yonderbook_clubs, :gemini_req_options)
    end)
  end

  defp stub_anthropic(adapter) do
    Application.put_env(:yonderbook_clubs, :anthropic_req_options, adapter: adapter)
  end

  defp stub_gemini(adapter) do
    Application.put_env(:yonderbook_clubs, :gemini_api_key, "test-gemini-key")
    Application.put_env(:yonderbook_clubs, :gemini_req_options, adapter: adapter)
  end

  defp counting_adapter(response_fn) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    adapter = fn request ->
      Agent.update(counter, &(&1 + 1))
      response_fn.(request)
    end

    {adapter, counter}
  end

  defp anthropic_success(request, title, author) do
    body = %{
      "content" => [%{"text" => Jason.encode!(%{"title" => title, "author" => author})}]
    }

    {request, Req.Response.new(status: 200, body: body)}
  end

  defp gemini_success(request, title, author) do
    body = %{
      "choices" => [%{"message" => %{"content" => Jason.encode!(%{"title" => title, "author" => author})}}]
    }

    {request, Req.Response.new(status: 200, body: body)}
  end

  # --- Anthropic retry behavior ---

  describe "search_ai/1 retries Anthropic transport errors" do
    test "retries on :closed" do
      {adapter, counter} = counting_adapter(fn req ->
        {req, %Req.TransportError{reason: :closed}}
      end)

      stub_anthropic(adapter)
      capture_log(fn -> Books.search_ai("some book") end)

      assert Agent.get(counter, & &1) == 2
      Agent.stop(counter)
    end

    test "retries on :timeout" do
      {adapter, counter} = counting_adapter(fn req ->
        {req, %Req.TransportError{reason: :timeout}}
      end)

      stub_anthropic(adapter)
      capture_log(fn -> Books.search_ai("some book") end)

      assert Agent.get(counter, & &1) == 2
      Agent.stop(counter)
    end

    test "retries on :econnrefused" do
      {adapter, counter} = counting_adapter(fn req ->
        {req, %Req.TransportError{reason: :econnrefused}}
      end)

      stub_anthropic(adapter)
      capture_log(fn -> Books.search_ai("some book") end)

      assert Agent.get(counter, & &1) == 2
      Agent.stop(counter)
    end

    test "retries at most once (max_retries: 1) to keep wait time bounded" do
      {adapter, counter} = counting_adapter(fn req ->
        {req, %Req.TransportError{reason: :closed}}
      end)

      stub_anthropic(adapter)
      capture_log(fn -> Books.search_ai("some book") end)

      call_count = Agent.get(counter, & &1)
      Agent.stop(counter)

      assert call_count == 2,
             "Expected exactly 2 calls (1 original + 1 retry), got #{call_count}. " <>
               "max_retries should be 1 to keep total wait time under ~60s."
    end
  end

  describe "search_ai/1 Anthropic recovers after transient failure" do
    test "recovers when second Anthropic attempt succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      adapter = fn request ->
        call = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if call == 1 do
          {request, %Req.TransportError{reason: :closed}}
        else
          anthropic_success(request, "Piranesi", "Susanna Clarke")
        end
      end

      stub_anthropic(adapter)

      log =
        capture_log(fn ->
          send(self(), {:result, Books.search_ai("that infinite house book")})
        end)

      assert_received {:result, {:ok, book_data}}
      assert book_data.title != nil
      assert book_data.author != nil

      call_count = Agent.get(counter, & &1)
      Agent.stop(counter)

      assert call_count == 2
      refute log =~ "[error]"
    end
  end

  # --- Gemini fallback behavior ---

  describe "search_ai/1 Gemini fallback" do
    test "tries Gemini when Anthropic fails with transport error" do
      stub_anthropic(fn req -> {req, %Req.TransportError{reason: :closed}} end)

      {gemini_adapter, gemini_counter} = counting_adapter(fn req ->
        gemini_success(req, "Piranesi", "Susanna Clarke")
      end)

      stub_gemini(gemini_adapter)

      capture_log(fn ->
        send(self(), {:result, Books.search_ai("that infinite house book")})
      end)

      assert_received {:result, {:ok, book_data}}
      assert book_data.title != nil

      assert Agent.get(gemini_counter, & &1) == 1
      Agent.stop(gemini_counter)
    end

    test "tries Gemini when Anthropic fails with HTTP error" do
      stub_anthropic(fn req ->
        {req, Req.Response.new(status: 500, body: %{"error" => "internal"})}
      end)

      {gemini_adapter, gemini_counter} = counting_adapter(fn req ->
        gemini_success(req, "Babel", "RF Kuang")
      end)

      stub_gemini(gemini_adapter)

      capture_log(fn ->
        send(self(), {:result, Books.search_ai("dark academia translation book")})
      end)

      assert_received {:result, {:ok, book_data}}
      assert book_data.title != nil

      assert Agent.get(gemini_counter, & &1) == 1
      Agent.stop(gemini_counter)
    end

    test "does not try Gemini when Anthropic returns :unrecognized" do
      stub_anthropic(fn req ->
        body = %{"content" => [%{"text" => ~s({"error": "unrecognized"})}]}
        {req, Req.Response.new(status: 200, body: body)}
      end)

      {gemini_adapter, gemini_counter} = counting_adapter(fn req ->
        gemini_success(req, "Anything", "Anyone")
      end)

      stub_gemini(gemini_adapter)

      capture_log(fn -> Books.search_ai("asdkjhqwkejh") end)

      assert Agent.get(gemini_counter, & &1) == 0,
             "Gemini should not be called for :unrecognized errors"
      Agent.stop(gemini_counter)
    end

    test "does not try Gemini when Anthropic succeeds" do
      stub_anthropic(fn req ->
        anthropic_success(req, "Piranesi", "Susanna Clarke")
      end)

      {gemini_adapter, gemini_counter} = counting_adapter(fn req ->
        gemini_success(req, "Anything", "Anyone")
      end)

      stub_gemini(gemini_adapter)

      capture_log(fn ->
        send(self(), {:result, Books.search_ai("piranesi")})
      end)

      assert_received {:result, {:ok, _}}

      assert Agent.get(gemini_counter, & &1) == 0,
             "Gemini should not be called when Anthropic succeeds"
      Agent.stop(gemini_counter)
    end

    test "returns original Anthropic error when Gemini also fails" do
      stub_anthropic(fn req -> {req, %Req.TransportError{reason: :closed}} end)
      stub_gemini(fn req -> {req, %Req.TransportError{reason: :timeout}} end)

      capture_log(fn ->
        send(self(), {:result, Books.search_ai("some book")})
      end)

      # Returns the original Anthropic error, not the Gemini error
      assert_received {:result, {:error, {:ai_transport_error, :closed}}}
    end

    test "skips Gemini when GEMINI_API_KEY is not configured" do
      stub_anthropic(fn req -> {req, %Req.TransportError{reason: :closed}} end)
      # Don't configure gemini_api_key

      capture_log(fn ->
        send(self(), {:result, Books.search_ai("some book")})
      end)

      assert_received {:result, {:error, {:ai_transport_error, :closed}}}
    end

    test "logs fallback attempt" do
      stub_anthropic(fn req -> {req, %Req.TransportError{reason: :closed}} end)
      stub_gemini(fn req -> gemini_success(req, "Piranesi", "Susanna Clarke") end)

      log = capture_log(fn -> Books.search_ai("some book") end)

      assert log =~ "trying Gemini fallback"
    end
  end

  # --- Logging levels ---

  describe "search_ai/1 logging levels" do
    test "transport errors log at warning, not error" do
      {adapter, counter} = counting_adapter(fn req ->
        {req, %Req.TransportError{reason: :closed}}
      end)

      stub_anthropic(adapter)

      log = capture_log(fn -> Books.search_ai("some book") end)

      Agent.stop(counter)

      refute log =~ "[error]",
             "Transport errors should not log at error level (triggers Sentry). Got: #{log}"

      assert log =~ "[warning]",
             "Transport errors should log at warning level. Got: #{log}"
    end

    test "API error responses (non-200) log at warning, not error" do
      stub_anthropic(fn request ->
        {request, Req.Response.new(status: 500, body: %{"error" => "internal"})}
      end)

      log = capture_log(fn -> Books.search_ai("some book") end)

      refute log =~ "[error]"
      assert log =~ "[warning]"
    end

    test "API 429 rate limit logs at warning, not error" do
      stub_anthropic(fn request ->
        {request, Req.Response.new(status: 429, body: %{"error" => "rate_limited"})}
      end)

      log = capture_log(fn -> Books.search_ai("some book") end)

      refute log =~ "[error]"
      assert log =~ "[warning]"
    end
  end
end
