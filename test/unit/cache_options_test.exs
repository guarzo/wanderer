defmodule WandererApp.CacheOptionsTest do
  @moduledoc """
  Guards against Cachex options that do nothing.

  Every cache in `application.ex` was declared with `default_ttl:`, which is a
  Cachex 2.x option. On 3.x it is not recognised, and Cachex ignores options it
  does not recognise rather than rejecting them — so fifteen caches claimed an
  expiry policy in source, applied none at runtime, and nothing anywhere said
  so. Two comments elsewhere in the tree had been written reasoning from those
  TTLs as if they were real.

  This is a source-level test on purpose. A runtime assertion would have to
  start every cache to check a property that is fully determined by the child
  spec, and a dead option is dead whether or not the cache is ever started.
  """

  use ExUnit.Case, async: true

  @application_path "lib/wanderer_app/application.ex"

  # Options accepted by Cachex 2.x and silently dropped by 3.x, mapped to the
  # 3.x spelling. `grep` for the option name is enough: these appear only in
  # cache child specs.
  @dead_cachex_options %{
    "default_ttl" => "expiration: expiration(default: ...)",
    "ttl_interval" => "expiration: expiration(interval: ...)",
    "default_fallback" => "fallback: fallback(default: ...)",
    "record_stats" => "stats: true"
  }

  test "no cache is declared with a Cachex 2.x option" do
    source = code_without_comments(@application_path)

    found =
      @dead_cachex_options
      |> Enum.filter(fn {option, _replacement} ->
        Regex.match?(~r/\b#{option}:/, source)
      end)

    assert found == [],
           """
           #{@application_path} declares Cachex options that Cachex 3.x ignores:

           #{Enum.map_join(found, "\n", fn {option, replacement} -> "  #{option}:  ->  #{replacement}" end)}

           Cachex 3 drops unrecognised options without complaining, so the
           option reads as configuration and behaves as a comment. Either use
           the 3.x spelling — which turns real expiry on, so decide that
           deliberately — or remove the option.
           """
  end

  # Whole-line comments are dropped before matching: the file documents these
  # option names in prose right above the cache list, and prose naming a dead
  # option is the opposite of the problem. Only full-line comments are stripped,
  # so a trailing `# default_ttl: ...` on a code line would still trip the test
  # — acceptable, since the point is to catch the option in a child spec.
  defp code_without_comments(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end
end
