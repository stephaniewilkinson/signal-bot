defmodule YonderbookClubs.Repo.Migrations.AddActiveToClubs do
  use Ecto.Migration

  def change do
    alter table(:clubs) do
      add :active, :boolean, default: true, null: false
    end
  end
end
