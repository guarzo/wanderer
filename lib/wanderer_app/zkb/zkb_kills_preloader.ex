defmodule WandererApp.Zkb.KillsPreloader do
  @moduledoc """
  Preloads kills from zKillboard for the last 24 hours, for all visible systems in all maps.
  Leverages concurrency plus ExRated for rate-limiting,
  and delegates actual request logic to KillsProvider.fetch_kills_for_system/3.

  On completion, logs total calls_count and total elapsed time in ms.
  """

  use GenServer
  require Logger

  @default_max_concurrency 10

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    state = %{
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      calls_count: 0
    }

    send(self(), :preload_kills)
    {:ok, state}
  end

  def handle_info(:preload_kills, state) do
    start_time = System.monotonic_time()
    new_state = do_preload_all_maps(state)

    end_time = System.monotonic_time()
    elapsed_ms = System.convert_time_unit(end_time - start_time, :native, :millisecond)

    Logger.info("""
    [KillsPreloader] Finished kills preload => total calls=#{new_state.calls_count}, elapsed=#{elapsed_ms} ms
    """)

    {:noreply, new_state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp do_preload_all_maps(state) do
    case WandererApp.Api.Map.available() do
      {:ok, maps} ->
        Enum.reduce(maps, state, fn map, acc_state ->
          Logger.debug("[KillsPreloader] Preloading kills for map=#{map.name} (id=#{map.id})")

          case WandererApp.MapSystemRepo.get_visible_by_map(map.id) do
            {:ok, systems} ->
              {final_acc_state, _results} =
                systems
                |> Task.async_stream(
                  fn system ->
                    preload_system(system.solar_system_id, acc_state)
                  end,
                  max_concurrency: acc_state.max_concurrency,
                  timeout: :timer.minutes(5)
                )
                |> Enum.reduce({acc_state, 0}, fn
                  {:ok, updated_state}, {acc_s, idx} ->
                    merged_state = merge_calls_count(acc_s, updated_state)
                    {merged_state, idx + 1}

                  {:error, reason}, {acc_s, idx} ->
                    Logger.error("[KillsPreloader] Task failed => #{inspect(reason)}")
                    {acc_s, idx + 1}
                end)

              final_acc_state

            {:error, reason} ->
              Logger.error("[KillsPreloader] Could not get systems for map=#{map.id} => #{inspect(reason)}")
              acc_state
          end
        end)

      {:error, reason} ->
        Logger.error("[KillsPreloader] Could not load maps => #{inspect(reason)}")
        state
    end
  end

  defp merge_calls_count(s1, s2) do
    %{s1 | calls_count: s1.calls_count + s2.calls_count}
  end

  defp preload_system(system_id, state) do
    case WandererApp.Zkb.KillsProvider.fetch_kills_for_system(system_id, 24, state) do
      {:ok, _kills, new_state} ->
        new_state

      {:error, reason, new_state} ->
        Logger.warning("[Preloader] fetch_kills_for_system error => #{inspect(reason)}")
        new_state
    end
  end
end
