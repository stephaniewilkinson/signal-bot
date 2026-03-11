defmodule YonderbookClubs.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias YonderbookClubs.Repo
      import Ecto
      import Ecto.Query
      import YonderbookClubs.DataCase
    end
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(YonderbookClubs.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
