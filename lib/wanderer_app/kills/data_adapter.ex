defmodule WandererApp.Kills.DataAdapter do
  @moduledoc """
  Adapts WandererKills service data format to match existing frontend expectations.

  The WandererKills service returns structured JSON with nested objects,
  but the frontend expects a flat structure with prefixed field names.
  """

  require Logger

  @doc """
  Converts a kill from WandererKills service format to the flat format expected by the frontend.

  ## Service Format (input):
  ```json
  {
    "killmail_id": 123456789,
    "kill_time": "2024-01-15T14:30:00Z",
    "solar_system_id": 30000142,
    "victim": {
      "character_id": 987654321,
      "corporation_id": 123456789,
      "alliance_id": 456789123,
      "ship_type_id": 671,
      "damage_taken": 2847
    },
    "attackers": [...],
    "zkb": {...}
  }
  ```

  ## Frontend Format (output):
  ```json
  {
    "killmail_id": 123456789,
    "victim_char_id": 987654321,
    "victim_corp_id": 123456789,
    ...
  }
  ```
  """
  def adapt_kill_data(service_kill) when is_map(service_kill) do
    victim = Map.get(service_kill, "victim", %{})
    attackers = Map.get(service_kill, "attackers", [])
    zkb = Map.get(service_kill, "zkb", %{})
    final_blow_attacker = find_final_blow_attacker(attackers)

    %{
      # Core kill data
      "killmail_id" => service_kill["killmail_id"],
      "kill_time" => service_kill["kill_time"],
      "solar_system_id" => service_kill["solar_system_id"],
      "zkb" => zkb,

      # Victim information - flatten victim object
      "victim_char_id" => victim["character_id"],
      "victim_char_name" => get_character_name(victim),
      "victim_corp_id" => victim["corporation_id"],
      "victim_corp_ticker" => get_corp_ticker(victim),
      "victim_corp_name" => get_corp_name(victim),
      "victim_alliance_id" => victim["alliance_id"],
      "victim_alliance_ticker" => get_alliance_ticker(victim),
      "victim_alliance_name" => get_alliance_name(victim),
      "victim_ship_type_id" => victim["ship_type_id"],
      "victim_ship_name" => get_ship_name(victim),

      # Final blow attacker information - flatten final blow attacker
      "final_blow_char_id" => final_blow_attacker["character_id"],
      "final_blow_char_name" => get_character_name(final_blow_attacker),
      "final_blow_corp_id" => final_blow_attacker["corporation_id"],
      "final_blow_corp_ticker" => get_corp_ticker(final_blow_attacker),
      "final_blow_corp_name" => get_corp_name(final_blow_attacker),
      "final_blow_alliance_id" => final_blow_attacker["alliance_id"],
      "final_blow_alliance_ticker" => get_alliance_ticker(final_blow_attacker),
      "final_blow_alliance_name" => get_alliance_name(final_blow_attacker),
      "final_blow_ship_type_id" => final_blow_attacker["ship_type_id"],
      "final_blow_ship_name" => get_ship_name(final_blow_attacker),

      # Kill statistics
      "attacker_count" => length(attackers),
      "total_value" => zkb["total_value"] || zkb["totalValue"] || 0,
      "npc" => zkb["npc"] || false
    }
  end

  def adapt_kill_data(invalid_data) do
    Logger.warning("[DataAdapter] Invalid kill data format: #{inspect(invalid_data)}")
    %{}
  end

  @doc """
  Adapts a list of kills from service format to frontend format.
  """
  def adapt_kills_list(kills) when is_list(kills) do
    Enum.map(kills, &adapt_kill_data/1)
  end

  def adapt_kills_list(invalid_data) do
    Logger.warning("[DataAdapter] Expected list of kills, got: #{inspect(invalid_data)}")
    []
  end

  @doc """
  Adapts a systems kills map from service format to frontend format.
  Returns a map of %{system_id => [adapted_kills]}
  """
  def adapt_systems_kills(systems_kills) when is_map(systems_kills) do
    Enum.into(systems_kills, %{}, fn {system_id, kills} ->
      adapted_kills = adapt_kills_list(kills)
      {system_id, adapted_kills}
    end)
  end

  def adapt_systems_kills(invalid_data) do
    Logger.warning("[DataAdapter] Expected map of systems kills, got: #{inspect(invalid_data)}")
    %{}
  end

  # Private helper functions

  defp find_final_blow_attacker(attackers) when is_list(attackers) do
    Enum.find(attackers, %{}, fn attacker ->
      attacker["final_blow"] == true
    end)
  end

  defp find_final_blow_attacker(_), do: %{}

  # Character name extraction - the service should provide enriched data
  defp get_character_name(%{"name" => name}) when is_binary(name), do: name
  defp get_character_name(%{"character_name" => name}) when is_binary(name), do: name
  defp get_character_name(_), do: nil

  # Corporation info extraction
  defp get_corp_ticker(%{"corporation_ticker" => ticker}) when is_binary(ticker), do: ticker
  defp get_corp_ticker(%{"corp_ticker" => ticker}) when is_binary(ticker), do: ticker
  defp get_corp_ticker(_), do: nil

  defp get_corp_name(%{"corporation_name" => name}) when is_binary(name), do: name
  defp get_corp_name(%{"corp_name" => name}) when is_binary(name), do: name
  defp get_corp_name(_), do: nil

  # Alliance info extraction
  defp get_alliance_ticker(%{"alliance_ticker" => ticker}) when is_binary(ticker), do: ticker
  defp get_alliance_ticker(_), do: nil

  defp get_alliance_name(%{"alliance_name" => name}) when is_binary(name), do: name
  defp get_alliance_name(_), do: nil

  # Ship info extraction
  defp get_ship_name(%{"ship_name" => name}) when is_binary(name), do: name
  defp get_ship_name(%{"ship_type_name" => name}) when is_binary(name), do: name
  defp get_ship_name(_), do: nil
end
