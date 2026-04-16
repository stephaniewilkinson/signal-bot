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
        insert_reading_with_limit(club, attrs)
    end
  end

  @month_order ~w(january february march april may june july august september october november december)

  @spec list_readings(Club.t()) :: [Reading.t()]
  def list_readings(club) do
    Reading
    |> where(club_id: ^club.id)
    |> Repo.all()
    |> Enum.sort_by(&parse_time_label_sort_key/1)
  end

  defp parse_time_label_sort_key(%{time_label: nil}), do: {9999, 99}

  defp parse_time_label_sort_key(%{time_label: label}) do
    downcased = String.downcase(label)

    year =
      case Regex.run(~r/\b(20\d{2})\b/, downcased) do
        [_, y] -> String.to_integer(y)
        nil -> 9999
      end

    month =
      Enum.find_index(@month_order, fn m -> String.contains?(downcased, m) end) || 99

    {year, month}
  end

  @spec remove_reading(Club.t(), String.t()) :: {:ok, Reading.t()} | {:error, :not_found}
  def remove_reading(club, text) do
    downcased = String.downcase(text)

    case find_by_title(club, downcased) || find_by_time_label(club, downcased) do
      nil -> {:error, :not_found}
      reading -> Repo.delete(reading)
    end
  end

  defp insert_reading_with_limit(club, attrs) do
    Repo.transaction(fn ->
      # Lock the club row to serialize concurrent inserts
      from(c in YonderbookClubs.Clubs.Club, where: c.id == ^club.id, lock: "FOR UPDATE")
      |> Repo.one!()

      if count_readings(club) >= @max_readings_per_club do
        Repo.rollback(:limit_reached)
      else
        attrs = Map.put(attrs, :club_id, club.id)

        case %Reading{} |> Reading.changeset(attrs) |> Repo.insert() do
          {:ok, reading} -> reading
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end
    end)
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
