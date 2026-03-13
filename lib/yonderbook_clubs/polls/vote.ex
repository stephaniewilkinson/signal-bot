defmodule YonderbookClubs.Polls.Vote do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "votes" do
    field(:signal_sender_uuid, :string)
    field(:option_indexes, {:array, :integer}, default: [])
    field(:vote_count, :integer)

    belongs_to(:poll, YonderbookClubs.Polls.Poll)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:poll_id, :signal_sender_uuid, :option_indexes, :vote_count])
    |> validate_required([:poll_id, :signal_sender_uuid, :option_indexes, :vote_count])
    |> foreign_key_constraint(:poll_id)
    |> unique_constraint([:poll_id, :signal_sender_uuid])
  end
end
