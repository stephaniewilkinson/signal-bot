defmodule YonderbookClubs.Clubs do
  @moduledoc """
  Context module for managing book clubs.
  """

  alias YonderbookClubs.Clubs.{Cache, Club}
  alias YonderbookClubs.Repo

  @doc """
  Finds a club by signal_group_id, or creates one if it doesn't exist.

  Returns `{:ok, club}`.
  """
  @spec get_or_create_club(String.t(), String.t()) :: {:ok, Club.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_club(signal_group_id, name) do
    %Club{}
    |> Club.changeset(%{signal_group_id: signal_group_id, name: name})
    |> Repo.insert(
      on_conflict: {:replace, [:name, :updated_at]},
      conflict_target: :signal_group_id,
      returning: true
    )
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
end
