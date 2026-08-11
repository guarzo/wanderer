defmodule WandererApp.Character.Tracker do
  @moduledoc false
  require Logger

  alias WandererApp.Api.Character

  defstruct [
    :character_id,
    :alliance_id,
    :corporation_id,
    :opts,
    server_online: true,
    start_time: nil,
    active_maps: [],
    is_online: false,
    track_online: true,
    track_location: false,
    track_ship: false,
    track_wallet: false,
    # Which branch point last cleared track_location, so report_location_repair/1
    # can say what it is repairing. Nil means "no clear recorded in this tracker's
    # lifetime" — including every character whose clear predates a restart, since
    # :character_state_cache is in-memory — and is reported as :unknown rather
    # than omitted, so the tag is always present in the series.
    last_cleared_reason: nil,
    status: "new"
  ]

  @type t :: %__MODULE__{
          character_id: integer,
          alliance_id: integer,
          corporation_id: integer,
          opts: map,
          server_online: boolean,
          start_time: DateTime.t(),
          active_maps: [integer],
          is_online: boolean,
          track_online: boolean,
          track_location: boolean,
          track_ship: boolean,
          track_wallet: boolean,
          last_cleared_reason: atom() | nil,
          status: binary()
        }

  @offline_timeout :timer.minutes(5)
  @location_error_timeout :timer.seconds(30)
  @location_error_threshold 3
  @online_forbidden_ttl :timer.seconds(7)
  @offline_check_delay_ttl :timer.seconds(15)
  @forbidden_ttl :timer.seconds(10)
  @limit_ttl :timer.seconds(5)
  @location_limit_ttl :timer.seconds(1)
  @pubsub_client Application.compile_env(:wanderer_app, :pubsub_client)

  def new(), do: __struct__()
  def new(args), do: __struct__(args)

  def init(args) do
    character_id = args[:character_id]

    {:ok, %{corporation_id: corporation_id, alliance_id: alliance_id}} =
      WandererApp.Character.get_character(character_id)

    %{
      character_id: character_id,
      corporation_id: corporation_id,
      alliance_id: alliance_id,
      start_time: DateTime.utc_now(),
      opts: args
    }
    |> new()
  end

  def check_offline(character_id) do
    WandererApp.Cache.lookup!("character:#{character_id}:last_online_time")
    |> case do
      nil ->
        :ok

      last_online_time ->
        duration = DateTime.diff(DateTime.utc_now(), last_online_time, :millisecond)

        if duration >= @offline_timeout do
          WandererApp.Character.update_character(character_id, %{online: false})

          WandererApp.Character.update_character_state(character_id, %{
            is_online: false
          })

          WandererApp.Cache.delete("character:#{character_id}:last_online_time")

          # The ESI handler clears ready status only when it observes the
          # online->offline transition. This timeout path writes `online: false`
          # directly, so without this call the character stayed marked ready
          # forever — and the next ESI poll skips cleanup because the state is
          # already false.
          clear_ready_status(character_id)

          :ok
        else
          :skip
        end
    end
  end

  defp clear_ready_status(character_id) do
    case WandererApp.Character.get_character(character_id) do
      {:ok, character} ->
        case WandererApp.Character.TrackingUtils.clear_ready_status_on_offline(character.eve_id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to clear ready status for character #{character.eve_id}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to get character #{character_id} for ready status clearing: #{inspect(reason)}"
        )
    end
  end

  defp increment_location_error_count(character_id) do
    cache_key = "character:#{character_id}:location_error_count"
    current_count = WandererApp.Cache.lookup!(cache_key) || 0
    new_count = current_count + 1
    WandererApp.Cache.put(cache_key, new_count)
    new_count
  end

  defp reset_location_error_count(character_id) do
    WandererApp.Cache.delete("character:#{character_id}:location_error_count")
  end

  def update_settings(character_id, track_settings) do
    {:ok, character_state} = WandererApp.Character.get_character_state(character_id)

    {:ok,
     character_state
     |> maybe_update_active_maps(track_settings)
     |> maybe_stop_tracking(track_settings)
     |> maybe_start_online_tracking(track_settings)
     |> maybe_start_location_tracking(track_settings)
     |> maybe_start_ship_tracking(track_settings)}
  end

  def update_online(character_id) when is_binary(character_id),
    do:
      character_id
      |> WandererApp.Character.get_character_state!()
      |> update_online()

  def update_online(
        %{track_online: true, character_id: character_id, is_online: is_online} = character_state
      ) do
    case WandererApp.Character.get_character(character_id) do
      {:ok, %{eve_id: eve_id, access_token: access_token, tracking_pool: tracking_pool}}
      when not is_nil(access_token) ->
        WandererApp.Cache.has_key?("character:#{character_id}:online_forbidden")
        |> case do
          true ->
            {:error, :skipped}

          _ ->
            case WandererApp.Esi.get_character_online(eve_id,
                   access_token: access_token,
                   character_id: character_id
                 ) do
              {:ok, online} when is_map(online) ->
                online = get_online(online)

                if online.online == true do
                  WandererApp.Cache.insert(
                    "character:#{character_id}:last_online_time",
                    DateTime.utc_now()
                  )

                  WandererApp.Cache.delete("character:#{character_id}:online_forbidden")
                else
                  # Delay next online updates for offline characters
                  WandererApp.Cache.put(
                    "character:#{character_id}:online_forbidden",
                    true,
                    ttl: @offline_check_delay_ttl
                  )
                end

                if online.online == true && not is_online do
                  WandererApp.Cache.delete("character:#{character_id}:ship_error_time")
                  WandererApp.Cache.delete("character:#{character_id}:location_error_time")
                  WandererApp.Cache.delete("character:#{character_id}:location_error_count")
                  WandererApp.Cache.delete("character:#{character_id}:info_forbidden")
                  WandererApp.Cache.delete("character:#{character_id}:ship_forbidden")
                  WandererApp.Cache.delete("character:#{character_id}:location_forbidden")
                  WandererApp.Cache.delete("character:#{character_id}:wallet_forbidden")
                  WandererApp.Cache.delete("character:#{character_id}:corporation_info_forbidden")
                end

                WandererApp.Cache.delete("character:#{character_id}:online_error_time")

                if online.online != is_online do
                  try do
                    WandererApp.Character.update_character(character_id, online)
                  rescue
                    error ->
                      Logger.error("DB_ERROR: Failed to update character in database",
                        character_id: character_id,
                        error: inspect(error),
                        operation: "update_character_online"
                      )

                      # Re-raise to maintain existing error handling
                      reraise error, __STACKTRACE__
                  end

                  # Clear ready status if character went offline
                  if not online.online do
                    clear_ready_status(character_id)
                  end

                  try do
                    WandererApp.Character.update_character_state(character_id, %{
                      character_state
                      | is_online: online.online,
                        track_ship: online.online,
                        track_location: online.online
                    })
                  rescue
                    error ->
                      Logger.error("DB_ERROR: Failed to update character state in database",
                        character_id: character_id,
                        error: inspect(error),
                        operation: "update_character_state"
                      )

                      # Re-raise to maintain existing error handling
                      reraise error, __STACKTRACE__
                  end
                end

                :ok

              {:error, error} when error in [:forbidden, :not_found, :timeout] ->
                WandererApp.Cache.put(
                  "character:#{character_id}:online_forbidden",
                  true,
                  ttl: @online_forbidden_ttl
                )

                if is_nil(
                     WandererApp.Cache.lookup!("character:#{character_id}:online_error_time")
                   ) do
                  WandererApp.Cache.insert(
                    "character:#{character_id}:online_error_time",
                    DateTime.utc_now()
                  )
                end

                {:error, :skipped}

              {:error, :error_limited, headers} ->
                reset_timeout = get_reset_timeout(headers)

                WandererApp.Cache.put(
                  "character:#{character_id}:online_forbidden",
                  true,
                  ttl: reset_timeout
                )

                {:error, :skipped}

              {:error, error} ->
                Logger.error("ESI_ERROR: Character online tracking failed: #{inspect(error)}",
                  character_id: character_id,
                  tracking_pool: tracking_pool,
                  error_type: error,
                  endpoint: "character_online"
                )

                WandererApp.Cache.put(
                  "character:#{character_id}:online_forbidden",
                  true,
                  ttl: @online_forbidden_ttl
                )

                if is_nil(
                     WandererApp.Cache.lookup!("character:#{character_id}:online_error_time")
                   ) do
                  WandererApp.Cache.insert(
                    "character:#{character_id}:online_error_time",
                    DateTime.utc_now()
                  )
                end

                {:error, :skipped}

              _ ->
                {:error, :skipped}
            end
        end

      _ ->
        Logger.debug(fn ->
          "[Tracker] update_online skipped for character #{character_id} - no valid access token"
        end)

        {:error, :skipped}
    end
  end

  def update_online(_), do: {:error, :skipped}

  defp get_reset_timeout(_headers, _default_timeout \\ @limit_ttl)

  defp get_reset_timeout(
         %{"x-esi-error-limit-remain" => ["0"], "x-esi-error-limit-reset" => [reset_seconds]},
         _default_timeout
       )
       when is_binary(reset_seconds),
       do: :timer.seconds((reset_seconds |> String.to_integer()) + 1)

  defp get_reset_timeout(_headers, default_timeout), do: default_timeout

  def update_info(character_id) do
    WandererApp.Cache.has_key?("character:#{character_id}:info_forbidden")
    |> case do
      true ->
        {:error, :skipped}

      false ->
        {:ok, %{eve_id: eve_id, tracking_pool: tracking_pool}} =
          WandererApp.Character.get_character(character_id)

        character_eve_id = eve_id |> String.to_integer()

        case WandererApp.Esi.post_characters_affiliation([character_eve_id]) do
          {:ok, [character_aff_info]} when not is_nil(character_aff_info) ->
            {:ok, character_state} = WandererApp.Character.get_character_state(character_id)

            alliance_id = character_aff_info |> Map.get("alliance_id")
            corporation_id = character_aff_info |> Map.get("corporation_id")

            updated_state =
              character_state
              |> maybe_update_corporation(corporation_id)
              |> maybe_update_alliance(alliance_id)

            WandererApp.Character.update_character_state(character_id, updated_state)

            :ok

          {:error, error} when error in [:forbidden, :not_found, :timeout] ->
            WandererApp.Cache.put(
              "character:#{character_id}:info_forbidden",
              true,
              ttl: @forbidden_ttl
            )

            {:error, error}

          {:error, :error_limited, headers} ->
            reset_timeout = get_reset_timeout(headers)

            WandererApp.Cache.put(
              "character:#{character_id}:info_forbidden",
              true,
              ttl: reset_timeout
            )

            {:error, :error_limited}

          {:error, error} ->
            WandererApp.Cache.put(
              "character:#{character_id}:info_forbidden",
              true,
              ttl: @forbidden_ttl
            )

            Logger.error("ESI_ERROR: Character info tracking failed: #{inspect(error)}",
              character_id: character_id,
              tracking_pool: tracking_pool,
              error_type: error,
              endpoint: "character_info"
            )

            {:error, error}

          _ ->
            {:error, :skipped}
        end
    end
  end

  def update_ship(character_id) when is_binary(character_id),
    do:
      character_id
      |> WandererApp.Character.get_character_state!()
      |> update_ship()

  def update_ship(
        %{character_id: character_id, track_ship: true, is_online: true} = character_state
      ) do
    character_id
    |> WandererApp.Character.get_character()
    |> case do
      {:ok, %{eve_id: eve_id, access_token: access_token, tracking_pool: tracking_pool}}
      when not is_nil(access_token) ->
        (WandererApp.Cache.has_key?("character:#{character_id}:online_forbidden") ||
           WandererApp.Cache.has_key?("character:#{character_id}:ship_forbidden"))
        |> case do
          true ->
            {:error, :skipped}

          _ ->
            case WandererApp.Esi.get_character_ship(eve_id,
                   access_token: access_token,
                   character_id: character_id
                 ) do
              {:ok, ship} when is_map(ship) and not is_struct(ship) ->
                character_state |> maybe_update_ship(ship)

                :ok

              {:error, error} when error in [:forbidden, :not_found, :timeout] ->
                WandererApp.Cache.put(
                  "character:#{character_id}:ship_forbidden",
                  true,
                  ttl: @forbidden_ttl
                )

                if is_nil(WandererApp.Cache.lookup!("character:#{character_id}:ship_error_time")) do
                  WandererApp.Cache.insert(
                    "character:#{character_id}:ship_error_time",
                    DateTime.utc_now()
                  )
                end

                {:error, error}

              {:error, :error_limited, headers} ->
                reset_timeout = get_reset_timeout(headers)

                WandererApp.Cache.put(
                  "character:#{character_id}:ship_forbidden",
                  true,
                  ttl: reset_timeout
                )

                {:error, :error_limited}

              {:error, error} ->
                Logger.error("ESI_ERROR: Character ship tracking failed: #{inspect(error)}",
                  character_id: character_id,
                  tracking_pool: tracking_pool,
                  error_type: error,
                  endpoint: "character_ship"
                )

                WandererApp.Cache.put(
                  "character:#{character_id}:ship_forbidden",
                  true,
                  ttl: @forbidden_ttl
                )

                if is_nil(WandererApp.Cache.lookup!("character:#{character_id}:ship_error_time")) do
                  WandererApp.Cache.insert(
                    "character:#{character_id}:ship_error_time",
                    DateTime.utc_now()
                  )
                end

                {:error, error}

              _ ->
                Logger.error("ESI_ERROR: Character ship tracking failed - wrong response",
                  character_id: character_id,
                  tracking_pool: tracking_pool,
                  error_type: "wrong_response",
                  endpoint: "character_ship"
                )

                WandererApp.Cache.put(
                  "character:#{character_id}:ship_forbidden",
                  true,
                  ttl: @forbidden_ttl
                )

                if is_nil(WandererApp.Cache.lookup!("character:#{character_id}:ship_error_time")) do
                  WandererApp.Cache.insert(
                    "character:#{character_id}:ship_error_time",
                    DateTime.utc_now()
                  )
                end

                {:error, :skipped}
            end
        end

      _ ->
        {:error, :skipped}
    end
  end

  def update_ship(_), do: {:error, :skipped}

  def update_location(character_id) when is_binary(character_id),
    do:
      character_id
      |> WandererApp.Character.get_character_state!()
      |> update_location()

  def update_location(
        %{track_location: true, is_online: true, character_id: character_id} = character_state
      ) do
    case WandererApp.Character.get_character(character_id) do
      {:ok, %{eve_id: eve_id, access_token: access_token, tracking_pool: tracking_pool}}
      when not is_nil(access_token) ->
        WandererApp.Cache.has_key?("character:#{character_id}:location_forbidden")
        |> case do
          true ->
            {:error, :skipped}

          _ ->
            # Monitor cache for potential evictions before ESI call

            case WandererApp.Esi.get_character_location(eve_id,
                   access_token: access_token,
                   character_id: character_id
                 ) do
              {:ok, location} when is_map(location) and not is_struct(location) ->
                reset_location_error_count(character_id)
                WandererApp.Cache.delete("character:#{character_id}:location_error_time")

                character_state
                |> maybe_update_location(location)

                :ok

              {:error, error} when error in [:forbidden, :not_found, :timeout] ->
                error_count = increment_location_error_count(character_id)

                Logger.warning("ESI_ERROR: Character location tracking failed",
                  character_id: character_id,
                  tracking_pool: tracking_pool,
                  error_type: error,
                  error_count: error_count,
                  endpoint: "character_location"
                )

                if error_count >= @location_error_threshold do
                  WandererApp.Cache.put(
                    "character:#{character_id}:location_forbidden",
                    true,
                    ttl: @location_error_timeout
                  )
                end

                if is_nil(
                     WandererApp.Cache.lookup!("character:#{character_id}:location_error_time")
                   ) do
                  WandererApp.Cache.insert(
                    "character:#{character_id}:location_error_time",
                    DateTime.utc_now()
                  )
                end

                {:error, :skipped}

              {:error, :error_limited, headers} ->
                reset_timeout = get_reset_timeout(headers, @location_limit_ttl)

                WandererApp.Cache.put(
                  "character:#{character_id}:location_forbidden",
                  true,
                  ttl: reset_timeout
                )

                {:error, :error_limited}

              {:error, error} ->
                error_count = increment_location_error_count(character_id)

                Logger.error("ESI_ERROR: Character location tracking failed: #{inspect(error)}",
                  character_id: character_id,
                  tracking_pool: tracking_pool,
                  error_type: error,
                  error_count: error_count,
                  endpoint: "character_location"
                )

                if error_count >= @location_error_threshold do
                  WandererApp.Cache.put(
                    "character:#{character_id}:location_forbidden",
                    true,
                    ttl: @location_error_timeout
                  )
                end

                if is_nil(
                     WandererApp.Cache.lookup!("character:#{character_id}:location_error_time")
                   ) do
                  WandererApp.Cache.insert(
                    "character:#{character_id}:location_error_time",
                    DateTime.utc_now()
                  )
                end

                {:error, :skipped}

              _ ->
                error_count = increment_location_error_count(character_id)

                Logger.error("ESI_ERROR: Character location tracking failed - wrong response",
                  character_id: character_id,
                  tracking_pool: tracking_pool,
                  error_type: "wrong_response",
                  error_count: error_count,
                  endpoint: "character_location"
                )

                if error_count >= @location_error_threshold do
                  WandererApp.Cache.put(
                    "character:#{character_id}:location_forbidden",
                    true,
                    ttl: @location_error_timeout
                  )
                end

                if is_nil(
                     WandererApp.Cache.lookup!("character:#{character_id}:location_error_time")
                   ) do
                  WandererApp.Cache.insert(
                    "character:#{character_id}:location_error_time",
                    DateTime.utc_now()
                  )
                end

                {:error, :skipped}
            end
        end

      _ ->
        Logger.debug(fn ->
          "[Tracker] update_location skipped for character #{character_id} - no valid access token"
        end)

        {:error, :skipped}
    end
  end

  # A character who is online and on at least one active map must have location
  # polling enabled. After the maybe_start_location_tracking/2 fix this state
  # should be unreachable, so log it loudly instead of returning
  # {:error, :skipped} silently — a silent skip here is exactly what hid this bug
  # in production: the map kept the character in presence and polled it every
  # second, but the tracker never fetched a location, so nothing looked wrong.
  #
  # Deliberately does not fire for offline characters; track_location is false
  # for them by design and that is not a fault.
  #
  # Throttled to one line per character per minute; update_location/1 runs on a
  # per-second tick.
  def update_location(
        %{
          track_location: false,
          is_online: true,
          character_id: character_id,
          active_maps: [_ | _] = active_maps
        } = _character_state
      ) do
    if WandererApp.Cache.put_new(
         "character:#{character_id}:location_skip_logged",
         true,
         ttl: :timer.minutes(1)
       ) do
      Logger.warning(
        "[Tracker] update_location skipped for online character #{character_id} while active " <>
          "on #{length(active_maps)} map(s): track_location=false. The map believes this " <>
          "character is tracked but its location will never update.",
        character_id: character_id
      )

      # Emitted inside the throttle deliberately: update_location/1 runs on a
      # per-second tick, so an unthrottled counter would measure ticks rather
      # than incidents. One count here is roughly one character-minute stuck.
      #
      # This must stay at zero once the maybe_start_location_tracking/2 fix is
      # deployed. Any nonzero value means a path to the frozen state that the
      # fix does not cover.
      #
      # There is no legacy-stuck drain period to discount: :character_state_cache
      # is in-memory (application.ex), so the deploy that ships this fix also
      # clears every already-frozen character. A count on a post-deploy tracker
      # is therefore a new incident, not a leftover one.
      :telemetry.execute(
        [:wanderer_app, :character, :tracking, :location_skipped_while_active],
        %{count: 1, system_time: System.system_time()},
        %{character_id: character_id}
      )
    end

    {:error, :skipped}
  end

  def update_location(_), do: {:error, :skipped}

  def update_wallet(character_id) do
    character_id
    |> WandererApp.Character.get_character()
    |> case do
      {:ok,
       %{eve_id: eve_id, access_token: access_token, tracking_pool: tracking_pool} = character}
      when not is_nil(access_token) ->
        character
        |> WandererApp.Character.can_track_wallet?()
        |> case do
          true ->
            (WandererApp.Cache.has_key?("character:#{character_id}:online_forbidden") ||
               WandererApp.Cache.has_key?("character:#{character_id}:wallet_forbidden"))
            |> case do
              true ->
                {:error, :skipped}

              _ ->
                case WandererApp.Esi.get_character_wallet(eve_id,
                       params: %{datasource: "tranquility"},
                       access_token: access_token,
                       character_id: character_id
                     ) do
                  {:ok, result} ->
                    {:ok, state} = WandererApp.Character.get_character_state(character_id)
                    maybe_update_wallet(state, result)

                    :ok

                  {:error, error} when error in [:forbidden, :not_found, :timeout] ->
                    Logger.warning("ESI_ERROR: Character wallet tracking failed",
                      character_id: character_id,
                      tracking_pool: tracking_pool,
                      error_type: error,
                      endpoint: "character_wallet"
                    )

                    WandererApp.Cache.put(
                      "character:#{character_id}:wallet_forbidden",
                      true,
                      ttl: @forbidden_ttl
                    )

                    {:error, :skipped}

                  {:error, :error_limited, headers} ->
                    reset_timeout = get_reset_timeout(headers)

                    WandererApp.Cache.put(
                      "character:#{character_id}:wallet_forbidden",
                      true,
                      ttl: reset_timeout
                    )

                    {:error, :skipped}

                  {:error, error} ->
                    Logger.error("ESI_ERROR: Character wallet tracking failed: #{inspect(error)}",
                      character_id: character_id,
                      tracking_pool: tracking_pool,
                      error_type: error,
                      endpoint: "character_wallet"
                    )

                    WandererApp.Cache.put(
                      "character:#{character_id}:wallet_forbidden",
                      true,
                      ttl: @forbidden_ttl
                    )

                    {:error, :skipped}

                  error ->
                    Logger.error("ESI_ERROR: Character wallet tracking failed: #{inspect(error)}",
                      character_id: character_id,
                      tracking_pool: tracking_pool,
                      error_type: error,
                      endpoint: "character_wallet"
                    )

                    WandererApp.Cache.put(
                      "character:#{character_id}:wallet_forbidden",
                      true,
                      ttl: @forbidden_ttl
                    )

                    {:error, :skipped}
                end
            end

          _ ->
            {:error, :skipped}
        end

      _ ->
        {:error, :skipped}
    end
  end

  # when old_alliance_id != alliance_id and is_nil(alliance_id)
  defp maybe_update_alliance(
         %{character_id: character_id, alliance_id: old_alliance_id} = state,
         alliance_id
       )
       when old_alliance_id != alliance_id and is_nil(alliance_id) do
    {:ok, character} = WandererApp.Character.get_character(character_id)

    character_update = %{
      alliance_id: nil,
      alliance_name: nil,
      alliance_ticker: nil
    }

    {:ok, _character} =
      Character.update_alliance(character, character_update)

    WandererApp.Character.update_character(character_id, character_update)

    @pubsub_client.broadcast(
      WandererApp.PubSub,
      "character:#{character_id}:alliance",
      {:character_alliance, {character_id, character_update}}
    )

    # Broadcast permission update to trigger LiveView refresh
    # This ensures users are kicked off maps they no longer have access to
    @pubsub_client.broadcast(
      WandererApp.PubSub,
      "character:#{character.eve_id}",
      :update_permissions
    )

    state
    |> Map.merge(%{alliance_id: nil})
  end

  defp maybe_update_alliance(
         %{character_id: character_id, alliance_id: old_alliance_id} = state,
         alliance_id
       )
       when old_alliance_id != alliance_id do
    WandererApp.Cache.has_key?("character:#{character_id}:online_forbidden")
    |> case do
      true ->
        state

      _ ->
        alliance_id
        |> WandererApp.Esi.get_alliance_info()
        |> case do
          {:ok, %{"name" => alliance_name, "ticker" => alliance_ticker}} ->
            {:ok, character} = WandererApp.Character.get_character(character_id)

            character_update = %{
              alliance_id: alliance_id,
              alliance_name: alliance_name,
              alliance_ticker: alliance_ticker
            }

            {:ok, _character} =
              WandererApp.Api.Character.update_alliance(character, character_update)

            WandererApp.Character.update_character(character_id, character_update)

            @pubsub_client.broadcast(
              WandererApp.PubSub,
              "character:#{character_id}:alliance",
              {:character_alliance, {character_id, character_update}}
            )

            # Broadcast permission update to trigger LiveView refresh
            # This ensures users are kicked off maps they no longer have access to
            @pubsub_client.broadcast(
              WandererApp.PubSub,
              "character:#{character.eve_id}",
              :update_permissions
            )

            state
            |> Map.merge(%{alliance_id: alliance_id})

          _error ->
            Logger.error("Failed to get alliance info for #{alliance_id}")
            state
        end
    end
  end

  defp maybe_update_alliance(state, _alliance_id), do: state

  defp maybe_update_corporation(
         %{character_id: character_id, corporation_id: old_corporation_id} = state,
         corporation_id
       )
       when old_corporation_id != corporation_id do
    (WandererApp.Cache.has_key?("character:#{character_id}:online_forbidden") ||
       WandererApp.Cache.has_key?("character:#{character_id}:corporation_info_forbidden"))
    |> case do
      true ->
        state

      _ ->
        corporation_id
        |> WandererApp.Esi.get_corporation_info()
        |> case do
          {:ok, %{"name" => corporation_name, "ticker" => corporation_ticker}} ->
            {:ok, character} =
              WandererApp.Character.get_character(character_id)

            character_update = %{
              corporation_id: corporation_id,
              corporation_name: corporation_name,
              corporation_ticker: corporation_ticker
            }

            {:ok, _character} =
              WandererApp.Api.Character.update_corporation(character, character_update)

            WandererApp.Character.update_character(character_id, character_update)

            @pubsub_client.broadcast(
              WandererApp.PubSub,
              "character:#{character_id}:corporation",
              {:character_corporation,
               {character_id,
                %{
                  corporation_id: corporation_id,
                  corporation_name: corporation_name,
                  corporation_ticker: corporation_ticker
                }}}
            )

            # Broadcast permission update to trigger LiveView refresh
            # This ensures users are kicked off maps they no longer have access to
            @pubsub_client.broadcast(
              WandererApp.PubSub,
              "character:#{character.eve_id}",
              :update_permissions
            )

            state
            |> Map.merge(%{corporation_id: corporation_id})

          {:error, :error_limited, headers} ->
            reset_timeout = get_reset_timeout(headers)

            WandererApp.Cache.put(
              "character:#{character_id}:corporation_info_forbidden",
              true,
              ttl: reset_timeout
            )

            state

          error ->
            Logger.warning(
              "Failed to get corporation info for character #{character_id}: #{inspect(error)}",
              character_id: character_id,
              corporation_id: corporation_id
            )

            state
        end
    end
  end

  defp maybe_update_corporation(state, _corporation_id), do: state

  defp maybe_update_ship(
         %{
           character_id: character_id
         } =
           state,
         ship
       )
       when is_map(ship) and not is_struct(ship) do
    ship_type_id = Map.get(ship, "ship_type_id")
    ship_name = Map.get(ship, "ship_name")

    {:ok, %{ship: old_ship_type_id, ship_name: old_ship_name} = character} =
      WandererApp.Character.get_character(character_id)

    ship_updated = old_ship_type_id != ship_type_id || old_ship_name != ship_name

    if ship_updated do
      character_update = %{
        ship: ship_type_id,
        ship_name: ship_name
      }

      {:ok, _character} =
        WandererApp.Api.Character.update_ship(character, character_update)

      WandererApp.Character.update_character(character_id, character_update)
    end

    state
  end

  defp maybe_update_ship(
         state,
         _ship
       ),
       do: state

  defp maybe_update_location(
         %{
           character_id: character_id
         } =
           state,
         location
       ) do
    location = get_location(location)

    {:ok,
     %{solar_system_id: solar_system_id, structure_id: structure_id, station_id: station_id} =
       character} =
      WandererApp.Character.get_character(character_id)

    is_location_updated?(location, solar_system_id, structure_id, station_id)
    |> case do
      true ->
        {:ok, _character} = WandererApp.Api.Character.update_location(character, location)
        WandererApp.Character.update_character(character_id, location)

        :ok

      _ ->
        :ok
    end

    state
  end

  defp is_location_updated?(
         %{
           solar_system_id: new_solar_system_id,
           station_id: new_station_id,
           structure_id: new_structure_id
         } = _location,
         solar_system_id,
         structure_id,
         station_id
       ),
       do:
         solar_system_id != new_solar_system_id ||
           structure_id != new_structure_id ||
           station_id != new_station_id

  defp maybe_update_wallet(
         %{character_id: character_id} =
           state,
         wallet_balance
       ) do
    {:ok, character} = WandererApp.Character.get_character(character_id)

    {:ok, _character} =
      WandererApp.Api.Character.update_wallet_balance(character, %{
        eve_wallet_balance: wallet_balance
      })

    WandererApp.Character.update_character(character_id, %{
      eve_wallet_balance: wallet_balance
    })

    @pubsub_client.broadcast(
      WandererApp.PubSub,
      "character:#{character_id}",
      {:character_wallet_balance}
    )

    state
  end

  defp maybe_start_online_tracking(
         state,
         %{track_online: true} = _track_settings
       ),
       do: %{
         state
         | track_online: true
       }

  defp maybe_start_online_tracking(
         state,
         _track_settings
       ),
       do: state

  # Location and ship tracking follow map membership rather than an explicit flag.
  #
  # Every caller that starts map tracking sends only %{map_id: ..., track: true}
  # (TrackingUtils.track_character/4 and both re-track paths in the map server's
  # reconcile_tracking/1), so matching solely on an explicit `track_location` key
  # left the flag false. The only other writer, update_online/1, fires on an
  # online-status *transition*, so a character who was already online when map
  # tracking began never got the flag set — update_location/1 then fell through
  # to its catch-all clause and the map never saw them move.
  #
  # Deriving from active_maps makes this symmetric with maybe_stop_tracking/2,
  # which clears both flags once no maps remain active. These clauses run after
  # maybe_update_active_maps/2 and maybe_stop_tracking/2 in the update_settings/2
  # pipeline, so active_maps is already accurate here.
  defp maybe_start_location_tracking(
         state,
         %{track_location: true} = _track_settings
       ),
       do: %{state | track_location: true}

  defp maybe_start_location_tracking(
         %{active_maps: [_ | _]} = state,
         _track_settings
       ) do
    report_location_repair(state)
    # last_cleared_reason is consumed here: the clear it described has now been
    # undone, and leaving it set would let the *next* repair inherit a label
    # belonging to an older clear.
    %{state | track_location: true, last_cleared_reason: nil}
  end

  defp maybe_start_location_tracking(
         state,
         _track_settings
       ),
       do: state

  # Emits only when maybe_start_location_tracking/2 is genuinely repairing the
  # defect: the character is online in EVE but location tracking is off — the
  # pair that update_online/1 can never fix, because no online transition will
  # ever occur.
  #
  # A freshly started tracker also reaches that clause with track_location:
  # false, but with is_online: false, and that is the ordinary start path rather
  # than a repair. Excluding it keeps this counter meaningful: every emission is
  # a character who WOULD have frozen on the map before this fix. Pair with
  # :location_flag_cleared (where the bad state is created) and
  # :location_skipped_while_active (which must stay at zero).
  # Tagged with the reason for the clear this repair undoes, because the two are
  # not the same kind of event: repaired{reason: presence_driven} is the fix
  # saving a character who would have frozen, while
  # repaired{reason: manual_untrack} is the fix reverting an operator who
  # deliberately pressed Untrack. Only the first belongs in the headline number.
  # :unknown covers clears this tracker did not witness — its state is held in an
  # in-memory cache, so every restart resets the field.
  defp report_location_repair(%{
         is_online: true,
         track_location: false,
         character_id: character_id,
         last_cleared_reason: last_cleared_reason
       }) do
    reason = last_cleared_reason || :unknown

    Logger.info(
      "[Tracker] Restored location tracking for online character #{character_id} on map " <>
        "re-entry; before this fix the character would have stopped moving on the map. " <>
        "cleared_reason=#{reason}",
      character_id: character_id
    )

    :telemetry.execute(
      [:wanderer_app, :character, :tracking, :location_flag_repaired],
      %{count: 1, system_time: System.system_time()},
      %{character_id: character_id, reason: reason}
    )
  end

  defp report_location_repair(_state), do: :ok

  defp maybe_start_ship_tracking(
         state,
         %{track_ship: true} = _track_settings
       ),
       do: %{state | track_ship: true}

  defp maybe_start_ship_tracking(
         %{active_maps: [_ | _]} = state,
         _track_settings
       ),
       do: %{state | track_ship: true}

  defp maybe_start_ship_tracking(
         state,
         _track_settings
       ),
       do: state

  defp maybe_update_active_maps(
         %{character_id: character_id, active_maps: active_maps} =
           state,
         %{map_id: map_id, track: true}
       ) do
    if not Enum.member?(active_maps, map_id) do
      WandererApp.Cache.put(
        "character:#{character_id}:map:#{map_id}:tracking_start_time",
        DateTime.utc_now()
      )

      WandererApp.Cache.delete("map:#{map_id}:character:#{character_id}:solar_system_id")
      WandererApp.Cache.delete("map:#{map_id}:character:#{character_id}:station_id")
      WandererApp.Cache.delete("map:#{map_id}:character:#{character_id}:structure_id")

      WandererApp.Cache.take("character:#{character_id}:last_active_time")

      %{state | active_maps: [map_id | active_maps]}
    else
      WandererApp.Cache.take("character:#{character_id}:last_active_time")

      state
    end
  end

  defp maybe_update_active_maps(
         %{character_id: character_id, active_maps: active_maps} = state,
         %{map_id: map_id, track: false} = _track_settings
       ) do
    WandererApp.Cache.take("character:#{character_id}:map:#{map_id}:tracking_start_time")
    |> case do
      start_time when not is_nil(start_time) ->
        duration = DateTime.diff(DateTime.utc_now(), start_time, :second)

        Logger.info(
          "[Tracker] Removed tracking_start_time cache key for character #{character_id} " <>
            "on map #{map_id} - tracking duration: #{duration}s"
        )

        :telemetry.execute([:wanderer_app, :character, :tracker], %{duration: duration})

        :ok

      _ ->
        Logger.info(
          "[Tracker] tracking_start_time cache key already missing for character #{character_id} " <>
            "on map #{map_id} when attempting to untrack"
        )

        :ok
    end

    %{state | active_maps: Enum.filter(active_maps, &(&1 != map_id))}
  end

  defp maybe_update_active_maps(
         state,
         _track_settings
       ),
       do: state

  defp maybe_stop_tracking(
         %{
           active_maps: [],
           character_id: character_id,
           is_online: is_online,
           track_location: track_location,
           opts: opts
         } = state,
         track_settings
       ) do
    if is_nil(opts[:keep_alive]) do
      WandererApp.Cache.put(
        "character:#{character_id}:last_active_time",
        DateTime.utc_now()
      )
    end

    # Clearing track_location while the character is still online in EVE is what
    # creates the (is_online: true, track_location: false) pair. update_online/1
    # only rewrites those fields on an online-status transition, so once this
    # runs no transition is pending and the flag cannot come back on its own.
    # This is the origin event for the freeze; correlate its timestamps with
    # presence grace-period expiry to confirm the trigger.
    #
    # Guarded on the *prior* track_location so this counts transitions, not
    # calls: a repeat untrack for an already-stopped character clears nothing,
    # and counting it would inflate this metric relative to the
    # :location_flag_repaired counter it is meant to be read against.
    if is_online and track_location do
      :telemetry.execute(
        [:wanderer_app, :character, :tracking, :location_flag_cleared],
        %{count: 1, system_time: System.system_time()},
        %{character_id: character_id, reason: untrack_reason(track_settings)}
      )
    end

    # Recorded even when the counter above does not fire, so a later repair can
    # still name its cause. Only overwritten on a real clear, so it always
    # describes the clear that the next repair undoes.
    %{
      state
      | track_location: false,
        track_ship: false,
        last_cleared_reason: untrack_reason(track_settings)
    }
  end

  defp maybe_stop_tracking(
         state,
         _track_settings
       ),
       do: state

  # Callers that predate the bounded reason (and the internal re-entry paths in
  # reconcile_tracking/1) send no untrack_reason at all; label those :unknown
  # rather than guessing :presence_driven, which would quietly attribute them to
  # the majority cause.
  defp untrack_reason(%{untrack_reason: reason}) when is_atom(reason) and not is_nil(reason),
    do: reason

  defp untrack_reason(_track_settings), do: :unknown

  defp get_location(%{
         "solar_system_id" => solar_system_id,
         "station_id" => station_id
       }),
       do: %{solar_system_id: solar_system_id, structure_id: nil, station_id: station_id}

  defp get_location(%{
         "solar_system_id" => solar_system_id,
         "structure_id" => structure_id
       }),
       do: %{solar_system_id: solar_system_id, structure_id: structure_id, station_id: nil}

  defp get_location(%{"solar_system_id" => solar_system_id}),
    do: %{solar_system_id: solar_system_id, structure_id: nil, station_id: nil}

  defp get_location(_), do: %{solar_system_id: nil, structure_id: nil, station_id: nil}

  defp get_online(%{"online" => online}), do: %{online: online}

  defp get_online(_), do: %{online: false}

  # Telemetry handler for database pool monitoring
  def handle_pool_query(_event_name, measurements, metadata, _config) do
    queue_time = measurements[:queue_time]

    # Check if queue_time exists and exceeds threshold (in microseconds)
    # 100ms = 100_000 microseconds indicates pool exhaustion
    if queue_time && queue_time > 100_000 do
      Logger.warning("DB_POOL_EXHAUSTED: Database pool contention detected",
        queue_time_ms: div(queue_time, 1000),
        query: metadata[:query],
        source: metadata[:source],
        repo: metadata[:repo]
      )
    end
  end
end
