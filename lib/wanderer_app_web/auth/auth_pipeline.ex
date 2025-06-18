defmodule WandererAppWeb.Auth.AuthPipeline do
  @moduledoc """
  Unified authentication pipeline that supports multiple authentication strategies.

  This plug replaces the various auth plugs with a configurable, behavior-driven
  approach. Strategies are tried in order until one succeeds or all fail.

  ## Usage

      # In your router pipeline
      plug WandererAppWeb.Auth.AuthPipeline,
        strategies: [:map_api_key, :jwt],
        required: true,
        assign_as: :current_user
        
      # With feature flags
      plug WandererAppWeb.Auth.AuthPipeline,
        strategies: [:map_api_key],
        feature_flag: :public_api_disabled,
        required: false
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @default_opts [
    strategies: [],
    required: true,
    assign_as: nil,
    feature_flag: nil,
    error_status: 401,
    error_message: "Authentication required"
  ]

  @impl Plug
  def init(opts) do
    opts = Keyword.merge(@default_opts, opts)

    # Validate strategies exist
    Enum.each(opts[:strategies], fn strategy ->
      unless strategy_module(strategy) do
        raise ArgumentError, "Unknown authentication strategy: #{inspect(strategy)}"
      end
    end)

    opts
  end

  @impl Plug
  def call(conn, opts) do
    # Check feature flag if configured
    if check_feature_flag(opts[:feature_flag]) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "This feature is disabled"}))
      |> halt()
    else
      authenticate_with_strategies(conn, opts)
    end
  end

  defp authenticate_with_strategies(conn, opts) do
    strategies = opts[:strategies]

    case try_strategies(conn, strategies, opts) do
      {:ok, conn, auth_data} ->
        if opts[:assign_as] do
          assign(conn, opts[:assign_as], auth_data)
        else
          conn
        end

      {:error, _reason} ->
        if opts[:required] do
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(opts[:error_status], Jason.encode!(%{error: opts[:error_message]}))
          |> halt()
        else
          conn
        end
    end
  end

  defp try_strategies(_conn, [], _opts), do: {:error, :no_strategies}

  defp try_strategies(conn, [strategy | rest], opts) do
    strategy_mod = strategy_module(strategy)
    strategy_opts = opts[strategy] || []

    case strategy_mod.authenticate(conn, strategy_opts) do
      {:ok, conn, auth_data} ->
        Logger.debug("Authentication successful with strategy: #{strategy}")
        {:ok, conn, auth_data}

      :skip ->
        # Strategy doesn't apply, try next
        try_strategies(conn, rest, opts)

      {:error, reason} ->
        Logger.debug("Authentication failed with strategy #{strategy}: #{inspect(reason)}")
        # Try next strategy
        try_strategies(conn, rest, opts)
    end
  end

  defp strategy_module(strategy) do
    case strategy do
      :jwt -> WandererAppWeb.Auth.Strategies.JwtStrategy
      :map_api_key -> WandererAppWeb.Auth.Strategies.MapApiKeyStrategy
      :acl_key -> WandererAppWeb.Auth.Strategies.AclKeyStrategy
      :character_jwt -> WandererAppWeb.Auth.Strategies.CharacterJwtStrategy
      _ -> nil
    end
  end

  defp check_feature_flag(nil), do: false

  defp check_feature_flag(flag) do
    case flag do
      :public_api_disabled ->
        Application.get_env(:wanderer_app, :public_api_disabled) == "true"

      :character_api_disabled ->
        Application.get_env(:wanderer_app, :character_api_disabled) == "true"

      :zkill_preload_disabled ->
        Application.get_env(:wanderer_app, :zkill_preload_disabled) == "true"

      _ ->
        false
    end
  end
end
