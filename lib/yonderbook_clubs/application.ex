defmodule YonderbookClubs.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        YonderbookClubs.Repo
      ] ++ signal_children()

    opts = [strategy: :one_for_one, name: YonderbookClubs.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp signal_children do
    if Application.get_env(:yonderbook_clubs, :signal_impl) == YonderbookClubs.Signal.Mock do
      []
    else
      [YonderbookClubs.Signal.CLI]
    end
  end
end
