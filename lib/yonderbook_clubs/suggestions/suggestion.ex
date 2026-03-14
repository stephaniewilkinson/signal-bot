defmodule YonderbookClubs.Suggestions.Suggestion do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          title: String.t(),
          author: String.t(),
          isbn: String.t() | nil,
          open_library_work_id: String.t(),
          cover_url: String.t() | nil,
          description: String.t() | nil,
          signal_sender_uuid: String.t(),
          signal_sender_name: String.t() | nil,
          status: :active | :archived,
          club_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "suggestions" do
    field(:title, :string)
    field(:author, :string)
    field(:isbn, :string)
    field(:open_library_work_id, :string)
    field(:cover_url, :string)
    field(:description, :string)
    field(:signal_sender_uuid, :string)
    field(:signal_sender_name, :string)
    field(:status, Ecto.Enum, values: [:active, :archived], default: :active)

    belongs_to(:club, YonderbookClubs.Clubs.Club)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(suggestion, attrs) do
    suggestion
    |> cast(attrs, [
      :title,
      :author,
      :isbn,
      :open_library_work_id,
      :cover_url,
      :description,
      :signal_sender_uuid,
      :signal_sender_name,
      :club_id
    ])
    |> validate_required([:title, :author, :open_library_work_id, :signal_sender_uuid, :club_id])
    |> foreign_key_constraint(:club_id)
    |> unique_constraint([:club_id, :open_library_work_id])
  end
end
