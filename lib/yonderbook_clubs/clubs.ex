defmodule YonderbookClubs.Clubs do
  @moduledoc """
  Context module for managing book clubs.
  """

  alias YonderbookClubs.Repo
  alias YonderbookClubs.Clubs.Club

  @doc """
  Finds a club by signal_group_id, or creates one if it doesn't exist.

  Returns `{:ok, club}`.
  """
  def get_or_create_club(signal_group_id, name) do
    case Repo.get_by(Club, signal_group_id: signal_group_id) do
      nil ->
        %Club{}
        |> Club.changeset(%{signal_group_id: signal_group_id, name: name})
        |> Repo.insert()

      club ->
        {:ok, club}
    end
  end

  @doc """
  Gets a club by id. Raises `Ecto.NoResultsError` if not found.
  """
  def get_club!(id) do
    Repo.get!(Club, id)
  end

  @doc """
  Gets a club by signal_group_id. Returns nil if not found.
  """
  def get_club_by_group_id(signal_group_id) do
    Repo.get_by(Club, signal_group_id: signal_group_id)
  end

  @doc """
  Updates the voting_active flag on a club.

  Returns `{:ok, club}` or `{:error, changeset}`.
  """
  def set_voting_active(%Club{} = club, active) when is_boolean(active) do
    club
    |> Club.changeset(%{voting_active: active})
    |> Repo.update()
  end
end
