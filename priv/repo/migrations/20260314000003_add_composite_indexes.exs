defmodule YonderbookClubs.Repo.Migrations.AddCompositeIndexes do
  use Ecto.Migration

  def change do
    create index(:suggestions, [:club_id, :status])
    create index(:polls, [:club_id, :status])
  end
end
