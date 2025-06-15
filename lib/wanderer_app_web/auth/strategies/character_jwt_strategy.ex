defmodule WandererAppWeb.Auth.Strategies.CharacterJwtStrategy do
  @moduledoc """
  Authentication strategy for character-specific JWT tokens.

  This strategy validates JWT tokens that include character information,
  typically used for ACL-based authentication where a specific character
  needs to be authenticated.
  """

  @behaviour WandererAppWeb.Auth.AuthStrategy

  import Plug.Conn
  alias WandererApp.Guardian
  alias WandererApp.Api.{User, Character}

  @impl true
  def name, do: :character_jwt

  @impl true
  def validate_opts(_opts), do: :ok

  @impl true
  def authenticate(conn, opts) do
    character_id = opts[:character_id] || conn.params["character_id"]

    with {:header, ["Bearer " <> token]} <- {:header, get_req_header(conn, "authorization")},
         {:decode, {:ok, claims}} <- {:decode, Guardian.decode_and_verify(token)},
         {:user, {:ok, user}} <- {:user, load_user(claims)},
         {:character, {:ok, character}} <- {:character, validate_character(user, character_id)} do
      # Authentication successful
      auth_data = %{
        type: :character_jwt,
        user: user,
        character: character,
        claims: claims
      }

      conn =
        conn
        |> assign(:current_user, user)
        |> assign(:current_character, character)
        |> assign(:authenticated_by, :character_jwt)

      {:ok, conn, auth_data}
    else
      {:header, _} ->
        # No Bearer token, skip this strategy
        :skip

      {:decode, {:error, reason}} ->
        {:error, {:invalid_token, reason}}

      {:user, {:error, reason}} ->
        {:error, {:user_not_found, reason}}

      {:character, {:error, reason}} ->
        {:error, {:character_validation_failed, reason}}
    end
  end

  defp load_user(%{"sub" => user_id}) do
    case User.by_id(user_id) do
      {:ok, user} -> {:ok, user}
      _ -> {:error, :not_found}
    end
  end

  defp load_user(_), do: {:error, :invalid_claims}

  defp validate_character(_user, nil), do: {:error, :character_id_required}

  defp validate_character(user, character_id) do
    with {:ok, character} <- Character.by_id(character_id),
         true <- character.user_id == user.id do
      {:ok, character}
    else
      {:ok, _character} -> {:error, :character_not_owned_by_user}
      _ -> {:error, :character_not_found}
    end
  end
end
