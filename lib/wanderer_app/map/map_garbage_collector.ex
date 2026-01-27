defmodule WandererApp.Map.GarbageCollector do
  @moduledoc """
  Manager map subscription plans
  """

  require Logger
  require Ash.Query

  @logger Application.compile_env(:wanderer_app, :logger)
  @one_week_seconds 7 * 24 * 60 * 60
  @two_weeks_seconds 14 * 24 * 60 * 60

  def cleanup_chain_passages() do
    Logger.info("Start cleanup old map chain passages...")

    # Use return_errors? to handle stale records gracefully
    result =
      WandererApp.Api.MapChainPassages
      |> Ash.Query.filter(updated_at: [less_than: get_cutoff_time(@one_week_seconds)])
      |> Ash.bulk_destroy(:destroy, %{}, batch_size: 100, return_errors?: true)

    case result do
      {:ok, %{errors: []}} ->
        @logger.info(fn -> "All map chain passages processed successfully" end)

      {:ok, %{errors: errors}} when is_list(errors) ->
        non_stale_errors =
          Enum.reject(errors, fn
            {_, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} -> true
            _ -> false
          end)

        if non_stale_errors != [] do
          Logger.warning("Some chain passages failed to delete: #{inspect(non_stale_errors)}")
        end

        @logger.info(fn ->
          "Map chain passages processed with #{length(errors)} race conditions"
        end)

      {:error, error} ->
        Logger.error("Failed to cleanup chain passages: #{inspect(error)}")
    end

    :ok
  end

  def cleanup_system_signatures() do
    Logger.info("Start cleanup old map system signatures...")

    # Use return_errors? to handle stale records gracefully (race conditions with on-demand cleanup)
    result =
      WandererApp.Api.MapSystemSignature
      |> Ash.Query.filter(updated_at: [less_than: get_cutoff_time(@two_weeks_seconds)])
      |> Ash.bulk_destroy(:destroy, %{}, batch_size: 100, return_errors?: true)

    case result do
      {:ok, %{errors: []}} ->
        @logger.info(fn -> "All map system signatures processed successfully" end)

      {:ok, %{errors: errors}} when is_list(errors) ->
        # Filter out stale record errors (expected race condition)
        non_stale_errors =
          Enum.reject(errors, fn
            {_, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} -> true
            _ -> false
          end)

        if non_stale_errors != [] do
          Logger.warning("Some signatures failed to delete: #{inspect(non_stale_errors)}")
        end

        @logger.info(fn ->
          "Map system signatures processed with #{length(errors)} race conditions"
        end)

      {:error, error} ->
        Logger.error("Failed to cleanup signatures: #{inspect(error)}")
    end

    :ok
  end

  defp get_cutoff_time(seconds), do: DateTime.utc_now() |> DateTime.add(-seconds, :second)
end
