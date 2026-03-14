defmodule YonderbookClubs.Suggestions do
  @moduledoc """
  Context module for managing book suggestions within clubs.
  """

  import Ecto.Query

  alias YonderbookClubs.Repo
  alias YonderbookClubs.Suggestions.Suggestion

  @doc """
  Creates a suggestion for the given club.

  Before inserting, checks for a duplicate by `open_library_work_id` within the club.
  If a duplicate is found, returns `{:ok, :duplicate}`.
  Otherwise inserts and returns `{:ok, suggestion}` or `{:error, changeset}`.
  """
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
  Returns all suggestions for a club, ordered by inserted_at ascending.
  """
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
  Archives all active suggestions for a club. Returns `{count, nil}`.
  """
  def archive_all_suggestions(club) do
    Suggestion
    |> where(club_id: ^club.id, status: :active)
    |> Repo.update_all(set: [status: :archived, updated_at: DateTime.utc_now()])
  end

  @doc """
  Returns all suggestions by a sender for a club, grouped by status.
  Returns `%{active: [...], archived: [...]}`.
  """
  def list_suggestions_by_sender(club_id, signal_sender_uuid) do
    suggestions =
      Suggestion
      |> where(club_id: ^club_id, signal_sender_uuid: ^signal_sender_uuid)
      |> order_by(desc: :inserted_at)
      |> Repo.all()

    %{
      active: Enum.filter(suggestions, &(&1.status == :active)),
      archived: Enum.filter(suggestions, &(&1.status == :archived))
    }
  end
end
