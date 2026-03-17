defmodule YonderbookClubs.Clubs.CacheTest do
  use ExUnit.Case, async: true

  alias YonderbookClubs.Clubs.Cache

  # The ETS table is created by the Cache GenServer at app startup.
  # Tests use unique keys to avoid conflicts.

  defp unique_key, do: "cache-test-#{System.unique_integer([:positive])}"

  defp fake_club(name \\ "Test Club") do
    %YonderbookClubs.Clubs.Club{
      id: Ecto.UUID.generate(),
      signal_group_id: unique_key(),
      name: name,
      voting_active: false
    }
  end

  describe "get/1" do
    test "returns :miss for unknown key" do
      assert :miss = Cache.get(unique_key())
    end

    test "returns {:ok, club} after put" do
      key = unique_key()
      club = fake_club()

      Cache.put(key, club)

      assert {:ok, ^club} = Cache.get(key)
    end

    test "returns :miss after TTL expires" do
      key = unique_key()
      club = fake_club()

      # Insert directly with an already-expired TTL
      :ets.insert(:clubs_cache, {key, club, System.monotonic_time(:millisecond) - 1})

      assert :miss = Cache.get(key)
    end
  end

  describe "put/1" do
    test "stores club in cache" do
      key = unique_key()
      club = fake_club()

      assert :ok = Cache.put(key, club)
      assert {:ok, ^club} = Cache.get(key)
    end

    test "overwrites existing entry" do
      key = unique_key()
      club1 = fake_club("Club 1")
      club2 = fake_club("Club 2")

      Cache.put(key, club1)
      Cache.put(key, club2)

      assert {:ok, ^club2} = Cache.get(key)
    end
  end

  describe "invalidate/1" do
    test "removes entry from cache" do
      key = unique_key()
      club = fake_club()

      Cache.put(key, club)
      assert {:ok, _} = Cache.get(key)

      assert :ok = Cache.invalidate(key)
      assert :miss = Cache.get(key)
    end

    test "returns :ok for non-existent key" do
      assert :ok = Cache.invalidate(unique_key())
    end
  end
end
