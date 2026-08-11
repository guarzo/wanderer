defmodule WandererApp.MetricsPortConsistencyTest do
  @moduledoc """
  Guards the metrics port against drifting between the two files that hardcode it.

  `fly.toml`'s `[[metrics]]` block tells Fly which port to scrape. It cannot read
  `METRICS_PORT`, and `config/runtime.exs` cannot read `fly.toml` — the release
  image does not ship it. So the value is written down twice, plus a third time
  in the runtime guard that raises when the env var diverges.

  Every way these can disagree fails silently and identically: PromEx serves
  /metrics correctly on one port, Fly polls another and collects nothing, and the
  result presents as "the app emits no metrics" rather than as a misconfiguration.

  The runtime guard only catches `METRICS_PORT` drifting away from the literal.
  It cannot catch `fly.toml` drifting, because by then the literal is the stale
  side. This test covers that direction.
  """

  use ExUnit.Case, async: true

  @fly_toml "fly.toml"
  @runtime_exs "config/runtime.exs"

  defp read!(relative), do: relative |> Path.expand(File.cwd!()) |> File.read!()

  defp capture!(source, regex, label) do
    case Regex.run(regex, source, capture: :all_but_first) do
      [value] ->
        String.to_integer(value)

      _ ->
        flunk("""
        Could not find #{label}.

        The regex this test uses no longer matches. Update the test to match the
        new shape — do not delete it, or the ports can drift apart unnoticed.
        """)
    end
  end

  test "fly.toml's scrape port matches the METRICS_PORT default and the runtime guard" do
    fly = read!(@fly_toml)
    runtime = read!(@runtime_exs)

    scrape_port =
      capture!(
        fly,
        ~r/\[\[metrics\]\].*?^\s*port\s*=\s*(\d+)/ms,
        "the [[metrics]] port in fly.toml"
      )

    default_port =
      capture!(
        runtime,
        ~r/System\.get_env\("METRICS_PORT",\s*"(\d+)"\)/,
        "the METRICS_PORT default in config/runtime.exs"
      )

    guard_port =
      capture!(
        runtime,
        ~r/metrics_port\s*!=\s*(\d+)/,
        "the port literal in the METRICS_PORT boot guard in config/runtime.exs"
      )

    assert scrape_port == default_port,
           """
           fly.toml scrapes port #{scrape_port} but METRICS_PORT defaults to #{default_port}.

           Fly would collect nothing, and nothing would report an error.
           """

    assert scrape_port == guard_port,
           """
           fly.toml scrapes port #{scrape_port} but the boot guard in
           config/runtime.exs compares against #{guard_port}.

           The guard is checking a stale value, so it would accept a
           METRICS_PORT that Fly does not scrape.
           """
  end
end
