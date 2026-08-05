defmodule WandererApp.Kills.Transport.WebSocketClientTest do
  # `split_opts/1` is pure, but `start_link/2` drives the Test.WebSocketClientMock
  # (private mode, so this must stay tied to this test's own process).
  use ExUnit.Case, async: true

  import Mox

  alias WandererApp.Kills.Transport.WebSocketClient

  setup :verify_on_exit!

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

  describe "start_link/2" do
    # This is the regression I-3 in the final review calls out: the
    # split_opts/1 tests above never prove :socket_opts actually reaches
    # :websocket_client.start_link/4. Drive start_link/2 through
    # Test.WebSocketClientMock (config/test.exs sets :websocket_client_module)
    # and assert on the exact argument positions upstream reads
    # (websocket_client.erl:195-196 for socket_opts, web_socket_client.ex:48
    # for the handler-state shape). This test fails if the ws_opts/rest
    # arguments in web_socket_client.ex's start_link/2 are swapped.
    test "forwards :socket_opts to :websocket_client and keeps the rest as handler state" do
      test_pid = self()

      Test.WebSocketClientMock
      |> expect(:start_link, fn url, upstream, handler_args, ws_opts ->
        assert url == ~c"ws://example.com"
        assert upstream == Phoenix.Channels.GenSocketClient.Transport.WebSocketClient
        assert ws_opts == [socket_opts: [:inet6]]
        assert handler_args == [test_pid, [timeout: 10_000]]
        {:ok, test_pid}
      end)

      assert {:ok, ^test_pid} =
               WebSocketClient.start_link("ws://example.com",
                 socket_opts: [:inet6],
                 timeout: 10_000
               )
    end
  end

  describe "behaviour conformance" do
    # The shim delegates push/2 and implements start_link/2 to satisfy
    # @behaviour Phoenix.Channels.GenSocketClient.Transport. This does NOT
    # guard against upstream adding a new callback — that surfaces as a
    # compile-time @behaviour warning (there is no --warnings-as-errors gate),
    # not a test failure. It only guards against these two functions being
    # renamed or dropped. Coverage of the actual handler-state coupling lives
    # in the "start_link/2" describe block above.
    test "exports both Transport callbacks" do
      Code.ensure_loaded!(WebSocketClient)

      assert function_exported?(WebSocketClient, :start_link, 2)
      assert function_exported?(WebSocketClient, :push, 2)
    end
  end
end
