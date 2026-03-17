defmodule YonderbookClubs.Bot.Router.Helpers do
  @moduledoc """
  Shared utilities for router command modules.
  """

  require Logger

  @spec strip_slash(String.t()) :: String.t()
  def strip_slash("/" <> rest), do: rest
  def strip_slash(text), do: text

  @spec download_covers([struct()]) :: [String.t()]
  def download_covers(suggestions) do
    suggestions
    |> Enum.filter(& &1.cover_url)
    |> Task.async_stream(
      fn suggestion ->
        case Req.get(suggestion.cover_url, receive_timeout: 10_000) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            path = Path.join(System.tmp_dir!(), "cover_#{suggestion.id}.jpg")

            case File.write(path, body) do
              :ok -> path
              {:error, reason} ->
                Logger.warning("Failed to write cover for #{suggestion.title}: #{inspect(reason)}")
                nil
            end

          _ ->
            Logger.warning("Failed to download cover for #{suggestion.title}")
            nil
        end
      end,
      max_concurrency: 6,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, path} when is_binary(path) -> [path]
      _ -> []
    end)
  end

  @dm_commands ["help", "suggest", "remove", "suggestions", "schedule"]
  @group_commands ["start vote", "start poll", "close vote", "close poll",
                   "results", "schedule", "unschedule"]

  @doc """
  Fuzzy-matches user input against known commands using Jaro distance.
  Returns `{:ok, command}` if a close match is found, `:no_match` otherwise.
  """
  @spec fuzzy_match_command(String.t(), :dm | :group) :: {:ok, String.t()} | :no_match
  def fuzzy_match_command(input, context) do
    commands = if context == :dm, do: @dm_commands, else: @group_commands
    words = String.split(input, " ", parts: 3)

    candidates =
      [Enum.take(words, 1), Enum.take(words, 2)]
      |> Enum.map(&Enum.join(&1, " "))
      |> Enum.uniq()

    best =
      for candidate <- candidates,
          command <- commands,
          dist = String.jaro_distance(candidate, command),
          dist > 0.85,
          reduce: nil do
        nil -> {command, dist}
        {_, prev_dist} = prev -> if dist > prev_dist, do: {command, dist}, else: prev
      end

    case best do
      {cmd, _} -> {:ok, cmd}
      nil -> :no_match
    end
  end

  @spec cleanup_covers([String.t()]) :: :ok
  def cleanup_covers(paths) do
    Enum.each(paths, fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Failed to clean up cover #{path}: #{inspect(reason)}")
      end
    end)
  end
end
