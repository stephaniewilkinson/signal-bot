defmodule YonderbookClubs.Polls do
  @moduledoc """
  Context module for managing polls, poll options, and votes.
  """

  import Ecto.Query

  alias YonderbookClubs.Repo
  alias YonderbookClubs.Polls.{Poll, PollOption, Vote}

  def create_poll(club, signal_timestamp, vote_budget, suggestions) do
    Repo.transaction(fn ->
      {:ok, poll} =
        %Poll{}
        |> Poll.changeset(%{
          club_id: club.id,
          signal_timestamp: signal_timestamp,
          vote_budget: vote_budget
        })
        |> Repo.insert()

      suggestions
      |> Enum.with_index()
      |> Enum.each(fn {suggestion, index} ->
        %PollOption{}
        |> PollOption.changeset(%{
          poll_id: poll.id,
          option_index: index,
          suggestion_id: suggestion.id
        })
        |> Repo.insert!()
      end)

      poll
    end)
  end

  def get_poll_by_timestamp(signal_timestamp) do
    Poll
    |> where(signal_timestamp: ^signal_timestamp)
    |> Repo.one()
  end

  def get_latest_poll(club) do
    Poll
    |> where(club_id: ^club.id)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def get_latest_active_poll(club) do
    Poll
    |> where(club_id: ^club.id, status: :active)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def record_vote(poll, signal_sender_uuid, option_indexes, vote_count) do
    attrs = %{
      poll_id: poll.id,
      signal_sender_uuid: signal_sender_uuid,
      option_indexes: option_indexes,
      vote_count: vote_count
    }

    %Vote{}
    |> Vote.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:option_indexes, :vote_count, :updated_at]},
      conflict_target: [:poll_id, :signal_sender_uuid]
    )
  end

  def close_poll(poll) do
    poll
    |> Poll.changeset(%{status: :closed})
    |> Repo.update()
  end

  def get_results(poll) do
    options =
      PollOption
      |> where(poll_id: ^poll.id)
      |> preload(:suggestion)
      |> order_by(asc: :option_index)
      |> Repo.all()

    votes =
      Vote
      |> where(poll_id: ^poll.id)
      |> Repo.all()

    options
    |> Enum.map(fn option ->
      count =
        Enum.count(votes, fn vote ->
          option.option_index in vote.option_indexes
        end)

      {option.suggestion, count}
    end)
    |> Enum.sort_by(fn {_suggestion, count} -> count end, :desc)
  end
end
