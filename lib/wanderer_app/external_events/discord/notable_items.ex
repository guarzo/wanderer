defmodule WandererApp.ExternalEvents.Discord.NotableItems do
  @moduledoc """
  Resolves the notable dropped loot for a batch of killmails, for the
  **Notable Items** section of the Discord kill embed.

  ## Why this needs network calls at all

  Kills reach us over the wanderer-kills websocket, whose payload carries no
  item data — its `Killmail` JSON encoder emits victim, attackers, system, and
  zkb metadata only. So the items have to be fetched from ESI using the
  killmail hash that *is* in the payload (`zkb.hash`), exactly as
  wanderer-notifier does.

  ## Pipeline

  1. `zkb.hash` → `get_killmail/2` on ESI.
  2. Flatten `victim.items` **recursively**. A container entry carries its own
     nested `items` list; wanderer-notifier reads the list flat and therefore
     silently omits loot inside a cargo container. Flattening is a deliberate
     improvement over that behaviour, not parity with it.
  3. Keep only entries with a `quantity_dropped` key — destroyed items no
     longer exist. Note that dropped-vs-destroyed is the *presence of the key*,
     not a value.
  4. Sum quantities per `item_type_id`: the same module fitted to several slots
     appears as several entries with distinct `flag`s.
  5. Price through `WandererApp.Market.Triff`, one batched request for the whole
     candidate set.
  6. Filter above the ISK threshold, sort descending, take the limit.
  7. **Only then** resolve type names, for the handful of survivors. Names are a
     per-type ESI call, so pricing first keeps the common case at zero lookups.

  ## Fail-open

  Every failure path — missing hash, ESI error, market error, unresolvable name
  — omits that kill or that item and returns. Nothing raises and nothing
  returns `{:error, _}`. A missing section is an acceptable outcome; a missing
  kill notification is not.

  ## Test seam

  ESI is resolved through `Application.get_env(:wanderer_app, :esi_client, ...)`
  rather than called directly, mirroring `Discord.HttpClient`. Every other ESI
  caller in the app still calls `WandererApp.Esi` directly; introducing the seam
  app-wide is out of scope for this feature, so a reader will find two idioms.
  """

  require Logger

  alias WandererApp.Market.Triff

  @type item :: %{
          name: String.t(),
          quantity: pos_integer(),
          value: float(),
          abyssal?: boolean()
        }

  @doc """
  Returns `%{killmail_id => [item]}` for the kills that have notable loot.

  Kills with no notable loot are **absent from the map**, not present with an
  empty list.
  """
  @callback enrich([map()]) :: %{optional(term()) => [item()]}

  @doc "Returns the configured enricher, so the dispatcher can inject a stub."
  def impl, do: Application.get_env(:wanderer_app, :notable_items_enricher, __MODULE__)

  @spec enrich([map()]) :: %{optional(term()) => [item()]}
  def enrich([]), do: %{}

  def enrich(kills) do
    dropped =
      Enum.reduce(kills, %{}, fn kill, acc ->
        case dropped_quantities(kill) do
          {killmail_id, quantities} when map_size(quantities) > 0 ->
            Map.put(acc, killmail_id, quantities)

          _ ->
            acc
        end
      end)

    if map_size(dropped) == 0, do: %{}, else: price_and_select(dropped)
  end

  # -- step 1-4: dropped quantities per kill ---------------------------------

  defp dropped_quantities(kill) do
    with killmail_id when not is_nil(killmail_id) <- kill["killmail_id"],
         hash when is_binary(hash) <- hash(kill),
         {:ok, killmail} <- safe(fn -> esi_client().get_killmail(killmail_id, hash) end, :error) do
      {killmail_id, sum_dropped(killmail)}
    else
      _ -> :skip
    end
  end

  # Defensive: `MessageHandler.add_core_kill_data/3` retains the whole `zkb`
  # map, but the flat-format path may not, and a kill without a hash is simply
  # one we cannot enrich.
  defp hash(%{"zkb" => %{"hash" => hash}}) when is_binary(hash), do: hash
  defp hash(_kill), do: nil

  defp sum_dropped(%{"victim" => %{"items" => items}}) when is_list(items) do
    items
    |> flatten_items()
    |> Enum.reduce(%{}, &add_dropped/2)
  end

  defp sum_dropped(_killmail), do: %{}

  # A container is itself dropped loot, so it is kept alongside its contents.
  defp flatten_items(items) when is_list(items) do
    Enum.flat_map(items, fn
      %{"items" => nested} = item when is_list(nested) -> [item | flatten_items(nested)]
      item -> [item]
    end)
  end

  defp flatten_items(_items), do: []

  defp add_dropped(%{"item_type_id" => type_id, "quantity_dropped" => quantity}, acc)
       when is_integer(type_id) and is_integer(quantity) and quantity > 0,
       do: Map.update(acc, type_id, quantity, &(&1 + quantity))

  defp add_dropped(_item, acc), do: acc

  # -- step 5-7: price, select, name -----------------------------------------

  defp price_and_select(dropped) do
    type_ids = dropped |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()

    case safe(fn -> Triff.quote_types(type_ids) end, :error) do
      {:ok, prices} -> select_and_name(dropped, prices)
      _ -> %{}
    end
  end

  defp select_and_name(dropped, prices) do
    threshold = WandererApp.Env.notable_items_threshold_isk()
    limit = WandererApp.Env.notable_items_limit()

    selected =
      dropped
      |> Enum.map(fn {killmail_id, quantities} ->
        {killmail_id, select(quantities, prices, threshold, limit)}
      end)
      |> Enum.reject(fn {_killmail_id, selected} -> selected == [] end)

    names = resolve_names(selected)

    selected
    |> Enum.map(fn {killmail_id, selected} -> {killmail_id, to_items(selected, names)} end)
    |> Enum.reject(fn {_killmail_id, items} -> items == [] end)
    |> Map.new()
  end

  defp select(quantities, prices, threshold, limit) do
    quantities
    |> Enum.flat_map(fn {type_id, quantity} ->
      case Map.get(prices, type_id) do
        nil -> []
        unit_price -> [{type_id, quantity, unit_price * quantity}]
      end
    end)
    |> Enum.filter(fn {_type_id, _quantity, value} -> value > threshold end)
    |> Enum.sort_by(fn {_type_id, _quantity, value} -> value end, :desc)
    |> Enum.take(limit)
  end

  defp resolve_names(selected) do
    selected
    |> Enum.flat_map(fn {_killmail_id, items} ->
      Enum.map(items, fn {type_id, _quantity, _value} -> type_id end)
    end)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn type_id, acc ->
      case safe(fn -> esi_client().get_type_info(type_id) end, :error) do
        {:ok, %{"name" => name}} when is_binary(name) -> Map.put(acc, type_id, name)
        _ -> acc
      end
    end)
  end

  # An item whose name would not resolve is dropped: there is nothing to render.
  defp to_items(selected, names) do
    Enum.flat_map(selected, fn {type_id, quantity, value} ->
      case Map.get(names, type_id) do
        nil -> []
        name -> [%{name: name, quantity: quantity, value: value, abyssal?: abyssal?(name)}]
      end
    end)
  end

  defp abyssal?(name), do: name |> String.downcase() |> String.starts_with?("abyssal")

  # -- plumbing --------------------------------------------------------------

  defp esi_client, do: Application.get_env(:wanderer_app, :esi_client, WandererApp.Esi)

  # Fail-open belt-and-braces. The dispatcher runs this module under
  # `async_nolink` so a crash would not take it down, but an exception here
  # would still cost the whole batch its section — including the kills that had
  # already resolved fine.
  defp safe(fun, fallback) do
    fun.()
  rescue
    error ->
      Logger.warning("[NotableItems] #{Exception.message(error)}")
      fallback
  catch
    :exit, reason ->
      Logger.warning("[NotableItems] exited: #{inspect(reason)}")
      fallback
  end
end
