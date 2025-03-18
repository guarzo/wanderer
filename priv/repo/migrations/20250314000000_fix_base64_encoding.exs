defmodule WandererApp.Repo.Migrations.FixBase64Encoding do
  @moduledoc """
  Fixes Base64 encoding issues in encrypted fields.
  """

  use Ecto.Migration
  require Logger

  def up do
    # Execute dummy query to ensure the connection is working
    execute "SELECT 1", ""

    # Since we can't rely on application code in migrations
    # We need to run raw SQL to find and fix the corrupted data
    fix_corrupted_data()
  end

  def down do
    # No rollback needed as we're fixing corrupted data
    :ok
  end

  defp fix_corrupted_data do
    # Fix each table with encrypted fields
    fix_corp_wallet_transactions()
    fix_character_encrypted_fields()
    fix_user_balance()
  end

  defp fix_corp_wallet_transactions do
    # Process corp_wallet_transactions table
    query = """
    SELECT id, encrypted_amount_encoded, encrypted_balance_encoded, encrypted_reason_encoded 
    FROM corp_wallet_transactions_v1
    """
    
    %{rows: rows} = execute_and_fetch(query)
    
    # Process each record
    Enum.each(rows, fn [id, amount, balance, reason] ->
      # Fix amount field if needed
      if contains_invalid_base64_chars?(amount) do
        fixed = convert_url_safe_to_standard_base64(amount)
        execute "UPDATE corp_wallet_transactions_v1 SET encrypted_amount_encoded = $1 WHERE id = $2", [fixed, id]
        Logger.info("Fixed amount encoding for corp_wallet_transaction id=#{id}")
      end
      
      # Fix balance field if needed
      if contains_invalid_base64_chars?(balance) do
        fixed = convert_url_safe_to_standard_base64(balance)
        execute "UPDATE corp_wallet_transactions_v1 SET encrypted_balance_encoded = $1 WHERE id = $2", [fixed, id]
        Logger.info("Fixed balance encoding for corp_wallet_transaction id=#{id}")
      end
      
      # Fix reason field if needed
      if reason && contains_invalid_base64_chars?(reason) do
        fixed = convert_url_safe_to_standard_base64(reason)
        execute "UPDATE corp_wallet_transactions_v1 SET encrypted_reason_encoded = $1 WHERE id = $2", [fixed, id]
        Logger.info("Fixed reason encoding for corp_wallet_transaction id=#{id}")
      end
    end)
  end

  defp fix_character_encrypted_fields do
    # Process character table
    query = """
    SELECT id, 
           encrypted_location, 
           encrypted_ship, 
           encrypted_solar_system_id,
           encrypted_structure_id, 
           encrypted_access_token, 
           encrypted_refresh_token,
           encrypted_eve_wallet_balance
    FROM character_v1
    """
    
    %{rows: rows} = execute_and_fetch(query)
    
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
    Enum.each(rows, fn [id | values] ->
      # Check each field
      Enum.zip(fields, values)
      |> Enum.each(fn {field, value} ->
        if value && contains_invalid_base64_chars?(value) do
          fixed = convert_url_safe_to_standard_base64(value)
          execute "UPDATE character_v1 SET #{field} = $1 WHERE id = $2", [fixed, id]
          Logger.info("Fixed #{field} encoding for character id=#{id}")
        end
      end)
    end)
  end

  defp fix_user_balance do
    # Process user table
    query = """
    SELECT id, encrypted_balance
    FROM user_v1
    WHERE encrypted_balance IS NOT NULL
    """
    
    %{rows: rows} = execute_and_fetch(query)
    
    # Process each user record
    Enum.each(rows, fn [id, balance] ->
      if balance && contains_invalid_base64_chars?(balance) do
        fixed = convert_url_safe_to_standard_base64(balance)
        execute "UPDATE user_v1 SET encrypted_balance = $1 WHERE id = $2", [fixed, id]
        Logger.info("Fixed balance encoding for user id=#{id}")
      end
    end)
  end

  # Helper to check for invalid Base64 characters
  defp contains_invalid_base64_chars?(binary) when is_binary(binary) do
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
  defp contains_invalid_base64_chars?(_), do: false

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

  # Helper to execute a query and get results
  defp execute_and_fetch(sql) do
    case repo().__adapter__.execute_and_cache(repo(), sql, [], :all) do
      {:ok, %{rows: rows} = result} -> result
      _ -> %{rows: []}
    end
  end

  # Get repo reference
  defp repo, do: WandererApp.Repo
end 