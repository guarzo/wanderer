defmodule WandererApp.Test.TrackedLocationsCleanupTest do
  use ExUnit.Case, async: true
  alias WandererApp.Test.TrackedLocationsFixtures

  test "cleanup attempts every record in order and reraises the first exception with its stack" do
    parent = self()

    try do
      TrackedLocationsFixtures.cleanup([:map, :owner, :user], fn record ->
        send(parent, {:destroy, record})
        if record != :user, do: fail_cleanup(record)
      end)

      flunk("cleanup must surface the first failure")
    rescue
      error in RuntimeError ->
        assert error.message == "cannot delete map"
        assert {__MODULE__, :fail_cleanup, 1, _} = hd(__STACKTRACE__)
    end

    for expected <- [:map, :owner, :user] do
      assert_received {:destroy, actual}
      assert actual == expected
    end
  end

  defp fail_cleanup(record), do: raise("cannot delete #{record}")
end
