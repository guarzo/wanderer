defmodule WandererApp.Repo.Migrations.FixBase64EncodingSimple do
  @moduledoc """
  Simple migration to fix URL-safe Base64 encoding in encrypted fields.
  """

  use Ecto.Migration
  require Logger

  def up do
    # Create a simple SQL function to convert URL-safe Base64 to standard Base64
    execute """
    CREATE OR REPLACE FUNCTION fix_base64_urlsafe(data bytea) RETURNS bytea AS $$
    DECLARE
      converted text;
    BEGIN
      IF data IS NULL THEN
        RETURN NULL;
      END IF;
      
      -- Convert bytea to text first
      converted := convert_from(data, 'UTF8');
      
      -- Replace URL-safe characters with standard Base64 characters
      converted := replace(converted, '-', '+');
      converted := replace(converted, '_', '/');
      
      -- Convert back to bytea
      RETURN convert_to(converted, 'UTF8');
    END;
    $$ LANGUAGE plpgsql;
    """

    # Fix corp_wallet_transactions
    execute """
    UPDATE corp_wallet_transactions_v1
    SET 
      encrypted_amount_encoded = fix_base64_urlsafe(encrypted_amount_encoded),
      encrypted_balance_encoded = fix_base64_urlsafe(encrypted_balance_encoded),
      encrypted_reason_encoded = fix_base64_urlsafe(encrypted_reason_encoded)
    WHERE 
      convert_from(encrypted_amount_encoded, 'UTF8') LIKE '%-%' 
      OR convert_from(encrypted_amount_encoded, 'UTF8') LIKE '%\\_%'
      OR convert_from(encrypted_balance_encoded, 'UTF8') LIKE '%-%' 
      OR convert_from(encrypted_balance_encoded, 'UTF8') LIKE '%\\_%'
      OR convert_from(encrypted_reason_encoded, 'UTF8') LIKE '%-%' 
      OR convert_from(encrypted_reason_encoded, 'UTF8') LIKE '%\\_%';
    """

    # Fix character table
    execute """
    UPDATE character_v1
    SET 
      encrypted_location = fix_base64_urlsafe(encrypted_location),
      encrypted_ship = fix_base64_urlsafe(encrypted_ship),
      encrypted_solar_system_id = fix_base64_urlsafe(encrypted_solar_system_id),
      encrypted_structure_id = fix_base64_urlsafe(encrypted_structure_id),
      encrypted_access_token = fix_base64_urlsafe(encrypted_access_token),
      encrypted_refresh_token = fix_base64_urlsafe(encrypted_refresh_token),
      encrypted_eve_wallet_balance = fix_base64_urlsafe(encrypted_eve_wallet_balance)
    WHERE 
      convert_from(encrypted_location, 'UTF8') LIKE '%-%' 
      OR convert_from(encrypted_location, 'UTF8') LIKE '%\\_%'
      OR convert_from(encrypted_ship, 'UTF8') LIKE '%-%' 
      OR convert_from(encrypted_ship, 'UTF8') LIKE '%\\_%'
      OR convert_from(encrypted_solar_system_id, 'UTF8') LIKE '%-%' 
      OR convert_from(encrypted_solar_system_id, 'UTF8') LIKE '%\\_%'
      OR convert_from(encrypted_structure_id, 'UTF8') LIKE '%-%' 
      OR convert_from(encrypted_structure_id, 'UTF8') LIKE '%\\_%'
      OR convert_from(encrypted_access_token, 'UTF8') LIKE '%-%' 
      OR convert_from(encrypted_access_token, 'UTF8') LIKE '%\\_%'
      OR convert_from(encrypted_refresh_token, 'UTF8') LIKE '%-%' 
      OR convert_from(encrypted_refresh_token, 'UTF8') LIKE '%\\_%'
      OR convert_from(encrypted_eve_wallet_balance, 'UTF8') LIKE '%-%' 
      OR convert_from(encrypted_eve_wallet_balance, 'UTF8') LIKE '%\\_%';
    """

    # Fix user table
    execute """
    UPDATE user_v1
    SET encrypted_balance = fix_base64_urlsafe(encrypted_balance)
    WHERE 
      encrypted_balance IS NOT NULL 
      AND (
        convert_from(encrypted_balance, 'UTF8') LIKE '%-%' 
        OR convert_from(encrypted_balance, 'UTF8') LIKE '%\\_%'
      );
    """

    # Drop the function
    execute "DROP FUNCTION fix_base64_urlsafe;"

    Logger.info("Base64 URL-safe conversion completed successfully")
  end

  def down do
    # No rollback needed
    :ok
  end
end 