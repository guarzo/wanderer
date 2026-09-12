defmodule WandererAppWeb.TrackedCharacterLocationsController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.MapIntegrationTokens, as: Tokens
  alias WandererApp.TrackedCharacterLocations, as: Locations

  @errors %{
    invalid_token: {401, "Missing or invalid integration token"},
    scope_forbidden: {403, "Token scope is not permitted"},
    wrong_map: {403, "Token is not valid for this map"},
    forbidden: {403, "Token owner no longer has map access"},
    disabled: {403, "Map integrations are disabled"},
    subscription_required: {403, "Active map subscription required"},
    map_not_found: {404, "Map not found"},
    not_acceptable: {406, "Unsupported media type or locations version"},
    invalid_request: {400, "Invalid request or request limits exceeded"},
    invalid_snapshot: {503, "Snapshot exceeds limits or contains invalid data"},
    service_unavailable: {503, "Locations temporarily unavailable"},
    rate_limited: {429, "Request limit exceeded"}
  }

  operation(:index,
    summary: "Read permitted tracked-character locations (single application process)",
    description:
      "Dedicated integration Bearer token only. Conditional polling every two seconds. Locations expire at 15 seconds; a 304 never renews their age. Requires WANDERER_MAP_INTEGRATIONS_ENABLED and ordinary API/subscription policy.",
    tags: ["Map integrations"],
    security: [%{"mapIntegrationToken" => []}],
    parameters: [
      map_identifier: [
        in: :path,
        type: :string,
        required: true,
        description: "Map UUID or slug (255 bytes maximum)"
      ],
      "X-Wanderer-Locations-Version": [
        in: :header,
        type: :string,
        description: "Optional; only version 1 is supported"
      ],
      "If-None-Match": [
        in: :header,
        type: :string,
        description: "Previous ETag; maximum 1024 bytes"
      ]
    ],
    responses: %{
      200 =>
        {"Freshly authorized snapshot", "application/json",
         WandererAppWeb.Schemas.TrackedCharacterLocationsResponse},
      304 =>
        {"Unchanged representation (not renewed location evidence)", "application/json", nil},
      400 =>
        {"Request limits exceeded", "application/json",
         WandererAppWeb.Schemas.TrackedCharacterLocationsError},
      401 =>
        {"Invalid token", "application/json",
         WandererAppWeb.Schemas.TrackedCharacterLocationsError},
      403 =>
        {"Scope, map, disabled or subscription denial", "application/json",
         WandererAppWeb.Schemas.TrackedCharacterLocationsError},
      404 =>
        {"Missing map", "application/json", WandererAppWeb.Schemas.TrackedCharacterLocationsError},
      406 =>
        {"Unsupported media/version", "application/json",
         WandererAppWeb.Schemas.TrackedCharacterLocationsError},
      429 =>
        {"60 requests/minute/token, burst 10/second", "application/json",
         WandererAppWeb.Schemas.TrackedCharacterLocationsError},
      503 =>
        {"Unavailable service or invalid/oversized snapshot", "application/json",
         WandererAppWeb.Schemas.TrackedCharacterLocationsError}
    }
  )

  def index(conn, %{"map_identifier" => identifier}) do
    with :ok <- negotiate(conn),
         :ok <- request_bounds(conn, identifier),
         {:ok, wire} <- bearer(conn),
         {:ok, principal} <- Tokens.authenticate(wire),
         :ok <- rate_limit(principal.id),
         {:ok, map} <- Locations.resolve_map(identifier),
         :ok <- bind_map(principal, map),
         :ok <- Locations.policy(map.id),
         {:ok, records, observed_at} <- Locations.snapshot(map.id, principal, wire) do
      respond(conn, map.id, records, observed_at)
    else
      {:error, code} -> error(conn, code)
      _ -> error(conn, :service_unavailable)
    end
  rescue
    _ -> error(conn, :service_unavailable)
  catch
    :exit, _ -> error(conn, :service_unavailable)
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      [header] when byte_size(header) <= 512 ->
        case Regex.run(~r/\ABearer ([^\s,]+)\z/i, header) do
          [_, wire] -> {:ok, wire}
          _ -> {:error, :invalid_token}
        end

      _ ->
        {:error, :invalid_token}
    end
  end

  defp bind_map(%{map_id: id}, %{id: id}), do: :ok
  defp bind_map(_, _), do: {:error, :wrong_map}

  defp request_bounds(conn, identifier) do
    conditional_size =
      conn |> get_req_header("if-none-match") |> Enum.reduce(0, &(byte_size(&1) + &2))

    if byte_size(identifier) <= 255 and conditional_size <= 1024,
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp negotiate(conn) do
    versions = get_req_header(conn, "x-wanderer-locations-version")
    accepts = get_req_header(conn, "accept")

    {_specificity, quality} =
      accepts
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&media_quality/1)
      |> Enum.max(fn -> {-1, 0.0} end)

    if versions in [[], ["1"]] and (accepts == [] or quality > 0),
      do: :ok,
      else: {:error, :not_acceptable}
  end

  defp media_quality(media) do
    case Plug.Conn.Utils.media_type(String.trim(media)) do
      {:ok, type, subtype, params} ->
        specificity =
          case {type, subtype} do
            {"application", "json"} -> 2
            {"application", "*"} -> 1
            {"*", "*"} -> 0
            _ -> -1
          end

        quality =
          case Float.parse(Map.get(params, "q", "1")) do
            {value, ""} when value >= 0 and value <= 1 -> value
            _ -> 0.0
          end

        {specificity, if(specificity >= 0, do: quality, else: 0.0)}

      _ ->
        {-1, 0.0}
    end
  end

  defp rate_limit(id) do
    with {:ok, _} <- ExRated.check_rate({:tracked_locations_burst, id}, 1000, 10),
         {:ok, _} <- ExRated.check_rate({:tracked_locations_minute, id}, 60_000, 60) do
      :ok
    else
      {:error, _} -> {:error, :rate_limited}
    end
  end

  defp respond(conn, map_id, records, observed_at) do
    canonical =
      Enum.map(records, fn record ->
        record |> Enum.sort() |> Enum.map(fn {k, v} -> [k, v] end)
      end)

    revision =
      :crypto.hash(:sha256, Jason.encode!([1, map_id, canonical]))
      |> Base.url_encode64(padding: false)

    etag = ~s(W/"#{revision}")

    body =
      Jason.encode!(%{
        data: records,
        observed_at: DateTime.to_iso8601(observed_at),
        revision: revision
      })

    if byte_size(body) <= 1_048_576 do
      conn =
        conn
        |> put_resp_header("x-wanderer-locations-version", "1")
        |> put_resp_header("cache-control", "private, no-cache, max-age=0, must-revalidate")
        |> put_resp_header("vary", "Authorization, Accept, X-Wanderer-Locations-Version")
        |> put_resp_header("etag", etag)
        |> put_resp_content_type("application/json")

      if matches?(conn, etag), do: send_resp(conn, 304, ""), else: send_resp(conn, 200, body)
    else
      error(conn, :invalid_snapshot)
    end
  end

  defp matches?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(fn candidate ->
      candidate = String.trim(candidate)

      candidate == "*" or
        String.replace_prefix(candidate, "W/", "") == String.replace_prefix(etag, "W/", "")
    end)
  end

  defp error(conn, code) do
    {status, message} = Map.get(@errors, code, @errors.service_unavailable)
    code = if Map.has_key?(@errors, code), do: code, else: :service_unavailable

    conn =
      conn
      |> delete_resp_header("etag")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-wanderer-locations-version", "1")
      |> put_resp_content_type("application/json")

    conn =
      cond do
        status == 401 ->
          put_resp_header(conn, "www-authenticate", ~s(Bearer error="invalid_token"))

        code in [:scope_forbidden, :wrong_map] ->
          put_resp_header(conn, "www-authenticate", ~s(Bearer error="insufficient_scope"))

        true ->
          conn
      end

    conn = if status == 429, do: put_resp_header(conn, "retry-after", "60"), else: conn
    send_resp(conn, status, Jason.encode!(%{error: message, code: code}))
  end
end
