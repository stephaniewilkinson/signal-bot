defmodule YonderbookClubs.Signal do
  @moduledoc """
  Behaviour defining the interface for interacting with Signal via signal-cli.

  In production, this is implemented by `YonderbookClubs.Signal.CLI` which
  connects to signal-cli's JSON-RPC daemon over TCP. In test, a Mox mock is
  used (see `YonderbookClubs.Signal.Mock`).
  """

  @callback send_message(recipient :: String.t(), body :: String.t()) ::
              :ok | {:error, term()}
  @callback send_message(recipient :: String.t(), body :: String.t(), attachments :: [String.t()]) ::
              :ok | {:error, term()}
  @callback send_poll(group_id :: String.t(), question :: String.t(), options :: [String.t()]) ::
              {:ok, integer()} | {:error, term()}
  @callback list_groups() :: {:ok, [map()]} | {:error, term()}

  @spec impl() :: module()
  def impl do
    Application.get_env(:yonderbook_clubs, :signal_impl, YonderbookClubs.Signal.CLI)
  end
end
