defmodule YonderbookClubs.Repo.Migrations.CreateClubs do
  use Ecto.Migration

  def change do
    create table(:clubs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :signal_group_id, :string, null: false
      add :name, :string, null: false
      add :voting_active, :boolean, default: false, null: false

      timestamps()
    end

    create unique_index(:clubs, [:signal_group_id])
  end
end
