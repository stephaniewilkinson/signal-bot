defmodule YonderbookClubs.Signal.CLI do
  @moduledoc """
  Real Signal implementation that connects to signal-cli's JSON-RPC 2.0 daemon
  over TCP.

  signal-cli must be running in daemon mode:

      signal-cli daemon --tcp localhost:7583

  This GenServer maintains a persistent TCP connection, handles reconnection
  with exponential backoff, buffers partial reads, and dispatches incoming
  Signal messages to `YonderbookClubs.Bot.Router.handle_message/1`.
  """

  use GenServer
  require Logger

  @behaviour YonderbookClubs.Signal

  @max_backoff_ms 30_000
  @initial_backoff_ms 1_000
  @rpc_timeout_ms 30_000
  @connect_timeout_ms 10_000
  @max_buffer_bytes 10_000_000
  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  # --- Public API (behaviour callbacks) ---

  @impl YonderbookClubs.Signal
  def send_message(recipient, body) do
    send_message(recipient, body, [])
  end

  @impl YonderbookClubs.Signal
  def send_message(recipient, body, attachments) do
    params = %{
      "account" => bot_number(),
      "message" => body
    }

    params =
      if dm_recipient?(recipient) do
        Map.put(params, "recipient", [recipient])
      else
        Map.put(params, "groupId", recipient)
      end

    params =
      if attachments == [] do
        params
      else
        Map.put(params, "attachments", attachments)
      end

    case call_rpc("send", params) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl YonderbookClubs.Signal
  def send_poll(group_id, question, options) do
    params = %{
      "account" => bot_number(),
      "groupId" => group_id,
      "question" => question,
      "options" => options
    }

    case call_rpc("sendPollCreate", params) do
      {:ok, result} ->
        timestamp = result["timestamp"]
        {:ok, timestamp}

      {:error, reason} = error ->
        Logger.error("SEND_POLL failed: #{inspect(reason)}")
        error
    end
  end

  @impl YonderbookClubs.Signal
  def list_groups do
    case call_rpc("listGroups", %{"account" => bot_number()}) do
      {:ok, groups} -> {:ok, groups}
      {:error, _} = error -> error
    end
  end

  # --- Client ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer callbacks ---

  defmodule State do
    @moduledoc false
    defstruct [
      :socket,
      :host,
      :port,
      buffer: "",
      backoff_ms: 1_000,
      request_id: 1,
      pending: %{}
    ]
  end

  @impl GenServer
  def init(_opts) do
    host =
      Application.get_env(:yonderbook_clubs, :signal_cli_host, "localhost")
      |> to_charlist()

    port = Application.get_env(:yonderbook_clubs, :signal_cli_port, 7583)

    state = %State{host: host, port: port, backoff_ms: @initial_backoff_ms}

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning(
          "Signal CLI connection failed: #{inspect(reason)}. Retrying in #{state.backoff_ms}ms."
        )

        Process.send_after(self(), :reconnect, state.backoff_ms)
        {:noreply, %{state | socket: nil}}
    end
  end

  @impl GenServer
  def handle_info(:reconnect, state) do
    case connect(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        next_backoff = min(state.backoff_ms * 2, @max_backoff_ms)

        Logger.warning(
          "Signal CLI reconnect failed: #{inspect(reason)}. Retrying in #{next_backoff}ms."
        )

        Process.send_after(self(), :reconnect, next_backoff)
        {:noreply, %{state | socket: nil, backoff_ms: next_backoff}}
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    buffer = state.buffer <> data

    if byte_size(buffer) > @max_buffer_bytes do
      Logger.error("Signal CLI buffer exceeded #{@max_buffer_bytes} bytes, resetting")
      {:noreply, %{state | buffer: ""}}
    else
      {messages, remaining} = extract_lines(buffer)

      state = %{state | buffer: remaining}

      state =
        Enum.reduce(messages, state, fn line, acc ->
          handle_json_line(line, acc)
        end)

      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.warning("Signal CLI TCP connection closed. Reconnecting in #{@initial_backoff_ms}ms.")

    # Reject all pending requests
    state = reject_all_pending(state, :connection_closed)

    Process.send_after(self(), :reconnect, @initial_backoff_ms)
    {:noreply, %{state | socket: nil, buffer: "", backoff_ms: @initial_backoff_ms}}
  end

  @impl GenServer
  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("Signal CLI TCP error: #{inspect(reason)}. Reconnecting.")

    state = reject_all_pending(state, {:tcp_error, reason})

    Process.send_after(self(), :reconnect, @initial_backoff_ms)
    {:noreply, %{state | socket: nil, buffer: "", backoff_ms: @initial_backoff_ms}}
  end

  @impl GenServer
  def handle_info({:rpc_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {from, pending} ->
        Logger.warning("RPC request #{id} timed out, cleaning up")
        GenServer.reply(from, {:error, :rpc_timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  @impl GenServer
  def handle_call({:rpc, _method, _params}, _from, %{socket: nil} = state) do
    # Not connected — fail fast
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:rpc, method, params}, from, state) do
    id = state.request_id

    payload =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    case :gen_tcp.send(state.socket, payload <> "\n") do
      :ok ->
        pending = Map.put(state.pending, id, from)
        # Reply before GenServer.call times out so we clean up pending state
        Process.send_after(self(), {:rpc_timeout, id}, @rpc_timeout_ms - 1_000)
        {:noreply, %{state | request_id: id + 1, pending: pending}}

      {:error, reason} ->
        {:reply, {:error, {:send_failed, reason}}, state}
    end
  end

  # --- Internal ---

  defp connect(state) do
    tcp_opts = [:binary, active: true, packet: :raw]

    case :gen_tcp.connect(state.host, state.port, tcp_opts, @connect_timeout_ms) do
      {:ok, socket} ->
        Logger.info("Connected to signal-cli at #{state.host}:#{state.port}")
        {:ok, %{state | socket: socket, buffer: "", backoff_ms: @initial_backoff_ms}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_lines(buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [complete, rest] ->
        {more, remaining} = extract_lines(rest)
        {[complete | more], remaining}

      [incomplete] ->
        {[], incomplete}
    end
  end

  defp handle_json_line("", state), do: state

  defp handle_json_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = response} when is_map_key(state.pending, id) ->
        {from, pending} = Map.pop(state.pending, id)

        reply =
          case response do
            %{"error" => error} -> {:error, error}
            %{"result" => result} -> {:ok, result}
            _ -> {:ok, nil}
          end

        GenServer.reply(from, reply)
        %{state | pending: pending}

      {:ok, %{"method" => _method, "params" => _params} = notification} ->
        dispatch_notification(notification)
        state

      {:ok, _other} ->
        Logger.debug("Unhandled JSON-RPC message: #{line}")
        state

      {:error, reason} ->
        Logger.warning("Failed to parse JSON from signal-cli: #{inspect(reason)}")
        state
    end
  end

  defp dispatch_notification(%{"params" => %{"envelope" => envelope}} = _notification) do
    # Extract the envelope from the JSON-RPC notification and build a flat map
    # for the router. Only dispatch if there's a dataMessage (skip typing indicators, etc.)
    case envelope do
      %{
        "sourceUuid" => source_uuid,
        "dataMessage" => %{
          "pollVote" => %{
            "targetSentTimestamp" => timestamp,
            "voteCount" => vote_count
          } = poll_vote
        }
      }
      when is_binary(source_uuid) and is_integer(timestamp) and is_integer(vote_count) ->
        vote_msg = %{
          "sourceUuid" => source_uuid,
          "targetSentTimestamp" => timestamp,
          "optionIndexes" => poll_vote["optionIndexes"] || [],
          "voteCount" => vote_count
        }

        Task.Supervisor.start_child(YonderbookClubs.TaskSupervisor, fn ->
          Sentry.Context.add_breadcrumb(%{
            category: "signal.poll_vote",
            message: "Received poll vote",
            level: :info
          })

          YonderbookClubs.Bot.Router.handle_poll_vote(vote_msg)
        end)

      %{"dataMessage" => %{"message" => message}} when is_binary(message) ->
        msg =
          %{
            "message" => message,
            "sourceUuid" => envelope["sourceUuid"],
            "sourceName" => envelope["sourceName"],
            "sourceNumber" => envelope["sourceNumber"]
          }
          |> maybe_add_group_info(envelope)

        Task.Supervisor.start_child(YonderbookClubs.TaskSupervisor, fn ->
          Sentry.Context.add_breadcrumb(%{
            category: "signal.message",
            message: "Received Signal message",
            level: :info,
            data: %{has_group: Map.has_key?(msg, "groupInfo")}
          })

          YonderbookClubs.Bot.Router.handle_message(msg)
        end)

      _ ->
        # Typing indicators, read receipts, etc. — ignore
        :ok
    end
  end

  defp dispatch_notification(_notification), do: :ok

  defp maybe_add_group_info(msg, %{"dataMessage" => %{"groupInfo" => group_info}}) do
    Map.put(msg, "groupInfo", group_info)
  end

  defp maybe_add_group_info(msg, _envelope), do: msg

  defp reject_all_pending(state, reason) do
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}}
  end

  defp call_rpc(method, params) do
    start_time = System.monotonic_time()
    result = GenServer.call(__MODULE__, {:rpc, method, params}, @rpc_timeout_ms)

    :telemetry.execute(
      [:yonderbook_clubs, :signal, :rpc],
      %{duration: System.monotonic_time() - start_time},
      %{method: method, result: elem(result, 0)}
    )

    result
  end

  defp bot_number do
    Application.get_env(:yonderbook_clubs, :signal_bot_number)
  end

  # UUIDs and phone numbers are DM recipients; everything else is a group ID (base64)
  defp dm_recipient?(recipient) do
    String.starts_with?(recipient, "+") or Regex.match?(@uuid_regex, recipient)
  end
end
