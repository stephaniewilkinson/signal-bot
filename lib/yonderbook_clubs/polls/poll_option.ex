defmodule YonderbookClubs.Polls.PollOption do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          option_index: integer(),
          poll_id: Ecto.UUID.t(),
          suggestion_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "poll_options" do
    field(:option_index, :integer)

    belongs_to(:poll, YonderbookClubs.Polls.Poll)
    belongs_to(:suggestion, YonderbookClubs.Suggestions.Suggestion)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(poll_option, attrs) do
    poll_option
    |> cast(attrs, [:poll_id, :option_index, :suggestion_id])
    |> validate_required([:poll_id, :option_index, :suggestion_id])
    |> foreign_key_constraint(:poll_id)
    |> foreign_key_constraint(:suggestion_id)
    |> unique_constraint([:poll_id, :option_index])
  end
end
