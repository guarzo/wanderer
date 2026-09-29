defmodule WandererAppWeb.PrejumpPrimeController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.PrejumpPrimes, as: Primes
  alias WandererApp.TrackedCharacterLocations, as: Locations

  @errors %{
    invalid_token: {401, "Missing or invalid integration token"},
    scope_forbidden: {403, "Token scope is not permitted"},
    wrong_map: {403, "Token is not valid for this map"},
    forbidden: {403, "Token owner no longer has map access"},
    disabled: {403, "Map integrations are disabled"},
    subscription_required: {403, "Active map subscription required"},
    map_not_found: {404, "Map not found"},
    invalid_request: {400, "Invalid request or request limits exceeded"},
    not_acceptable: {406, "Unsupported media type or primes version"},
    service_unavailable: {503, "Primes temporarily unavailable"},
    rate_limited: {429, "Request limit exceeded"}
  }

  operation(:stage,
    summary: "Stage a pre-jump prime for a tracked character",
    description:
      "Dedicated prime-scope integration Bearer token only. Bounded, idempotent per event ID; the newest prime per character+map wins and unconsumed primes expire after 15 minutes. A 200 means staged, not consumed. Requires WANDERER_MAP_INTEGRATIONS_ENABLED and ordinary subscription policy.",
    tags: ["Map integrations"],
    security: [%{"mapIntegrationToken" => []}],
    parameters: [
      map_identifier: [
        in: :path,
        type: :string,
        required: true,
        description: "Map UUID or slug (255 bytes maximum)"
      ],
      "X-Wanderer-Primes-Version": [
        in: :header,
        type: :string,
        description: "Optional; only version 1 is supported"
      ]
    ],
    request_body:
      {"Prime record", "application/json", WandererAppWeb.Schemas.PrejumpPrimeRequest},
    responses: %{
      200 =>
        {"Staged (or idempotent replay)", "application/json",
         WandererAppWeb.Schemas.PrejumpPrimeStaged},
      400 => {"Invalid request", "application/json", WandererAppWeb.Schemas.PrejumpPrimeError},
      401 => {"Invalid token", "application/json", WandererAppWeb.Schemas.PrejumpPrimeError},
      403 =>
        {"Scope, map, disabled or subscription denial", "application/json",
         WandererAppWeb.Schemas.PrejumpPrimeError},
      406 =>
        {"Unsupported media/version", "application/json",
         WandererAppWeb.Schemas.PrejumpPrimeError},
      429 =>
        {"30 requests/minute/token, burst 10/second", "application/json",
         WandererAppWeb.Schemas.PrejumpPrimeError},
      503 => {"Unavailable", "application/json", WandererAppWeb.Schemas.PrejumpPrimeError}
    }
  )

  def stage(conn, %{"map_identifier" => identifier} = params) do
    with :ok <- negotiate(conn),
         :ok <- bounds(conn, identifier, params),
         {:ok, wire} <- bearer(conn),
         {:ok, principal} <- Primes.authenticate(wire),
         :ok <- rate_limit(principal.id),
         {:ok, map} <- Locations.resolve_map(identifier),
         {:ok, record} <- record(params) do
      case Primes.stage(map.id, principal, record) do
        :ok -> respond(conn, %{staged: true, event_id: record.event_id})
        {:error, code} when is_atom(code) -> error(conn, code)
        _ -> error(conn, :service_unavailable)
      end
    else
      {:error, code} -> error(conn, code)
      _ -> error(conn, :service_unavailable)
    end
  rescue
    _ -> error(conn, :service_unavailable)
  catch
    :exit, _ -> error(conn, :service_unavailable)
  end

  defp record(%{"prime" => %{} = prime}) do
    flags = prime["flags"] || %{}

    with {:ok, event_id} <- uuid(prime["event_id"]),
         {:ok, eve_character_id} <- integer(prime["eve_character_id"]),
         {:ok, source} <- integer(prime["source_solar_system_id"]),
         {:ok, name} <- name(prime["system_name"]) do
      {:ok,
       %{
         event_id: event_id,
         eve_character_id: eve_character_id,
         source_solar_system_id: source,
         system_name: name,
         flags: %{
           eol: !!flags["eol"],
           half_mass: !!flags["half_mass"],
           critical: !!flags["critical"],
           frigate: !!flags["frigate"]
         }
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp record(_), do: {:error, :invalid_request}

  defp uuid(v) when is_binary(v) and byte_size(v) <= 64 do
    case Ecto.UUID.cast(v) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid_request}
    end
  end

  defp uuid(_), do: {:error, :invalid_request}

  defp integer(v) when is_integer(v) and v > 0, do: {:ok, v}

  defp integer(v) when is_binary(v) and byte_size(v) <= 19 do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :invalid_request}
    end
  end

  defp integer(_), do: {:error, :invalid_request}

  defp name(v) when is_binary(v) and byte_size(v) > 0 and byte_size(v) <= 255,
    do: {:ok, String.trim(v)}

  defp name(_), do: {:error, :invalid_request}

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

  defp negotiate(conn) do
    versions = get_req_header(conn, "x-wanderer-primes-version")

    if versions in [[], ["1"]], do: :ok, else: {:error, :not_acceptable}
  end

  defp bounds(_conn, identifier, params) do
    body_size = byte_size(Jason.encode!(params))

    if byte_size(identifier) <= 255 and body_size <= 8192,
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp rate_limit(id) do
    with {:ok, _} <- ExRated.check_rate({:prime_staging_burst, id}, 1000, 10),
         {:ok, _} <- ExRated.check_rate({:prime_staging_minute, id}, 60_000, 30) do
      :ok
    else
      {:error, _} -> {:error, :rate_limited}
    end
  end

  defp respond(conn, body) do
    conn
    |> put_resp_header("x-wanderer-primes-version", "1")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp error(conn, code) do
    {status, message} = Map.get(@errors, code, @errors.service_unavailable)
    code = if Map.has_key?(@errors, code), do: code, else: :service_unavailable

    conn =
      conn
      |> delete_resp_header("etag")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-wanderer-primes-version", "1")
      |> put_resp_content_type("application/json")

    conn =
      if status == 401,
        do: put_resp_header(conn, "www-authenticate", ~s(Bearer error="invalid_token")),
        else: conn

    conn =
      if code in [:scope_forbidden, :wrong_map],
        do: put_resp_header(conn, "www-authenticate", ~s(Bearer error="insufficient_scope")),
        else: conn

    conn = if status == 429, do: put_resp_header(conn, "retry-after", "60"), else: conn
    send_resp(conn, status, Jason.encode!(%{error: message, code: code}))
  end
end
