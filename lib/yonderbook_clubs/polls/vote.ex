defmodule YonderbookClubs.Polls.Vote do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          signal_sender_uuid: String.t(),
          option_indexes: [integer()],
          vote_count: integer(),
          poll_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

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
    |> validate_number(:vote_count, greater_than: 0)
    |> validate_option_indexes()
    |> foreign_key_constraint(:poll_id)
    |> unique_constraint([:poll_id, :signal_sender_uuid])
  end

  defp validate_option_indexes(changeset) do
    indexes = get_field(changeset, :option_indexes)

    cond do
      is_nil(indexes) -> changeset
      indexes == [] -> add_error(changeset, :option_indexes, "must not be empty")
      not Enum.all?(indexes, &(is_integer(&1) and &1 >= 0)) -> add_error(changeset, :option_indexes, "must contain non-negative integers")
      true -> changeset
    end
  end
end
