#!/usr/bin/env bash
#
# update_directory.sh
#
# Recursively gather the directory structure and output it as
# a Markdown file similar to your PowerShell script.

################################################################################
# Configuration
################################################################################

PROJECT_ROOT=".."               # Directory to start from
OUTPUT_FILE="./.notes/directory_structure.md"

# Directories to exclude
EXCLUDE_DIRS=(".git" "node_modules" "_build" "priv" "rel" "test" "assets/node_modules")

################################################################################
# Helper to build the indent prefix
################################################################################

indent_prefix() {
  local indent="$1"
  local prefix=""
  for ((i=0; i<indent; i++)); do
    prefix+="    "
  done
  echo -n "$prefix"
}

################################################################################
# Helper to check if path should be excluded
################################################################################

should_exclude() {
  local path="$1"
  local rel_path="${path#$PROJECT_ROOT/}"  # Remove PROJECT_ROOT prefix
  
  for exclude in "${EXCLUDE_DIRS[@]}"; do
    if [[ "$rel_path" == "$exclude" || "$rel_path" == "$exclude/"* ]]; then
      return 0  # true, should exclude
    fi
  done
  return 1  # false, should not exclude
}

################################################################################
# Recursive function to list files and directories with Markdown formatting
################################################################################

get_formatted_directory() {
  local path="$1"
  local indent="${2:-0}"

  # Read directory contents into an array, ignoring errors
  local items=()
  IFS=$'\n' read -r -d '' -a items < <(ls -A "$path" 2>/dev/null && printf '\0')

  for item in "${items[@]}"; do
    # Ignore the current and parent dir entries
    [[ "$item" == "." || "$item" == ".." ]] && continue

    local fullpath="$path/$item"
    
    # Skip excluded directories
    should_exclude "$fullpath" && continue
    
    local prefix
    prefix="$(indent_prefix "$indent")"

    if [[ -d "$fullpath" ]]; then
      # Directory
      echo "${prefix}- **${item}/**"
      get_formatted_directory "$fullpath" $((indent + 1))
    else
      # File
      echo "${prefix}- ${item}"
    fi
  done
}

################################################################################
# Generate the output content (Markdown)
################################################################################

# Store in a variable so we can write once at the end
MARKDOWN_CONTENT="# Current Directory Structure

## Core Components

\`\`\`
$( get_formatted_directory "$PROJECT_ROOT" 0 )
\`\`\`
"

################################################################################
# Write to the output file
################################################################################

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"
# Write content
echo "$MARKDOWN_CONTENT" > "$OUTPUT_FILE"

echo "Directory structure updated in $OUTPUT_FILE"

