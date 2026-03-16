defmodule YonderbookClubs.Readings.Reading do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          title: String.t(),
          author: String.t() | nil,
          time_label: String.t(),
          club_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "readings" do
    field(:title, :string)
    field(:author, :string)
    field(:time_label, :string)

    belongs_to(:club, YonderbookClubs.Clubs.Club)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(reading, attrs) do
    reading
    |> cast(attrs, [:title, :author, :time_label, :club_id])
    |> validate_required([:title, :time_label, :club_id])
    |> foreign_key_constraint(:club_id)
  end
end
