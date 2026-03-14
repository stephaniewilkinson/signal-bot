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
end
