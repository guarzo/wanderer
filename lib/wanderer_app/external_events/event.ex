defmodule WandererApp.ExternalEvents.Event do
  @moduledoc """
  Event structure for external event delivery.
  
  This represents an event that can be delivered to external clients
  via WebSocket connections, webhooks, or SSE streams.
  """
  
  @enforce_keys [:id, :map_id, :type, :data]
  defstruct [:id, :map_id, :type, :data, :timestamp]
  
  @type t :: %__MODULE__{
    id: String.t(),
    map_id: String.t(),
    type: String.t(),
    data: map(),
    timestamp: DateTime.t()
  }
  
  @doc """
  Creates a new external event.
  """
  @spec new(String.t(), String.t(), map()) :: t()
  def new(map_id, type, data) do
    %__MODULE__{
      id: Ulid.generate(),
      map_id: map_id,
      type: type,
      data: data,
      timestamp: DateTime.utc_now()
    }
  end
  
  @doc """
  Converts an event to JSON format for transmission.
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = event) do
    Jason.encode!(%{
      id: event.id,
      map_id: event.map_id,
      type: event.type,
      data: event.data,
      timestamp: DateTime.to_iso8601(event.timestamp)
    })
  end
  
  @doc """
  Creates an event from a JSON string.
  """
  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{
        "id" => id,
        "map_id" => map_id,
        "type" => type,
        "data" => data,
        "timestamp" => timestamp_str
      }} ->
        case DateTime.from_iso8601(timestamp_str) do
          {:ok, timestamp, _} ->
            {:ok, %__MODULE__{
              id: id,
              map_id: map_id,
              type: type,
              data: data,
              timestamp: timestamp
            }}
          
          {:error, reason} ->
            {:error, {:invalid_timestamp, reason}}
        end
      
      {:ok, _} ->
        {:error, :invalid_event_format}
      
      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end
end