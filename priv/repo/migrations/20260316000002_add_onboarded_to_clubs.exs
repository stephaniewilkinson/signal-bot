defmodule YonderbookClubs.Repo.Migrations.AddOnboardedToClubs do
  use Ecto.Migration

  def change do
    alter table(:clubs) do
      add :onboarded, :boolean, null: false, default: false
    end
  end
end
