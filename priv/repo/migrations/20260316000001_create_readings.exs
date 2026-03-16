defmodule YonderbookClubs.Repo.Migrations.CreateReadings do
  use Ecto.Migration

  def change do
    create table(:readings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :club_id, references(:clubs, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :author, :string
      add :time_label, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:readings, [:club_id])
  end
end
