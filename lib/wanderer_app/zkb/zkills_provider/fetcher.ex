defmodule WandererApp.Zkb.KillsProvider.Fetcher do
  @moduledoc """
  Fetches killmail data from zKillboard API.
  """

  require Logger
  alias WandererApp.Zkb.HttpClient
  alias WandererApp.Zkb.KillsProvider.{KillsCache, Parser}

  @type system_id :: integer()
  @type state :: map()
  @type opts :: keyword()

  @doc """
  Fetches kills for a given system ID.
  Returns {:ok, kills, state} or {:error, reason, state}.
  """
  @spec fetch_kills_for_system(system_id(), integer(), state(), opts()) ::
          {:ok, list(map()), state()} | {:error, term(), state()}
  def fetch_kills_for_system(system_id, since_hours, state, opts \\ []) do
    _limit = Keyword.get(opts, :limit, 50)
    force = Keyword.get(opts, :force, false)

    if force || !KillsCache.recently_fetched?(system_id) do
      case HttpClient.fetch_kills(system_id) do
        {:ok, kills} ->
          # Calculate cutoff time based on since_hours
          cutoff_dt = DateTime.utc_now() |> DateTime.add(-since_hours * 3600, :second)
          Logger.info(fn -> "[Fetcher] Processing #{length(kills)} kills for system=#{system_id} with cutoff=#{DateTime.to_iso8601(cutoff_dt)}" end)

          # Parse and store each kill in the cache
          parsed_kills = Enum.map(kills, fn kill ->
            case Parser.parse_and_store_killmail(kill) do
              :ok ->
                Logger.info(fn -> "[Fetcher] Successfully processed kill #{kill["killmail_id"]}" end)
                kill
              :skip ->
                Logger.info(fn -> "[Fetcher] Skipped kill #{kill["killmail_id"]}" end)
                nil
              :older ->
                Logger.info(fn -> "[Fetcher] Kill #{kill["killmail_id"]} is older than cutoff" end)
                nil
            end
          end) |> Enum.reject(&is_nil/1)

          Logger.info(fn -> "[Fetcher] Processed #{length(parsed_kills)} valid kills out of #{length(kills)} total for system=#{system_id}" end)
          KillsCache.put_full_fetched_timestamp(system_id)
          {:ok, parsed_kills, state}

        {:error, reason} ->
          Logger.warning("[Zkb.Fetcher] Failed to fetch kills for system=#{system_id}: #{inspect(reason)}")
          {:error, reason, state}
      end
    else
      {:ok, KillsCache.fetch_cached_kills(system_id), state}
    end
  end

  @doc """
  Fetches kills for multiple systems in parallel.
  Returns a map of system_id => {:ok, kills, state} or {:error, reason, state}.
  """
  @spec fetch_kills_for_systems([system_id()], integer(), state(), opts()) ::
          %{system_id() => {:ok, list(map()), state()} | {:error, term(), state()}}
  def fetch_kills_for_systems(system_ids, since_hours, state, opts \\ []) do
    system_ids
    |> Enum.map(fn system_id ->
      Task.async(fn ->
        {system_id, fetch_kills_for_system(system_id, since_hours, state, opts)}
      end)
    end)
    |> Enum.map(&Task.await(&1, 30_000))
    |> Map.new()
  end

  @doc """
  Fetches and parses a full killmail from ESI.
  Returns {:ok, killmail} or {:error, reason}.
  """
  @spec fetch_full_killmail(integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_full_killmail(kill_id, kill_hash) do
    case WandererApp.Esi.ApiClient.get_killmail(kill_id, kill_hash) do
      {:ok, killmail} -> {:ok, killmail}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses a partial killmail from the list endpoint.
  Returns {:ok, killmail} or {:error, reason}.
  """
  @spec parse_partial(map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def parse_partial(%{"killmail_id" => kill_id, "zkb" => %{"hash" => kill_hash}} = partial, cutoff_dt) do
    case fetch_full_killmail(kill_id, kill_hash) do
      {:ok, full_kill} ->
        case Parser.parse_full_and_store(full_kill, partial, cutoff_dt) do
          {:ok, killmail} -> {:ok, killmail}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
