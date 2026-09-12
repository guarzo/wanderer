# Disposable upgrade proof: run --seed at the old migration, migrate forward,
# then --verify. Never touches non-test or non-dedicated database partitions.
import ExUnit.Assertions
alias WandererApp.Repo

partition = System.get_env("MIX_TEST_PARTITION", "")
assert Mix.env() == :test
assert String.starts_with?(partition, "_personal_locations_upgrade")
assert Repo.config()[:database] == "wanderer_test#{partition}"

map_id = "11111111-1111-4111-8111-111111111111"
active_id = "22222222-2222-4222-8222-222222222222"
revoked_id = "33333333-3333-4333-8333-333333333333"
secret = String.duplicate("A", 43)

digest =
  :crypto.hash(:sha256, ["wanderer:map-integration-token:v1", <<0>>, active_id, <<0>>, secret])

case System.argv() do
  ["--seed"] ->
    Repo.query!(
      "INSERT INTO maps_v1 (id, name, slug) VALUES ($1, 'Upgrade fixture', 'personal-token-upgrade')",
      [Ecto.UUID.dump!(map_id)]
    )

    Repo.query!(
      "INSERT INTO map_integration_tokens_v1 (id, map_id, name, digest) VALUES ($1, $2, 'Old active token', $3)",
      [Ecto.UUID.dump!(active_id), Ecto.UUID.dump!(map_id), digest]
    )

    Repo.query!(
      "INSERT INTO map_integration_tokens_v1 (id, map_id, name, digest, revoked_at) VALUES ($1, $2, 'Old revoked token', $3, '2026-09-01 00:00:00')",
      [Ecto.UUID.dump!(revoked_id), Ecto.UUID.dump!(map_id), digest]
    )

    IO.puts("UPGRADE_FIXTURE seeded: 1 active, 1 revoked map-only hash credential")

  ["--verify"] ->
    assert [[2, 0, 0, 0]] =
             Repo.query!(
               "SELECT count(*), count(*) FILTER (WHERE revoked_at IS NULL), count(user_id), count(encrypted_value) FROM map_integration_tokens_v1 WHERE map_id = $1",
               [Ecto.UUID.dump!(map_id)]
             ).rows

    assert [[false]] =
             Repo.query!("SELECT location_api_enabled FROM maps_v1 WHERE id = $1", [
               Ecto.UUID.dump!(map_id)
             ]).rows

    assert [[^digest]] =
             Repo.query!("SELECT digest FROM map_integration_tokens_v1 WHERE id = $1", [
               Ecto.UUID.dump!(active_id)
             ]).rows

    assert {:error, :invalid_token} =
             WandererApp.MapIntegrationTokens.authenticate("wmi_v1_#{active_id}_#{secret}")

    assert [[true]] =
             Repo.query!(
               "SELECT revoked_at = '2026-09-01 00:00:00' FROM map_integration_tokens_v1 WHERE id = $1",
               [Ecto.UUID.dump!(revoked_id)]
             ).rows

    assert [[3]] =
             Repo.query!(
               "SELECT count(*) FROM pg_constraint WHERE conrelid = 'map_integration_tokens_v1'::regclass AND conname IN ('map_integration_tokens_v1_map_id_fkey', 'map_integration_tokens_v1_user_id_fkey', 'personal_credential')"
             ).rows

    assert [[index]] =
             Repo.query!(
               "SELECT indexdef FROM pg_indexes WHERE indexname = 'map_integration_tokens_v1_active_user_map_index'"
             ).rows

    assert index =~ "UNIQUE"
    assert index =~ "WHERE (revoked_at IS NULL)"

    IO.puts(
      "UPGRADE_FIXTURE verified: rows/digests preserved, old credentials invalid, opt-in false, FKs/check/active uniqueness present"
    )
end
