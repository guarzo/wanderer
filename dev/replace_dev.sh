#!/bin/bash
# replace_dev_with_prod_full.sh
#
# This script replaces the current development database (wanderer_dev)
# with a full production backup (schema and data). It:
#   1. Optionally backs up the current dev database.
#   2. Terminates connections to the dev database.
#   3. Drops the current dev database.
#   4. Recreates the dev database.
#   5. Restores the full production backup into the dev database.
#
# Usage:
#   ./replace_dev_with_prod_full.sh <prod_full_backup.sql>
#
# IMPORTANT: This will drop your current development database!
#
set -e

# Check that exactly one argument (the production backup file) is provided.
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <prod_full_backup.sql>"
    exit 1
fi

PROD_BACKUP="$1"

if [ ! -f "$PROD_BACKUP" ]; then
    echo "Error: Production backup file '$PROD_BACKUP' does not exist."
    exit 1
fi

# Define the development container name and database.
DEV_CONTAINER="wanderer_devcontainer-db-1"
DEV_DB="wanderer_dev"
DB_USER="postgres"

echo "Using development container: $DEV_CONTAINER"
echo "Development database to replace: $DEV_DB"
echo "Production backup file to restore: $PROD_BACKUP"
echo ""

# Verify the development container exists.
if ! docker inspect "$DEV_CONTAINER" > /dev/null 2>&1; then
    echo "Error: Development container '$DEV_CONTAINER' not found."
    exit 1
fi

# Optional: Backup the current development database before replacing it.
DEV_BACKUP="wanderer_dev_backup_$(date +'%Y%m%d_%H%M%S').sql"
echo "Backing up current development database to $DEV_BACKUP ..."
docker exec -i "$DEV_CONTAINER" pg_dump -U "$DB_USER" -d "$DEV_DB" > "$DEV_BACKUP"
echo "Current development database backup complete."
echo ""

# Terminate active connections to the dev database.
echo "Terminating active connections to $DEV_DB ..."
docker exec -i "$DEV_CONTAINER" psql -U "$DB_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DEV_DB';"

# Drop the current development database.
echo "Dropping the current development database $DEV_DB ..."
docker exec -i "$DEV_CONTAINER" psql -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS $DEV_DB;"
echo "Database dropped."

# Recreate the development database.
echo "Creating new development database $DEV_DB ..."
docker exec -i "$DEV_CONTAINER" psql -U "$DB_USER" -d postgres -c "CREATE DATABASE $DEV_DB;"
echo "Database created."

# Restore the full production backup into the newly created development database.
echo "Restoring production backup into development database $DEV_DB ..."
docker exec -i "$DEV_CONTAINER" psql -U "$DB_USER" -d "$DEV_DB" < "$PROD_BACKUP"
echo "Restoration complete."

echo ""
echo "The development database has been replaced with the production backup."
