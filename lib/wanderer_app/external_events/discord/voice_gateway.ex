defmodule WandererApp.ExternalEvents.Discord.VoiceGateway do
  @moduledoc """
  Boot-time starter for the Nostrum gateway connection behind voice-mention
  kill notifications.

  Not a running process: `start_link/1` attempts the start and returns
  `:ignore`, so a failing gateway can never take the supervision tree with
  it — the invariant is that voice tagging degrades, kill delivery does
  not. Nostrum's own application supervises the connection from then on
  (reconnect/resume included).

  Startup outcomes are the one-time signals an operator needs: `info` on
  success, `error` on failure, one `warning` for partial configuration.
  After boot, per-lookup health is visible via the `mention_count`
  telemetry measurement and `VoiceParticipants` debug logs.
  """

  require Logger

  alias WandererApp.Env

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Nothing to restart: start_link always returns :ignore.
      restart: :temporary
    }
  end

  def start_link(_opts) do
    cond do
      Env.discord_voice_mentions_enabled?() ->
        start_gateway()

      partial_config?() ->
        Logger.warning(
          "[VoiceGateway] voice mentions disabled: set both DISCORD_BOT_TOKEN " <>
            "and a valid positive-integer DISCORD_GUILD_ID"
        )

      true ->
        :ok
    end

    :ignore
  end

  defp start_gateway do
    # Seam: tests inject a starter fun via app env to exercise the fail-open
    # contract without a live token; production starts Nostrum for real.
    starter =
      Application.get_env(
        :wanderer_app,
        :discord_gateway_starter,
        &Application.ensure_all_started/1
      )

    case starter.(:nostrum) do
      {:ok, _apps} ->
        Logger.info(
          "[VoiceGateway] Discord gateway started; voice mentions enabled " <>
            "for guild #{Env.discord_guild_id()}"
        )

      {:error, reason} ->
        Logger.error(
          "[VoiceGateway] Discord gateway failed to start: #{inspect(reason)} — " <>
            "kill notifications continue without voice mentions"
        )
    end
  end

  # Reached only when the feature predicate is false, so any raw value —
  # token without guild, guild without token, blank token, malformed guild
  # id — means the operator tried to configure this and something is missing
  # or unusable. Raw values, not Env: Env normalizes blank/malformed to nil,
  # which is exactly the difference between "unset" and "set but broken".
  defp partial_config? do
    external = Application.get_env(:wanderer_app, :external_events, [])

    Keyword.get(external, :discord_bot_token) != nil or
      Keyword.get(external, :discord_guild_id) != nil
  end
end
