defmodule WandererApp.Kills.ClientBackoffTest do
  # `retry_delay_ms/2` is pure: no app env, no cache, no process state.
  use ExUnit.Case, async: true

  alias WandererApp.Kills.Client

  # `:rand.uniform/1` returns an integer in 1..n. These three stand-ins pin it to
  # the bottom, middle and top of that range, which map to the minimum, zero and
  # maximum jitter offsets respectively.
  #
  # They are functions rather than module attributes on purpose: an anonymous
  # function cannot be stored in a module attribute (it is not a valid
  # compile-time value).
  defp min_jitter, do: fn _n -> 1 end
  defp no_jitter, do: fn n -> div(n + 1, 2) end
  defp max_jitter, do: fn n -> n end

  describe "retry_delay_ms/2 with jitter pinned to zero" do
    test "doubles from 1s and holds at the 60s ceiling" do
      assert Client.retry_delay_ms(0, no_jitter()) == 1_000
      assert Client.retry_delay_ms(1, no_jitter()) == 2_000
      assert Client.retry_delay_ms(2, no_jitter()) == 4_000
      assert Client.retry_delay_ms(3, no_jitter()) == 8_000
      assert Client.retry_delay_ms(4, no_jitter()) == 16_000
      assert Client.retry_delay_ms(5, no_jitter()) == 32_000
      assert Client.retry_delay_ms(6, no_jitter()) == 60_000
      assert Client.retry_delay_ms(7, no_jitter()) == 60_000
      assert Client.retry_delay_ms(10, no_jitter()) == 60_000
    end
  end

  describe "retry_delay_ms/2 with jitter pinned to its minimum" do
    test "produces exactly the base minus 30%" do
      assert Client.retry_delay_ms(0, min_jitter()) == 700
      assert Client.retry_delay_ms(1, min_jitter()) == 1_400
      assert Client.retry_delay_ms(2, min_jitter()) == 2_800
      assert Client.retry_delay_ms(3, min_jitter()) == 5_600
      assert Client.retry_delay_ms(4, min_jitter()) == 11_200
      assert Client.retry_delay_ms(5, min_jitter()) == 22_400
      assert Client.retry_delay_ms(6, min_jitter()) == 42_000
      assert Client.retry_delay_ms(9, min_jitter()) == 42_000
    end
  end

  describe "retry_delay_ms/2 with jitter pinned to its maximum" do
    test "produces exactly the base plus 30% below the ceiling" do
      assert Client.retry_delay_ms(0, max_jitter()) == 1_300
      assert Client.retry_delay_ms(1, max_jitter()) == 2_600
      assert Client.retry_delay_ms(2, max_jitter()) == 5_200
      assert Client.retry_delay_ms(3, max_jitter()) == 10_400
      assert Client.retry_delay_ms(4, max_jitter()) == 20_800
      assert Client.retry_delay_ms(5, max_jitter()) == 41_600
    end

    # THE regression this design guards against. With the ceiling applied only
    # before jitter, retry 6 computes min(64_000, 60_000) = 60_000, then adds
    # +18_000 for 78_000 — over the ceiling. The ceiling must be applied again
    # after the offset.
    test "the ceiling holds AFTER jitter is applied, not before" do
      assert Client.retry_delay_ms(6, max_jitter()) == 60_000
      assert Client.retry_delay_ms(7, max_jitter()) == 60_000
      assert Client.retry_delay_ms(20, max_jitter()) == 60_000
    end
  end

  describe "retry_delay_ms/2 invariants across the real random source" do
    test "no delay ever exceeds the 60s ceiling or drops to zero" do
      for retry_count <- 0..20, _ <- 1..50 do
        delay = Client.retry_delay_ms(retry_count)

        assert delay > 0, "retry #{retry_count} produced a non-positive delay #{delay}"
        assert delay <= 60_000, "retry #{retry_count} produced #{delay}, over the ceiling"
      end
    end

    test "the first retry is not zero" do
      for _ <- 1..100 do
        assert Client.retry_delay_ms(0) >= 700
      end
    end

    test "the default rand_fun is used when the second argument is omitted" do
      assert is_integer(Client.retry_delay_ms(3))
    end

    # Not a strict ordering assertion — jitter ranges overlap between adjacent
    # steps. This asserts the *envelope* grows, which a broken exponent would
    # not.
    test "later retries back off further than earlier ones" do
      assert Client.retry_delay_ms(0, max_jitter()) < Client.retry_delay_ms(2, min_jitter())
      assert Client.retry_delay_ms(2, max_jitter()) < Client.retry_delay_ms(4, min_jitter())
    end
  end
end
