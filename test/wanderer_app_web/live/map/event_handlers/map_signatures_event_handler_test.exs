defmodule WandererAppWeb.MapSignaturesEventHandlerTest do
  use WandererApp.DataCase, async: false

  alias WandererAppWeb.MapSignaturesEventHandler

  describe "get_system_signatures/1" do
    setup do
      map = WandererAppWeb.Factory.create_map()
      system = WandererAppWeb.Factory.create_map_system(map.id)
      signature = WandererAppWeb.Factory.create_map_system_signature(system.id)

      %{system: system, signature: signature}
    end

    # The frontend reads these with `new Date`, which resolves a zone-less
    # `2026/08/09 10:00:00` as *local* time. That silently shifted every
    # signature by the viewer's UTC offset and pinned the scan-age bookmark at
    # "0h" west of UTC. The zone marker is the whole contract: assert on it here
    # so the format cannot regress to something ambiguous.
    test "serialises timestamps as ISO-8601 with an explicit zone", %{system: system} do
      [serialised] = MapSignaturesEventHandler.get_system_signatures(system.id)

      assert {:ok, _dt, 0} = DateTime.from_iso8601(serialised.updated_at)
      assert {:ok, _dt, 0} = DateTime.from_iso8601(serialised.inserted_at)
      assert String.ends_with?(serialised.updated_at, "Z")
      assert String.ends_with?(serialised.inserted_at, "Z")
    end

    test "the serialised instant matches the stored one", %{
      system: system,
      signature: signature
    } do
      [serialised] = MapSignaturesEventHandler.get_system_signatures(system.id)

      {:ok, parsed, 0} = DateTime.from_iso8601(serialised.updated_at)

      assert DateTime.compare(parsed, signature.updated_at) == :eq
    end
  end
end
