defmodule YonderbookClubs.Repo.Migrations.CreateSuggestions do
  use Ecto.Migration

  def change do
    create table(:suggestions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :club_id, references(:clubs, type: :binary_id), null: false
      add :title, :string, null: false
      add :author, :string, null: false
      add :isbn, :string
      add :open_library_work_id, :string, null: false
      add :cover_url, :string
      add :description, :text
      add :signal_sender_uuid, :string, null: false

      timestamps()
    end

    create index(:suggestions, [:club_id])
    create unique_index(:suggestions, [:club_id, :open_library_work_id])
  end
end
