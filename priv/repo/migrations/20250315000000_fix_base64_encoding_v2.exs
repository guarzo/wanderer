defmodule WandererApp.Repo.Migrations.FixBase64EncodingV2 do
  @moduledoc """
  More thorough fix for Base64 encoding issues in encrypted fields.
  """

  use Ecto.Migration
  require Logger

  def up do
    execute "SELECT 1", ""
    
    Logger.info("Running more thorough Base64 encoding fix...")
    
    # Let's patch the AshCloak module directly in the database to fix all queries
    create_base64_fix_trigger()
    
    # Also apply the fixes directly to table data
    fix_tables_directly()

    Logger.info("Base64 encoding fix v2 completed successfully")
  end

  def down do
    execute "DROP FUNCTION IF EXISTS fix_url_safe_base64(bytea);", ""
  end

  defp create_base64_fix_trigger do
    # Create a more comprehensive helper function
    execute """
    CREATE OR REPLACE FUNCTION fix_url_safe_base64(data bytea) RETURNS bytea AS $$
    DECLARE
      text_data text;
      fixed_data text;
    BEGIN
      IF data IS NULL THEN
        RETURN NULL;
      END IF;
      
      -- Convert to text for string operations
      text_data := convert_from(data, 'UTF8');
      
      -- First replace URL-safe chars
      fixed_data := regexp_replace(text_data, '-', '+', 'g');
      fixed_data := regexp_replace(fixed_data, '_', '/', 'g');
      
      -- Return as bytea
      RETURN convert_to(fixed_data, 'UTF8');
    END;
    $$ LANGUAGE plpgsql IMMUTABLE;
    """

    # Create a SQL function that can be used to fix all instances
    execute """
    CREATE OR REPLACE FUNCTION fix_encrypted_columns()
    RETURNS void AS $$
    BEGIN
      -- Fix corp_wallet_transactions
      UPDATE corp_wallet_transactions_v1
      SET 
        encrypted_amount_encoded = fix_url_safe_base64(encrypted_amount_encoded),
        encrypted_balance_encoded = fix_url_safe_base64(encrypted_balance_encoded),
        encrypted_reason_encoded = fix_url_safe_base64(encrypted_reason_encoded);
      
      -- Fix character table
      UPDATE character_v1
      SET 
        encrypted_location = fix_url_safe_base64(encrypted_location),
        encrypted_ship = fix_url_safe_base64(encrypted_ship),
        encrypted_solar_system_id = fix_url_safe_base64(encrypted_solar_system_id),
        encrypted_structure_id = fix_url_safe_base64(encrypted_structure_id),
        encrypted_access_token = fix_url_safe_base64(encrypted_access_token),
        encrypted_refresh_token = fix_url_safe_base64(encrypted_refresh_token),
        encrypted_eve_wallet_balance = fix_url_safe_base64(encrypted_eve_wallet_balance);
      
      -- Fix user table
      UPDATE user_v1
      SET encrypted_balance = fix_url_safe_base64(encrypted_balance)
      WHERE encrypted_balance IS NOT NULL;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp fix_tables_directly do
    # Call our function to apply fixes to all tables
    execute "SELECT fix_encrypted_columns();"
    
    # Create functions to automatically fix incoming data
    create_data_protection_functions()
  end

  defp create_data_protection_functions do
    # Create triggers to automatically fix data on insert/update for corp_wallet_transactions
    execute """
    CREATE OR REPLACE FUNCTION fix_corp_wallet_transactions_encrypted_data()
    RETURNS TRIGGER AS $$
    BEGIN
      NEW.encrypted_amount_encoded := fix_url_safe_base64(NEW.encrypted_amount_encoded);
      NEW.encrypted_balance_encoded := fix_url_safe_base64(NEW.encrypted_balance_encoded);
      NEW.encrypted_reason_encoded := fix_url_safe_base64(NEW.encrypted_reason_encoded);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    DROP TRIGGER IF EXISTS fix_corp_wallet_encryption_trigger ON corp_wallet_transactions_v1;
    """

    execute """
    CREATE TRIGGER fix_corp_wallet_encryption_trigger
    BEFORE INSERT OR UPDATE ON corp_wallet_transactions_v1
    FOR EACH ROW
    EXECUTE FUNCTION fix_corp_wallet_transactions_encrypted_data();
    """

    # Create triggers for character table
    execute """
    CREATE OR REPLACE FUNCTION fix_character_encrypted_data()
    RETURNS TRIGGER AS $$
    BEGIN
      NEW.encrypted_location := fix_url_safe_base64(NEW.encrypted_location);
      NEW.encrypted_ship := fix_url_safe_base64(NEW.encrypted_ship);
      NEW.encrypted_solar_system_id := fix_url_safe_base64(NEW.encrypted_solar_system_id);
      NEW.encrypted_structure_id := fix_url_safe_base64(NEW.encrypted_structure_id);
      NEW.encrypted_access_token := fix_url_safe_base64(NEW.encrypted_access_token);
      NEW.encrypted_refresh_token := fix_url_safe_base64(NEW.encrypted_refresh_token);
      NEW.encrypted_eve_wallet_balance := fix_url_safe_base64(NEW.encrypted_eve_wallet_balance);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    DROP TRIGGER IF EXISTS fix_character_encryption_trigger ON character_v1;
    """

    execute """
    CREATE TRIGGER fix_character_encryption_trigger
    BEFORE INSERT OR UPDATE ON character_v1
    FOR EACH ROW
    EXECUTE FUNCTION fix_character_encrypted_data();
    """

    # Create triggers for user table
    execute """
    CREATE OR REPLACE FUNCTION fix_user_encrypted_data()
    RETURNS TRIGGER AS $$
    BEGIN
      NEW.encrypted_balance := fix_url_safe_base64(NEW.encrypted_balance);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    DROP TRIGGER IF EXISTS fix_user_encryption_trigger ON user_v1;
    """

    execute """
    CREATE TRIGGER fix_user_encryption_trigger
    BEFORE INSERT OR UPDATE ON user_v1
    FOR EACH ROW
    EXECUTE FUNCTION fix_user_encrypted_data();
    """
  end
end 