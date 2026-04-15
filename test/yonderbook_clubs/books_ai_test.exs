defmodule YonderbookClubs.BooksAITest do
  @moduledoc """
  Tests for AI extraction error handling in YonderbookClubs.Books.

  Uses Req's adapter option to stub the Anthropic API without hitting the network.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YonderbookClubs.Books

  setup do
    Application.put_env(:yonderbook_clubs, :anthropic_api_key, "test-key")

    on_exit(fn ->
      Application.delete_env(:yonderbook_clubs, :anthropic_api_key)
      Application.delete_env(:yonderbook_clubs, :anthropic_req_options)
    end)
  end

  defp stub_adapter(adapter) do
    Application.put_env(:yonderbook_clubs, :anthropic_req_options, adapter: adapter)
  end

  defp counting_adapter(response_fn) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    adapter = fn request ->
      Agent.update(counter, &(&1 + 1))
      response_fn.(request)
    end

    {adapter, counter}
  end

  defp ai_success_response(request, title, author) do
    body = %{
      "content" => [%{"text" => Jason.encode!(%{"title" => title, "author" => author})}]
    }

    {request, Req.Response.new(status: 200, body: body)}
  end

  describe "search_ai/1 retries transport errors" do
    test "retries on :closed" do
      {adapter, counter} = counting_adapter(fn req ->
        {req, %Req.TransportError{reason: :closed}}
      end)

      stub_adapter(adapter)
      capture_log(fn -> Books.search_ai("some book") end)

      assert Agent.get(counter, & &1) == 2
      Agent.stop(counter)
    end

    test "retries on :timeout" do
      {adapter, counter} = counting_adapter(fn req ->
        {req, %Req.TransportError{reason: :timeout}}
      end)

      stub_adapter(adapter)
      capture_log(fn -> Books.search_ai("some book") end)

      assert Agent.get(counter, & &1) == 2
      Agent.stop(counter)
    end

    test "retries on :econnrefused" do
      {adapter, counter} = counting_adapter(fn req ->
        {req, %Req.TransportError{reason: :econnrefused}}
      end)

      stub_adapter(adapter)
      capture_log(fn -> Books.search_ai("some book") end)

      assert Agent.get(counter, & &1) == 2
      Agent.stop(counter)
    end

    test "retries at most once (max_retries: 1) to keep wait time bounded" do
      {adapter, counter} = counting_adapter(fn req ->
        {req, %Req.TransportError{reason: :closed}}
      end)

      stub_adapter(adapter)
      capture_log(fn -> Books.search_ai("some book") end)

      call_count = Agent.get(counter, & &1)
      Agent.stop(counter)

      assert call_count == 2,
             "Expected exactly 2 calls (1 original + 1 retry), got #{call_count}. " <>
               "max_retries should be 1 to keep total wait time under ~60s."
    end
  end

  describe "search_ai/1 succeeds after transient failure" do
    test "recovers when second attempt succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      adapter = fn request ->
        call = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if call == 1 do
          {request, %Req.TransportError{reason: :closed}}
        else
          ai_success_response(request, "Piranesi", "Susanna Clarke")
        end
      end

      stub_adapter(adapter)

      log =
        capture_log(fn ->
          send(self(), {:result, Books.search_ai("that infinite house book")})
        end)

      assert_received {:result, {:ok, book_data}}
      assert book_data.title != nil
      assert book_data.author != nil

      call_count = Agent.get(counter, & &1)
      Agent.stop(counter)

      assert call_count == 2, "Expected exactly 2 calls (1 failure + 1 success), got #{call_count}"
      refute log =~ "[error]"
    end
  end

  describe "search_ai/1 logging levels" do
    test "transport errors log at warning, not error" do
      {adapter, counter} = counting_adapter(fn req ->
        {req, %Req.TransportError{reason: :closed}}
      end)

      stub_adapter(adapter)

      log = capture_log(fn -> Books.search_ai("some book") end)

      Agent.stop(counter)

      refute log =~ "[error]",
             "Transport errors should not log at error level (triggers Sentry). Got: #{log}"

      assert log =~ "[warning]",
             "Transport errors should log at warning level. Got: #{log}"
    end

    test "API error responses (non-200) log at warning, not error" do
      stub_adapter(fn request ->
        {request, Req.Response.new(status: 500, body: %{"error" => "internal"})}
      end)

      log = capture_log(fn -> Books.search_ai("some book") end)

      refute log =~ "[error]"
      assert log =~ "[warning]"
    end

    test "API 429 rate limit logs at warning, not error" do
      stub_adapter(fn request ->
        {request, Req.Response.new(status: 429, body: %{"error" => "rate_limited"})}
      end)

      log = capture_log(fn -> Books.search_ai("some book") end)

      refute log =~ "[error]"
      assert log =~ "[warning]"
    end
  end

  describe "search_ai/1 error propagation" do
    test "returns {:error, {:ai_transport_error, reason}} after exhausting retries" do
      {adapter, counter} = counting_adapter(fn req ->
        {req, %Req.TransportError{reason: :closed}}
      end)

      stub_adapter(adapter)

      result = capture_log(fn ->
        send(self(), {:result, Books.search_ai("some book")})
      end)

      Agent.stop(counter)

      assert_received {:result, {:error, {:ai_transport_error, :closed}}}
      assert result =~ "skipping fallback"
    end

    test "returns {:error, {:ai_http_error, status}} for non-200 responses" do
      stub_adapter(fn request ->
        {request, Req.Response.new(status: 500, body: %{"error" => "internal"})}
      end)

      capture_log(fn ->
        send(self(), {:result, Books.search_ai("some book")})
      end)

      assert_received {:result, {:error, {:ai_http_error, 500}}}
    end
  end
end
