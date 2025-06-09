defmodule WandererApp.Kills.Storage do
  @moduledoc """
  Manages caching and storage of killmail data.
  
  Provides a centralized interface for storing and retrieving kill-related data
  using Cachex for distributed caching.
  """
  
  require Logger
  
  alias WandererApp.Kills.Config
  
  @cache_name :wanderer_kills_cache
  
  @doc """
  Stores killmails for a specific system.
  
  Stores both individual killmails by ID and a list of kills for the system.
  """
  @spec store_killmails(integer(), list(map()), pos_integer()) :: :ok
  def store_killmails(system_id, killmails, ttl) do
    # Store individual killmails
    Enum.each(killmails, &store_individual_killmail(&1, ttl))
    
    # Update system kill list
    update_system_kill_list(system_id, killmails, ttl)
    
    :ok
  end
  
  @doc """
  Stores or updates the kill count for a system.
  """
  @spec store_kill_count(integer(), non_neg_integer()) :: :ok
  def store_kill_count(system_id, count) do
    key = "kill_count:#{system_id}"
    ttl = Config.kill_count_ttl()
    
    Cachex.put(@cache_name, key, count, ttl: ttl)
    :ok
  end
  
  @doc """
  Updates the kill count by adding to the existing count.
  """
  @spec update_kill_count(integer(), non_neg_integer(), pos_integer()) :: :ok
  def update_kill_count(system_id, additional_kills, ttl) do
    key = "kill_count:#{system_id}"
    
    case Cachex.get(@cache_name, key) do
      {:ok, nil} ->
        Cachex.put(@cache_name, key, additional_kills, ttl: ttl)
      {:ok, current_count} ->
        Cachex.put(@cache_name, key, current_count + additional_kills, ttl: ttl)
      {:error, _} ->
        Cachex.put(@cache_name, key, additional_kills, ttl: ttl)
    end
    
    :ok
  end
  
  @doc """
  Retrieves the kill count for a system.
  """
  @spec get_kill_count(integer()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def get_kill_count(system_id) do
    key = "kill_count:#{system_id}"
    
    case Cachex.get(@cache_name, key) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, count} -> {:ok, count}
      {:error, _} -> {:error, :not_found}
    end
  end
  
  @doc """
  Retrieves a specific killmail by ID.
  """
  @spec get_killmail(integer()) :: {:ok, map()} | {:error, :not_found}
  def get_killmail(killmail_id) do
    key = "killmail:#{killmail_id}"
    
    case Cachex.get(@cache_name, key) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, killmail} -> {:ok, killmail}
      {:error, _} -> {:error, :not_found}
    end
  end
  
  @doc """
  Retrieves all kills for a specific system.
  """
  @spec get_system_kills(integer()) :: {:ok, list(map())} | {:error, :not_found}
  def get_system_kills(system_id) do
    key = "system_kills:#{system_id}"
    
    case Cachex.get(@cache_name, key) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, kills} -> {:ok, kills}
      {:error, _} -> {:error, :not_found}
    end
  end
  
  # Private functions
  
  defp store_individual_killmail(killmail, ttl) do
    key = "killmail:#{killmail.killmail_id}"
    Cachex.put(@cache_name, key, killmail, ttl: ttl)
  end
  
  defp update_system_kill_list(system_id, new_killmails, ttl) do
    key = "system_kills:#{system_id}"
    
    existing_kills = case Cachex.get(@cache_name, key) do
      {:ok, nil} -> []
      {:ok, kills} -> kills
      {:error, _} -> []
    end
    
    # Merge new kills with existing, avoiding duplicates
    all_kills = merge_killmails(existing_kills, new_killmails)
    
    Cachex.put(@cache_name, key, all_kills, ttl: ttl)
  end
  
  defp merge_killmails(existing, new) do
    existing_ids = MapSet.new(existing, & &1.killmail_id)
    
    new_unique = Enum.reject(new, fn kill ->
      MapSet.member?(existing_ids, kill.killmail_id)
    end)
    
    # Keep most recent kills first
    new_unique ++ existing
  end
end