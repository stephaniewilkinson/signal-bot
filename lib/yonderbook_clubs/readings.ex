defmodule YonderbookClubs.Readings do
  @moduledoc """
  Context module for managing reading schedule entries within clubs.
  """

  import Ecto.Query

  alias YonderbookClubs.Clubs.Club
  alias YonderbookClubs.Readings.Reading
  alias YonderbookClubs.Repo

  @max_readings_per_club 50

  @spec create_reading(Club.t(), map()) :: {:ok, Reading.t()} | {:error, Ecto.Changeset.t()} | {:error, :limit_reached}
  def create_reading(club, attrs) do
    downcased = String.downcase(attrs[:title] || attrs["title"] || "")

    case find_by_title(club, downcased) do
      %Reading{} = existing ->
        existing
        |> Reading.changeset(Map.take(attrs, [:time_label, :author]))
        |> Repo.update()

      nil ->
        if count_readings(club) >= @max_readings_per_club do
          {:error, :limit_reached}
        else
          attrs = Map.put(attrs, :club_id, club.id)

          %Reading{}
          |> Reading.changeset(attrs)
          |> Repo.insert()
        end
    end
  end

  @spec list_readings(Club.t()) :: [Reading.t()]
  def list_readings(club) do
    Reading
    |> where(club_id: ^club.id)
    |> order_by(asc: :inserted_at, asc: :id)
    |> Repo.all()
  end

  @spec remove_reading(Club.t(), String.t()) :: {:ok, Reading.t()} | {:error, :not_found}
  def remove_reading(club, text) do
    downcased = String.downcase(text)

    case find_by_title(club, downcased) || find_by_time_label(club, downcased) do
      nil -> {:error, :not_found}
      reading -> Repo.delete(reading)
    end
  end

  defp find_by_title(club, downcased) do
    Reading
    |> where(club_id: ^club.id)
    |> where([r], fragment("lower(?)", r.title) == ^downcased)
    |> limit(1)
    |> Repo.one()
  end

  defp find_by_time_label(club, downcased) do
    Reading
    |> where(club_id: ^club.id)
    |> where([r], fragment("lower(?)", r.time_label) == ^downcased)
    |> limit(1)
    |> Repo.one()
  end

  defp count_readings(club) do
    Reading
    |> where(club_id: ^club.id)
    |> Repo.aggregate(:count)
  end
end
