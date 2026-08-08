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
end
