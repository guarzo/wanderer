defmodule WandererApp.ExternalEvents.ProducerPayloadContractTest do
  @moduledoc """
  Source-level contract test over the system-event producers.

  The JSON:API formatter identifies system events by the `system_id` the
  producer sends; without it every add_system falls back to the event-ULID
  shape. That dependency is invisible from the formatter's own tests - they
  are fed fixtures, not real broadcasts - so a refactor that drops the
  `system_id:` line would leave the whole suite green while silently
  reverting every add_system on the wire.

  This test therefore reads the producer source, parses it, and asserts the
  literal payload of every add_system/deleted_system broadcast. It is a
  source-level test on purpose: exercising these code paths for real needs a
  running map server, a database, and ESI static data, none of which this
  invariant actually depends on.
  """
  use ExUnit.Case, async: true

  @producer "lib/wanderer_app/map/server/map_server_systems_impl.ex"

  # Every key each site sent before system_id was added, plus system_id.
  # Removing or renaming any of these breaks live consumers: the legacy
  # SSE/webhook path forwards payloads verbatim.
  @expected_payload_keys %{
    add_system: [
      # :673 - do_add_system_from_location, existing-system branch
      [:system_id, :solar_system_id, :name, :position_x, :position_y],
      # :729 - do_add_system_from_location, MapSystemRepo.upsert/1 branch
      [:system_id, :solar_system_id, :name, :position_x, :position_y],
      # :943 - do_add_system
      [:system_id, :solar_system_id, :position_x, :position_y]
    ],
    deleted_system: [
      # :385 - delete_systems
      [:system_id, :solar_system_id, :name, :position_x, :position_y]
    ]
  }

  setup_all do
    ast =
      @producer
      |> File.read!()
      |> Code.string_to_quoted!()

    {:ok, broadcasts: collect_broadcasts(ast)}
  end

  # Collects {event_type, payload_keys} for every literal
  # WandererApp.ExternalEvents.broadcast(_, :atom, %{...}) call in the AST.
  defp collect_broadcasts(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:WandererApp, :ExternalEvents]}, :broadcast]}, _,
         [_map_id, event_type, {:%{}, _, pairs}]} = node,
        acc
        when is_atom(event_type) ->
          keys = for {key, _value} <- pairs, is_atom(key), do: key
          {node, [{event_type, keys} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  for {event_type, expected_sites} <- @expected_payload_keys do
    test "every #{event_type} broadcast sends system_id and every key it sent before",
         %{broadcasts: broadcasts} do
      event_type = unquote(event_type)
      expected_sites = unquote(Macro.escape(expected_sites))

      sites =
        for {^event_type, keys} <- broadcasts, do: keys

      # A new, unpatched call site must fail this test rather than slip
      # through as an extra element nobody checked.
      assert length(sites) == length(expected_sites),
             "expected #{length(expected_sites)} #{event_type} broadcast sites in " <>
               "#{@producer}, found #{length(sites)}: #{inspect(sites)}"

      for keys <- sites do
        assert :system_id in keys,
               "a #{event_type} broadcast omits :system_id (keys: #{inspect(keys)})"
      end

      assert Enum.sort(Enum.map(sites, &Enum.sort/1)) ==
               Enum.sort(Enum.map(expected_sites, &Enum.sort/1))
    end
  end
end
