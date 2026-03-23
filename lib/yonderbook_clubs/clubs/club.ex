defmodule YonderbookClubs.Clubs.Club do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          signal_group_id: String.t(),
          name: String.t(),
          voting_active: boolean(),
          onboarded: boolean(),
          active: boolean(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "clubs" do
    field(:signal_group_id, :string)
    field(:name, :string)
    field(:voting_active, :boolean, default: false)
    field(:onboarded, :boolean, default: false)
    field(:active, :boolean, default: true)

    has_many(:suggestions, YonderbookClubs.Suggestions.Suggestion)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(club, attrs) do
    club
    |> cast(attrs, [:signal_group_id, :name, :voting_active, :onboarded, :active])
    |> validate_required([:signal_group_id, :name])
    |> unique_constraint(:signal_group_id)
  end
end
