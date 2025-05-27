defmodule WandererApp.Zkb.KillsProvider do
  @moduledoc """
  Provides access to killmail data from zKillboard.
  """

  require Logger
  alias WandererApp.Zkb.KillsProvider.{Fetcher, KillsCache}

  @doc """
  Fetch kills for a system from zKillboard.
  Returns a list of killmail maps.
  """
  def fetch_kills(system_id) do
    case Fetcher.fetch_kills_for_system(system_id, 1, %{}) do
      {:ok, kills, _state} -> {:ok, kills}
      error -> error
    end
  end

  @doc """
  Get cached kills for a system.
  Returns a list of killmail maps.
  """
  def get_cached_kills(system_id) do
    KillsCache.fetch_cached_kills(system_id)
  end

  @doc """
  Get the kill count for a system.
  Returns an integer.
  """
  def get_kill_count(system_id) do
    KillsCache.get_system_kill_count(system_id)
  end

  @doc """
  Clear all cached kills.
  """
  def clear_cache do
    # TODO: Implement cache clearing
    :ok
  end
end
