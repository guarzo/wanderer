defmodule WandererApp.Test.TrackedLocationsFixtures do
  @moduledoc false
  import WandererAppWeb.Factory
  alias WandererApp.Api
  alias WandererApp.Character.LocationConfirmations, as: Store

  def tracked_character(map, attrs \\ %{}) do
    character = insert(:character, attrs)

    {:ok, character} =
      Api.Character.update(character, %{
        access_token: "fixture-access-#{character.id}",
        expires_at: DateTime.to_unix(DateTime.utc_now()) + 3600
      })

    insert(:map_character_settings, %{map_id: map.id, character_id: character.id, tracked: true})
    character
  end

  def online(character, map) do
    Cachex.put(
      :character_state_cache,
      character.id,
      WandererApp.Character.Tracker.new(
        character_id: character.id,
        active_maps: [map.id],
        track_location: true,
        is_online: true
      )
    )

    # A live process registered with the existing pool registry supplies local
    # tracker-presence evidence without starting production pollers in tests.
    Registry.register(:unique_tracker_pool_registry, {:locations_fixture, character.id}, [
      character.id
    ])

    character
  end

  def confirm(character, id \\ 30_000_142, at \\ DateTime.utc_now()) do
    {:ok, ticket} = Store.begin_request(character.id, character.access_token)
    :ok = Store.confirm(ticket, id, at)
    at
  end

  def cleanup(records, destroy \\ &Ash.destroy!/1) do
    error =
      Enum.reduce(records, nil, fn record, first_error ->
        try do
          destroy.(record)
          first_error
        rescue
          error -> first_error || {error, __STACKTRACE__}
        end
      end)

    case error do
      nil -> :ok
      {exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  def viewer_access(map) do
    user = insert(:user)
    character = insert(:character, %{user_id: user.id})
    acl = insert(:access_list, %{owner_id: map.owner_id})
    insert(:map_access_list, %{map_id: map.id, access_list_id: acl.id})

    member =
      insert(:access_list_member, %{
        access_list_id: acl.id,
        eve_character_id: character.eve_id,
        role: :viewer
      })

    %{user: user, character: character, access_list: acl, member: member}
  end

  def static_system(id \\ 30_000_142, name \\ "Jita") do
    Ash.create!(Api.MapSolarSystem, %{solar_system_id: id, solar_system_name: name},
      action: :create
    )
  end
end
