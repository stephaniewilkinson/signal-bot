defmodule YonderbookClubs.Repo.Migrations.FixSuggestionsUniqueIndex do
  use Ecto.Migration

  def change do
    drop unique_index(:suggestions, [:club_id, :open_library_work_id])

    create unique_index(:suggestions, [:club_id, :open_library_work_id],
      where: "status = 'active'",
      name: :suggestions_club_id_work_id_active_index
    )
  end
end
