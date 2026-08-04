defmodule WandererApp.ExternalEvents.Discord.MatcherInvolvementTest do
  # `involvement/3` itself is pure: no database, no application env. This file is
  # `async: false` for two reasons. First, several tests assert on the
  # divergence log and `config/test.exs` pins the *primary* Logger level to
  # :warning; `capture_log`'s own `:level` option cannot override that (per its
  # docs: "this setting does not override the overall Logger.level/0 value"),
  # and `Logger.put_process_level/2` does not either, because `:logger.allow/2`
  # caches its verdict per *module* in a `persistent_term` and so has no way to
  # vary by calling process. The only lever that works is the global primary
  # level. Second, the divergence warning is throttled through a shared Cachex
  # entry, which this file clears per test.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias WandererApp.ExternalEvents.Discord.Matcher

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    # The throttle is process-independent shared state, so without this a test
    # that runs second sees its warning suppressed and fails for a reason that
    # has nothing to do with what it is testing.
    Cachex.del(:discord_notification_cache, Matcher.divergence_log_key())
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  @tracked MapSet.new([1001, 1002])
  @focus [500_001]
  # The map's tracked characters are ignored while a corporation filter is set,
  # so every corporation-mode test passes a tracked set that WOULD match if the
  # old union behaviour came back.
  @no_focus []

  # A nested-format kill: Task 5 guarantees the attacker keys are present, even
  # when the lists are empty.
  defp nested(overrides) do
    Map.merge(
      %{
        "killmail_id" => 900_001,
        "solar_system_id" => 31_000_005,
        "victim_char_id" => 7000,
        "victim_corp_id" => 700_000,
        "attacker_char_ids" => [],
        "attacker_corp_ids" => []
      },
      overrides
    )
  end

  # A flat-format kill: the attacker keys are ABSENT, not empty.
  defp flat(overrides) do
    Map.merge(
      %{
        "killmail_id" => 900_002,
        "solar_system_id" => 31_000_005,
        "victim_char_id" => 7000,
        "victim_corp_id" => 700_000
      },
      overrides
    )
  end

  describe "character mode (no corporation filter)" do
    test "a tracked victim character is a loss" do
      kill = nested(%{"victim_char_id" => 1001})

      assert Matcher.involvement(kill, @tracked, @no_focus) == {:involved, :victim}
    end

    test "a tracked attacker character is a kill" do
      kill = nested(%{"attacker_char_ids" => [4242, 1002]})

      assert Matcher.involvement(kill, @tracked, @no_focus) == {:involved, :attacker}
    end

    test "an untouched kill is not involved" do
      kill = nested(%{"attacker_char_ids" => [4242], "attacker_corp_ids" => [999_999]})

      assert Matcher.involvement(kill, @tracked, @no_focus) == :not_involved
    end

    # Pins the ordering from spec section 3. Reversing the two blocks leaves
    # every other test in this file green while turning every self-inflicted
    # loss into a green "kill" embed in the channel.
    test "the victim check wins when both sides are tracked" do
      kill = nested(%{"victim_char_id" => 1001, "attacker_char_ids" => [1002]})

      assert Matcher.involvement(kill, @tracked, @no_focus) == {:involved, :victim}
    end

    test "corporation membership alone does not match" do
      kill = nested(%{"victim_corp_id" => 500_001, "attacker_corp_ids" => [500_001]})

      assert Matcher.involvement(kill, @tracked, @no_focus) == :not_involved
    end

    # `victim_char_id` is a pass-through on the flat-payload branch (Task 5) and
    # is NOT normalized by `collect_ids/2` — unlike the attacker id lists, it can
    # arrive as a binary. The comparison site here must coerce it the same way
    # `tracked_eve_ids/1` coerces `eve_id`, or a string-typed tracked victim
    # silently fails to match.
    test "a string-typed victim char id still produces a loss verdict" do
      kill = flat(%{"victim_char_id" => "1001"})

      assert Matcher.involvement(kill, @tracked, @no_focus) == {:involved, :victim}
    end

    test "a malformed victim char id string does not match and does not crash" do
      kill = nested(%{"victim_char_id" => "12345abc"})

      # `parse_eve_id/1` logs a warning for the non-numeric id; suppress it here
      # so this test doesn't print a stray log line on every green run.
      capture_log(fn ->
        assert Matcher.involvement(kill, @tracked, @no_focus) == :not_involved
      end)
    end

    # `collect_ids/2` normalizes attacker ids to integers on the *nested*
    # branch only (`add_attacker_identity_data/2`); the flat branch is a pure
    # pass-through with no coercion. Nothing today enforces that a flat
    # payload can't carry these keys as binaries, so the comparison site must
    # coerce them too, or a string-typed tracked attacker silently misses.
    test "a flat-shaped payload with string attacker ids still produces a kill verdict" do
      kill = flat(%{"attacker_char_ids" => ["1002"], "attacker_corp_ids" => []})

      assert Matcher.involvement(kill, @tracked, @no_focus) == {:involved, :attacker}
    end

    # NPC and structure kills legitimately have no character victim.
    test "an absent victim char id does not match and does not crash" do
      kill = nested(%{"victim_char_id" => nil, "victim_corp_id" => nil})

      assert Matcher.involvement(kill, @tracked, @no_focus) == :not_involved
    end

    # Half-present attacker data: one key present, the other absent. The
    # absent-vs-empty gate must not re-trigger on the missing half.
    test "one attacker key present and the other absent still matches on the present key" do
      kill = flat(%{"attacker_char_ids" => [1002]})

      assert Matcher.involvement(kill, @tracked, @no_focus) == {:involved, :attacker}
    end
  end

  describe "corporation filter mode" do
    test "a victim in a filtered corporation is a loss" do
      kill = nested(%{"victim_corp_id" => 500_001})

      assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :victim}
    end

    test "an attacker in a filtered corporation is a kill" do
      kill = nested(%{"attacker_corp_ids" => [999_999, 500_001]})

      assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :attacker}
    end

    test "the victim check still wins when both sides are in a filtered corporation" do
      kill = nested(%{"victim_corp_id" => 500_001, "attacker_corp_ids" => [500_001]})

      assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :victim}
    end

    # THE test for the replacement semantic. The corporation filter answers
    # "who is the character channel for", so setting it must be able to take
    # map-tracked pilots OUT of that channel. If these two ever go green as
    # `{:involved, _}` the filter has silently become a union again, and an
    # admin who set it to narrow the channel has instead widened it.
    test "a tracked victim character is NOT matched while a filter is set" do
      kill = nested(%{"victim_char_id" => 1001})

      assert Matcher.involvement(kill, @tracked, @focus) == :not_involved
    end

    test "a tracked attacker character is NOT matched while a filter is set" do
      kill = nested(%{"attacker_char_ids" => [1002]})

      assert Matcher.involvement(kill, @tracked, @focus) == :not_involved
    end

    # The filter does not read the tracked set at all, so the cache outage that
    # produces `:unknown` in character mode cannot degrade this path.
    test "an unavailable tracked set does not affect a filtered decision" do
      kill = nested(%{"victim_corp_id" => 500_001})

      assert Matcher.involvement(kill, :unavailable, @focus) == {:involved, :victim}
    end

    test "a corporation outside the filter is not involved" do
      kill = nested(%{"victim_corp_id" => 700_000, "attacker_corp_ids" => [999_999]})

      assert Matcher.involvement(kill, @tracked, @focus) == :not_involved
    end
  end

  describe ":unknown verdict" do
    # `:not_involved` is a positive finding, and `Router` acts on it by applying
    # the excluded-system and wormhole-only filters. Reporting it here would
    # mean a cache outage silently drops every k-space kill on the map.
    test "an unavailable tracked set is unknown, not 'not involved'" do
      kill = nested(%{"victim_char_id" => 4242})

      assert Matcher.involvement(kill, :unavailable, @no_focus) == :unknown
    end

    test "a flat payload with no victim match is unknown and warns" do
      kill = flat(%{"killmail_id" => 900_777})

      log =
        capture_log(fn ->
          assert Matcher.involvement(kill, @tracked, @no_focus) == :unknown
        end)

      assert log =~ "900777"
      assert log =~ "attacker data absent"
      # At warning, not debug: this is the reason a kill lands in the system
      # channel rather than the character channel.
      assert log =~ "[warning]"
    end

    test "a flat payload is equally unknown under a corporation filter" do
      kill = flat(%{"victim_corp_id" => 700_000})

      capture_log(fn ->
        assert Matcher.involvement(kill, @tracked, @focus) == :unknown
      end)
    end

    # THE case that distinguishes absent from empty. Reading the attacker keys
    # with a `|| []` default makes the previous tests pass and this one fail;
    # this one exists so nobody "fixes" that by silencing the log unconditionally.
    test "present-but-empty attacker lists are not a divergence" do
      kill = nested(%{"attacker_char_ids" => [], "attacker_corp_ids" => []})

      log =
        capture_log(fn ->
          assert Matcher.involvement(kill, @tracked, @no_focus) == :not_involved
        end)

      refute log =~ "attacker data absent"
    end

    # The warning fires per kill, so an unthrottled one would be the only thing
    # in the log on a feed that only sends flat payloads.
    test "the divergence warning is throttled to one line per interval" do
      log =
        capture_log(fn ->
          assert Matcher.involvement(flat(%{"killmail_id" => 1}), @tracked, @no_focus) == :unknown
          assert Matcher.involvement(flat(%{"killmail_id" => 2}), @tracked, @no_focus) == :unknown
        end)

      assert log =~ "attacker data absent"
      refute log =~ "killmail 2:"
    end
  end

  # `focus_corp_ids` is a caller contract, not runtime data — the guard makes
  # a non-list argument a compile-visible `FunctionClauseError` rather than a
  # `Protocol.UndefinedError` buried inside `Enum.member?/2`'s `in` expansion.
  test "a non-list focus_corp_ids raises FunctionClauseError, not a protocol error" do
    kill = nested(%{})

    assert_raise FunctionClauseError, fn ->
      Matcher.involvement(kill, @tracked, nil)
    end
  end
end
