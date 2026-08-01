defmodule WandererApp.ExternalEvents.Discord.MatcherInvolvementTest do
  # `involvement/3` itself is pure: no database, no cache, no application env.
  # This file is `async: false` for one reason only — two tests below assert
  # on a `Logger.debug` message, and `config/test.exs` pins the *primary*
  # Logger level to :warning. `capture_log`'s own `:level` option cannot
  # override that (per its docs: "this setting does not override the overall
  # Logger.level/0 value"), and `Logger.put_process_level/2` does not either:
  # `:logger.allow/2` caches its verdict per *module* in a `persistent_term`,
  # so it has no way to vary by calling process. The only lever that actually
  # works is the global primary level, so we flip it for the duration of the
  # affected tests and restore it in `on_exit` — which requires this file to
  # not run concurrently with other async suites.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias WandererApp.ExternalEvents.Discord.Matcher

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  @tracked MapSet.new([1001, 1002])
  @focus [500_001]

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

  test "a tracked victim character is a loss" do
    kill = nested(%{"victim_char_id" => 1001})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :victim}
  end

  test "a victim in a focused corporation is a loss" do
    kill = nested(%{"victim_corp_id" => 500_001})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :victim}
  end

  test "a tracked attacker character is a kill" do
    kill = nested(%{"attacker_char_ids" => [4242, 1002]})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :attacker}
  end

  test "an attacker in a focused corporation is a kill" do
    kill = nested(%{"attacker_corp_ids" => [999_999, 500_001]})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :attacker}
  end

  test "an untouched kill is not involved" do
    kill = nested(%{"attacker_char_ids" => [4242], "attacker_corp_ids" => [999_999]})

    assert Matcher.involvement(kill, @tracked, @focus) == :not_involved
  end

  # Pins the ordering from spec section 3. Reversing the two blocks leaves every
  # other test in this file green while turning every self-inflicted loss into a
  # green "kill" embed in the channel.
  test "the victim check wins when both sides are tracked" do
    kill = nested(%{"victim_char_id" => 1001, "attacker_char_ids" => [1002]})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :victim}
  end

  test "a flat payload with a tracked victim is still a loss" do
    kill = flat(%{"victim_char_id" => 1001})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :victim}
  end

  test "a flat payload with no victim match is not involved and logs the divergence" do
    kill = flat(%{"killmail_id" => 900_777})

    log =
      capture_log([level: :debug], fn ->
        assert Matcher.involvement(kill, @tracked, @focus) == :not_involved
      end)

    assert log =~ "900777"
    assert log =~ "attacker data absent"
  end

  # THE case that distinguishes absent from empty. `Map.get(k, [])` in the
  # implementation makes this test pass and the previous one fail; this one
  # exists so nobody "fixes" that by silencing the log unconditionally.
  test "present-but-empty attacker lists are not a divergence" do
    kill = nested(%{"attacker_char_ids" => [], "attacker_corp_ids" => []})

    log =
      capture_log([level: :debug], fn ->
        assert Matcher.involvement(kill, @tracked, @focus) == :not_involved
      end)

    refute log =~ "attacker data absent"
  end

  test "an empty focus list never matches" do
    kill = nested(%{"victim_corp_id" => 500_001, "attacker_corp_ids" => [500_001]})

    assert Matcher.involvement(kill, @tracked, []) == :not_involved
  end

  # `victim_char_id` is a pass-through on the flat-payload branch (Task 5) and
  # is NOT normalized by `collect_ids/2` — unlike the attacker id lists, it can
  # arrive as a binary. The comparison site here must coerce it the same way
  # `tracked_eve_ids/1` coerces `eve_id`, or a string-typed tracked victim
  # silently fails to match.
  test "a string-typed victim char id still produces a loss verdict" do
    kill = flat(%{"victim_char_id" => "1001"})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :victim}
  end

  test "a malformed victim char id string does not match and does not crash" do
    kill = flat(%{"victim_char_id" => "12345abc"})

    # `parse_eve_id/1` logs a warning for the non-numeric id; suppress it here
    # so this test doesn't print a stray log line on every green run.
    capture_log(fn ->
      assert Matcher.involvement(kill, @tracked, @focus) == :not_involved
    end)
  end

  # `collect_ids/2` normalizes attacker ids to integers on the *nested*
  # branch only (`add_attacker_identity_data/2`); the flat branch is a pure
  # pass-through with no coercion. Nothing today enforces that a flat
  # payload can't carry these keys as binaries, so the comparison site must
  # coerce them too, or a string-typed tracked attacker silently misses.
  test "a flat-shaped payload with string attacker ids still produces a kill verdict" do
    kill = flat(%{"attacker_char_ids" => ["1002"], "attacker_corp_ids" => []})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :attacker}
  end

  # NPC and structure kills legitimately have no character victim. Both
  # attacker keys are absent on this fixture too, so this also fires the
  # divergence log — wrapped to keep test output clean.
  test "an absent victim char id does not match and does not crash" do
    kill = flat(%{"victim_char_id" => nil, "victim_corp_id" => nil})

    capture_log(fn ->
      assert Matcher.involvement(kill, @tracked, @focus) == :not_involved
    end)
  end

  # Half-present attacker data: one key present, the other absent. The `||`
  # inside `attacker_match?/3` must not be reached by the absent-vs-empty
  # gate re-triggering on the missing half.
  test "one attacker key present and the other absent still matches on the present key" do
    kill = flat(%{"attacker_char_ids" => [1002]})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :attacker}
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
