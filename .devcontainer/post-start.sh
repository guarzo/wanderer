#!/bin/bash
# Post-start script - runs every time the container starts

set -e

echo "🔄 Running post-start tasks..."

# Fix Claude Code host-path references.
# When ~/.claude is mounted from the host, config files contain absolute paths
# using the host username (e.g. /home/tng/.claude/...) which don't resolve in
# the container where the user is "developer". Create a symlink from the host
# home directory to the container home so these paths resolve.
CONTAINER_HOME="$(eval echo ~)"

if [ -d "$CONTAINER_HOME/.claude" ]; then
    # Detect all host usernames referenced in Claude's config. Over a container's
    # lifetime multiple host usernames may have been written, and we need a
    # symlink for each so stale absolute paths still resolve.
    MARKETPLACE_CFG="$CONTAINER_HOME/.claude/plugins/known_marketplaces.json"
    INSTALLED_CFG="$CONTAINER_HOME/.claude/plugins/installed_plugins.json"
    HOST_HOMES=$(
        {
            [ -f "$MARKETPLACE_CFG" ] && grep -oP '"installLocation":\s*"\K/home/[^/]+' "$MARKETPLACE_CFG"
            [ -f "$INSTALLED_CFG" ]   && grep -oP '"installPath":\s*"\K/home/[^/]+' "$INSTALLED_CFG"
        } 2>/dev/null | sort -u
    )
    for HOST_HOME in $HOST_HOMES; do
        if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "$CONTAINER_HOME" ] && [ ! -e "$HOST_HOME" ]; then
            echo "🔗 Creating symlink $HOST_HOME -> $CONTAINER_HOME (Claude Code host path fix)"
            sudo ln -sfn "$CONTAINER_HOME" "$HOST_HOME"
        fi
    done
fi

# Remove Windows credential helper if present (copied from host .gitconfig).
# The devcontainer already has its own credential helper in /etc/gitconfig.
if grep -q "credential-manager.exe" "$CONTAINER_HOME/.gitconfig" 2>/dev/null; then
    echo "🔧 Removing Windows credential helper from git config..."
    git config --global --unset credential.helper 2>/dev/null || true
fi

# Display helpful information
echo ""
echo "📊 Environment Info:"
echo "  Elixir version: $(elixir --version | tail -1 | awk '{print $2}' 2>/dev/null || echo 'not installed')"
echo "  Node version:   $(node --version 2>/dev/null || echo 'not installed')"
echo "  Claude Code:    $(claude --version 2>/dev/null || echo 'not installed')"
echo "  Shell:          $(basename "${SHELL}")"
echo "  Working dir:    $(pwd)"
echo ""

# Check database (Postgres)
DB_HOST=${DB_HOST:-db}
if command -v nc >/dev/null 2>&1; then
    if nc -z "$DB_HOST" 5432 2>/dev/null; then
        echo "💾 Postgres: ready (${DB_HOST}:5432)"
    else
        echo "⚠️  Postgres not yet ready at ${DB_HOST}:5432 — check docker compose logs db"
    fi
fi

echo ""
echo "🎯 Ready to code!"
echo ""
echo "Useful commands:"
echo "  make server   # Start Phoenix dev server (port 4444)"
echo "  mix test      # Run tests"
echo "  mix format    # Format code"
echo "  claude        # Start Claude Code CLI"
echo ""
