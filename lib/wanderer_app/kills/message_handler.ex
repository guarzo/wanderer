defmodule WandererApp.Kills.MessageHandler do
  @moduledoc """
  Handles killmail message processing and broadcasting.
  """
  
  require Logger
  
  alias WandererApp.Kills.{Config, DataAdapter, Storage}
  alias WandererApp.Kills.Subscription.MapIntegration
  
  @pubsub WandererApp.PubSub
  
  @spec process_killmail_update(map()) :: :ok
  def process_killmail_update(%{"system_id" => system_id, "killmails" => killmails} = payload) do
    valid_killmails = killmails
                     |> Enum.filter(&is_map/1)
                     |> Enum.map(&DataAdapter.adapt_kill_data/1)
                     |> Enum.filter(&match?({:ok, _}, &1))
                     |> Enum.map(&elem(&1, 1))
    
    if valid_killmails != [] do
      ttl = Config.killmail_ttl()
      Storage.store_killmails(system_id, valid_killmails, ttl)
      Storage.update_kill_count(system_id, length(valid_killmails), ttl)
      broadcast_killmails(system_id, valid_killmails, payload)
    end
    
    :ok
  end
  
  def process_killmail_update(payload) do
    Logger.warning("[KillsClient] Invalid killmail payload: #{inspect(payload)}")
    :ok
  end
  
  @spec process_kill_count_update(map()) :: :ok
  def process_kill_count_update(%{"system_id" => system_id, "count" => count} = payload) do
    Storage.store_kill_count(system_id, count)
    broadcast_kill_count(system_id, payload)
    :ok
  end
  
  def process_kill_count_update(payload) do
    Logger.warning("[KillsClient] Invalid kill count payload: #{inspect(payload)}")
    :ok
  end
  
  defp broadcast_kill_count(system_id, payload) do
    MapIntegration.broadcast_kill_to_maps(%{
      solar_system_id: system_id,
      count: payload["count"],
      type: :kill_count
    })
  end
  
  defp broadcast_killmails(system_id, killmails, payload) do
    MapIntegration.broadcast_kill_to_maps(%{
      solar_system_id: system_id,
      killmails: killmails,
      timestamp: payload["timestamp"],
      type: :killmail_update
    })
  end
  
end