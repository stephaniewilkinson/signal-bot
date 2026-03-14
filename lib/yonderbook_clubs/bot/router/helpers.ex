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
