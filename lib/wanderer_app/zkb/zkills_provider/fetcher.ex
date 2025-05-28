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
    limit = Keyword.get(opts, :limit, 5)  # Default to 5 for quick passes
    force = Keyword.get(opts, :force, false)

    if force || !KillsCache.recently_fetched?(system_id) do

      case HttpClient.fetch_kills(system_id) do
        {:ok, kills} ->

          # Calculate cutoff time based on since_hours, ensuring UTC
          cutoff_dt = DateTime.utc_now()
            |> DateTime.shift_zone!("Etc/UTC")
            |> DateTime.add(-since_hours * 3600, :second)

          # Take only the first 'limit' kills to process
          kills_to_process = Enum.take(kills, limit)

          # Parse and store each kill in the cache, filtering by cutoff time
          # Stop when we find a kill older than cutoff
          {parsed_kills, _} = Enum.reduce_while(kills_to_process, {[], false}, fn kill, {acc, stop} ->
            if stop do
              {:halt, {acc, true}}
            else
              case parse_partial(kill, cutoff_dt) do
                {:ok, parsed_kill} ->
                  {:cont, {[parsed_kill | acc], false}}
                {:error, :skip} ->
                  {:cont, {acc, false}}
                {:error, :older} ->
                  {:halt, {acc, true}}
                {:error, reason} ->
                  Logger.warning(fn -> "[Zkb.Fetcher] Failed to parse kill #{kill["killmail_id"]} for system=#{system_id}: #{inspect(reason)}" end)
                  {:cont, {acc, false}}
              end
            end
          end)

          parsed_kills = Enum.reverse(parsed_kills)

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
    case WandererApp.Esi.ApiClient.get_killmail(kill_id, kill_hash) do
      {:ok, full_kill} ->
        case WandererApp.Zkb.KillsProvider.Parser.parse_full_and_store(full_kill, partial, cutoff_dt) do
          :ok -> {:ok, full_kill}
          :skip -> {:error, :skip}
          :older -> {:error, :older}
          error -> {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parse_partial(_, _), do: {:error, :invalid_killmail}
end
