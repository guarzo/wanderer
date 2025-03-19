defmodule WandererApp.Repo.Migrations.MarkProblematicRecords do
  @moduledoc """
  Identifies and marks problematic encrypted records.
  Instead of trying to fix corrupted data, this migration sets invalid fields to NULL
  and logs the IDs of affected records for further review.
  """

  use Ecto.Migration
  require Logger

  def up do
    # Create a table to log affected records
    create table(:corrupted_encryption_log) do
      add :table_name, :string, null: false
      add :record_id, :uuid, null: false
      add :field_name, :string, null: false
      add :timestamp, :utc_datetime, null: false
    end

    # Create a helper function to detect invalid Base64
    execute """
    CREATE OR REPLACE FUNCTION is_likely_corrupted(data bytea) RETURNS boolean AS $$
    DECLARE
      text_data text;
    BEGIN
      IF data IS NULL THEN
        RETURN false;
      END IF;
      
      -- Get text representation
      text_data := convert_from(data, 'UTF8');
      
      -- Check for URL-safe Base64 characters
      IF text_data LIKE '%-%' OR text_data LIKE '%\\_%' THEN
        RETURN true;
      END IF;
      
      -- Check for obviously too small data
      IF length(data) < 10 THEN
        RETURN true;
      END IF;
      
      RETURN false;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Create a function to log corrupted data
    execute """
    CREATE OR REPLACE FUNCTION log_corrupted_data(table_name text, id uuid, field_name text) RETURNS void AS $$
    BEGIN
      INSERT INTO corrupted_encryption_log (table_name, record_id, field_name, timestamp)
      VALUES (table_name, id, field_name, now());
    END;
    $$ LANGUAGE plpgsql;
    """

    # Process corp_wallet_transactions - one field at a time
    execute """
    UPDATE corp_wallet_transactions_v1
    SET encrypted_amount_encoded = NULL
    WHERE is_likely_corrupted(encrypted_amount_encoded)
    RETURNING (
      SELECT log_corrupted_data('corp_wallet_transactions_v1', id, 'encrypted_amount_encoded')
    );
    """
    
    execute """
    UPDATE corp_wallet_transactions_v1
    SET encrypted_balance_encoded = NULL
    WHERE is_likely_corrupted(encrypted_balance_encoded)
    RETURNING (
      SELECT log_corrupted_data('corp_wallet_transactions_v1', id, 'encrypted_balance_encoded')
    );
    """
    
    execute """
    UPDATE corp_wallet_transactions_v1
    SET encrypted_reason_encoded = NULL
    WHERE is_likely_corrupted(encrypted_reason_encoded)
    RETURNING (
      SELECT log_corrupted_data('corp_wallet_transactions_v1', id, 'encrypted_reason_encoded')
    );
    """
    
    # Process character table - one field at a time
    execute """
    UPDATE character_v1
    SET encrypted_location = NULL
    WHERE is_likely_corrupted(encrypted_location)
    RETURNING (
      SELECT log_corrupted_data('character_v1', id, 'encrypted_location')
    );
    """
    
    execute """
    UPDATE character_v1
    SET encrypted_ship = NULL
    WHERE is_likely_corrupted(encrypted_ship)
    RETURNING (
      SELECT log_corrupted_data('character_v1', id, 'encrypted_ship')
    );
    """
    
    execute """
    UPDATE character_v1
    SET encrypted_solar_system_id = NULL
    WHERE is_likely_corrupted(encrypted_solar_system_id)
    RETURNING (
      SELECT log_corrupted_data('character_v1', id, 'encrypted_solar_system_id')
    );
    """
    
    execute """
    UPDATE character_v1
    SET encrypted_structure_id = NULL
    WHERE is_likely_corrupted(encrypted_structure_id)
    RETURNING (
      SELECT log_corrupted_data('character_v1', id, 'encrypted_structure_id')
    );
    """
    
    execute """
    UPDATE character_v1
    SET encrypted_access_token = NULL
    WHERE is_likely_corrupted(encrypted_access_token)
    RETURNING (
      SELECT log_corrupted_data('character_v1', id, 'encrypted_access_token')
    );
    """
    
    execute """
    UPDATE character_v1
    SET encrypted_refresh_token = NULL
    WHERE is_likely_corrupted(encrypted_refresh_token)
    RETURNING (
      SELECT log_corrupted_data('character_v1', id, 'encrypted_refresh_token')
    );
    """
    
    execute """
    UPDATE character_v1
    SET encrypted_eve_wallet_balance = NULL
    WHERE is_likely_corrupted(encrypted_eve_wallet_balance)
    RETURNING (
      SELECT log_corrupted_data('character_v1', id, 'encrypted_eve_wallet_balance')
    );
    """
    
    # Process user table
    execute """
    UPDATE user_v1
    SET encrypted_balance = NULL
    WHERE is_likely_corrupted(encrypted_balance)
    RETURNING (
      SELECT log_corrupted_data('user_v1', id, 'encrypted_balance')
    );
    """
    
    # Get total count of affected records
    execute """
    SELECT count(*) FROM corrupted_encryption_log;
    """
    
    # Clean up functions
    execute "DROP FUNCTION is_likely_corrupted(bytea);"
    execute "DROP FUNCTION log_corrupted_data(text, uuid, text);"
    
    Logger.info("Problematic encrypted records have been identified and set to NULL")
  end

  def down do
    drop table(:corrupted_encryption_log)
  end
end 