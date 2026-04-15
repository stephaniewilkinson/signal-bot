defmodule YonderbookClubs.Bot.PendingCommands do
  @moduledoc """
  Stores the last DM command per sender so that multi-club users can reply
  with just a number instead of repeating the full command.

  Entries expire after 5 minutes.
  """

  use GenServer

  @table :pending_commands
  @ttl_ms 300_000
  @sweep_interval_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec store(term(), term()) :: :ok
  def store(key, command) do
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {key, command, expires_at})
    :ok
  end

  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @spec pop(term()) :: {:ok, term()} | :miss | :expired
  def has_pending?(key) do
    case :ets.lookup(@table, key) do
      [{^key, _command, expires_at}] ->
        System.monotonic_time(:millisecond) < expires_at

      [] ->
        false
    end
  end

  def pop(key) do
    case :ets.lookup(@table, key) do
      [{^key, command, expires_at}] ->
        :ets.delete(@table, key)
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, command}, else: :expired

      [] ->
        :miss
    end
  end

  # GenServer callbacks

  @impl GenServer
  def init(_) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
