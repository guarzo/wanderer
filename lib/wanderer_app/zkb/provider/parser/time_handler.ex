defmodule WandererApp.Zkb.Provider.Parser.TimeHandler do
  @moduledoc """
  Handles time parsing and validation for killmails.
  Manages time-related operations and cutoff checks.
  """

  require Logger

  @type killmail :: map()
  @type cutoff_dt :: DateTime.t()
  @type time_result :: {:ok, DateTime.t()} | {:error, term()}
  @type validate_result :: {:ok, {killmail(), DateTime.t()}} | :older | :skip

  @doc """
  Gets the killmail time from any supported format.
  Returns {:ok, DateTime.t()} or {:error, reason}.
  """
  @spec get_killmail_time(killmail()) :: time_result()
  def get_killmail_time(%{"killmail_time" => time}) when is_binary(time) do
    parse_time(time)
  end
  def get_killmail_time(%{"killTime" => time}) when is_binary(time) do
    parse_time(time)
  end
  def get_killmail_time(%{"zkb" => %{"time" => time}}) when is_binary(time) do
    parse_time(time)
  end
  def get_killmail_time(_), do: {:error, :missing_time}

  @doc """
  Validates a killmail's time against a cutoff time.
  Returns:
    - `{:ok, {km, dt}}` if valid and newer than cutoff
    - `:older` if older than cutoff
    - `:skip` if invalid time
  """
  @spec validate_killmail_time(killmail(), cutoff_dt()) :: validate_result()
  def validate_killmail_time(km, cutoff_dt) do
    case get_killmail_time(km) do
      {:ok, km_dt} ->
        if older_than_cutoff?(km_dt, cutoff_dt) do
          :older
        else
          # Preserve all fields from the original killmail
          {:ok, {km, km_dt}}
        end

      {:error, reason} ->
        Logger.warning("[TimeHandler] Failed to parse time for killmail #{km["killmail_id"]}: #{inspect(reason)}")
        :skip
    end
  end

  @spec parse_time(String.t()) :: time_result()
  def parse_time(time_str) when is_binary(time_str) do
    # First try standard ISO-8601 parsing
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _offset} ->
        # Convert to UTC if it's not already
        {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}

      {:error, :invalid_format} ->
        # Try parsing without timezone (assume UTC)
        case NaiveDateTime.from_iso8601(time_str) do
          {:ok, ndt} ->
            # Convert naive datetime to UTC
            {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          error ->
            log_time_parse_error(time_str, error)
            error
        end

      error ->
        log_time_parse_error(time_str, error)
        error
    end
  end

  def parse_time(_), do: {:error, :invalid_time_format}

  @spec log_time_parse_error(String.t(), term()) :: :ok
  defp log_time_parse_error(time_str, error) do
    Logger.warning(fn -> "[Parser] Failed to parse time: #{time_str}, error: #{inspect(error)}" end)
  end

  @spec older_than_cutoff?(DateTime.t(), DateTime.t()) :: boolean()
  def older_than_cutoff?(km_dt, cutoff_dt) do
    # A kill is older than cutoff if it's before the cutoff time
    # DateTime.compare returns :lt if km_dt is before cutoff_dt
    # We want to return true if the kill is older than cutoff
    case DateTime.compare(km_dt, cutoff_dt) do
      :lt -> true  # Kill is before cutoff
      :eq -> false # Kill is exactly at cutoff
      :gt -> false # Kill is after cutoff
    end
  end
end
