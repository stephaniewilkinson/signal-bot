defmodule YonderbookClubs.Repo.Migrations.AddStatusToSuggestions do
  use Ecto.Migration

  def change do
    alter table(:suggestions) do
      add :status, :string, default: "active", null: false
    end
  end
end
