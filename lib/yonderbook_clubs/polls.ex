defmodule YonderbookClubs.Polls do
  @moduledoc """
  Context module for managing polls, poll options, and votes.
  """

  import Ecto.Query

  alias YonderbookClubs.Clubs.Club
  alias YonderbookClubs.Repo
  alias YonderbookClubs.Polls.{Poll, PollOption, Vote}
  alias YonderbookClubs.Suggestions.Suggestion

  @spec create_poll(Club.t(), integer(), integer(), [Suggestion.t()]) :: {:ok, Poll.t()} | {:error, term()}
  def create_poll(club, signal_timestamp, vote_budget, suggestions) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:poll, Poll.changeset(%Poll{}, %{
        club_id: club.id,
        signal_timestamp: signal_timestamp,
        vote_budget: vote_budget
      }))
      |> Ecto.Multi.run(:poll_options, fn repo, %{poll: poll} ->
        options =
          suggestions
          |> Enum.with_index()
          |> Enum.map(fn {suggestion, index} ->
            %PollOption{}
            |> PollOption.changeset(%{
              poll_id: poll.id,
              option_index: index,
              suggestion_id: suggestion.id
            })
            |> repo.insert!()
          end)

        {:ok, options}
      end)

    case Repo.transaction(multi) do
      {:ok, %{poll: poll}} -> {:ok, poll}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  @spec get_poll_by_timestamp(integer()) :: Poll.t() | nil
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

  @spec get_latest_polls(Club.t()) :: [Poll.t()]
  def get_latest_polls(club) do
    case get_latest_poll(club) do
      nil ->
        []

      latest ->
        Poll
        |> where(club_id: ^club.id, vote_budget: ^latest.vote_budget, status: ^latest.status)
        |> where([p], p.inserted_at >= ^DateTime.add(latest.inserted_at, -60, :second))
        |> order_by(asc: :inserted_at)
        |> Repo.all()
    end
  end

  @spec get_latest_active_polls(Club.t()) :: [Poll.t()]
  def get_latest_active_polls(club) do
    Poll
    |> where(club_id: ^club.id, status: :active)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @spec record_vote(Poll.t(), String.t(), [integer()], integer()) :: {:ok, Vote.t()} | {:error, Ecto.Changeset.t()}
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

  @spec close_poll(Poll.t()) :: {:ok, Poll.t()} | {:error, Ecto.Changeset.t()}
  def close_poll(poll) do
    poll
    |> Poll.changeset(%{status: :closed})
    |> Repo.update()
  end

  @spec delete_poll(Poll.t()) :: {:ok, Poll.t()} | {:error, Ecto.Changeset.t()}
  def delete_poll(poll) do
    Repo.delete(poll)
  end

  @spec get_combined_results([Poll.t()]) :: [{Suggestion.t(), non_neg_integer()}]
  def get_combined_results(polls) do
    poll_ids = Enum.map(polls, & &1.id)

    options =
      PollOption
      |> where([o], o.poll_id in ^poll_ids)
      |> preload(:suggestion)
      |> order_by(asc: :option_index)
      |> Repo.all()

    votes =
      Vote
      |> where([v], v.poll_id in ^poll_ids)
      |> Repo.all()

    votes_by_poll = Enum.group_by(votes, & &1.poll_id)

    options
    |> Enum.map(fn option ->
      poll_votes = Map.get(votes_by_poll, option.poll_id, [])

      count =
        Enum.count(poll_votes, fn vote ->
          option.option_index in vote.option_indexes
        end)

      {option.suggestion, count}
    end)
    |> Enum.sort_by(fn {_suggestion, count} -> count end, :desc)
  end
end
