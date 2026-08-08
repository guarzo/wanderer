defmodule WandererApp.ExternalEvents.Discord.EmbedFormatterTest do
  use ExUnit.Case, async: true

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
end
