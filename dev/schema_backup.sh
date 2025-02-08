#!/bin/bash
# schema_backup.sh
#
# This script downloads a schema-only backup from a Postgres database running
# in a Docker container. It auto-detects whether to use the development or production
# container based on the container name:
#
#   - Production: container name "wanderer-wanderer_db-1" (target database: postgres)
#   - Development: container name "wanderer_devcontainer-db-1" (target database: wanderer_dev)
#
# The schema-only backup is generated using pg_dump with the following options:
#   --schema-only   : Dump only the schema (no data)
#   --no-owner      : Do not output commands to set ownership of objects
#   --no-acl        : Do not dump access privileges (grant/revoke)
#
# The output is then piped through grep to remove lines starting with "SET"
# so that the resulting file is more compatible with schema-diff tools like apgdiff.
#
# Usage:
#   ./schema_backup.sh
#

set -e  # Exit immediately if any command fails

# Define possible container names.
POSSIBLE_CONTAINERS=("wanderer-wanderer_db-1" "wanderer_devcontainer-db-1")
CONTAINER_NAME=""

echo "Detecting running Postgres container..."
for container in "${POSSIBLE_CONTAINERS[@]}"; do
    if docker inspect "$container" > /dev/null 2>&1; then
        CONTAINER_NAME="$container"
        break
    fi
done

if [ -z "$CONTAINER_NAME" ]; then
    echo "Error: No known Postgres container found. Checked: ${POSSIBLE_CONTAINERS[*]}"
    exit 1
fi

echo "Using database container: $CONTAINER_NAME"

# Database credentials and target database selection.
DB_USER="postgres"
if [[ "$CONTAINER_NAME" == *"devcontainer"* ]]; then
    DB_NAME="wanderer_dev"
else
    DB_NAME="postgres"
fi

echo "Target database: $DB_NAME"

# Define output file name with a timestamp.
OUTPUT_FILE="schema_backup_$(date +'%Y%m%d_%H%M%S').sql"
echo "Output file: $OUTPUT_FILE"

# Run pg_dump inside the container with the desired options, and remove SET commands.
docker exec -i "$CONTAINER_NAME" \
  pg_dump -U "$DB_USER" -d "$DB_NAME" --schema-only --no-owner --no-acl | grep -v '^SET' > "$OUTPUT_FILE"

echo "Schema-only backup complete. Output written to $OUTPUT_FILE"
