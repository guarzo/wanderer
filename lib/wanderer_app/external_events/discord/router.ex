defmodule WandererApp.ExternalEvents.Discord.Router do
  @moduledoc """
  Chooses the destination webhook for a single killmail.

  Rules, evaluated in order (design section 4):

  | # | Condition                                          | Destination       |
  |---|----------------------------------------------------|-------------------|
  | 1 | System in `excluded_systems`, **not** involved     | drop              |
  | 2 | `wh_only` on, system not a wormhole, not involved  | drop              |
  | 3 | Involved                                           | character webhook |
  | 4 | Otherwise                                          | system webhook    |

  Rules 1 and 2 are carve-outs: a kill involving your own pilots is always
  interesting, wherever it happened, so the exclusion and wormhole-only filters
  do not apply to it.

  ## Fallback

  When no `:character` webhook row exists, rule 3 resolves to the **system**
  webhook. Every existing single-webhook configuration therefore keeps working
  with no user action, and the character channel is purely opt-in.

  ## Disabled destinations drop; they do not reroute

  If the webhook a kill routes to is itself disabled — by the user or by the
  consecutive-failure threshold — the kill is dropped, **not** sent to the other
  channel. Disabling a channel must mean silence for that class of kill, not
  silent misdirection into a channel the user did not choose. For a public
  character channel that is a privacy question, not just a preference.

  Do not "fix" this into a reroute. `RouterTest` asserts it deliberately.
  """

  alias WandererApp.SystemClass

  @type verdict :: WandererApp.ExternalEvents.Discord.Matcher.verdict()

  @doc """
  Resolves one killmail to a destination. `notification` must have `:webhooks`
  loaded.
  """
  @spec route(map(), struct(), verdict()) :: {:ok, struct()} | :drop
  def route(kill, notification, verdict) do
    involved? = match?({:involved, _}, verdict)
    system_id = kill["solar_system_id"]

    cond do
      not involved? and system_id in (notification.excluded_systems || []) ->
        :drop

      not involved? and notification.wh_only and not SystemClass.wormhole_system?(system_id) ->
        :drop

      involved? ->
        # Fallback to the system webhook when the character channel is not
        # configured at all. `nil` here means "not configured"; a configured but
        # disabled row is a different thing and is handled by `usable/1`.
        usable(webhook(notification, :character) || webhook(notification, :system))

      true ->
        usable(webhook(notification, :system))
    end
  end

  defp webhook(notification, role) do
    notification.webhooks
    |> List.wrap()
    |> Enum.find(&(&1.role == role))
  end

  defp usable(nil), do: :drop
  defp usable(%{enabled?: false}), do: :drop
  defp usable(webhook), do: {:ok, webhook}
end
