defmodule WandererApp.ConfigHelpers do
  def get_var_from_path_or_env(config_dir, var_name, default \\ nil) do
    var_path = Path.join(config_dir, var_name)

    if File.exists?(var_path) do
      File.read!(var_path) |> String.trim()
    else
      System.get_env(var_name, default)
    end
  end

  def get_int_from_path_or_env(config_dir, var_name, default \\ nil) do
    var = get_var_from_path_or_env(config_dir, var_name)

    case var do
      nil ->
        default

      var ->
        case Integer.parse(var) do
          {int, ""} -> int
          _ -> raise "Config variable #{var_name} must be an integer. Got #{var}"
        end
    end
  end

  @fly_sentinel "NOT_FLY_APP"

  @doc """
  Resolves the external hostname.

  `FLY_APP_NAME` is a **fallback**, not an override. An operator who sets
  `PHX_HOST` explicitly gets it even on Fly, which is what makes a custom
  domain — and therefore a working EVE OAuth callback — possible. When
  `PHX_HOST` is unset the behaviour is unchanged from before this function
  existed.
  """
  def resolve_host(phx_host, fly_app_name)

  def resolve_host(phx_host, _fly_app_name) when is_binary(phx_host) and phx_host != "",
    do: phx_host

  def resolve_host(_phx_host, fly_app_name)
      when is_binary(fly_app_name) and fly_app_name != "" and fly_app_name != @fly_sentinel,
      do: "#{fly_app_name}.fly.dev"

  def resolve_host(_phx_host, _fly_app_name), do: "localhost"

  @doc """
  Resolves the externally-visible base URL.

  Same rule as `resolve_host/2`: an explicit `WEB_APP_URL` always wins. On Fly
  without one, https is assumed because the Fly edge terminates TLS.
  """
  def resolve_web_app_url(web_app_url, host, port, fly_app_name)

  def resolve_web_app_url(web_app_url, _host, _port, _fly_app_name)
      when is_binary(web_app_url) and web_app_url != "",
      do: web_app_url

  def resolve_web_app_url(_web_app_url, host, _port, fly_app_name)
      when is_binary(fly_app_name) and fly_app_name != "" and fly_app_name != @fly_sentinel,
      do: "https://#{host}"

  def resolve_web_app_url(_web_app_url, host, port, _fly_app_name),
    do: "http://#{host}:#{port}"
end
