defmodule WandererApp.Zkb.Supervisor do
  @moduledoc """
  Supervisor for the zKillboard module.
  """

  use Supervisor

  @type child_spec :: Supervisor.child_spec()
  @type children :: [child_spec()]

  @doc """
  Start the supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec init(keyword()) :: {:ok, {Supervisor.strategy(), children()}}
  def init(_opts) do
    children = [
      # Dynamic supervisor for runtime-spawned workers
      {DynamicSupervisor, strategy: :one_for_one, name: WandererApp.Zkb.DynamicSupervisor},

      # Static workers
      WandererApp.Zkb.KillsProvider.RedisQ,
      WandererApp.Zkb.KillsPreloader
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
