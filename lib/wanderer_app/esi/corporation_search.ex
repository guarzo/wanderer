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

  # ESI returns every corporation whose name matches the prefix, and `decorate/1`
  # issues one sequential `get_corporation_info/1` per hit — inside the calling
  # LiveView process, on every debounced keystroke. A broad term like "corp"
  # would otherwise block the settings tab for the sum of hundreds of lookups
  # whose results the caller then truncates anyway. Cap first, enrich after.
  @max_results 20

  @doc "Minimum number of characters before a search is sent to ESI."
  @spec min_search_length() :: pos_integer()
  def min_search_length, do: @min_search_length

  @doc "Maximum number of hits enriched and returned by `search/3`."
  @spec max_results() :: pos_integer()
  def max_results, do: @max_results

  @doc """
  Searches corporations by name as the first of `characters`.

  Returns `{:ok, []}` when the user has no characters or the term is too short,
  so callers can render "no matches" without distinguishing those cases from a
  genuinely empty result. An ESI failure is passed through as `{:error, reason}`
  and is not swallowed here — the map settings notifications tab turns that into
  a visible message, while the system-settings dialog logs it and still renders
  an empty dropdown.

  At most `max_results/0` hits are returned.

  Each hit keeps the keys `Character.search/2` produced (`:label`, `:value`,
  `:corporation`) and adds `:formatted`, `:name`, `:ticker`, `:id`, `:type`.
  `:value` and `:id` are **strings**; callers that persist integers must convert.

  `opts` exists for tests: `:search_fun` replaces `Character.search/2` and
  `:fetch_fun` replaces the ticker lookup.
  """
  @spec search(list(), any(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def search(characters, search, opts \\ [])

  def search([], _search, _opts), do: {:ok, []}

  def search([first_char | _], search, opts) when is_binary(search) do
    if String.length(search) < @min_search_length do
      {:ok, []}
    else
      search_fun = Keyword.get(opts, :search_fun, &Character.search/2)
      fetch_fun = Keyword.get(opts, :fetch_fun, &WandererApp.Esi.get_corporation_info/1)

      case search_fun.(first_char.id, params: [search: search, categories: "corporation"]) do
        {:ok, results} ->
          {:ok, results |> Enum.take(@max_results) |> Enum.map(&decorate(&1, fetch_fun))}

        other ->
          other
      end
    end
  end

  # A list of characters with a search term that is not a binary is a real,
  # expected state: the typeahead fires before anything has been typed. Answering
  # `{:ok, []}` is correct there.
  def search(characters, _search, _opts) when is_list(characters), do: {:ok, []}

  # Anything else is a programming error, not a user state — most likely
  # `characters` arriving as `%Ash.NotLoaded{}` from an unloaded association, or
  # the arguments passed in the wrong order. This used to be folded into the
  # `{:ok, []}` clause above, which reported success and rendered a permanently
  # empty dropdown with nothing in the logs to explain it.
  def search(characters, _search, _opts) do
    Logger.warning(
      "[CorporationSearch] search called with unusable characters: #{inspect(characters)}"
    )

    {:error, :invalid_characters}
  end

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

  defp decorate(item, fetch_fun) do
    name = Map.get(item, :label, "")
    corp_id = Map.get(item, :value, "")

    ticker =
      case safe_fetch(fetch_fun, corp_id) do
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
