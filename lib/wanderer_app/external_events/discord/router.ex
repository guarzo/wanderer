defmodule WandererApp.ExternalEvents.Discord.Router do
  @moduledoc """
  Chooses the destination webhook for a single killmail.

  Rules, evaluated in order (design section 4):

  | # | Condition                                          | Destination       |
  |---|----------------------------------------------------|-------------------|
  | 1 | System in `excluded_systems`, verdict `:not_involved` | drop            |
  | 2 | `wh_only` on, system not a wormhole, `:not_involved`  | drop            |
  | 3 | `{:involved, _}`                                   | character webhook |
  | 4 | Otherwise (`:not_involved` past 1-2, or `:unknown`) | system webhook   |

  Rules 1 and 2 are carve-outs: a kill involving the pilots or corporations the
  character channel is for is always interesting, wherever it happened, so the
  exclusion and wormhole-only filters do not apply to it.

  ## `:unknown` is not `:not_involved`

  Only `:not_involved` — a positive finding that this kill is not ours — enables
  rules 1 and 2. `:unknown` means `Matcher` could not determine involvement
  (the tracked-character set was unavailable, or the payload carried no attacker
  data). It bypasses rules 1 and 2 and lands on the **system** webhook.

  This distinction is the whole point. Folding `:unknown` into `:not_involved`
  would mean a cache outage silently drops every k-space kill on a map with the
  default `wh_only`, and the only trace is one log line. Delivering a kill to
  the system channel that a filter might have excluded is the cheaper error.

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

  ## Route alerts have their own destination

  `route_destination/1` resolves a route alert to the `:route` webhook,
  falling back to the `:system` webhook when no `:route` row exists — the same
  fallback pattern rule 3 uses for `:character`. Existing maps therefore need
  no configuration change to keep receiving route alerts once the feature is
  enabled.

  A route alert *is* the chain topology: the path field names every system a
  scout has found, in order, from the map's home system to Jita. There is no
  redacted version of that message. A configured-but-disabled `:route` webhook
  therefore drops rather than falling back to `:system` — the same
  disabled-drops-never-reroutes rule above, for the same reason: silence must
  mean silence, not misdirection into a channel the user did not pick for a
  message this sensitive.
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
    # Only a positive "this kill is not ours" opens the filters. `:unknown` must
    # not, or an undetermined verdict is indistinguishable from an excluded one.
    filterable? = verdict == :not_involved
    system_id = kill["solar_system_id"]

    cond do
      filterable? and system_id in (notification.excluded_systems || []) ->
        :drop

      filterable? and notification.wh_only and not SystemClass.wormhole_system?(system_id) ->
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

  @doc """
  Resolves a route alert to a destination. `notification` must have
  `:webhooks` loaded.
  """
  @spec route_destination(struct()) :: {:ok, struct()} | :drop
  def route_destination(notification) do
    usable(webhook(notification, :route) || webhook(notification, :system))
  end

  # Guarded on `is_list`: `:webhooks` is a relationship, so an unloaded
  # notification carries `%Ash.NotLoaded{}` here. Reading `.role` off that would
  # raise on the dispatch path; treating it as "no destination" drops instead,
  # which is the conservative direction.
  defp webhook(%{webhooks: webhooks}, role) when is_list(webhooks) do
    Enum.find(webhooks, &(&1.role == role))
  end

  defp webhook(_notification, _role), do: nil

  defp usable(nil), do: :drop
  defp usable(%{enabled?: false}), do: :drop
  defp usable(webhook), do: {:ok, webhook}
end
