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

  alias WandererApp.ExternalEvents.Discord.Mentions
  alias WandererApp.ExternalEvents.Discord.SystemName

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
  @max_description_length 4096
  # The per-message ceiling counts the text of every embed in the message
  # together, so it can be breached by a batch that satisfies each field bound
  # individually.
  @max_message_text 6000

  @color_loss 0xE74C3C
  @color_kill 0x2ECC71
  @color_route 0x2ECC71

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
      "title" => route_title(alert),
      "color" => @color_route,
      "fields" => [
        %{"name" => "Path", "value" => route_path_text(alert), "inline" => false},
        %{
          "name" => "Exit system",
          "value" => route_system_name(alert, alert.exit_system),
          "inline" => true
        }
      ]
    }
    |> drop_nils()
  end

  defp route_title(%{kind: :opened, jumps: jumps}),
    do: "Highsec route to Jita — #{jumps} jumps"

  defp route_title(%{kind: :improved, jumps: jumps}),
    do: "Highsec route to Jita improved — #{jumps} jumps"

  defp route_path_text(alert) do
    Enum.map_join(alert.path, " → ", &route_system_name(alert, &1))
  end

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
