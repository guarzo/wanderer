defmodule WandererApp.Zkb.Key do
  @moduledoc """
  Centralizes cache key generation and time utilities for the ZKB module.
  Provides consistent key naming and time-related functions used across the ZKB system.
  """

  @doc """
  Generates a cache key for a killmail.

  ## Parameters
    - killmail_id: The ID of the killmail

  ## Returns
    A string key in the format "zkb_killmail_<killmail_id>"
  """
  @spec killmail_key(killmail_id :: integer()) :: String.t()
  def killmail_key(killmail_id) when is_integer(killmail_id) do
    "zkb_killmail_#{killmail_id}"
  end

  @doc """
  Generates a cache key for a system's kill count.

  ## Parameters
    - system_id: The ID of the solar system

  ## Returns
    A string key in the format "zkb_kills_<system_id>"
  """
  @spec system_kills_key(system_id :: integer()) :: String.t()
  def system_kills_key(system_id) when is_integer(system_id) do
    "zkb_kills_#{system_id}"
  end

  @doc """
  Generates a cache key for a system's killmail ID list.

  ## Parameters
    - system_id: The ID of the solar system

  ## Returns
    A string key in the format "zkb_kills_list_<system_id>"
  """
  @spec system_kills_list_key(system_id :: integer()) :: String.t()
  def system_kills_list_key(system_id) when is_integer(system_id) do
    "zkb_kills_list_#{system_id}"
  end

  @doc """
  Generates a cache key for a system's fetched timestamp.

  ## Parameters
    - system_id: The ID of the solar system

  ## Returns
    A string key in the format "zkb_system_fetched_at_<system_id>"
  """
  @spec fetched_timestamp_key(system_id :: integer()) :: String.t()
  def fetched_timestamp_key(system_id) when is_integer(system_id) do
    "zkb_system_fetched_at_#{system_id}"
  end

  @doc """
  Returns the current time in milliseconds since Unix epoch.

  ## Returns
    The current time as an integer number of milliseconds
  """
  @spec current_time_ms() :: integer()
  def current_time_ms do
    DateTime.utc_now() |> DateTime.to_unix(:millisecond)
  end
end
