defmodule WandererApp.Zkb.KillsProvider.KillsCache.CacheServer do
  @moduledoc """
  GenServer that manages the ETS tables for killmails and kill counts.
  """

  use GenServer
  require Logger

  @type killmail :: map()
  @type system_id :: non_neg_integer()
  @type kill_count :: non_neg_integer()
  @type result :: :ok | {:error, term()}
  @type state :: %{
    killmails_table: :ets.tid(),
    kill_counts_table: :ets.tid()
  }

  # Client API

  @doc """
  Start the cache server.
  """
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Store a killmail in the cache.
  """
  @spec put_killmail(killmail()) :: result()
  def put_killmail(killmail) do
    GenServer.call(__MODULE__, {:put_killmail, killmail})
  end

  @doc """
  Get a killmail from the cache by its ID.
  """
  @spec get_killmail(non_neg_integer()) :: {:ok, killmail()} | {:error, :not_found}
  def get_killmail(killmail_id) do
    GenServer.call(__MODULE__, {:get_killmail, killmail_id})
  end

  @doc """
  Get all killmails for a system from the cache.
  """
  @spec get_killmails_for_system(system_id()) :: [killmail()]
  def get_killmails_for_system(system_id) do
    GenServer.call(__MODULE__, {:get_killmails_for_system, system_id})
  end

  @doc """
  Get the kill count for a system from the cache.
  """
  @spec get_kill_count(system_id()) :: kill_count()
  def get_kill_count(system_id) do
    GenServer.call(__MODULE__, {:get_kill_count, system_id})
  end

  @doc """
  Increment the kill count for a system.
  """
  @spec increment_kill_count(system_id()) :: result()
  def increment_kill_count(system_id) do
    GenServer.call(__MODULE__, {:increment_kill_count, system_id})
  end

  @doc """
  Clear all killmails and kill counts from the cache.
  """
  @spec clear() :: result()
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # Server Callbacks

  @impl true
  @spec init(map()) :: {:ok, state()}
  def init(_) do
    killmails_table = :ets.new(:killmails, [:set, :protected, :named_table])
    kill_counts_table = :ets.new(:kill_counts, [:set, :protected, :named_table])

    {:ok, %{
      killmails_table: killmails_table,
      kill_counts_table: kill_counts_table
    }}
  end

  @impl true
  @spec handle_call({:put_killmail, killmail()}, GenServer.from(), state()) :: {:reply, result(), state()}
  def handle_call({:put_killmail, killmail}, _from, state) do
    result = :ets.insert(state.killmails_table, {killmail["killmail_id"], killmail})
    {:reply, result, state}
  end

  @impl true
  @spec handle_call({:get_killmail, non_neg_integer()}, GenServer.from(), state()) :: {:reply, {:ok, killmail()} | {:error, :not_found}, state()}
  def handle_call({:get_killmail, killmail_id}, _from, state) do
    case :ets.lookup(state.killmails_table, killmail_id) do
      [{^killmail_id, killmail}] -> {:reply, {:ok, killmail}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  @spec handle_call({:get_killmails_for_system, system_id()}, GenServer.from(), state()) :: {:reply, [killmail()], state()}
  def handle_call({:get_killmails_for_system, system_id}, _from, state) do
    killmails = :ets.match_object(state.killmails_table, {:"$1", %{"solar_system_id" => system_id}})
    {:reply, Enum.map(killmails, fn {_id, killmail} -> killmail end), state}
  end

  @impl true
  @spec handle_call({:get_kill_count, system_id()}, GenServer.from(), state()) :: {:reply, kill_count(), state()}
  def handle_call({:get_kill_count, system_id}, _from, state) do
    case :ets.lookup(state.kill_counts_table, system_id) do
      [{^system_id, count}] -> {:reply, count, state}
      [] -> {:reply, 0, state}
    end
  end

  @impl true
  @spec handle_call({:increment_kill_count, system_id()}, GenServer.from(), state()) :: {:reply, result(), state()}
  def handle_call({:increment_kill_count, system_id}, _from, state) do
    result = :ets.update_counter(state.kill_counts_table, system_id, {2, 1}, {system_id, 0})
    {:reply, {:ok, result}, state}
  end

  @impl true
  @spec handle_call(:clear, GenServer.from(), state()) :: {:reply, result(), state()}
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.killmails_table)
    :ets.delete_all_objects(state.kill_counts_table)
    {:reply, :ok, state}
  end
end
