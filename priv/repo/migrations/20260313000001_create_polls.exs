defmodule YonderbookClubs.Repo.Migrations.CreatePolls do
  use Ecto.Migration

  def change do
    create table(:polls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :club_id, references(:clubs, type: :binary_id, on_delete: :delete_all), null: false
      add :signal_timestamp, :bigint, null: false
      add :vote_budget, :integer, null: false, default: 1
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:polls, [:club_id])
    create unique_index(:polls, [:signal_timestamp])

    create table(:poll_options, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :poll_id, references(:polls, type: :binary_id, on_delete: :delete_all), null: false
      add :option_index, :integer, null: false
      add :suggestion_id, references(:suggestions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:poll_options, [:poll_id, :option_index])

    create table(:votes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :poll_id, references(:polls, type: :binary_id, on_delete: :delete_all), null: false
      add :signal_sender_uuid, :string, null: false
      add :option_indexes, {:array, :integer}, null: false, default: []
      add :vote_count, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:votes, [:poll_id, :signal_sender_uuid])
  end
end
