defmodule WandererApp.ExternalEvents.Discord.EmbedFormatterTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.ExternalEvents.Discord.EmbedFormatter
  alias WandererAppWeb.Factory

  @loss {:involved, :victim}
  @kill {:involved, :attacker}
  @bystander :not_involved

  describe "colour" do
    test "a loss is red" do
      kill = Factory.build(:killmail)
      assert EmbedFormatter.format_kill(kill, @loss, "J123456")["color"] == 0xE74C3C
    end

    test "a kill is green" do
      kill = Factory.build(:killmail)
      assert EmbedFormatter.format_kill(kill, @kill, "J123456")["color"] == 0x2ECC71
    end

    test "an uninvolved kill is coloured by ISK tier" do
      tiers = [
        {5_000_000_000, 0xFF0000},
        {9_999_999_999, 0xFF0000},
        {4_999_999_999, 0xFF6600},
        {1_000_000_000, 0xFF6600},
        {999_999_999, 0xFFFF00},
        {100_000_000, 0xFFFF00},
        {99_999_999, 0x00FF00},
        {10_000_000, 0x00FF00},
        {9_999_999, 0x808080},
        {0, 0x808080}
      ]

      Enum.each(tiers, fn {value, expected} ->
        kill = Factory.build(:killmail, %{"total_value" => value})
        actual = EmbedFormatter.format_kill(kill, @bystander, "J123456")["color"]

        assert actual == expected,
               "total_value #{value} coloured #{inspect(actual, base: :hex)}, " <>
                 "expected #{inspect(expected, base: :hex)}"
      end)
    end

    test "an uninvolved kill with no value falls to the default grey" do
      kill = Factory.build(:killmail, %{"total_value" => nil})
      assert EmbedFormatter.format_kill(kill, @bystander, "J123456")["color"] == 0x808080
    end

    test "the loss colour and the kill colour do not depend on ISK value" do
      cheap = Factory.build(:killmail, %{"total_value" => 1})
      rich = Factory.build(:killmail, %{"total_value" => 9_000_000_000})

      assert EmbedFormatter.format_kill(cheap, @loss, "J")["color"] ==
               EmbedFormatter.format_kill(rich, @loss, "J")["color"]

      assert EmbedFormatter.format_kill(cheap, @kill, "J")["color"] ==
               EmbedFormatter.format_kill(rich, @kill, "J")["color"]
    end
  end

  describe "format_isk/1" do
    test "handles ISK formatting boundary values correctly" do
      test_cases = [
        {0, "0 ISK"},
        {999, "999 ISK"},
        {1_000, "1.0K ISK"},
        {999_999, "1.0M ISK"},
        {1_000_000, "1.0M ISK"},
        {999_999_999, "1.0B ISK"},
        {1_500_000_000, "1.5B ISK"},
        {nil, nil}
      ]

      Enum.each(test_cases, fn {value, expected} ->
        actual = EmbedFormatter.format_isk(value)

        assert actual == expected,
               "format_isk(#{inspect(value)}) returned #{inspect(actual)}, expected #{inspect(expected)}"
      end)
    end

    test "handles trillion-ISK values correctly (supercapital/structure kills)" do
      test_cases = [
        {999_999_999_999, "1.0T ISK"},
        {1_000_000_000_000, "1.0T ISK"},
        {5_000_000_000_000, "5.0T ISK"}
      ]

      Enum.each(test_cases, fn {value, expected} ->
        actual = EmbedFormatter.format_isk(value)

        assert actual == expected,
               "format_isk(#{inspect(value)}) returned #{inspect(actual)}, expected #{inspect(expected)}"
      end)
    end

    test "clamps at trillion unit (does not underreport above 1 quadrillion)" do
      test_cases = [
        {100_000_000_000_000, "100.0T ISK"},
        {999_000_000_000_000, "999.0T ISK"},
        {1_000_000_000_000_000, "1000.0T ISK"},
        {999_999_999_999_999, "1000.0T ISK"}
      ]

      Enum.each(test_cases, fn {value, expected} ->
        actual = EmbedFormatter.format_isk(value)

        assert actual == expected,
               "format_isk(#{inspect(value)}) returned #{inspect(actual)}, expected #{inspect(expected)}"
      end)
    end
  end

  describe "author line" do
    test "a loss is labelled Loss and carries the victim's corp logo" do
      kill = Factory.build(:killmail, %{"victim_corp_id" => 98_000_001})
      author = EmbedFormatter.format_kill(kill, @loss, "J123456")["author"]

      assert author["name"] == "Loss"
      assert author["icon_url"] == "https://images.evetech.net/corporations/98000001/logo?size=64"
    end

    test "a kill is labelled Kill and carries the final-blow pilot's corp logo" do
      kill = Factory.build(:killmail, %{"final_blow_corp_id" => 98_000_002})
      author = EmbedFormatter.format_kill(kill, @kill, "J123456")["author"]

      assert author["name"] == "Kill"
      assert author["icon_url"] == "https://images.evetech.net/corporations/98000002/logo?size=64"
    end

    test "the author line is omitted entirely when not involved" do
      kill = Factory.build(:killmail)
      embed = EmbedFormatter.format_kill(kill, @bystander, "J123456")

      refute Map.has_key?(embed, "author")
    end

    test "the label survives a missing corp id, without a logo" do
      kill = Factory.build(:killmail, %{"victim_corp_id" => nil})
      author = EmbedFormatter.format_kill(kill, @loss, "J123456")["author"]

      assert author == %{"name" => "Loss"}
    end
  end

  describe "title and description prose" do
    test "the title names the ship and the system it died in" do
      kill = Factory.build(:killmail, %{"victim_ship_name" => "Vexor"})
      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      assert embed["title"] == "Vexor destroyed in Home"
    end

    test "the title survives a missing ship name and a missing system name" do
      kill = Factory.build(:killmail, %{"victim_ship_name" => nil})
      embed = EmbedFormatter.format_kill(kill, @loss, nil)

      assert embed["title"] == "Unknown ship destroyed in Unknown system"
    end

    test "the prose links every name to zKillboard" do
      kill =
        Factory.build(:killmail, %{
          "victim_char_id" => 90_000_001,
          "victim_char_name" => "Test Victim",
          "victim_corp_id" => 98_000_001,
          "victim_corp_ticker" => "TSTC",
          "victim_ship_name" => "Vexor",
          "final_blow_char_id" => 90_000_002,
          "final_blow_char_name" => "Test Attacker",
          "final_blow_corp_id" => 98_000_002,
          "final_blow_corp_ticker" => "ATKC",
          "top_damage_char_id" => 90_000_003,
          "top_damage_char_name" => "Top Gun",
          "attacker_count" => 5
        })

      assert EmbedFormatter.format_kill(kill, @loss, "Home")["description"] ==
               "**[Test Victim](https://zkillboard.com/character/90000001/)** " <>
                 "(**[TSTC](https://zkillboard.com/corporation/98000001/)**) " <>
                 "lost their **Vexor** to " <>
                 "**[Test Attacker](https://zkillboard.com/character/90000002/)** " <>
                 "(**[ATKC](https://zkillboard.com/corporation/98000002/)**), " <>
                 "top damage by **[Top Gun](https://zkillboard.com/character/90000003/)**, " <>
                 "and 3 others."
    end

    test "top damage is not named when it is the final-blow pilot" do
      kill =
        Factory.build(:killmail, %{
          "final_blow_char_id" => 90_000_002,
          "final_blow_char_name" => "Test Attacker",
          "top_damage_char_id" => 90_000_002,
          "top_damage_char_name" => "Test Attacker",
          "attacker_count" => 3
        })

      description = EmbedFormatter.format_kill(kill, @loss, "Home")["description"]

      refute description =~ "top damage"
      assert description =~ "and 2 others."
    end

    test "a solo kill omits the others clause" do
      kill =
        Factory.build(:killmail, %{
          "attacker_count" => 1,
          "final_blow_char_id" => 90_000_002,
          "final_blow_char_name" => "Test Attacker",
          "top_damage_char_id" => 90_000_002,
          "top_damage_char_name" => "Test Attacker"
        })

      description = EmbedFormatter.format_kill(kill, @loss, "Home")["description"]

      refute description =~ "others"
      refute description =~ "other."
      assert description =~ "lost their **Vexor** to **[Test Attacker]"
    end

    test "a single unnamed extra attacker reads 'other', not 'others'" do
      kill =
        Factory.build(:killmail, %{
          "attacker_count" => 2,
          "final_blow_char_id" => 90_000_002,
          "final_blow_char_name" => "Test Attacker",
          "top_damage_char_id" => 90_000_002,
          "top_damage_char_name" => "Test Attacker"
        })

      assert EmbedFormatter.format_kill(kill, @loss, "Home")["description"] =~ "and 1 other."
    end

    test "an NPC final blow renders as absent, not as a placeholder name" do
      kill =
        Factory.build(:killmail, %{
          "npc" => true,
          "attacker_count" => 1,
          "final_blow_char_id" => nil,
          "final_blow_char_name" => nil,
          "final_blow_corp_id" => nil,
          "final_blow_corp_ticker" => nil,
          "top_damage_char_id" => nil,
          "top_damage_char_name" => nil
        })

      description = EmbedFormatter.format_kill(kill, @bystander, "Home")["description"]

      assert description ==
               "**[Test Victim](https://zkillboard.com/character/90000001/)** " <>
                 "(**[TSTC](https://zkillboard.com/corporation/98000001/)**) " <>
                 "lost their **Vexor**."

      refute description =~ "Unknown"
      refute description =~ "nil"
    end

    test "an NPC final blow with a named top-damage pilot still reports the others clause" do
      kill =
        Factory.build(:killmail, %{
          "npc" => true,
          "attacker_count" => 3,
          "final_blow_char_id" => nil,
          "final_blow_char_name" => nil,
          "final_blow_corp_id" => nil,
          "final_blow_corp_ticker" => nil,
          "top_damage_char_id" => 90_000_003,
          "top_damage_char_name" => "Top Gun"
        })

      description = EmbedFormatter.format_kill(kill, @bystander, "Home")["description"]

      assert description =~ "top damage by **[Top Gun]"
      assert description =~ "and 2 others."
    end

    test "names render unlinked when the id is missing" do
      kill =
        Factory.build(:killmail, %{
          "victim_char_id" => nil,
          "victim_corp_id" => nil,
          "final_blow_char_id" => nil,
          "final_blow_corp_id" => nil,
          "top_damage_char_id" => nil,
          "top_damage_char_name" => nil,
          "attacker_count" => 1
        })

      assert EmbedFormatter.format_kill(kill, @loss, "Home")["description"] ==
               "**Test Victim** (**TSTC**) lost their **Vexor** to **Test Attacker** (**ATKC**)."
    end

    test "a missing victim name does not leak the word nil" do
      kill =
        Factory.build(:killmail, %{
          "victim_char_id" => nil,
          "victim_char_name" => nil,
          "victim_corp_ticker" => nil,
          "top_damage_char_id" => nil,
          "top_damage_char_name" => nil
        })

      description = EmbedFormatter.format_kill(kill, @loss, "Home")["description"]

      assert description =~ "**Unknown pilot** lost their **Vexor**"
      refute description =~ "nil"
    end
  end

  describe "fields" do
    test "carries exactly Value and When, both inline" do
      kill = Factory.build(:killmail, %{"total_value" => 84_000_000})
      fields = EmbedFormatter.format_kill(kill, @loss, "Home")["fields"]

      assert Enum.map(fields, & &1["name"]) == ["Value", "When"]
      assert Enum.all?(fields, & &1["inline"])
    end

    test "Value uses the existing ISK formatter" do
      kill = Factory.build(:killmail, %{"total_value" => 84_000_000})
      fields = EmbedFormatter.format_kill(kill, @loss, "Home")["fields"]

      assert Enum.find(fields, &(&1["name"] == "Value"))["value"] == "84.0M ISK"
    end

    test "When is a Discord relative timestamp derived from kill_time" do
      kill = Factory.build(:killmail, %{"kill_time" => "2026-08-01T12:00:00Z"})
      fields = EmbedFormatter.format_kill(kill, @loss, "Home")["fields"]

      unix = DateTime.to_unix(~U[2026-08-01 12:00:00Z])
      assert Enum.find(fields, &(&1["name"] == "When"))["value"] == "<t:#{unix}:R>"
    end

    test "an unparseable kill_time drops the When field rather than rendering junk" do
      kill = Factory.build(:killmail, %{"kill_time" => "not a timestamp"})
      fields = EmbedFormatter.format_kill(kill, @loss, "Home")["fields"]

      assert Enum.map(fields, & &1["name"]) == ["Value"]
    end

    test "a nil total_value drops the Value field" do
      kill = Factory.build(:killmail, %{"total_value" => nil})
      fields = EmbedFormatter.format_kill(kill, @loss, "Home")["fields"]

      assert Enum.map(fields, & &1["name"]) == ["When"]
    end

    test "the system name is no longer a field — it is in the title" do
      kill = Factory.build(:killmail)
      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      refute Enum.any?(embed["fields"], &(&1["name"] == "System"))
      assert embed["title"] =~ "Home"
    end
  end

  describe "thumbnail and footer" do
    test "renders a 1024px ship render when the ship type id is present" do
      kill = Factory.build(:killmail, %{"victim_ship_type_id" => 626})
      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      assert embed["thumbnail"]["url"] ==
               "https://images.evetech.net/types/626/render?size=1024"
    end

    test "falls back to the character portrait when the ship type id is absent" do
      kill =
        Factory.build(:killmail, %{
          "victim_ship_type_id" => nil,
          "victim_char_id" => 90_000_001
        })

      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      assert embed["thumbnail"]["url"] ==
               "https://images.evetech.net/characters/90000001/portrait?size=1024"
    end

    test "a string-typed victim_char_id still links the name and renders the portrait" do
      kill =
        Factory.build(:killmail, %{
          "victim_char_id" => "90000001",
          "victim_ship_type_id" => nil
        })

      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      assert embed["description"] =~
               "**[Test Victim](https://zkillboard.com/character/90000001/)**"

      assert embed["thumbnail"]["url"] ==
               "https://images.evetech.net/characters/90000001/portrait?size=1024"
    end

    test "omits the thumbnail when neither ship type nor character id is present" do
      kill =
        Factory.build(:killmail, %{
          "victim_ship_type_id" => nil,
          "victim_char_id" => nil
        })

      refute Map.has_key?(EmbedFormatter.format_kill(kill, @loss, "Home"), "thumbnail")
    end

    test "prefers the ship render even when a character id is also present" do
      kill =
        Factory.build(:killmail, %{
          "victim_ship_type_id" => 626,
          "victim_char_id" => 90_000_001
        })

      assert EmbedFormatter.format_kill(kill, @loss, "Home")["thumbnail"]["url"] =~ "/types/626/"
    end

    test "the footer carries the killmail id" do
      kill = Factory.build(:killmail, %{"killmail_id" => 12_345})
      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      assert embed["footer"] == %{"text" => "Killmail ID: 12345"}
      assert embed["url"] == "https://zkillboard.com/kill/12345/"
    end

    test "the corp ticker is no longer in the footer" do
      kill = Factory.build(:killmail, %{"victim_corp_ticker" => "TSTC"})
      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      refute embed["footer"]["text"] =~ "TSTC"
      assert embed["description"] =~ "TSTC"
    end

    test "is JSON-encodable and never leaks the word nil" do
      kill =
        Factory.build(:killmail, %{
          "victim_char_name" => nil,
          "victim_corp_name" => nil,
          "victim_corp_ticker" => nil,
          "victim_alliance_name" => nil,
          "victim_ship_name" => nil,
          "victim_ship_type_id" => nil,
          "victim_char_id" => nil,
          "final_blow_char_name" => nil,
          "top_damage_char_name" => nil,
          "total_value" => nil,
          "kill_time" => nil
        })

      embed = EmbedFormatter.format_kill(kill, @bystander, nil)

      assert {:ok, json} = Jason.encode(embed)
      refute json =~ "nil"
    end
  end

  describe "format_batch/2" do
    defp entries(count, verdict \\ :not_involved) do
      for _ <- 1..count, do: {Factory.build(:killmail), verdict}
    end

    test "single message for 10 or fewer kills" do
      assert [%{"embeds" => embeds}] = EmbedFormatter.format_batch(entries(10), "J123456")
      assert length(embeds) == 10
    end

    test "chunks into messages of at most 10 embeds" do
      messages = EmbedFormatter.format_batch(entries(25), "J123456")

      assert length(messages) == 3
      assert Enum.all?(messages, &(length(&1["embeds"]) <= 10))
      assert messages |> Enum.map(&length(&1["embeds"])) |> Enum.sum() == 25
    end

    test "caps at 30 kills and notes the overflow" do
      messages = EmbedFormatter.format_batch(entries(42), "J123456")

      assert messages |> Enum.map(&length(&1["embeds"])) |> Enum.sum() == 30
      assert List.last(messages)["content"] =~ "12 more"
    end

    test "exactly 30 kills has no overflow notation" do
      messages = EmbedFormatter.format_batch(entries(30), "J123456")

      assert messages |> Enum.map(&length(&1["embeds"])) |> Enum.sum() == 30
      refute Map.has_key?(List.last(messages), "content")
    end

    test "returns empty list for no kills" do
      assert EmbedFormatter.format_batch([], "J123456") == []
    end

    test "each kill is coloured by its own verdict within one batch" do
      batch = [
        {Factory.build(:killmail), {:involved, :victim}},
        {Factory.build(:killmail), {:involved, :attacker}},
        {Factory.build(:killmail, %{"total_value" => 1_000}), :not_involved}
      ]

      [%{"embeds" => embeds}] = EmbedFormatter.format_batch(batch, "J123456")

      assert Enum.map(embeds, & &1["color"]) == [0xE74C3C, 0x2ECC71, 0x808080]
    end

    test "every embed in a batch carries the same system name" do
      [%{"embeds" => embeds}] = EmbedFormatter.format_batch(entries(3), "Home")

      assert Enum.all?(embeds, &(&1["title"] =~ "destroyed in Home"))
    end

    test "max_kills_per_event/0 is still 30" do
      assert EmbedFormatter.max_kills_per_event() == 30
    end

    # Discord rejects an over-long embed with a 400, which the worker records as
    # a delivery failure — so without these bounds a single long map-local
    # system name would burn through @max_consecutive_failures and auto-disable
    # the destination. `custom_name`/`temporary_name` carry no length
    # constraint on MapSystem, so this is reachable from ordinary user input.
    test "a system name longer than the title limit is truncated, not passed through" do
      long_name = String.duplicate("あ", 400)

      [%{"embeds" => [embed]}] = EmbedFormatter.format_batch(entries(1), long_name)

      assert String.length(embed["title"]) == 256
      assert String.ends_with?(embed["title"], "…")
    end

    test "a system name at exactly the title limit is left alone" do
      # "X destroyed in " + name == exactly 256 graphemes.
      {kill, verdict} = hd(entries(1))
      ship = kill["victim_ship_name"]
      name = String.duplicate("a", 256 - String.length("#{ship} destroyed in "))

      [%{"embeds" => [embed]}] = EmbedFormatter.format_batch([{kill, verdict}], name)

      assert String.length(embed["title"]) == 256
      refute String.ends_with?(embed["title"], "…")
      assert embed["title"] =~ name
    end

    test "a batch is split so no message exceeds the 6000-character text total" do
      # Long pilot names, not a long system name: once the title is bounded at
      # 256 the ten-embed message tops out well under 6000, so the description
      # is the only way left to breach the total. ~2400 characters each means
      # three embeds already exceed it.
      long = String.duplicate("n", 2_400)

      batch =
        for _ <- 1..12 do
          {Factory.build(:killmail, %{"victim_char_name" => long}), :not_involved}
        end

      messages = EmbedFormatter.format_batch(batch, "J123456")

      for %{"embeds" => embeds} <- messages do
        assert embed_text_total(embeds) <= 6000,
               "message carried #{embed_text_total(embeds)} characters of embed text"

        assert length(embeds) <= 10
      end

      # Every kill still delivered, just spread across more messages than the
      # ten-embeds-per-message bound alone would produce.
      assert messages |> Enum.map(&length(&1["embeds"])) |> Enum.sum() == 12
      assert length(messages) > 2
    end

    test "a realistic batch is still bounded by the embed count, not the text total" do
      messages = EmbedFormatter.format_batch(entries(30), String.duplicate("b", 240))

      assert Enum.all?(messages, &(embed_text_total(&1["embeds"]) <= 6000))
      assert messages |> Enum.map(&length(&1["embeds"])) |> Enum.sum() == 30
      assert length(messages) == 3
    end

    defp embed_text_total(embeds) do
      Enum.reduce(embeds, 0, fn e, acc ->
        fields =
          e
          |> Map.get("fields", [])
          |> Enum.map(&(String.length(&1["name"]) + String.length(&1["value"])))
          |> Enum.sum()

        acc + String.length(e["title"] || "") + String.length(e["description"] || "") +
          String.length(get_in(e, ["footer", "text"]) || "") +
          String.length(get_in(e, ["author", "name"]) || "") + fields
      end)
    end
  end

  describe "notable items" do
    defp with_items(items),
      do: Factory.build(:killmail) |> Map.put("notable_items", items)

    defp describe_kill(kill), do: EmbedFormatter.format_kill(kill, @bystander, "J123456")

    defp item(name, opts \\ []) do
      %{
        name: name,
        quantity: Keyword.get(opts, :quantity, 1),
        value: Keyword.get(opts, :value, 100_000_000.0),
        abyssal?: Keyword.get(opts, :abyssal?, false)
      }
    end

    test "no section when the key is absent" do
      description = Factory.build(:killmail) |> describe_kill() |> Map.get("description")
      refute description =~ "Notable Items"
    end

    test "no section when the list is empty" do
      refute describe_kill(with_items([]))["description"] =~ "Notable Items"
    end

    test "no section when the value is not a list" do
      refute describe_kill(with_items(nil))["description"] =~ "Notable Items"
      refute describe_kill(with_items("nope"))["description"] =~ "Notable Items"
    end

    test "a single item renders without a quantity" do
      description = describe_kill(with_items([item("Damage Control II")]))["description"]

      assert description =~ "\n\n**Notable Items:**\n"
      assert description =~ "• Damage Control II (~100.0M ISK)"
      refute description =~ "x1"
    end

    test "a stacked item renders its quantity" do
      description =
        describe_kill(with_items([item("Nanite Repair Paste", quantity: 300)]))["description"]

      assert description =~ "• Nanite Repair Paste x300 (~100.0M ISK)"
    end

    test "an abyssal item renders no price" do
      description =
        describe_kill(with_items([item("Abyssal Warp Scrambler", abyssal?: true)]))["description"]

      assert description =~ "• Abyssal Warp Scrambler"
      refute description =~ "ISK)"
    end

    test "an abyssal item still renders its quantity" do
      description =
        describe_kill(with_items([item("Abyssal Damage Control", quantity: 2, abyssal?: true)]))[
          "description"
        ]

      assert description =~ "• Abyssal Damage Control x2"
      refute description =~ "ISK)"
    end

    test "items render one per line, in the order given" do
      description =
        describe_kill(with_items([item("First"), item("Second"), item("Third")]))["description"]

      assert [_prose, "• First (~100.0M ISK)", "• Second (~100.0M ISK)", "• Third (~100.0M ISK)"] =
               String.split(description, "\n", trim: true) |> Enum.take(-4)
    end

    test "a malformed item is skipped rather than rendered" do
      description = describe_kill(with_items([%{name: "Real"}, item("Good")]))["description"]

      assert description =~ "• Good"
      refute description =~ "• Real"
    end

    # `NotableItems.item()` declares all four keys, so an item missing one did
    # not come from the enricher and cannot be trusted to render.
    test "an item missing a key the type requires is skipped" do
      for missing <- [:name, :quantity, :value, :abyssal?] do
        malformed = item("Partial") |> Map.delete(missing)
        description = describe_kill(with_items([malformed, item("Good")]))["description"]

        assert description =~ "• Good", "expected the well-formed item with #{missing} missing"
        refute description =~ "• Partial"
      end
    end

    # -- budgeting ------------------------------------------------------------

    # Builds a killmail whose base description (before any section) is exactly
    # `target` graphemes, by padding the victim name — it appears once in the
    # description, so length grows with it one for one.
    defp kill_with_base_length(target) do
      probe = Factory.build(:killmail) |> Map.put("victim_char_name", "X")
      base = String.length(describe_kill(probe)["description"])
      Map.put(probe, "victim_char_name", String.duplicate("X", target - base + 1))
    end

    test "the base description alone is still truncated to the Discord limit" do
      description = describe_kill(kill_with_base_length(5000))["description"]
      assert String.length(description) == 4096
    end

    test "a full section never pushes the description past the limit" do
      items = for n <- 1..5, do: item("Item #{n}")

      description =
        kill_with_base_length(4000)
        |> Map.put("notable_items", items)
        |> describe_kill()
        |> Map.get("description")

      assert String.length(description) <= 4096
    end

    test "only whole lines that fit are kept; the rest are dropped silently" do
      line = "• Item 1 (~100.0M ISK)"
      header = "\n\n**Notable Items:**\n"
      items = for n <- 1..5, do: item("Item #{n}")

      # Room for the header and exactly one line, and nothing more.
      base = 4096 - String.length(header) - String.length(line)

      description =
        kill_with_base_length(base)
        |> Map.put("notable_items", items)
        |> describe_kill()
        |> Map.get("description")

      assert String.ends_with?(description, header <> line)
      refute description =~ "Item 2"
      assert String.length(description) == 4096
    end

    test "the header is omitted entirely when not even one line fits" do
      items = for n <- 1..5, do: item("Item #{n}")

      description =
        kill_with_base_length(4090)
        |> Map.put("notable_items", items)
        |> describe_kill()
        |> Map.get("description")

      refute description =~ "Notable Items"
      refute description =~ "•"
    end

    test "a long section splits a batch into more messages" do
      items = for n <- 1..5, do: item(String.duplicate("N", 200) <> " #{n}")

      entries =
        for _n <- 1..10 do
          {Factory.build(:killmail) |> Map.put("notable_items", items), @bystander}
        end

      without =
        EmbedFormatter.format_batch(
          Enum.map(entries, fn {k, v} -> {Map.delete(k, "notable_items"), v} end),
          "J123456"
        )

      with_sections = EmbedFormatter.format_batch(entries, "J123456")

      assert length(without) == 1
      assert length(with_sections) > 1
      assert Enum.all?(with_sections, &(embed_text_total(&1["embeds"]) <= 6000))
    end
  end

  describe "format_route_alert/2" do
    @home 31_000_005
    @wh_hop 31_000_006
    @exit_system 30_002_053
    @jita 30_000_142

    setup do
      Cachex.put(:system_static_info_cache, @home, %{
        solar_system_id: @home,
        solar_system_name: "J115405",
        system_class: 3
      })

      Cachex.put(:system_static_info_cache, @wh_hop, %{
        solar_system_id: @wh_hop,
        solar_system_name: "J132412",
        system_class: 3
      })

      Cachex.put(:system_static_info_cache, @exit_system, %{
        solar_system_id: @exit_system,
        solar_system_name: "Amarr",
        system_class: 0
      })

      Cachex.put(:system_static_info_cache, @jita, %{
        solar_system_id: @jita,
        solar_system_name: "Jita",
        system_class: 0
      })

      on_exit(fn ->
        Enum.each(
          [@home, @wh_hop, @exit_system, @jita],
          &Cachex.del(:system_static_info_cache, &1)
        )
      end)

      map = Factory.insert(:map, %{})

      alert = %{
        kind: :opened,
        jumps: 4,
        path: [@home, @wh_hop, @exit_system, @jita],
        exit_system: @exit_system,
        map_id: map.id,
        home_system_id: @home
      }

      %{alert: alert}
    end

    test "an opened alert is a single green embed titled with the jump count", %{alert: alert} do
      assert [%{"embeds" => [embed]}] = EmbedFormatter.format_route_alert(alert, [])

      assert embed["title"] == "Highsec route to Jita — 4 jumps"
      assert embed["color"] == 0x2ECC71
    end

    test "the path renders home through Jita using map-local names for wormhole hops", %{
      alert: alert
    } do
      [%{"embeds" => [embed]}] = EmbedFormatter.format_route_alert(alert, [])

      path_field = Enum.find(embed["fields"], &(&1["name"] == "Path"))
      assert path_field["value"] == "J115405 → J132412 → Amarr → Jita"
    end

    # route_max_jumps tops out at 20, so a path is at most 21 systems — but
    # MapSystem's custom_name/temporary_name carry no length constraint, so an
    # ordinary long name breaches Discord's 1024-char field bound and the POST
    # is rejected 400 (which counts toward @max_consecutive_failures and can
    # auto-disable the destination).
    test "a path too long for Discord's field bound is truncated", %{alert: alert} do
      long_name = String.duplicate("A", 60)

      ids = Enum.map(1..21, &(32_000_000 + &1))

      Enum.each(ids, fn id ->
        Cachex.put(:system_static_info_cache, id, %{
          solar_system_id: id,
          solar_system_name: long_name,
          system_class: 0
        })
      end)

      on_exit(fn -> Enum.each(ids, &Cachex.del(:system_static_info_cache, &1)) end)

      [%{"embeds" => [embed]}] =
        EmbedFormatter.format_route_alert(%{alert | path: ids, jumps: 20}, [])

      path_field = Enum.find(embed["fields"], &(&1["name"] == "Path"))

      assert String.length(path_field["value"]) == 1024
      assert String.ends_with?(path_field["value"], "…")
    end

    test "the exit system gets its own field", %{alert: alert} do
      [%{"embeds" => [embed]}] = EmbedFormatter.format_route_alert(alert, [])

      exit_field = Enum.find(embed["fields"], &(&1["name"] == "Exit system"))
      assert exit_field["value"] == "Amarr"
    end

    test "an improved alert titles with 'improved' and carries no content", %{alert: alert} do
      improved = %{alert | kind: :improved, jumps: 3}

      assert [%{"embeds" => [embed]} = message] = EmbedFormatter.format_route_alert(improved, [])
      assert embed["title"] == "Highsec route to Jita improved — 3 jumps"
      refute Map.has_key?(message, "content")
    end

    test "an opened alert with configured targets carries a content ping and allowed_mentions", %{
      alert: alert
    } do
      put_discord_mentions_enabled(true)

      [message] =
        EmbedFormatter.format_route_alert(alert, mention_targets: ["role:123456789012345678"])

      assert message["content"] =~ "<@&123456789012345678>"

      assert message["allowed_mentions"] ==
               %{"parse" => [], "users" => [], "roles" => ["123456789012345678"]}
    end

    test "no content when no mention targets are configured", %{alert: alert} do
      put_discord_mentions_enabled(true)

      [message] = EmbedFormatter.format_route_alert(alert, mention_targets: [])

      refute Map.has_key?(message, "content")
      refute Map.has_key?(message, "allowed_mentions")
    end

    test "no content when the mentions env gate is off, even with targets configured", %{
      alert: alert
    } do
      put_discord_mentions_enabled(false)

      [message] =
        EmbedFormatter.format_route_alert(alert, mention_targets: ["role:123456789012345678"])

      refute Map.has_key?(message, "content")
    end

    test "an improved alert never carries content, even with targets configured", %{alert: alert} do
      put_discord_mentions_enabled(true)

      improved = %{alert | kind: :improved}

      [message] =
        EmbedFormatter.format_route_alert(improved, mention_targets: ["role:123456789012345678"])

      refute Map.has_key?(message, "content")
      refute Map.has_key?(message, "allowed_mentions")
    end

    # Mention injection guard (design: "Mention injection is a real risk").
    # A system's temporary_name is user-supplied and goes in the EMBED only;
    # it must never reach `content`, and `allowed_mentions` must stay a closed
    # allowlist regardless of what the embed renders.
    test "a system named @everyone does not inject into content", %{alert: alert} do
      put_discord_mentions_enabled(true)

      Factory.insert(:map_system, %{
        map_id: alert.map_id,
        solar_system_id: @home,
        name: "J115405",
        temporary_name: "@everyone"
      })

      [message] =
        EmbedFormatter.format_route_alert(alert, mention_targets: ["role:123456789012345678"])

      refute message["content"] =~ "@everyone"

      assert message["allowed_mentions"] ==
               %{"parse" => [], "users" => [], "roles" => ["123456789012345678"]}

      [%{"embeds" => [embed]}] = [message]

      assert embed["fields"] |> Enum.find(&(&1["name"] == "Path")) |> Map.get("value") =~
               "@everyone"
    end

    # `Env.discord_mentions_enabled?/0` reads a nested `:discord_mentions_enabled`
    # key inside the `:external_events` keyword list, not a top-level app env
    # key — mirrors `test/unit/env_discord_mentions_test.exs`.
    defp put_discord_mentions_enabled(enabled?) do
      original = Application.get_env(:wanderer_app, :external_events, [])

      Application.put_env(
        :wanderer_app,
        :external_events,
        Keyword.put(original, :discord_mentions_enabled, enabled?)
      )

      on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
    end
  end
end
