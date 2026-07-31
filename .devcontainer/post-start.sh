#!/bin/bash
# Post-start script - runs every time the container starts

set -e

echo "🔄 Running post-start tasks..."

# NOTE: two blocks used to live here and were deliberately removed.
#
# 1. A "host path fix" that grepped host home paths out of ~/.claude/plugins/*.json
#    and created root-owned symlinks between home directories (e.g. /home/tng -> $HOME).
#    That was only needed back when ~/.claude was bind-mounted from the host, which
#    meant host-absolute paths leaked into a container with a different username.
#    ~/.claude is now a container-local named volume seeded read-only from
#    /host-seed (see local-seed.sh), so no host paths are written into it and the
#    symlinks would only serve to alias two homes together and mask real path bugs.
#
# 2. `git config --global --unset credential.helper`, which removed a Windows
#    credential helper. --global resolves to $HOME/.gitconfig, and VS Code shares
#    the host .gitconfig into the container read-write, so this mutated the
#    developer's HOST git config as a side effect of starting a container. The
#    credential.useHttpPath setting the devcontainer actually needs is supplied
#    by a compose `configs:` entry in the local override instead.

CONTAINER_HOME="$(eval echo ~)"

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
