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
      %Ash.BulkResult{status: :error, errors: errors} ->
        Logger.error("Failed to cleanup chain passages: #{inspect(errors)}")

      %Ash.BulkResult{errors: errors} ->
        report_bulk_errors(errors, "chain passages")
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
      %Ash.BulkResult{status: :error, errors: errors} ->
        Logger.error("Failed to cleanup signatures: #{inspect(errors)}")

      %Ash.BulkResult{errors: errors} ->
        report_bulk_errors(errors, "map system signatures")
    end

    :ok
  end

  # `Ash.bulk_destroy/4` returns a bare `%Ash.BulkResult{}`, never an `{:ok, _}`
  # / `{:error, _}` tuple, so the previous tuple-matching `case` raised
  # CaseClauseError on every run. `errors` is a list of `Ash.Error` structs (or
  # nil when `return_errors?` is off), not `{record, error}` tuples.
  defp report_bulk_errors(errors, label) when errors in [nil, []] do
    @logger.info(fn -> "All #{label} processed successfully" end)
  end

  defp report_bulk_errors(errors, label) do
    non_stale_errors =
      Enum.reject(errors, fn
        %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]} -> true
        %Ash.Error.Changes.StaleRecord{} -> true
        _ -> false
      end)

    if non_stale_errors != [] do
      Logger.warning("Some #{label} failed to delete: #{inspect(non_stale_errors)}")
    end

    # Count the stale errors, not every error: `length(errors)` also counted the
    # genuine failures logged above and then labelled them race conditions.
    stale_count = length(errors) - length(non_stale_errors)

    @logger.info(fn -> "#{label} processed with #{stale_count} race conditions" end)
  end

  defp get_cutoff_time(seconds), do: DateTime.utc_now() |> DateTime.add(-seconds, :second)
end
