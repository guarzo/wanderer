defmodule WandererApp.Character.LocationConfirmations do
  @moduledoc "Ephemeral confirmations from this application's scheduled location requests. Never seeded from persisted locations."
  use GenServer

  @freshness_us 15_000_000
  # Two location attempts can each spend 15s in the pool and 60s receiving,
  # plus token refresh/dispatch overhead. This budget does not extend entry freshness.
  @request_ttl_us 180_000_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def fingerprint(token) when is_binary(token) and token != "",
    do: :crypto.hash(:sha256, ["wanderer:location-access-token:v1", <<0>>, token])

  def fingerprint(_), do: nil

  def begin_request(character_id, access_token),
    do: call({:begin, character_id, fingerprint(access_token)})

  def confirm({pid, character_id, order, fingerprint}, system_id, observed_at) do
    if Process.whereis(__MODULE__) == pid do
      call({:confirm, character_id, order, fingerprint, system_id, observed_at})
    else
      :discarded
    end
  end

  def confirm(_, _, _), do: :discarded

  def snapshot(now \\ DateTime.utc_now()), do: call({:snapshot, now})

  def fresh?(%DateTime{} = observed_at, %DateTime{} = now) do
    age = DateTime.diff(now, observed_at, :microsecond)
    age >= 0 and age < @freshness_us
  end

  def fresh?(_, _), do: false

  defp call(message) do
    GenServer.call(__MODULE__, message, 1_000)
  catch
    :exit, _ -> {:error, :service_unavailable}
  end

  @impl true
  def init(_) do
    schedule_expiry()
    {:ok, %{requests: %{}, entries: %{}}}
  end

  @impl true
  def handle_call({:begin, id, fingerprint}, _from, state) do
    order = System.unique_integer([:monotonic, :positive])
    request = %{order: order, fingerprint: fingerprint, started_at: DateTime.utc_now()}
    state = put_in(state, [:requests, id], request)
    {:reply, {:ok, {self(), id, order, fingerprint}}, state}
  end

  def handle_call({:confirm, id, order, fingerprint, system_id, observed_at}, _from, state) do
    request = state.requests[id]

    if request != nil and request.order == order and request.fingerprint == fingerprint and
         fingerprint != nil and is_integer(system_id) and system_id > 0 and
         fresh?(observed_at, DateTime.utc_now()) do
      entry = %{
        solar_system_id: system_id,
        observed_at: observed_at,
        order: order,
        fingerprint: fingerprint
      }

      {:reply, :ok, put_in(state, [:entries, id], entry)}
    else
      {:reply, :discarded, state}
    end
  end

  def handle_call({:snapshot, now}, _from, state) do
    state = prune(state, now)
    {:reply, {:ok, %{lifetime: self(), entries: state.entries}}, state}
  end

  @impl true
  def handle_info(:expire, state) do
    schedule_expiry()
    {:noreply, prune(state, DateTime.utc_now())}
  end

  defp prune(state, now) do
    %{
      requests:
        Map.filter(state.requests, fn {_, request} ->
          age = DateTime.diff(now, request.started_at, :microsecond)
          age >= 0 and age < @request_ttl_us
        end),
      entries: Map.filter(state.entries, fn {_, entry} -> fresh?(entry.observed_at, now) end)
    }
  end

  defp schedule_expiry, do: Process.send_after(self(), :expire, 1_000)
end
