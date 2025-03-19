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
      first_bytes bytea;
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
      
      -- Get first few bytes to check for valid AES.GCM.V1 tag
      -- This may not be 100% reliable but helps catch obviously corrupted data
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

    # Create function to check and mark corrupted data in all tables
    execute """
    CREATE OR REPLACE FUNCTION mark_corrupted_data() RETURNS void AS $$
    DECLARE
      corp_wallet_count int := 0;
      character_count int := 0;
      user_count int := 0;
    BEGIN
      -- Process corp_wallet_transactions
      UPDATE corp_wallet_transactions_v1
      SET encrypted_amount_encoded = NULL
      WHERE is_likely_corrupted(encrypted_amount_encoded)
      RETURNING (
        SELECT log_corrupted_data('corp_wallet_transactions_v1', id, 'encrypted_amount_encoded')
      );
      GET DIAGNOSTICS corp_wallet_count = ROW_COUNT;
      
      UPDATE corp_wallet_transactions_v1
      SET encrypted_balance_encoded = NULL
      WHERE is_likely_corrupted(encrypted_balance_encoded)
      RETURNING (
        SELECT log_corrupted_data('corp_wallet_transactions_v1', id, 'encrypted_balance_encoded')
      );
      GET DIAGNOSTICS corp_wallet_count = corp_wallet_count + ROW_COUNT;
      
      UPDATE corp_wallet_transactions_v1
      SET encrypted_reason_encoded = NULL
      WHERE is_likely_corrupted(encrypted_reason_encoded)
      RETURNING (
        SELECT log_corrupted_data('corp_wallet_transactions_v1', id, 'encrypted_reason_encoded')
      );
      GET DIAGNOSTICS corp_wallet_count = corp_wallet_count + ROW_COUNT;
      
      -- Process character table
      UPDATE character_v1
      SET encrypted_location = NULL
      WHERE is_likely_corrupted(encrypted_location)
      RETURNING (
        SELECT log_corrupted_data('character_v1', id, 'encrypted_location')
      );
      GET DIAGNOSTICS character_count = ROW_COUNT;
      
      UPDATE character_v1
      SET encrypted_ship = NULL
      WHERE is_likely_corrupted(encrypted_ship)
      RETURNING (
        SELECT log_corrupted_data('character_v1', id, 'encrypted_ship')
      );
      GET DIAGNOSTICS character_count = character_count + ROW_COUNT;
      
      UPDATE character_v1
      SET encrypted_solar_system_id = NULL
      WHERE is_likely_corrupted(encrypted_solar_system_id)
      RETURNING (
        SELECT log_corrupted_data('character_v1', id, 'encrypted_solar_system_id')
      );
      GET DIAGNOSTICS character_count = character_count + ROW_COUNT;
      
      UPDATE character_v1
      SET encrypted_structure_id = NULL
      WHERE is_likely_corrupted(encrypted_structure_id)
      RETURNING (
        SELECT log_corrupted_data('character_v1', id, 'encrypted_structure_id')
      );
      GET DIAGNOSTICS character_count = character_count + ROW_COUNT;
      
      UPDATE character_v1
      SET encrypted_access_token = NULL
      WHERE is_likely_corrupted(encrypted_access_token)
      RETURNING (
        SELECT log_corrupted_data('character_v1', id, 'encrypted_access_token')
      );
      GET DIAGNOSTICS character_count = character_count + ROW_COUNT;
      
      UPDATE character_v1
      SET encrypted_refresh_token = NULL
      WHERE is_likely_corrupted(encrypted_refresh_token)
      RETURNING (
        SELECT log_corrupted_data('character_v1', id, 'encrypted_refresh_token')
      );
      GET DIAGNOSTICS character_count = character_count + ROW_COUNT;
      
      UPDATE character_v1
      SET encrypted_eve_wallet_balance = NULL
      WHERE is_likely_corrupted(encrypted_eve_wallet_balance)
      RETURNING (
        SELECT log_corrupted_data('character_v1', id, 'encrypted_eve_wallet_balance')
      );
      GET DIAGNOSTICS character_count = character_count + ROW_COUNT;
      
      -- Process user table
      UPDATE user_v1
      SET encrypted_balance = NULL
      WHERE is_likely_corrupted(encrypted_balance)
      RETURNING (
        SELECT log_corrupted_data('user_v1', id, 'encrypted_balance')
      );
      GET DIAGNOSTICS user_count = ROW_COUNT;
      
      -- Log results
      RAISE NOTICE 'Marked corrupted data: corp_wallet=%, character=%, user=%', 
                    corp_wallet_count, character_count, user_count;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Execute the function to identify and mark corrupted data
    execute "SELECT mark_corrupted_data();"
    
    # Clean up functions
    execute "DROP FUNCTION mark_corrupted_data();"
    execute "DROP FUNCTION is_likely_corrupted(bytea);"
    execute "DROP FUNCTION log_corrupted_data(text, uuid, text);"
    
    Logger.info("Problematic encrypted records have been identified and marked")
  end

  def down do
    drop table(:corrupted_encryption_log)
  end
end 