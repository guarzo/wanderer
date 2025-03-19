defmodule WandererApp.Repo.Migrations.FixBase64Encoding do
  @moduledoc """
  Fixes Base64 encoding issues in encrypted fields.
  """

  use Ecto.Migration
  require Logger

  def up do
    # Execute dummy query to ensure the connection is working
    execute "SELECT 1", ""
    
    # Fix corp_wallet_transactions
    fix_corp_wallet_transactions()
    
    # Fix character table
    fix_character_encrypted_fields()
    
    # Fix user table
    fix_user_balance()

    # Log migration completion
    Logger.info("Base64 encoding fix migration completed successfully")
  end

  def down do
    # No rollback needed as we're fixing corrupted data
    :ok
  end

  defp fix_corp_wallet_transactions do
    # Get all records
    %{rows: rows} = repo().query!("""
    SELECT id, encrypted_amount_encoded, encrypted_balance_encoded, encrypted_reason_encoded 
    FROM corp_wallet_transactions_v1
    """, [], log: false)
    
    # Process each record
    Enum.each(rows || [], fn [id, amount, balance, reason] ->
      # Fix amount field if needed
      if amount && has_invalid_base64?(amount) do
        fixed = convert_url_safe_to_standard_base64(amount)
        execute "UPDATE corp_wallet_transactions_v1 SET encrypted_amount_encoded = $1 WHERE id = $2", [fixed, id]
        Logger.info("Fixed amount encoding for corp_wallet_transaction id=#{id}")
      end
      
      # Fix balance field if needed
      if balance && has_invalid_base64?(balance) do
        fixed = convert_url_safe_to_standard_base64(balance)
        execute "UPDATE corp_wallet_transactions_v1 SET encrypted_balance_encoded = $1 WHERE id = $2", [fixed, id]
        Logger.info("Fixed balance encoding for corp_wallet_transaction id=#{id}")
      end
      
      # Fix reason field if needed
      if reason && has_invalid_base64?(reason) do
        fixed = convert_url_safe_to_standard_base64(reason)
        execute "UPDATE corp_wallet_transactions_v1 SET encrypted_reason_encoded = $1 WHERE id = $2", [fixed, id]
        Logger.info("Fixed reason encoding for corp_wallet_transaction id=#{id}")
      end
    end)
  end

  defp fix_character_encrypted_fields do
    # Get all records
    %{rows: rows} = repo().query!("""
    SELECT id, 
           encrypted_location, 
           encrypted_ship, 
           encrypted_solar_system_id,
           encrypted_structure_id, 
           encrypted_access_token, 
           encrypted_refresh_token,
           encrypted_eve_wallet_balance
    FROM character_v1
    """, [], log: false)
    
    # Field names in the same order as the query
    fields = [
      :encrypted_location,
      :encrypted_ship,
      :encrypted_solar_system_id,
      :encrypted_structure_id,
      :encrypted_access_token,
      :encrypted_refresh_token,
      :encrypted_eve_wallet_balance
    ]
    
    # Process each character record
    Enum.each(rows || [], fn [id | values] ->
      # Check each field
      Enum.zip(fields, values)
      |> Enum.each(fn {field, value} ->
        if value && has_invalid_base64?(value) do
          fixed = convert_url_safe_to_standard_base64(value)
          execute "UPDATE character_v1 SET #{field} = $1 WHERE id = $2", [fixed, id]
          Logger.info("Fixed #{field} encoding for character id=#{id}")
        end
      end)
    end)
  end

  defp fix_user_balance do
    # Get all records
    %{rows: rows} = repo().query!("""
    SELECT id, encrypted_balance
    FROM user_v1
    WHERE encrypted_balance IS NOT NULL
    """, [], log: false)
    
    # Process each user record
    Enum.each(rows || [], fn [id, balance] ->
      if balance && has_invalid_base64?(balance) do
        fixed = convert_url_safe_to_standard_base64(balance)
        execute "UPDATE user_v1 SET encrypted_balance = $1 WHERE id = $2", [fixed, id]
        Logger.info("Fixed balance encoding for user id=#{id}")
      end
    end)
  end

  # Helper to check for invalid Base64 characters
  defp has_invalid_base64?(binary) when is_binary(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.any?(fn c ->
      # Check for URL-safe Base64 chars that aren't valid in standard Base64
      c == 45 || c == 95 ||  # - and _
      # Also check for any non-Base64 characters
      not ((c >= 65 and c <= 90) or  # A-Z
            (c >= 97 and c <= 122) or  # a-z
            (c >= 48 and c <= 57) or  # 0-9
            c == 43 or c == 47 or  # +/
            c == 61)  # =
    end)
  end
  defp has_invalid_base64?(_), do: false

  # Convert URL-safe Base64 to standard Base64
  defp convert_url_safe_to_standard_base64(binary) when is_binary(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.map(fn
      45 -> 43  # - to +
      95 -> 47  # _ to /
      c -> c
    end)
    |> :binary.list_to_bin()
  end
  defp convert_url_safe_to_standard_base64(nil), do: nil
end 