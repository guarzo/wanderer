#!/bin/bash
# update_upstream.sh
# This script updates your fork by merging changes from the upstream repository.
# It assumes you have two branches:
#   - main: tracks the upstream repository.
#   - custom-branch: your branch with custom modifications.

set -e  # Exit immediately if a command exits with a non-zero status.

# Check that we’re in a Git repository.
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "Error: This is not a Git repository."
    exit 1
fi

# Step 1: Ensure the upstream remote exists.
if ! git remote | grep -q '^upstream$'; then
    echo "Adding 'upstream' remote..."
    git remote add upstream https://github.com/upstream/repo.git
fi

# Step 2: Fetch the latest changes from upstream.
echo "Fetching upstream changes..."
git fetch upstream

# Step 3: Update the local main branch.
echo "Checking out the 'main' branch..."
git checkout main

echo "Merging changes from upstream/main into main..."
git merge upstream/main

# Step 4: Rebase your custom branch on top of the updated main branch.
echo "Checking out your custom branch 'custom-branch'..."
git checkout guarzo/zoo

echo "Rebasing custom-branch on top of main..."
git rebase main

echo "Upstream update and rebase complete!"

