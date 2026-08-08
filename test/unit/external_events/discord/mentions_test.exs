defmodule WandererApp.ExternalEvents.Discord.MentionsTest do
  use ExUnit.Case, async: true

  alias WandererApp.ExternalEvents.Discord.Mentions

  describe "prefix/1" do
    test "renders a user target" do
      assert Mentions.prefix(["user:123456789012345678"]) == "<@123456789012345678>"
    end

    test "renders a role target" do
      assert Mentions.prefix(["role:987654321098765432"]) == "<@&987654321098765432>"
    end

    test "joins multiple targets with a space, in order" do
      assert Mentions.prefix(["user:111111111111111111", "role:222222222222222222"]) ==
               "<@111111111111111111> <@&222222222222222222>"
    end

    test "empty list is nil" do
      assert Mentions.prefix([]) == nil
    end
  end

  describe "allowed_mentions/1" do
    test "empty targets still has parse: [] and empty lists" do
      assert Mentions.allowed_mentions([]) == %{"parse" => [], "users" => [], "roles" => []}
    end

    test "lists users and roles separately" do
      assert Mentions.allowed_mentions([
               "user:111111111111111111",
               "role:222222222222222222",
               "user:333333333333333333"
             ]) == %{
               "parse" => [],
               "users" => ["111111111111111111", "333333333333333333"],
               "roles" => ["222222222222222222"]
             }
    end

    test "drops invalid entries but keeps the valid ones" do
      assert Mentions.allowed_mentions([
               "user:111111111111111111",
               "@guarzo",
               "role:222222222222222222",
               "user:123"
             ]) == %{
               "parse" => [],
               "users" => ["111111111111111111"],
               "roles" => ["222222222222222222"]
             }
    end
  end

  describe "valid_target?/1" do
    test "accepts well-formed user and role snowflakes" do
      assert Mentions.valid_target?("user:12345678901234567")
      assert Mentions.valid_target?("role:12345678901234567890")
    end

    test "rejects a handle, a bare id, an unknown prefix, and out-of-range lengths" do
      refute Mentions.valid_target?("@guarzo")
      refute Mentions.valid_target?("123456789012345678")
      refute Mentions.valid_target?("corp:123456789012345678")
      refute Mentions.valid_target?("user:123")
      refute Mentions.valid_target?("role:123456789012345678901")
    end

    # `$` matches before a trailing newline in PCRE, so `^...$` accepts this and
    # `allowed_mentions/1` — which splits on ":" rather than re-matching —
    # carries the newline into the snowflake handed to Discord.
    test "rejects a trailing newline" do
      refute Mentions.valid_target?("user:123456789012345678\n")
      refute Mentions.valid_target?("role:123456789012345678\n")

      assert Mentions.allowed_mentions(["user:123456789012345678\n"]) == %{
               "parse" => [],
               "users" => [],
               "roles" => []
             }
    end
  end
end
