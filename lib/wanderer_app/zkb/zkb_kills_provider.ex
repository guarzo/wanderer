defmodule WandererApp.Zkb.KillsProvider do
  use Fresh
  require Logger

  defstruct [:connected]

  # Since we've moved to polling, we don't need these websocket callbacks anymore
  def handle_connect(_status, _headers, state), do: {:ok, state}
  def handle_in(_frame, state), do: {:ok, state}
  def handle_control(_msg, state), do: {:ok, state}
  def handle_info(_msg, state), do: {:ok, state}
  def handle_disconnect(_code, _reason, state), do: {:ok, state}
  def handle_error(_err, state), do: {:ok, state}
  def handle_terminate(_reason, state), do: {:ok, state}
end
