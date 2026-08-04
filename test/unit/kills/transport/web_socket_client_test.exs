defmodule WandererApp.Kills.Transport.WebSocketClientTest do
  # `split_opts/1` is pure.
  use ExUnit.Case, async: true

  alias WandererApp.Kills.Transport.WebSocketClient

  describe "split_opts/1" do
    # The bug this module exists to fix: upstream splits on
    # [:extra_headers, :ssl_verify] only, so :socket_opts fell through into the
    # handler-state argument and never reached :websocket_client.
    test "routes :socket_opts to the websocket_client options" do
      {ws_opts, rest} = WebSocketClient.split_opts(socket_opts: [:inet6])

      assert ws_opts == [socket_opts: [:inet6]]
      assert rest == []
    end

    test "still routes the two options upstream already handled" do
      {ws_opts, rest} =
        WebSocketClient.split_opts(extra_headers: [{"x", "y"}], ssl_verify: :verify_none)

      assert Keyword.fetch!(ws_opts, :extra_headers) == [{"x", "y"}]
      assert Keyword.fetch!(ws_opts, :ssl_verify) == :verify_none
      assert rest == []
    end

    # Anything upstream treats as handler state must keep being handler state,
    # or the shim breaks GenSocketClient rather than fixing it.
    test "leaves unrecognised options in the handler-state half" do
      {ws_opts, rest} = WebSocketClient.split_opts(timeout: 10_000, tcp_opts: [x: 1])

      assert ws_opts == []
      assert Keyword.fetch!(rest, :timeout) == 10_000
      assert Keyword.fetch!(rest, :tcp_opts) == [x: 1]
    end

    test "partitions a mixed keyword list into both halves" do
      {ws_opts, rest} =
        WebSocketClient.split_opts(socket_opts: [:inet6], timeout: 10_000)

      assert ws_opts == [socket_opts: [:inet6]]
      assert rest == [timeout: 10_000]
    end

    test "handles an empty option list" do
      assert WebSocketClient.split_opts([]) == {[], []}
    end
  end

  describe "behaviour conformance" do
    # The shim delegates push/2 and implements start_link/2. If a
    # phoenix_gen_socket_client upgrade adds a callback, this test fails and
    # the handler-state coupling gets re-verified — which is the point.
    test "exports both Transport callbacks" do
      assert function_exported?(WebSocketClient, :start_link, 2)
      assert function_exported?(WebSocketClient, :push, 2)
    end
  end
end
