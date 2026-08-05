defmodule WandererApp.Market.Triff.HttpStub do
  @moduledoc """
  Test double for triff.tools HTTP calls.

  State lives in ONE named Agent shared by every test, so any test using this
  stub must be `async: false`. Call `start/0` in setup (it resets the state if
  the Agent is already up), `set_responses/1` to script replies, and
  `requests/0` to assert on what was requested.

  Mirrors `WandererApp.ExternalEvents.Discord.HttpStub`.
  """
  @behaviour WandererApp.Market.Triff.HttpClient

  @agent __MODULE__.Agent

  def start do
    # `Agent.start`, not `start_link`: linking would tie the shared Agent to
    # whichever test process happened to call `start/0` first, so it would die
    # with that test, and an enrichment task still in flight would then hit a
    # dead Agent and exit `:noproc` instead of getting the scripted response.
    case Agent.start(fn -> new_state() end, name: @agent) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> reset() && {:ok, pid}
      {:error, reason} -> raise "could not start #{inspect(@agent)}: #{inspect(reason)}"
    end
  end

  def reset, do: Agent.update(@agent, fn _ -> new_state() end) == :ok

  defp new_state, do: %{responses: [], requests: []}

  @doc """
  Queues responses, consumed in order. Each is `{:ok, status, body}` or
  `{:error, term}`. A body given as a map is JSON-encoded for you. When the
  queue runs dry the stub returns an empty `types` list rather than raising, so
  a test only has to script the calls it cares about.
  """
  def set_responses(responses), do: Agent.update(@agent, &%{&1 | responses: responses})

  @doc "Returns the requested urls, in the order they were sent."
  def requests, do: Agent.get(@agent, & &1.requests) |> Enum.reverse()

  @impl true
  def get(url, _headers) do
    Agent.get_and_update(@agent, fn state ->
      state = %{state | requests: [url | state.requests]}

      case state.responses do
        [] -> {{:ok, 200, ~s({"types":[]})}, state}
        [resp | rest] -> {encode(resp), %{state | responses: rest}}
      end
    end)
  end

  defp encode({:ok, status, body}) when is_map(body), do: {:ok, status, Jason.encode!(body)}
  defp encode(resp), do: resp
end
