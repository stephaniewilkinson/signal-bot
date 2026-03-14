defmodule YonderbookClubs.Clubs.Cache do
  @moduledoc """
  ETS-backed cache for club lookups by signal_group_id.

  Caches clubs with a 60-second TTL to avoid repeated DB hits during
  DM processing (where resolve_club loops over all groups).
  """

  use GenServer

  @table :clubs_cache
  @ttl_ms 60_000
  @sweep_interval_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec get(String.t()) :: {:ok, struct()} | :miss
  def get(signal_group_id) do
    case :ets.lookup(@table, signal_group_id) do
      [{^signal_group_id, club, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, club}, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec put(String.t(), struct()) :: :ok
  def put(signal_group_id, club) do
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {signal_group_id, club, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(signal_group_id) do
    :ets.delete(@table, signal_group_id)
    :ok
  rescue
    ArgumentError -> :ok
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
