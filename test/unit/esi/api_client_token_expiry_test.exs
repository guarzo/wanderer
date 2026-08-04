defmodule WandererApp.Esi.ApiClientTokenExpiryTest do
  @moduledoc """
  Regression coverage for `WandererApp.Esi.ApiClient.is_access_token_expired?/1`.

  Every authenticated ESI call routes through this predicate — location, online,
  ship, wallet and search — so a raise here takes down character tracking, not
  just the corporation search where it was first observed.
  """
  use WandererApp.DataCase, async: true

  alias WandererApp.Esi.ApiClient

  setup do
    character_id = "token-expiry-#{System.unique_integer([:positive])}"
    on_exit(fn -> Cachex.del(:character_cache, character_id) end)
    %{character_id: character_id}
  end

  defp cache_character(character_id, character),
    do: Cachex.put(:character_cache, character_id, character)

  defp unix_now, do: DateTime.utc_now() |> DateTime.to_unix()

  test "a token expiring in the future is not expired", %{character_id: character_id} do
    cache_character(character_id, %{expires_at: unix_now() + 3600})

    refute ApiClient.is_access_token_expired?(character_id)
  end

  test "a token whose expiry has passed is expired", %{character_id: character_id} do
    cache_character(character_id, %{expires_at: unix_now() - 1})

    assert ApiClient.is_access_token_expired?(character_id)
  end

  test "a token expiring exactly now is expired", %{character_id: character_id} do
    cache_character(character_id, %{expires_at: unix_now()})

    assert ApiClient.is_access_token_expired?(character_id)
  end

  test "a nil expires_at is treated as expired rather than raising", %{
    character_id: character_id
  } do
    # `expires_at` is nullable on WandererApp.Api.Character (no `allow_nil? false`),
    # so a character that never completed an OAuth exchange carries nil. Arithmetic
    # on it used to raise ArithmeticError on every authenticated ESI call.
    cache_character(character_id, %{expires_at: nil})

    assert ApiClient.is_access_token_expired?(character_id)
  end

  test "a nil character_id is treated as expired rather than raising" do
    # WandererApp.Character.get_character/1 answers {:ok, nil} for a nil id, which
    # used to fail the `{:ok, %{expires_at: _}} =` destructure with a MatchError.
    assert ApiClient.is_access_token_expired?(nil)
  end

  test "an unknown character_id is treated as expired rather than raising" do
    # Not in the cache and not in the DB => {:error, :not_found}, another MatchError.
    # `DataCase` rather than a bare `ExUnit.Case`: without a sandbox checkout the
    # Ash read fails on connection ownership, Ash wraps that into an error tuple,
    # and the assertion passes for the wrong reason — "DB unreachable" instead of
    # "row absent".
    assert ApiClient.is_access_token_expired?(Ecto.UUID.generate())
  end

  describe "time_since_expiry/1" do
    # `is_access_token_expired?/1` reports a nil `expires_at` as expired, which
    # sends exactly those characters down the refresh-and-retry path. Every
    # `handle_refresh_token_result/5` clause there logs how long ago the token
    # expired, and computing that with `DateTime.from_unix!/1` raised
    # `FunctionClauseError` on the same nil the predicate above tolerates.
    #
    # The visible symptom was the corporation typeahead in map settings: the
    # LiveView rescued the raise and rendered an empty dropdown, so the search
    # looked like it returned no matches instead of like it had crashed.

    test "returns elapsed seconds for a timestamp in the past" do
      assert ApiClient.time_since_expiry(unix_now() - 60) in 59..61
    end

    test "returns a negative value for a timestamp in the future" do
      assert ApiClient.time_since_expiry(unix_now() + 60) in -61..-59
    end

    test "returns nil for a nil expires_at rather than raising" do
      assert ApiClient.time_since_expiry(nil) == nil
    end

    test "returns nil for a non-integer expires_at rather than raising" do
      # Belt-and-braces for shapes the cache could hold after a schema change:
      # this value is only ever used as log/telemetry metadata, so no shape of it
      # is worth failing an ESI call over.
      assert ApiClient.time_since_expiry(DateTime.utc_now()) == nil
      assert ApiClient.time_since_expiry("1700000000") == nil
    end

    test "returns nil for an out-of-range unix timestamp rather than raising" do
      assert ApiClient.time_since_expiry(1_000_000_000_000_000_000_000) == nil
    end
  end
end
