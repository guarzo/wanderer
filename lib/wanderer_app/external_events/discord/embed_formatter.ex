defmodule WandererApp.ExternalEvents.Discord.EmbedFormatter do
  @moduledoc """
  Turns flattened killmails into Discord message bodies.

  Only `killmail_id`, `kill_time` and `solar_system_id` are guaranteed present
  on a killmail (see `WandererApp.Kills.MessageHandler`), so every other field
  is rendered defensively.

  Each kill arrives paired with the involvement verdict from
  `WandererApp.ExternalEvents.Discord.Matcher.involvement/3`. The verdict, not
  the payload, decides the colour and the author line.
  """

  require Logger

  alias WandererApp.ExternalEvents.Discord.Mentions
  alias WandererApp.ExternalEvents.Discord.SystemName
  alias WandererApp.SystemClass

  @type verdict ::
          {:involved, :victim} | {:involved, :attacker} | :not_involved | :unknown

  @max_embeds_per_message 10
  @max_kills_per_event 30

  # Discord's documented embed limits. Exceeding any of them is a 400, not a
  # truncation, and a 400 counts as a delivery failure — so ten kills in a
  # system whose map-local name is long enough would trip
  # `@max_consecutive_failures` and auto-disable the destination. `custom_name`
  # and `temporary_name` carry no length constraint on `MapSystem`, so the
  # title bound is reachable from ordinary user input, not just malice.
  @max_title_length 256
  # The route path renders as the description. Its HOP COUNT has always been
  # bounded — route_max_jumps caps at 20 (`map_discord_notification.ex:182-191`),
  # so a path is at most 21 systems, and the collapsed rendering is shorter still.
  # What is unbounded is each hop's NAME: `custom_name`/`temporary_name` carry no
  # length constraint on `MapSystem`, so an uncollapsed chain of long-named
  # systems reaches this bound from ordinary user input, and exceeding it is a
  # 400, not a truncation.
  @max_description_length 4096
  # The per-message ceiling counts the text of every embed in the message
  # together, so it can be breached by a batch that satisfies each field bound
  # individually.
  @max_message_text 6000
  # Discord's author-name bound. Reachable from ordinary input: the route
  # embed's author line embeds a `Character.name`, which carries no length
  # constraint, and exceeding this is a 400 — a delivery failure, not a
  # truncation.
  @max_author_length 256

  @color_loss 0xE74C3C
  @color_kill 0x2ECC71

  # Route alerts are logistics, not combat, and they share a channel with kill
  # embeds — so they deliberately sit outside the kill palette's hues. Red,
  # green, yellow and orange are all spoken for by @color_loss, @color_kill and
  # the @value_colors tiers below; blue is unclaimed, and it is also The Forge's
  # own colour, which is where the alert always points.
  #
  # The two states are one hue at two lightness steps rather than two hues: the
  # family should read as "route" at a glance, with `:improved` legibly the
  # quieter of the two. An `:improved` alert also carries no ping (see
  # `route_ping/2`), so the dimmer stripe matches how loud the message is.
  @color_route_opened 0x2E9BD6
  @color_route_improved 0x2A6E90

  # What `Evaluator`'s pinned @solver_settings actually guarantee, in the
  # reader's language rather than the config's. This is the whole value of the
  # alert — that the route needs no scouting — and it was previously invisible,
  # so a reader had to know the internals to trust the message.
  #
  # Deliberately makes NO ship-class claim: `include_cruise: true` means a
  # cruiser-sized hole qualifies, so "freighter-safe" would be false. The three
  # exclusions are stated plainly and the reader judges their own hull.
  # `route_guarantee_settings/0` and its test pin this string to the settings it
  # describes, because drift here turns a safety guarantee into a lie.
  @route_guarantee "highsec only · no EOL · no crit · no frigate holes"

  # ISK tiers for kills involving nobody we track, largest first.
  #
  # NOTE: @color_kill (0x2ECC71) and the 10M tier (0x00FF00) are both green.
  # They are *distinct meanings* that happen to share a hue — "you killed
  # something" versus "a bystander kill worth 10M-100M" — and they are
  # disambiguated by the author line, which is present on a kill and absent on
  # an uninvolved embed. Do not collapse these two constants into one.
  @value_colors [
    {5_000_000_000, 0xFF0000},
    {1_000_000_000, 0xFF6600},
    {100_000_000, 0xFFFF00},
    {10_000_000, 0x00FF00}
  ]
  @color_default 0x808080

  @zkill_base "https://zkillboard.com"
  @image_base "https://images.evetech.net"
  @thumbnail_size 1024

  # ISK magnitude table, largest first: {threshold, divisor, unit, next_unit}.
  # `next_unit` is what a value promotes to when rounding pushes it to >= 1000
  # within its own unit. It is nil at the top so T clamps instead of promoting,
  # which makes self-promotion impossible by construction.
  @isk_units [
    {1_000_000_000_000, 1_000_000_000_000, "T", nil},
    {1_000_000_000, 1_000_000_000, "B", "T"},
    {1_000_000, 1_000_000, "M", "B"},
    {1_000, 1_000, "K", "M"}
  ]

  @doc """
  The per-event kill cap. Exposed so callers can tell which kills were actually
  formatted — the dispatcher must not mark kills past this cap as attempted,
  since they are never rendered into a message.
  """
  @spec max_kills_per_event() :: pos_integer()
  def max_kills_per_event, do: @max_kills_per_event

  @spec format_batch([{map(), verdict()}], String.t() | nil) :: [map()]
  def format_batch([], _system_name), do: []

  def format_batch(entries, system_name) do
    total = length(entries)
    shown = Enum.take(entries, @max_kills_per_event)
    overflow = total - length(shown)

    messages =
      shown
      |> Enum.map(fn {kill, verdict} -> format_kill(kill, verdict, system_name) end)
      |> chunk_messages()
      |> Enum.map(&%{"embeds" => &1})

    append_overflow(messages, overflow)
  end

  @doc """
  Formats a route-alert transition (design §"Message, mentions, and privacy")
  into Discord message chunks. `opts[:mention_targets]` are guild-scoped
  snowflake strings (`"user:123"` / `"role:456"`); pinging is gated on
  `WandererApp.Env.discord_mentions_enabled?/0` and fires only for `:opened`
  (design: "Ping on open only" — an "improved" update posts with no `content`,
  keeping the ping meaningful on a chain under active scanning).
  """
  @spec format_route_alert(map(), keyword()) :: [map()]
  def format_route_alert(alert, opts) do
    embed = route_embed(alert)
    mention_targets = Keyword.get(opts, :mention_targets, [])

    message =
      case route_ping(alert.kind, mention_targets) do
        nil ->
          %{"embeds" => [embed]}

        {content, allowed_mentions} ->
          %{"embeds" => [embed], "content" => content, "allowed_mentions" => allowed_mentions}
      end

    [message]
  end

  defp route_embed(alert) do
    %{
      "author" => route_author(alert),
      "title" => truncate(route_title(alert), @max_title_length),
      "url" => map_url(alert.map_id),
      "color" => route_color(alert.kind),
      "description" => truncate(route_path_text(alert), @max_description_length),
      "footer" => %{"text" => @route_guarantee},
      # Renders client-side as the reader's local time. A qualifying route is
      # perishable — the chain it runs through can roll or die within the hour —
      # so "how old is this alert" is part of the decision, not metadata.
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> drop_nils()
  end

  # The scout's portrait rides in the author line rather than the thumbnail
  # slot: a 72px face would make a logistics alert louder than the kill embeds
  # sharing its channel, and would squeeze the path text on a long chain.
  #
  # `alert` may carry no `:scout` key at all — the watcher only adds one when
  # attribution resolved — so this reads defensively rather than matching.
  defp route_author(alert) do
    base = %{"name" => truncate(route_author_name(alert), @max_author_length)}

    case Map.get(alert, :scout) do
      %{eve_id: eve_id} when is_binary(eve_id) ->
        Map.put(base, "icon_url", "#{@image_base}/characters/#{eve_id}/portrait?size=64")

      _ ->
        base
    end
  end

  defp route_author_name(alert) do
    case Map.get(alert, :scout) do
      %{name: name} when is_binary(name) and name != "" ->
        "#{route_kind_label(alert.kind)} · scouted by #{name}"

      _ ->
        route_kind_label(alert.kind)
    end
  end

  defp route_kind_label(:opened), do: "Route opened"
  defp route_kind_label(:improved), do: "Route shortened"

  defp route_color(:opened), do: @color_route_opened
  defp route_color(:improved), do: @color_route_improved

  # Origin and destination live in the TITLE, not only in the description,
  # because a mobile push preview shows the title and nothing else. The origin
  # resolves map-local first (see `route_system_name/2`), so a map that names its
  # home "Home" reads as "Home → Jita" with no special-casing here — that naming
  # decision belongs to the map, not to this formatter.
  #
  # The delta clause comes first and everything else falls through to the plain
  # total: that covers `:opened` (which has no previous count by construction)
  # and an `:improved` alert whose previous count is somehow absent, without
  # writing the same title string twice. Two copies of one format string is how
  # the separator drifts in one place and not the other.
  #
  # The delta itself is why `previous_jumps` is threaded down from the watcher's
  # transition table at all: 3 → 2 is a shrug and 7 → 2 is news, and the bare
  # "2 jumps" of the old format could not tell them apart.
  defp route_title(%{kind: :improved, previous_jumps: previous} = alert)
       when is_integer(previous) do
    "#{route_origin_name(alert)} → #{route_destination_name(alert)} · #{previous} → #{pluralize(alert.jumps, "jump")}"
  end

  defp route_title(alert) do
    "#{route_origin_name(alert)} → #{route_destination_name(alert)} · #{pluralize(alert.jumps, "jump")}"
  end

  defp route_origin_name(alert), do: route_system_name(alert, List.first(alert.path))

  # Canonical, with no parenthetical: a mobile push preview shows the title and
  # nothing else, so it stays as short as it can while still naming a system the
  # reader can act on. The origin keeps its map-local name on the same line — it
  # is the map's home and the map's own word for it is the right one — so the two
  # halves of the title deliberately speak different languages.
  defp route_destination_name(alert) do
    destination = List.last(alert.path)
    SystemName.canonical_name(destination) || route_system_name(alert, destination)
  end

  defp pluralize(1, unit), do: "1 #{unit}"
  defp pluralize(count, unit), do: "#{count} #{unit}s"

  # The path stops naming hops the moment it leaves the chain FOR GOOD.
  #
  # Inside the chain, a map-local tag ("3") IS the name the reader navigates by
  # and the canonical J-name is useless, so chain hops keep `route_system_name/2`
  # untouched. Once the route is gating and will not re-enter a hole, the reverse
  # holds: those hops are gates, not decisions, and the reader has to type the
  # first of them into autopilot — so it gets the name CCP knows it by, with the
  # map's tag alongside. Everything between it and the destination collapses to a
  # gate count.
  #
  # The anchor is the start of the FINAL k-space run, deliberately not
  # `alert.exit_system`. `find_exit_system/2` returns the FIRST non-wormhole hop,
  # and `path_qualifies?/2` (`evaluator.ex:102`) admits wormhole systems at any
  # position — the route graph is the gate graph plus every map connection
  # (`map_routes.ex:120-140`), so a two-chain route may gate through k-space,
  # take a second hole, and come out again. Anchoring on the first exit would
  # delete those chain systems from the message and count their wormhole jumps
  # as "gates". Scanning back from the destination cannot: every hop it
  # collapses is a gate by construction.
  #
  # The destination is bolded because it is the one hop the reader is scanning
  # for; every other token is context for getting there.
  defp route_path_text(alert) do
    path = alert.path
    last_index = length(path) - 1
    start = kspace_tail_start(path)

    cond do
      # No k-space tail at all: the destination could not be classified. Renders
      # exactly as it did before this change rather than guessing.
      start > last_index ->
        Enum.map_join(path, " → ", fn system_id ->
          name = route_system_name(alert, system_id)
          if system_id == List.last(path), do: "**#{name}**", else: name
        end)

      # The tail is the destination alone — nothing between them to collapse, and
      # "Jita · 0 gates → **Jita**" would say it twice.
      start == last_index ->
        chain = Enum.map(Enum.take(path, last_index), &route_system_name(alert, &1))
        Enum.join(chain ++ ["**#{kspace_name(alert, List.last(path))}**"], " → ")

      true ->
        chain = Enum.map(Enum.take(path, start), &route_system_name(alert, &1))
        gates = pluralize(last_index - start, "gate")
        exit_token = "#{kspace_name(alert, Enum.at(path, start))} · #{gates}"

        Enum.join(chain ++ [exit_token, "**#{kspace_name(alert, List.last(path))}**"], " → ")
    end
  end

  # Index of the first hop in the path's final unbroken run of k-space systems,
  # or `length(path)` when the last hop is not k-space (which leaves the caller
  # nothing to collapse).
  defp kspace_tail_start(path) do
    tail =
      path
      |> Enum.reverse()
      |> Enum.take_while(&kspace_hop?/1)
      |> length()

    length(path) - tail
  end

  # Unclassifiable systems answer false — "not part of the gating tail" — so an
  # unresolvable hop shortens the collapse rather than being swallowed by it. The
  # message then shows MORE than it needed to, which is the safe direction: the
  # unsafe one silently deletes a chain system and calls its hole a gate.
  defp kspace_hop?(system_id) do
    case WandererApp.CachedInfo.get_system_static_info(system_id) do
      {:ok, %{system_class: class}} -> not SystemClass.wormhole?(class)
      _ -> false
    end
  rescue
    _ -> false
  end

  # A k-space system in EVE's language rather than the map's, with the map's tag
  # kept alongside it. Used for the two hops a reader carries out of Discord and
  # into the client: where they start gating, and where they stop.
  #
  # This is NOT the "fix" that `SystemName`'s moduledoc warns off. That warning
  # protects the privacy boundary BETWEEN ROLES — map-local chain naming must not
  # reach the public character-kill channel. Route alerts go only to an opt-in
  # `:route` webhook that has already consented to full chain topology
  # (`router.ex:48-58`), and this adds the canonical name rather than removing
  # the tag, so it discloses nothing the message did not already carry.
  #
  # The parenthetical is dropped when it would add nothing: a system that is not
  # on the map has no tag, and one tagged with its own canonical name would read
  # "Amarr (Amarr)". When the canonical lookup fails there is no bridge to build,
  # so this degrades to exactly what the old code rendered — the tag alone. That
  # is the best name available, not a fabricated one.
  defp kspace_name(alert, system_id) do
    canonical = SystemName.canonical_name(system_id)
    tag = SystemName.map_local_name(alert.map_id, system_id)

    case {canonical, tag} do
      {nil, _} -> route_system_name(alert, system_id)
      {name, nil} -> name
      # Repeated variable: this clause matches only when the two are equal.
      {name, name} -> name
      {name, tag} -> "#{name} (#{tag})"
    end
  end

  # Makes the embed title a link back to the map that raised the alert, so the
  # message is not a dead end.
  #
  # Returns nil rather than a best-effort URL on every failure path. A malformed
  # `url` is a 400 from Discord, not a broken link in the client — and a 400 is
  # a delivery failure, which counts toward `@max_consecutive_failures` and can
  # auto-disable the destination. `Env.base_url/0` defaults to the literal
  # placeholder "<BASE_URL>" when unconfigured, so the scheme check is load-
  # bearing, not defensive padding.
  defp map_url(map_id) when is_binary(map_id) do
    with %URI{scheme: scheme, host: host} <- URI.parse(WandererApp.Env.base_url()),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "",
         {:ok, %{slug: slug}} when is_binary(slug) <- WandererApp.Api.Map.by_id(map_id) do
      "#{String.trim_trailing(WandererApp.Env.base_url(), "/")}/#{slug}"
    else
      _ -> nil
    end
  rescue
    error ->
      Logger.debug(fn ->
        "[EmbedFormatter] map url lookup failed for #{map_id}: #{inspect(error)}"
      end)

      nil
  end

  defp map_url(_map_id), do: nil

  @doc """
  The `Evaluator` settings that `@route_guarantee` claims to describe, as
  `{key, required_value}` pairs. Exposed so a test can assert the string and the
  solver cannot drift apart — the footer is a safety guarantee, and a stale one
  is worse than none.
  """
  @spec route_guarantee_settings() :: keyword()
  def route_guarantee_settings,
    do: [include_eol: false, include_mass_crit: false, include_frig: false]

  @doc false
  @spec route_guarantee() :: String.t()
  def route_guarantee, do: @route_guarantee

  # Literal :route, per SystemName's map-local-names privacy boundary — never
  # threaded through as a variable. See the Router moduledoc's "Role
  # resolution is literal" note and SystemName's own moduledoc.
  defp route_system_name(_alert, nil), do: "Unknown system"

  defp route_system_name(alert, solar_system_id) do
    SystemName.display_name(alert.map_id, solar_system_id, :route) || "Unknown system"
  end

  defp route_ping(:improved, _mention_targets), do: nil
  defp route_ping(:opened, []), do: nil

  defp route_ping(:opened, mention_targets) do
    if WandererApp.Env.discord_mentions_enabled?() do
      case Mentions.prefix(mention_targets) do
        nil -> nil
        content -> {content, Mentions.allowed_mentions(mention_targets)}
      end
    end
  end

  # Two bounds at once: at most @max_embeds_per_message embeds, and at most
  # @max_message_text characters of embed text across them. Each embed is
  # already within the per-field limits by construction, so a single embed can
  # never exceed the message total on its own and this always terminates.
  defp chunk_messages(embeds) do
    embeds
    |> Enum.reduce([], fn embed, acc ->
      size = embed_text_length(embed)

      case acc do
        [{chunk, chunk_size} | rest]
        when length(chunk) < @max_embeds_per_message and chunk_size + size <= @max_message_text ->
          [{[embed | chunk], chunk_size + size} | rest]

        _ ->
          [{[embed], size} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {chunk, _size} -> Enum.reverse(chunk) end)
  end

  # Discord counts title, description, field names and values, footer text and
  # author name toward the per-message total. URLs and colours do not count.
  defp embed_text_length(embed) do
    fields =
      embed
      |> Map.get("fields", [])
      |> Enum.map(&(String.length(&1["name"] || "") + String.length(&1["value"] || "")))
      |> Enum.sum()

    String.length(embed["title"] || "") +
      String.length(embed["description"] || "") +
      String.length(get_in(embed, ["footer", "text"]) || "") +
      String.length(get_in(embed, ["author", "name"]) || "") +
      fields
  end

  defp append_overflow(messages, overflow) when overflow <= 0, do: messages

  defp append_overflow(messages, overflow) do
    {init, [last]} = Enum.split(messages, -1)
    init ++ [Map.put(last, "content", "…and #{overflow} more kills not shown.")]
  end

  @spec format_kill(map(), verdict(), String.t() | nil) :: map()
  def format_kill(kill, verdict, system_name) do
    %{
      "title" => truncate(title(kill, system_name), @max_title_length),
      "url" => zkill_url(kill["killmail_id"]),
      "color" => color(verdict, kill["total_value"]),
      "description" => full_description(kill),
      "fields" => fields(kill)
    }
    |> maybe_put("author", author(kill, verdict))
    |> maybe_put("thumbnail", thumbnail(kill))
    |> maybe_put("footer", footer(kill))
    |> drop_nils()
  end

  # Ellipsis rather than a hard cut, so a clipped name reads as clipped instead
  # of as a differently-named system. Measured in graphemes, matching how
  # Discord counts: a name of emoji or non-Latin script would otherwise pass a
  # byte-based check and still be rejected.
  defp truncate(nil, _limit), do: nil

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) <= limit,
      do: text,
      else: String.slice(text, 0, limit - 1) <> "…"
  end

  defp title(kill, system_name) do
    ship = present(kill["victim_ship_name"]) || "Unknown ship"
    system = present(system_name) || "Unknown system"
    "#{ship} destroyed in #{system}"
  end

  defp color({:involved, :victim}, _value), do: @color_loss
  defp color({:involved, :attacker}, _value), do: @color_kill

  # `:unknown` renders exactly like `:not_involved`. Both mean "we cannot label
  # this a kill or a loss", and an `:unknown` embed is already in the system
  # channel — colouring it as ours would be a claim the verdict does not support.
  defp color(verdict, value) when verdict in [:not_involved, :unknown] and is_number(value) do
    Enum.find_value(@value_colors, @color_default, fn {threshold, color} ->
      if value >= threshold, do: color
    end)
  end

  defp color(verdict, _value) when verdict in [:not_involved, :unknown], do: @color_default

  # Omitted entirely when we are not involved, or could not tell: neither "Kill"
  # nor "Loss" would be a true statement about the fight.
  defp author(_kill, verdict) when verdict in [:not_involved, :unknown], do: nil
  defp author(kill, {:involved, :victim}), do: author_line("Loss", kill["victim_corp_id"])
  defp author(kill, {:involved, :attacker}), do: author_line("Kill", kill["final_blow_corp_id"])

  defp author_line(label, corp_id) when is_integer(corp_id) or is_binary(corp_id) do
    %{
      "name" => label,
      "icon_url" => "#{@image_base}/corporations/#{corp_id}/logo?size=64"
    }
  end

  defp author_line(label, _corp_id), do: %{"name" => label}

  # Prose, not a field grid. Each clause carries its own leading separator and
  # returns nil when the underlying data is absent, so an NPC kill simply reads
  # "X lost their Y." rather than naming a placeholder attacker.
  defp description(kill) do
    [
      victim_clause(kill),
      final_blow_clause(kill),
      top_damage_clause(kill),
      others_clause(kill)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
    |> Kernel.<>(".")
  end

  # The notable-items section is PRE-BUDGETED rather than left to `truncate/2`.
  # `truncate/2` cuts at an arbitrary grapheme, which on a bullet list emits a
  # half-written item name or a bare "• ". So the base description is truncated
  # first, and only whole item lines that still fit are appended. If not even
  # one fits, the header is omitted too — never a heading with nothing under it.
  #
  # A dropped line is silent: the ISK threshold already makes this a top-N, not
  # an inventory. The `truncate/2` call stays because it still guards the base.
  defp full_description(kill) do
    base = truncate(description(kill), @max_description_length)
    base <> notable_items_section(kill["notable_items"], String.length(base))
  end

  @notable_items_header "\n\n**Notable Items:**\n"

  defp notable_items_section(items, used) when is_list(items) do
    budget = @max_description_length - used - String.length(@notable_items_header)

    case items |> Enum.flat_map(&item_line/1) |> take_fitting(budget) do
      [] -> ""
      lines -> @notable_items_header <> Enum.join(lines, "\n")
    end
  end

  defp notable_items_section(_items, _used), do: ""

  defp take_fitting(lines, budget) do
    {kept, _used} =
      Enum.reduce_while(lines, {[], 0}, fn line, {kept, used} ->
        # The +1 is the newline joining this line to the previous one.
        needed = String.length(line) + if kept == [], do: 0, else: 1

        if used + needed <= budget,
          do: {:cont, {[line | kept], used + needed}},
          else: {:halt, {kept, used}}
      end)

    Enum.reverse(kept)
  end

  # Matches the full `NotableItems.item()` shape rather than reading `:value`
  # and `:abyssal?` defensively: every key is required by that type, so an item
  # missing one is malformed and is dropped rather than rendered half-formed.
  #
  # Abyssal modules carry no price: their market values are unreliable enough
  # that quoting one would be worse than saying nothing, matching
  # wanderer-notifier.
  defp item_line(%{name: name, quantity: quantity, value: value, abyssal?: abyssal?})
       when is_binary(name) and is_integer(quantity) and quantity > 0 do
    count = if quantity > 1, do: " x#{quantity}", else: ""

    price =
      if abyssal? do
        ""
      else
        case format_isk(value) do
          nil -> ""
          isk -> " (~#{isk})"
        end
      end

    ["• #{name}#{count}#{price}"]
  end

  defp item_line(_item), do: []

  defp victim_clause(kill) do
    pilot =
      character_link(kill["victim_char_id"], present(kill["victim_char_name"]) || "Unknown pilot")

    ship = present(kill["victim_ship_name"]) || "Unknown ship"

    case corporation_link(kill["victim_corp_id"], present(kill["victim_corp_ticker"])) do
      nil -> "#{pilot} lost their **#{ship}**"
      corp -> "#{pilot} (#{corp}) lost their **#{ship}**"
    end
  end

  defp final_blow_clause(kill) do
    case present(kill["final_blow_char_name"]) do
      nil ->
        nil

      name ->
        pilot = character_link(kill["final_blow_char_id"], name)

        case corporation_link(kill["final_blow_corp_id"], present(kill["final_blow_corp_ticker"])) do
          nil -> " to #{pilot}"
          corp -> " to #{pilot} (#{corp})"
        end
    end
  end

  defp top_damage_clause(kill) do
    with name when not is_nil(name) <- present(kill["top_damage_char_name"]),
         true <- distinct_from_final_blow?(kill) do
      ", top damage by #{character_link(kill["top_damage_char_id"], name)}"
    else
      _ -> nil
    end
  end

  # Ids are authoritative when both are present; names are the fallback for
  # payloads that carry one without the other. Compared as strings because the
  # two ids do not have to arrive as the same type: `collect_ids/2` normalizes
  # to integers on the nested branch only, so a flat payload can pair an
  # integer with a binary. Matching only `is_integer/1` on both would drop such
  # a pair to the name comparison, which is exactly the case the ids exist to
  # settle.
  defp distinct_from_final_blow?(kill) do
    case {kill["final_blow_char_id"], kill["top_damage_char_id"]} do
      {fb, td} when (is_integer(fb) or is_binary(fb)) and (is_integer(td) or is_binary(td)) ->
        to_string(fb) != to_string(td)

      _ ->
        present(kill["final_blow_char_name"]) != present(kill["top_damage_char_name"])
    end
  end

  # Relative to whichever pilot(s) got named in the clauses above — final blow,
  # top damage, or both. With nobody named at all there is no antecedent for
  # "others" to modify, so a wholly anonymous fight (e.g. an NPC final blow
  # with no top-damage pilot either) renders no others-clause at all rather
  # than a dangling ", and 1 other." An NPC final blow with a *named*
  # top-damage pilot still gets an others-clause, since something was named.
  defp others_clause(kill) do
    named = named_attacker_count(kill)

    if named > 0 do
      case kill["attacker_count"] do
        count when is_integer(count) and count - named == 1 -> ", and 1 other"
        count when is_integer(count) and count - named > 1 -> ", and #{count - named} others"
        _ -> nil
      end
    end
  end

  defp named_attacker_count(kill) do
    final_blow = if present(kill["final_blow_char_name"]), do: 1, else: 0

    top_damage =
      if present(kill["top_damage_char_name"]) && distinct_from_final_blow?(kill), do: 1, else: 0

    final_blow + top_damage
  end

  defp character_link(id, name) when is_integer(id) or is_binary(id),
    do: "**[#{name}](#{@zkill_base}/character/#{id}/)**"

  defp character_link(_id, name), do: "**#{name}**"

  defp corporation_link(_id, nil), do: nil

  defp corporation_link(id, ticker) when is_integer(id) or is_binary(id),
    do: "**[#{ticker}](#{@zkill_base}/corporation/#{id}/)**"

  defp corporation_link(_id, ticker), do: "**#{ticker}**"

  defp fields(kill) do
    [
      field("Value", format_isk(kill["total_value"]), true),
      field("When", relative_time(kill["kill_time"]), true)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp field(_name, nil, _inline), do: nil
  defp field(name, value, inline), do: %{"name" => name, "value" => value, "inline" => inline}

  # `<t:unix:R>` renders client-side as "3 hours ago", in the reader's own
  # timezone. An unparseable kill_time drops the field rather than guessing.
  defp relative_time(kill_time) when is_binary(kill_time) do
    case DateTime.from_iso8601(kill_time) do
      {:ok, datetime, _offset} -> "<t:#{DateTime.to_unix(datetime)}:R>"
      _ -> nil
    end
  end

  defp relative_time(%DateTime{} = datetime), do: "<t:#{DateTime.to_unix(datetime)}:R>"

  defp relative_time(%NaiveDateTime{} = naive),
    do: relative_time(DateTime.from_naive!(naive, "Etc/UTC"))

  defp relative_time(unix) when is_integer(unix), do: "<t:#{unix}:R>"
  defp relative_time(_), do: nil

  # Selection is on FIELD PRESENCE ONLY. This is *not* a 404 fallback: Discord
  # fetches the image itself when it renders the embed, so a failed fetch is
  # never observable from here and cannot be reacted to. If the ship type id is
  # present we use the ship render even if that render happens not to exist
  # upstream; the character portrait is only for kills that carry no ship type.
  defp thumbnail(kill) do
    cond do
      is_integer(kill["victim_ship_type_id"]) or is_binary(kill["victim_ship_type_id"]) ->
        %{
          "url" =>
            "#{@image_base}/types/#{kill["victim_ship_type_id"]}/render?size=#{@thumbnail_size}"
        }

      is_integer(kill["victim_char_id"]) or is_binary(kill["victim_char_id"]) ->
        %{
          "url" =>
            "#{@image_base}/characters/#{kill["victim_char_id"]}/portrait?size=#{@thumbnail_size}"
        }

      true ->
        nil
    end
  end

  defp footer(kill) do
    case kill["killmail_id"] do
      nil -> nil
      id -> %{"text" => "Killmail ID: #{id}"}
    end
  end

  defp zkill_url(nil), do: nil
  defp zkill_url(id), do: "#{@zkill_base}/kill/#{id}/"

  @doc false
  def format_isk(nil), do: nil
  def format_isk(0), do: "0 ISK"

  def format_isk(value) when is_number(value) do
    Enum.find_value(@isk_units, "#{round(value)} ISK", &format_at_unit(value, &1))
  end

  def format_isk(_), do: nil

  defp format_at_unit(value, {threshold, _divisor, _unit, _next}) when value < threshold, do: nil

  defp format_at_unit(value, {_threshold, divisor, unit, next_unit}) do
    case {round_to(value / divisor), next_unit} do
      # Top of the table: clamp rather than promote.
      {rounded, nil} ->
        "#{format_float(rounded)}#{unit} ISK"

      {rounded, next} when rounded >= 1000.0 ->
        "#{format_float(round_to(rounded / 1000))}#{next} ISK"

      {rounded, _} ->
        "#{format_float(rounded)}#{unit} ISK"
    end
  end

  # Format a float to avoid scientific notation (e.g., 1.0e3 -> "1000.0")
  defp format_float(float) when is_float(float) do
    # `:decimals` avoids scientific notation, keeping 1 decimal place
    :erlang.float_to_list(float, [{:decimals, 1}])
    |> List.to_string()
  end

  defp round_to(float), do: Float.round(float, 1)

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
  defp present(value), do: to_string(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_nils(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
