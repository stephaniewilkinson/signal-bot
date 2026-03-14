defmodule YonderbookClubs.Polls.Poll do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          signal_timestamp: integer(),
          vote_budget: integer(),
          status: :active | :closed,
          club_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "polls" do
    field(:signal_timestamp, :integer)
    field(:vote_budget, :integer, default: 1)
    field(:status, Ecto.Enum, values: [:active, :closed], default: :active)

    belongs_to(:club, YonderbookClubs.Clubs.Club)
    has_many(:poll_options, YonderbookClubs.Polls.PollOption)
    has_many(:votes, YonderbookClubs.Polls.Vote)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(poll, attrs) do
    poll
    |> cast(attrs, [:club_id, :signal_timestamp, :vote_budget, :status])
    |> validate_required([:club_id, :signal_timestamp, :vote_budget])
    |> foreign_key_constraint(:club_id)
    |> unique_constraint(:signal_timestamp)
  end
end
