defmodule YonderbookClubs.Clubs.Club do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "clubs" do
    field :signal_group_id, :string
    field :name, :string
    field :voting_active, :boolean, default: false

    has_many :suggestions, YonderbookClubs.Suggestions.Suggestion

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(club, attrs) do
    club
    |> cast(attrs, [:signal_group_id, :name, :voting_active])
    |> validate_required([:signal_group_id, :name])
    |> unique_constraint(:signal_group_id)
  end
end
