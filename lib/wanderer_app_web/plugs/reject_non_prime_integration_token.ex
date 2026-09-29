defmodule WandererAppWeb.Plugs.RejectNonPrimeIntegrationToken do
  @moduledoc """
  Guards the pre-jump prime staging pipeline.

  Header-only namespace checks, not validation: a request that carries an
  `authorization` header must have a `wmi_` credential (any other scheme is
  foreign to this endpoint), while map/ACL API keys are rejected outright.
  The prime scope itself is verified by the controller via
  `WandererApp.PrejumpPrimes.authenticate/1`. Query parameters, cookies and
  bodies never supply authority.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    header = conn |> get_req_header("authorization") |> List.first("")

    cond do
      header == "" ->
        reject(conn, 401, "Missing or invalid 'Bearer' token", nil)

      Regex.match?(~r/(?:^|[ \t,])wmi_/, header) ->
        # Prime namespace: accepted here, scope-checked by the controller.
        conn

      true ->
        # Map/ACL/JSON-API keys and unknown schemes: never prime authority.
        reject(conn, 403, "This endpoint only accepts prime integration tokens", nil)
    end
  end

  def reject(conn, status, message, code) do
    body = %{error: message}
    body = if code, do: Map.put(body, :code, code), else: body

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-wanderer-primes-version", "1")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
