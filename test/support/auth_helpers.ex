defmodule WandererApp.Test.AuthHelpers do
  @moduledoc """
  Authentication helpers for tests.

  Provides functions to generate proper JWT tokens for testing authenticated endpoints.
  Uses real Guardian JWT implementation for authentic token generation.
  """

  alias WandererApp.Guardian

  @doc """
  Generates a real JWT token for a user using Guardian.

  This creates a proper JWT token that matches production authentication flow.
  """
  def generate_jwt_token(user) do
    case Guardian.generate_user_token(user) do
      {:ok, token, _claims} ->
        token

      {:error, reason} ->
        raise "Failed to generate JWT token for user #{user.id}: #{inspect(reason)}"
    end
  end

  @doc """
  Generates a real JWT token for a character using Guardian.

  This creates a proper JWT token that matches production authentication flow.
  """
  def generate_character_token(character) do
    case Guardian.generate_character_token(character) do
      {:ok, token, _claims} ->
        token

      {:error, reason} ->
        raise "Failed to generate JWT token for character #{character.id}: #{inspect(reason)}"
    end
  end

  @doc """
  Decodes a JWT token using Guardian (for debugging and validation).
  """
  def decode_jwt_token(token) do
    case Guardian.decode_and_verify(token) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates that a JWT token is properly formatted and signed.
  """
  def validate_jwt_token(token) do
    Guardian.validate_token(token)
  end
end
