defmodule WandererAppWeb.MapLocationApiEventHandler do
  @moduledoc false
  alias WandererApp.MapIntegrationTokens, as: Tokens

  @errors %{
    forbidden: "You no longer have permission to manage this Location API token.",
    disabled: "The Location API is disabled.",
    conflict: "Your token changed. Reload it before trying again.",
    invalid_request: "Invalid Location API request.",
    service_unavailable: "The Location API is temporarily unavailable."
  }

  def handle(event, data, %{assigns: %{map_id: map_id, current_user: user}} = socket) do
    # Identity comes only from the signed LiveView socket. Dedicated replies are
    # the only plaintext transport; do not assign or broadcast these results.
    reply = event |> dispatch(data, map_id, user) |> reply()
    {:reply, reply, socket}
  end

  def handle(_, _, socket), do: {:reply, reply({:error, :forbidden}), socket}

  defp dispatch("get_location_api_settings", _, map, user), do: Tokens.settings(map, user)

  defp dispatch("set_location_api_enabled", %{"enabled" => enabled}, map, user)
       when is_boolean(enabled),
       do: Tokens.set_enabled(map, user, enabled)

  defp dispatch("get_location_api_token", _, map, user), do: Tokens.get(map, user)
  defp dispatch("generate_location_api_token", _, map, user), do: Tokens.generate(map, user)

  defp dispatch(
         "regenerate_location_api_token",
         %{"id" => id, "generation" => generation},
         map,
         user
       ),
       do: Tokens.regenerate(map, user, id, generation)

  defp dispatch(
         "revoke_location_api_token",
         %{"id" => id, "generation" => generation},
         map,
         user
       ),
       do: Tokens.revoke(map, user, id, generation)

  defp dispatch(_, _, _, _), do: {:error, :invalid_request}

  defp reply({:ok, %{token: %Tokens.Revealed{} = token} = result}),
    do: result |> Map.put(:token, Map.from_struct(token)) |> Map.put(:success, true)

  defp reply({:ok, result}), do: Map.put(result, :success, true)

  defp reply({:error, code}) do
    code = if Map.has_key?(@errors, code), do: code, else: :service_unavailable
    %{success: false, error: Map.fetch!(@errors, code), code: Atom.to_string(code)}
  end
end
