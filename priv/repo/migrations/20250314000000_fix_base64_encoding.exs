defmodule WandererApp.Repo.Migrations.FixBase64Encoding do
  @moduledoc """
  Fixes Base64 encoding issues in encrypted fields.
  """

  use Ecto.Migration
  require Logger

  def up do
    # Execute dummy query to ensure the connection is working
    execute "SELECT 1", ""
    
    # Run a simpler query directly to fix the issues
    Logger.info("Running UTF-8 safe fix query for all tables...")
    
    # Fix with custom SQL that avoids encoding issues
    run_fix_sql()

    # Log migration completion
    Logger.info("Base64 encoding fix migration completed successfully")
  end

  def down do
    # No rollback needed as we're fixing corrupted data
    :ok
  end

  defp run_fix_sql do
    # Create a helper function in the database to convert URL-safe to standard Base64
    execute """
    CREATE OR REPLACE FUNCTION convert_url_safe_base64(data bytea) RETURNS bytea AS $$
    BEGIN
      -- Convert '-' to '+' and '_' to '/'
      RETURN REPLACE(REPLACE(data::text, '-', '+'), '_', '/')::bytea;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Fix corp_wallet_transactions table
    execute """
    UPDATE corp_wallet_transactions_v1
    SET 
      encrypted_amount_encoded = convert_url_safe_base64(encrypted_amount_encoded),
      encrypted_balance_encoded = convert_url_safe_base64(encrypted_balance_encoded),
      encrypted_reason_encoded = convert_url_safe_base64(encrypted_reason_encoded)
    WHERE
      encrypted_amount_encoded::text LIKE '%-%' 
      OR encrypted_amount_encoded::text LIKE '%\\_%' 
      OR encrypted_balance_encoded::text LIKE '%-%' 
      OR encrypted_balance_encoded::text LIKE '%\\_%'
      OR encrypted_reason_encoded::text LIKE '%-%' 
      OR encrypted_reason_encoded::text LIKE '%\\_%';
    """
    
    # Fix character_v1 table
    execute """
    UPDATE character_v1
    SET 
      encrypted_location = convert_url_safe_base64(encrypted_location),
      encrypted_ship = convert_url_safe_base64(encrypted_ship),
      encrypted_solar_system_id = convert_url_safe_base64(encrypted_solar_system_id),
      encrypted_structure_id = convert_url_safe_base64(encrypted_structure_id),
      encrypted_access_token = convert_url_safe_base64(encrypted_access_token),
      encrypted_refresh_token = convert_url_safe_base64(encrypted_refresh_token),
      encrypted_eve_wallet_balance = convert_url_safe_base64(encrypted_eve_wallet_balance)
    WHERE
      encrypted_location::text LIKE '%-%' 
      OR encrypted_location::text LIKE '%\\_%'
      OR encrypted_ship::text LIKE '%-%' 
      OR encrypted_ship::text LIKE '%\\_%'
      OR encrypted_solar_system_id::text LIKE '%-%' 
      OR encrypted_solar_system_id::text LIKE '%\\_%'
      OR encrypted_structure_id::text LIKE '%-%' 
      OR encrypted_structure_id::text LIKE '%\\_%'
      OR encrypted_access_token::text LIKE '%-%' 
      OR encrypted_access_token::text LIKE '%\\_%'
      OR encrypted_refresh_token::text LIKE '%-%' 
      OR encrypted_refresh_token::text LIKE '%\\_%'
      OR encrypted_eve_wallet_balance::text LIKE '%-%' 
      OR encrypted_eve_wallet_balance::text LIKE '%\\_%';
    """
    
    # Fix user_v1 table
    execute """
    UPDATE user_v1
    SET encrypted_balance = convert_url_safe_base64(encrypted_balance)
    WHERE
      encrypted_balance::text LIKE '%-%' 
      OR encrypted_balance::text LIKE '%\\_%';
    """
    
    # Drop the helper function
    execute "DROP FUNCTION convert_url_safe_base64;"
  end
end 