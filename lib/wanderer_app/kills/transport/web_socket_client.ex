defmodule WandererApp.Kills.Transport.WebSocketClient do
  @moduledoc """
  A thin wrapper around `Phoenix.Channels.GenSocketClient.Transport.WebSocketClient`
  that also forwards `:socket_opts` through to `:websocket_client`.

  Upstream splits transport options on exactly `[:extra_headers, :ssl_verify]`
  (`web_socket_client.ex:18`) and passes everything else through as the handler
  state, so `:socket_opts` — the key `:websocket_client` actually reads
  (`websocket_client.erl:195`) — never reaches the socket.

  Without this, `:inet6` cannot be set. Erlang's `gen_tcp` resolves hostnames as
  IPv4 by default, so a kills service published only as an AAAA record — which
  is what private container networks such as Fly's 6PN produce — is
  unreachable, and the socket retries forever.

  This module couples to an upstream private contract: the handler-state
  argument is `[socket, transport_options]` (`web_socket_client.ex:48`).
  `phoenix_gen_socket_client` is pinned in `mix.exs` for that reason. Delete
  this module once `:socket_opts` is added to upstream's split list.
  """
  @behaviour Phoenix.Channels.GenSocketClient.Transport

  @upstream Phoenix.Channels.GenSocketClient.Transport.WebSocketClient
  @websocket_client Application.compile_env(
                      :wanderer_app,
                      :websocket_client_module,
                      :websocket_client
                    )
  @ws_opts [:extra_headers, :ssl_verify, :socket_opts]

  @doc """
  Partitions transport options into `{websocket_client_options, handler_state}`.

  Public only so it can be tested directly; not part of the behaviour.
  """
  def split_opts(transport_options), do: Keyword.split(transport_options, @ws_opts)

  @impl true
  def start_link(url, transport_options) do
    {ws_opts, rest} = split_opts(transport_options)

    url
    |> to_charlist()
    |> @websocket_client.start_link(@upstream, [self(), rest], ws_opts)
  end

  @impl true
  defdelegate push(pid, frame), to: @upstream
end
