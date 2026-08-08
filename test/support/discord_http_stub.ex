defmodule WandererApp.ExternalEvents.Discord.HttpStub do
  @moduledoc """
  Test double for Discord HTTP delivery.

  State lives in ONE named Agent shared by every test, so any test using this
  stub must be `async: false`. Call `start/0` in setup (it resets the state if
  the Agent is already up), `set_responses/1` to script replies, and
  `requests/0` to assert on what was sent.
  """
  @behaviour WandererApp.ExternalEvents.Discord.HttpClient

  @agent __MODULE__.Agent

  def start do
    # `Agent.start`, not `start_link`: linking would tie the shared Agent to
    # whichever test process happened to call `start/0` first, so it would die
    # with that test. A worker Task still in flight afterwards would then hit a
    # dead Agent, exit `:noproc`, and record a spurious delivery failure instead
    # of the scripted response.
    case Agent.start(fn -> new_state() end, name: @agent) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> reset() && {:ok, pid}
      {:error, reason} -> raise "could not start #{inspect(@agent)}: #{inspect(reason)}"
    end
  end

  def reset, do: Agent.update(@agent, fn _ -> new_state() end) == :ok

  defp new_state, do: %{responses: [], by_url: %{}, requests: [], gets: %{}}

  @doc "Queues responses for ANY url, consumed in order. Each is {:ok, status, headers} or {:error, term}."
  def set_responses(responses), do: Agent.update(@agent, &%{&1 | responses: responses})

  @doc """
  Queues responses for ONE url, consumed in order and checked before the global
  queue. Needed once a map has two webhooks: with a single global queue the two
  destinations race for the scripted reply, so "404 the character webhook" would
  land on whichever request happened to arrive first.
  """
  def set_responses_for(url, responses),
    do: Agent.update(@agent, &%{&1 | by_url: Map.put(&1.by_url, url, responses)})

  @doc "Returns {url, body} tuples in the order they were sent."
  def requests, do: Agent.get(@agent, & &1.requests) |> Enum.reverse()

  @doc "Returns the {url, body} tuples sent to one url, in order."
  def requests_for(url), do: Enum.filter(requests(), fn {u, _body} -> u == url end)

  @doc """
  Scripts a reply for one GET url as `{:ok, status, body}` or `{:error, term}`.

  Unscripted GETs return `{:error, :not_stubbed}` rather than a success: every
  test that renders the notifications settings tab reaches `ChannelInfo`
  incidentally, and those tests assert on the tab, not on Discord. An error is
  the input that exercises the masked-hint fallback, which is what an offline
  test environment genuinely is.
  """
  def set_get_response(url, response),
    do: Agent.update(@agent, &%{&1 | gets: Map.put(&1.gets, url, response)})

  @impl true
  def get(url, _headers) do
    Agent.get(@agent, &Map.get(&1.gets, url, {:error, :not_stubbed}))
  end

  @impl true
  def post(url, body) do
    Agent.get_and_update(@agent, fn state ->
      state = %{state | requests: [{url, body} | state.requests]}

      case Map.get(state.by_url, url) do
        [resp | rest] ->
          {resp, %{state | by_url: Map.put(state.by_url, url, rest)}}

        _ ->
          case state.responses do
            [] -> {{:ok, 204, []}, state}
            [resp | rest] -> {resp, %{state | responses: rest}}
          end
      end
    end)
  end
end
