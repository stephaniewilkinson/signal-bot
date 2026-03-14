defmodule YonderbookClubs.Repo.Migrations.AddSenderNameToSuggestions do
  use Ecto.Migration

  def change do
    alter table(:suggestions) do
      add :signal_sender_name, :string
    end
  end
end
