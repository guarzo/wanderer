defmodule WandererApp.ExternalEvents.Discord.Mentions do
  @moduledoc """
  Renders configured `MapDiscordWebhook.mention_targets` into Discord's two
  mention mechanisms: a `content` prefix that actually pings, and the
  `allowed_mentions` allowlist that makes doing so safe.

  Deliberately does not observe anything — no voice state, no map presence.
  Targets come only from what a map operator configured; see the design
  doc's "Why not VoiceParticipants".
  """

  # Guild snowflakes are 17-20 decimal digits. This is the single definition of
  # a well-formed mention target; `MapDiscordWebhook.ValidateMentionTargets`
  # delegates here. The dependency runs resource -> Mentions and must not be
  # reversed: this module stays free of any Ash compile-time dependency.
  @target_regex ~r/^(user|role):(\d{17,20})$/

  @doc """
  Whether `target` is a well-formed `"user:<id>"` or `"role:<id>"` mention
  target. Exposed so callers (and the resource-side validation) can check a
  single value without going through the list-shaped functions below.
  """
  @spec valid_target?(String.t()) :: boolean()
  def valid_target?(target) when is_binary(target), do: Regex.match?(@target_regex, target)
  def valid_target?(_), do: false

  @doc """
  Renders `targets` into a `content` prefix: `"user:123"` -> `"<@123>"`,
  `"role:456"` -> `"<@&456>"`, joined by spaces. `[]` -> `nil`, so callers can
  feed this straight to `VoiceParticipants.prepend_to_messages/2`, whose
  no-prefix case is also `nil`. Any entry that fails `valid_target?/1` is
  silently dropped rather than raising — malformed data should never turn
  into a delivery failure.
  """
  @spec prefix([String.t()]) :: String.t() | nil
  def prefix([]), do: nil

  def prefix(targets) do
    targets
    |> Enum.map(&render/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      rendered -> Enum.join(rendered, " ")
    end
  end

  @doc """
  Builds the `allowed_mentions` object for a Discord message body. ALWAYS
  includes `"parse" => []`, even for `[]` — an empty allowlist with no parse
  modes is what makes an unconfigured map safe to post to (see the design
  doc's "Mention injection is a real risk"). Invalid entries are dropped, the
  same as `prefix/1`.
  """
  @spec allowed_mentions([String.t()]) :: map()
  def allowed_mentions(targets) do
    {users, roles} =
      targets
      |> Enum.filter(&valid_target?/1)
      |> Enum.reduce({[], []}, fn target, {users, roles} ->
        case String.split(target, ":", parts: 2) do
          ["user", id] -> {[id | users], roles}
          ["role", id] -> {users, [id | roles]}
        end
      end)

    %{"parse" => [], "users" => Enum.reverse(users), "roles" => Enum.reverse(roles)}
  end

  defp render(target) do
    case Regex.run(@target_regex, target) do
      [_, "user", id] -> "<@#{id}>"
      [_, "role", id] -> "<@&#{id}>"
      _ -> nil
    end
  end
end
