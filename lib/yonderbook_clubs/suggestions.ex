defmodule YonderbookClubs.Suggestions do
  @moduledoc """
  Context module for managing book suggestions within clubs.
  """

  import Ecto.Query

  alias YonderbookClubs.Clubs.Club
  alias YonderbookClubs.Repo
  alias YonderbookClubs.Suggestions.Suggestion

  @doc """
  Creates a suggestion for the given club.

  Before inserting, checks for a duplicate by `open_library_work_id` within the club.
  If a duplicate is found, returns `{:ok, :duplicate}`.
  Otherwise inserts and returns `{:ok, suggestion}` or `{:error, changeset}`.
  """
  @spec create_suggestion(Club.t(), map()) :: {:ok, Suggestion.t()} | {:ok, :duplicate} | {:error, Ecto.Changeset.t()}
  def create_suggestion(club, attrs) do
    attrs = Map.put(attrs, :club_id, club.id)

    if duplicate?(club.id, attrs[:open_library_work_id]) do
      {:ok, :duplicate}
    else
      case %Suggestion{}
           |> Suggestion.changeset(attrs)
           |> Repo.insert() do
        {:ok, suggestion} ->
          {:ok, suggestion}

        {:error, %Ecto.Changeset{} = changeset} ->
          if unique_violation?(changeset) do
            {:ok, :duplicate}
          else
            {:error, changeset}
          end
      end
    end
  end

  defp unique_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      opts[:constraint] == :unique
    end)
  end

  defp duplicate?(_club_id, nil), do: false

  defp duplicate?(club_id, open_library_work_id) do
    Suggestion
    |> where(club_id: ^club_id, open_library_work_id: ^open_library_work_id, status: :active)
    |> Repo.exists?()
  end

  @doc """
  Gets a suggestion by id. Raises `Ecto.NoResultsError` if not found.
  """
  @spec get_suggestion!(Ecto.UUID.t()) :: Suggestion.t()
  def get_suggestion!(id) do
    Repo.get!(Suggestion, id)
  end

  @doc """
  Returns all suggestions for a club, ordered by inserted_at ascending.
  """
  @spec list_suggestions(Club.t()) :: [Suggestion.t()]
  def list_suggestions(club) do
    Suggestion
    |> where(club_id: ^club.id, status: :active)
    |> order_by(asc: :inserted_at, asc: :id)
    |> Repo.all()
  end

  @doc """
  Deletes the sender's most recent suggestion (by inserted_at desc) for the given club.

  Returns `{:ok, suggestion}` if deleted, `{:error, :not_found}` if none exist.
  """
  @spec remove_latest_suggestion(Ecto.UUID.t(), String.t()) :: {:ok, Suggestion.t()} | {:error, :not_found}
  def remove_latest_suggestion(club_id, signal_sender_uuid) do
    query =
      Suggestion
      |> where(club_id: ^club_id, signal_sender_uuid: ^signal_sender_uuid, status: :active)
      |> order_by(desc: :inserted_at, desc: :id)
      |> limit(1)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      suggestion -> Repo.delete(suggestion)
    end
  end

  @doc """
  Returns true if the given sender has ever created a suggestion (any status, any club).
  """
  @spec has_suggestions_from?(String.t()) :: boolean()
  def has_suggestions_from?(signal_sender_uuid) do
    Suggestion
    |> where(signal_sender_uuid: ^signal_sender_uuid)
    |> Repo.exists?()
  end

  @doc """
  Returns the club name for a sender who has suggestions in exactly one club.
  Returns nil if the sender has no suggestions or is in multiple clubs.
  """
  @spec sender_club_name(String.t()) :: String.t() | nil
  def sender_club_name(signal_sender_uuid) do
    names =
      Suggestion
      |> join(:inner, [s], c in YonderbookClubs.Clubs.Club, on: s.club_id == c.id)
      |> where([s], s.signal_sender_uuid == ^signal_sender_uuid)
      |> distinct([s, c], c.id)
      |> select([s, c], c.name)
      |> Repo.all()

    case names do
      [name] -> name
      _ -> nil
    end
  end

  @doc """
  Archives all active suggestions for a club. Returns `{count, nil}`.
  """
  @spec archive_all_suggestions(Club.t()) :: {non_neg_integer(), nil}
  def archive_all_suggestions(club) do
    Suggestion
    |> where(club_id: ^club.id, status: :active)
    |> Repo.update_all(set: [status: :archived, updated_at: DateTime.utc_now()])
  end

end
