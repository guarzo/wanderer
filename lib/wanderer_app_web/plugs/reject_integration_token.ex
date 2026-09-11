defmodule WandererAppWeb.Plugs.RejectIntegrationToken do
  @moduledoc """
  Reserves integration Authorization credentials for their dedicated pipeline.

  This is a header-only namespace check, not token validation: every `wmi_`
  version is rejected here, even if malformed or copied into a legacy key field.
  Query parameters, cookies and bodies do not supply integration authority.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if integration_token?(conn), do: reject(conn), else: conn
  end

  def integration_token?(conn) do
    conn
    |> get_req_header("authorization")
    |> Enum.any?(fn value ->
      # Inspect every credential component, including combined/duplicate values
      # and malformed schemes, without changing legacy Bearer parsing.
      Regex.match?(~r/(?:^|[ \t,])wmi_/, value)
    end)
  end

  def reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> delete_resp_header("etag")
    |> put_resp_header("x-wanderer-locations-version", "1")
    |> put_resp_header("www-authenticate", ~s(Bearer error="insufficient_scope"))
    |> send_resp(
      403,
      Jason.encode!(%{
        error: "Integration tokens cannot access this endpoint",
        code: "token_scope_forbidden"
      })
    )
    |> halt()
  end
end
