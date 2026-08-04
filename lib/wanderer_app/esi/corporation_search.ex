defmodule WandererApp.Esi.CorporationSearch do
  @moduledoc """
  Corporation name search against ESI, performed as one of the user's characters.

  ESI's `/search/` endpoint is authenticated, so a search needs a character with
  a live access token — which is why this takes a character list rather than a
  bare query string. Extracted from `MapSystemsEventHandler` so the map UI and
  the notification settings component share one implementation of the
  minimum-length rule and the ticker enrichment.
  """

  require Logger

  alias WandererApp.Character

  @min_search_length 3

  @doc "Minimum number of characters before a search is sent to ESI."
  @spec min_search_length() :: pos_integer()
  def min_search_length, do: @min_search_length

  @doc """
  Searches corporations by name as the first of `characters`.

  Returns `{:ok, []}` — never an error tuple — when the user has no characters
  or the term is too short, so callers can render "no matches" without
  distinguishing those cases from a genuinely empty result.

  Each hit keeps the keys `Character.search/2` produced (`:label`, `:value`,
  `:corporation`) and adds `:formatted`, `:name`, `:ticker`, `:id`, `:type`.
  `:value` and `:id` are **strings**; callers that persist integers must convert.
  """
  @spec search(list(), any()) :: {:ok, list(map())}
  def search([], _search), do: {:ok, []}

  def search([first_char | _], search) when is_binary(search) do
    if String.length(search) < @min_search_length do
      {:ok, []}
    else
      case Character.search(first_char.id, params: [search: search, categories: "corporation"]) do
        {:ok, results} ->
          {:ok, Enum.map(results, &decorate/1)}

        other ->
          other
      end
    end
  end

  def search(_characters, _search), do: {:ok, []}

  @doc """
  Human-readable label for a stored corporation id.

  Falls back to `to_string(corp_id)` whenever ESI cannot answer: a saved focus
  corporation has to stay visible and removable while ESI is down.
  """
  @spec label_for(integer() | String.t()) :: String.t()
  @spec label_for(integer() | String.t(), (any() -> any())) :: String.t()
  def label_for(corp_id, fetch_fun \\ &WandererApp.Esi.get_corporation_info/1) do
    case safe_fetch(fetch_fun, corp_id) do
      {:ok, %{"name" => name} = info} when is_binary(name) and name != "" ->
        format_label(name, Map.get(info, "ticker"))

      _ ->
        to_string(corp_id)
    end
  end

  defp decorate(item) do
    name = Map.get(item, :label, "")
    corp_id = Map.get(item, :value, "")

    ticker =
      case safe_fetch(&WandererApp.Esi.get_corporation_info/1, corp_id) do
        {:ok, %{"ticker" => ticker}} -> ticker
        _ -> ""
      end

    Map.merge(item, %{
      formatted: format_label(name, ticker),
      name: name,
      ticker: ticker,
      id: corp_id,
      type: "corp"
    })
  end

  defp format_label(name, ticker) when is_binary(ticker) and ticker != "",
    do: "[#{ticker}] #{name}"

  defp format_label(name, _ticker), do: name

  # ESI is a network dependency reached from a LiveView process; a raise here
  # would take the settings tab down over a transient lookup.
  defp safe_fetch(fetch_fun, corp_id) do
    fetch_fun.(corp_id)
  rescue
    error ->
      Logger.warning(
        "[CorporationSearch] lookup failed for #{inspect(corp_id)}: #{inspect(error)}"
      )

      :error
  end
end
