defmodule YonderbookClubs.Clubs do
  @moduledoc """
  Context module for managing book clubs.
  """

  alias YonderbookClubs.Clubs.{Cache, Club}
  alias YonderbookClubs.Repo

  require Logger

  @doc """
  Finds a club by signal_group_id, or creates one if it doesn't exist.

  Returns `{:ok, club}`.
  """
  @spec get_or_create_club(String.t(), String.t()) :: {:ok, Club.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_club(signal_group_id, name) do
    result =
      %Club{}
      |> Club.changeset(%{signal_group_id: signal_group_id, name: name, active: true})
      |> Repo.insert(
        # active: true ensures re-adding the bot to a group reactivates the club
        on_conflict: {:replace, [:name, :active, :updated_at]},
        conflict_target: :signal_group_id,
        returning: true
      )

    case result do
      {:ok, club} -> Cache.put(signal_group_id, club)
      _ -> :ok
    end

    result
  end

  @doc """
  Gets a club by id. Raises `Ecto.NoResultsError` if not found.
  """
  @spec get_club!(Ecto.UUID.t()) :: Club.t()
  def get_club!(id) do
    Repo.get!(Club, id)
  end

  @doc """
  Gets all clubs matching the given signal_group_ids in a single query.
  """
  @spec get_clubs_by_group_ids([String.t()]) :: [Club.t()]
  def get_clubs_by_group_ids([]), do: []

  def get_clubs_by_group_ids(signal_group_ids) do
    import Ecto.Query

    Club
    |> where([c], c.signal_group_id in ^signal_group_ids)
    |> order_by([c], asc: c.name, asc: c.id)
    |> Repo.all()
  end

  @doc """
  Gets a club by signal_group_id. Returns nil if not found.
  """
  @spec get_club_by_group_id(String.t()) :: Club.t() | nil
  def get_club_by_group_id(signal_group_id) do
    case Cache.get(signal_group_id) do
      {:ok, club} ->
        club

      :miss ->
        club = Repo.get_by(Club, signal_group_id: signal_group_id)
        if club, do: Cache.put(signal_group_id, club)
        club
    end
  end

  @doc """
  Updates the voting_active flag on a club.

  Returns `{:ok, club}` or `{:error, changeset}`.
  """
  @spec set_voting_active(Club.t(), boolean()) :: {:ok, Club.t()} | {:error, Ecto.Changeset.t()}
  def set_voting_active(%Club{} = club, active) when is_boolean(active) do
    result =
      club
      |> Club.changeset(%{voting_active: active})
      |> Repo.update()

    case result do
      {:ok, updated} -> Cache.invalidate(updated.signal_group_id)
      _ -> :ok
    end

    result
  end

  @doc """
  Marks a club as onboarded (welcome message has been sent).
  """
  @spec mark_onboarded(Club.t()) :: {:ok, Club.t()} | {:error, Ecto.Changeset.t()}
  def mark_onboarded(%Club{} = club) do
    result =
      club
      |> Club.changeset(%{onboarded: true})
      |> Repo.update()

    case result do
      {:ok, updated} -> Cache.invalidate(updated.signal_group_id)
      _ -> :ok
    end

    result
  end

  @doc """
  Deactivates a single club (marks it inactive).
  """
  @spec deactivate_club(Club.t()) :: {:ok, Club.t()} | {:error, Ecto.Changeset.t()}
  def deactivate_club(%Club{} = club) do
    result =
      club
      |> Club.changeset(%{active: false})
      |> Repo.update()

    case result do
      {:ok, updated} -> Cache.invalidate(updated.signal_group_id)
      _ -> :ok
    end

    result
  end

  @doc """
  Deactivates all clubs whose signal_group_id is NOT in the given list.

  Called during DM club resolution to sync DB state with reality —
  if the bot has been removed from a group, the club is marked inactive.
  """
  @spec deactivate_clubs_not_in([String.t()]) :: {non_neg_integer(), nil}
  def deactivate_clubs_not_in([]), do: {0, nil}

  def deactivate_clubs_not_in(active_group_ids) do
    import Ecto.Query

    # Find affected group IDs before update so we can invalidate their cache entries
    affected_group_ids =
      Club
      |> where([c], c.active == true and c.signal_group_id not in ^active_group_ids)
      |> select([c], c.signal_group_id)
      |> Repo.all()

    {count, _} =
      Club
      |> where([c], c.active == true and c.signal_group_id not in ^active_group_ids)
      |> Repo.update_all(set: [active: false, updated_at: DateTime.utc_now()])

    if count > 0 do
      Enum.each(affected_group_ids, &Cache.invalidate/1)
      Logger.info("Deactivated #{count} club(s) — bot was removed from their groups")
    end

    {count, nil}
  end

  @doc """
  Atomically sets voting_active to true, but only if it's currently false.

  Returns `{:ok, club}` if the transition succeeded, or `{:error, :already_voting}`
  if another request already activated voting (prevents TOCTOU races).
  """
  @spec activate_voting(Club.t()) :: {:ok, Club.t()} | {:error, :already_voting}
  def activate_voting(%Club{} = club) do
    import Ecto.Query

    {count, updated} =
      Club
      |> where(id: ^club.id, voting_active: false)
      |> select([c], c)
      |> Repo.update_all(set: [voting_active: true, updated_at: DateTime.utc_now()])

    case {count, updated} do
      {1, [updated_club]} ->
        Cache.invalidate(club.signal_group_id)
        {:ok, updated_club}

      {0, _} ->
        {:error, :already_voting}
    end
  end

  @doc """
  Atomically sets voting_active to false, but only if it's currently true.

  Returns `{:ok, club}` if the transition succeeded, or `{:error, :not_voting}`
  if voting was already inactive.
  """
  @spec deactivate_voting(Club.t()) :: {:ok, Club.t()} | {:error, :not_voting}
  def deactivate_voting(%Club{} = club) do
    import Ecto.Query

    {count, updated} =
      Club
      |> where(id: ^club.id, voting_active: true)
      |> select([c], c)
      |> Repo.update_all(set: [voting_active: false, updated_at: DateTime.utc_now()])

    case {count, updated} do
      {1, [updated_club]} ->
        Cache.invalidate(club.signal_group_id)
        {:ok, updated_club}

      {0, _} ->
        {:error, :not_voting}
    end
  end
end
