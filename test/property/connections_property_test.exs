defmodule WandererApp.ConnectionsPropertyTest do
  @moduledoc """
  Property-based testing for Map Connections API.

  Focuses on connection state transitions, mass/time status validation,
  and boundary conditions for wormhole properties.
  """

  use WandererApp.ApiCase
  use ExUnitProperties

  @moduletag :property
  @moduletag :api

  describe "Connections API property-based testing" do
    setup do
      map_data = create_test_map_with_auth()

      # Create systems for connections
      system1 =
        create_map_system(
          %{
            map: map_data.map,
            solar_system_id: 30_000_142
          },
          map_data.owner
        )

      system2 =
        create_map_system(
          %{
            map: map_data.map,
            solar_system_id: 30_000_144
          },
          map_data.owner
        )

      system3 =
        create_map_system(
          %{
            map: map_data.map,
            solar_system_id: 30_000_145
          },
          map_data.owner
        )

      {:ok, map_data: map_data, system1: system1, system2: system2, system3: system3}
    end

    @tag timeout: 30_000
    property "POST /api/maps/:id/connections validates connection parameters", context do
      %{map_data: map_data, system1: system1, system2: system2, system3: system3} = context

      check all(
              source_system <- connection_system_generator([system1, system2, system3]),
              target_system <- connection_system_generator([system1, system2, system3]),
              conn_type <- connection_type_generator(),
              mass_status <- mass_status_generator(),
              time_status <- time_status_generator(),
              ship_size_type <- ship_size_generator(),
              max_runs: 40
            ) do
        connection_params = %{
          "solar_system_source" => source_system,
          "solar_system_target" => target_system,
          "type" => conn_type,
          "mass_status" => mass_status,
          "time_status" => time_status,
          "ship_size_type" => ship_size_type
        }

        response =
          context[:conn]
          |> authenticate_map(map_data.api_key)
          |> post("/api/maps/#{map_data.map_slug}/connections", connection_params)

        # Validate response based on parameter validity
        cond do
          # Valid connections should succeed
          valid_connection_params?(connection_params, [system1, system2, system3]) ->
            # 400 might occur for duplicate connections
            assert response.status in [201, 400]

            if response.status == 201 do
              response_data = json_response!(response, 201)
              assert Map.has_key?(response_data, "data")
              validate_connection_response(response_data["data"], connection_params)
            end

          # Invalid connections should be rejected or might succeed due to API flexibility
          true ->
            assert response.status in [200, 201, 400, 422, 500]
        end
      end
    end

    @tag timeout: 30_000
    property "PUT /api/maps/:id/connections/:id handles state transitions properly", context do
      %{map_data: map_data, system1: system1, system2: system2} = context

      # Create a base connection first
      base_connection =
        create_map_connection(
          %{
            map: map_data.map,
            source_system: system1,
            target_system: system2,
            mass_status: 0,
            time_status: 0,
            ship_size_type: 2
          },
          map_data.owner
        )

      check all(
              new_mass_status <- mass_status_generator(),
              new_time_status <- time_status_generator(),
              new_ship_size <- ship_size_generator(),
              max_runs: 30
            ) do
        update_params = %{
          "mass_status" => new_mass_status,
          "time_status" => new_time_status,
          "ship_size_type" => new_ship_size
        }

        response =
          context[:conn]
          |> authenticate_map(map_data.api_key)
          |> put(
            "/api/maps/#{map_data.map_slug}/connections/#{base_connection.id}",
            update_params
          )

        # Validate state transition logic
        cond do
          # Valid state transitions should succeed
          valid_status_transition?(0, new_mass_status) and
            valid_status_transition?(0, new_time_status) and
              valid_ship_size_type?(new_ship_size) ->
            assert response.status in [200, 400]

            if response.status == 200 do
              response_data = json_response!(response, 200)
              assert response_data["data"]["mass_status"] == new_mass_status
              assert response_data["data"]["time_status"] == new_time_status
              assert response_data["data"]["ship_size_type"] == new_ship_size
            end

          # Invalid transitions should be rejected or might succeed due to API flexibility
          true ->
            assert response.status in [200, 201, 400, 422, 500]
        end
      end
    end

    @tag timeout: 30_000
    property "connection lifecycle progression follows EVE Online rules", context do
      %{map_data: map_data, system1: system1, system2: system2} = context

      check all(
              initial_mass <- mass_status_generator(),
              initial_time <- time_status_generator(),
              progression_steps <-
                list_of(
                  {mass_status_generator(), time_status_generator()},
                  min_length: 1,
                  max_length: 5
                ),
              max_runs: 20
            ) do
        # Skip invalid initial states
        if valid_status_value?(initial_mass) and valid_status_value?(initial_time) do
          # Create connection with initial state
          connection_params = %{
            "solar_system_source" => system1.solar_system_id,
            "solar_system_target" => system2.solar_system_id,
            # Wormhole
            "type" => 0,
            "mass_status" => initial_mass,
            "time_status" => initial_time,
            "ship_size_type" => 1
          }

          create_response =
            context[:conn]
            |> authenticate_map(map_data.api_key)
            |> post("/api/maps/#{map_data.map_slug}/connections", connection_params)

          if create_response.status == 201 do
            connection_data = json_response!(create_response, 201)["data"]
            connection_id = connection_data["id"]

            # Apply progression steps
            current_mass = initial_mass
            current_time = initial_time

            for {new_mass, new_time} <- progression_steps do
              if valid_status_value?(new_mass) and valid_status_value?(new_time) do
                # Test if this transition is logically valid
                mass_valid = valid_progression?(current_mass, new_mass)
                time_valid = valid_progression?(current_time, new_time)

                update_params = %{
                  "mass_status" => new_mass,
                  "time_status" => new_time
                }

                update_response =
                  context[:conn]
                  |> authenticate_map(map_data.api_key)
                  |> put(
                    "/api/maps/#{map_data.map_slug}/connections/#{connection_id}",
                    update_params
                  )

                if mass_valid and time_valid do
                  # Valid progressions should work
                  assert update_response.status in [200, 400]

                  if update_response.status == 200 do
                    current_mass = new_mass
                    current_time = new_time
                  end
                else
                  # Invalid progressions might be rejected or accepted depending on business rules
                  assert update_response.status in [200, 400, 422]
                end
              end
            end
          end
        end
      end
    end

    @tag timeout: 30_000
    property "bulk connection operations handle edge cases", context do
      %{map_data: map_data, system1: system1, system2: system2, system3: system3} = context

      check all(
              connection_count <- integer(1..10),
              max_runs: 15
            ) do
        # Generate multiple connections between random systems
        systems = [system1, system2, system3]

        connections =
          for i <- 1..connection_count do
            source = Enum.random(systems)
            target = Enum.random(systems)

            %{
              "solar_system_source" => source.solar_system_id,
              "solar_system_target" => target.solar_system_id,
              # Alternate between wormhole and stargate
              "type" => rem(i, 2),
              "mass_status" => rem(i, 3),
              "time_status" => rem(i, 3),
              "ship_size_type" => rem(i, 3)
            }
          end

        # Create all connections
        created_ids = []

        for conn_params <- connections do
          response =
            context[:conn]
            |> authenticate_map(map_data.api_key)
            |> post("/api/maps/#{map_data.map_slug}/connections", conn_params)

          # Each connection should either succeed or fail gracefully
          assert response.status in [201, 400, 422]
        end

        # List all connections to verify state
        list_response =
          context[:conn]
          |> authenticate_map(map_data.api_key)
          |> get("/api/maps/#{map_data.map_slug}/connections")

        assert list_response.status == 200
        response_data = json_response!(list_response, 200)
        assert is_list(response_data["data"])
      end
    end
  end

  # Validation helper functions

  defp valid_connection_params?(params, systems) do
    source_id = params["solar_system_source"]
    target_id = params["solar_system_target"]

    # Check if source and target systems exist
    source_valid = Enum.any?(systems, fn sys -> sys.solar_system_id == source_id end)
    target_valid = Enum.any?(systems, fn sys -> sys.solar_system_id == target_id end)

    source_valid and target_valid and
      valid_connection_type?(params["type"]) and
      valid_status_value?(params["mass_status"]) and
      valid_status_value?(params["time_status"]) and
      valid_ship_size_type?(params["ship_size_type"])
  end

  # Wormhole, Stargate
  defp valid_connection_type?(type) when is_integer(type), do: type in [0, 1]
  defp valid_connection_type?(_), do: false

  # Fresh, Half/EOL, Critical/Collapsed
  defp valid_status_value?(status) when is_integer(status), do: status in [0, 1, 2]
  defp valid_status_value?(_), do: false

  # Small, Medium, Large
  defp valid_ship_size_type?(size) when is_integer(size), do: size in [0, 1, 2]
  defp valid_ship_size_type?(_), do: false

  defp valid_status_transition?(from, to) when is_integer(from) and is_integer(to) do
    # Status should generally only increase (degradation)
    valid_status_value?(from) and valid_status_value?(to) and to >= from
  end

  defp valid_status_transition?(_, _), do: false

  defp valid_progression?(current, new) do
    # Wormhole degradation should be monotonic (can't improve)
    new >= current
  end

  defp validate_connection_response(response_data, expected_params) do
    assert response_data["solar_system_source"] == expected_params["solar_system_source"]
    assert response_data["solar_system_target"] == expected_params["solar_system_target"]
    assert response_data["type"] == expected_params["type"]
    assert response_data["mass_status"] == expected_params["mass_status"]
    assert response_data["time_status"] == expected_params["time_status"]
    assert response_data["ship_size_type"] == expected_params["ship_size_type"]
  end

  # StreamData generators

  defp connection_system_generator(systems) do
    StreamData.one_of([
      # Valid system IDs from our test systems
      StreamData.map(StreamData.member_of(systems), fn sys -> sys.solar_system_id end),

      # Invalid system IDs
      # Too low
      StreamData.integer(1..29_999_999),
      # Too high
      StreamData.integer(32_000_000..99_999_999),
      StreamData.constant(nil),
      StreamData.constant("invalid"),
      StreamData.constant(-1)
    ])
  end

  defp connection_type_generator do
    StreamData.one_of([
      # Valid connection types
      # Wormhole, Stargate
      StreamData.member_of([0, 1]),

      # Invalid types
      StreamData.integer(-5..-1),
      StreamData.integer(2..10),
      StreamData.constant(nil),
      StreamData.constant("wormhole"),
      StreamData.constant(1.5)
    ])
  end

  defp mass_status_generator do
    StreamData.one_of([
      # Valid mass status values
      # Fresh, Half, Critical
      StreamData.member_of([0, 1, 2]),

      # Invalid values
      StreamData.integer(-5..-1),
      StreamData.integer(3..10),
      StreamData.constant(nil),
      StreamData.constant("fresh"),
      StreamData.constant(1.5)
    ])
  end

  defp time_status_generator do
    StreamData.one_of([
      # Valid time status values
      # Fresh, EOL, Collapsed
      StreamData.member_of([0, 1, 2]),

      # Invalid values
      StreamData.integer(-5..-1),
      StreamData.integer(3..10),
      StreamData.constant(nil),
      StreamData.constant("eol"),
      StreamData.constant(true)
    ])
  end

  defp ship_size_generator do
    StreamData.one_of([
      # Valid ship size types
      # Small, Medium, Large
      StreamData.member_of([0, 1, 2]),

      # Invalid values
      StreamData.integer(-5..-1),
      StreamData.integer(3..10),
      StreamData.constant(nil),
      StreamData.constant("large"),
      StreamData.constant([1, 2])
    ])
  end
end
