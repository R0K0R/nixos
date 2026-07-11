#!/usr/bin/env bash
# Bump the pinned claude-code: ./update.sh [version]
# No argument = whatever Anthropic's release channel calls "latest" right now.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BASE_URL="https://downloads.claude.ai/claude-code-releases"
VERSION="${1:-$(curl -fsSL "$BASE_URL/latest")}"

curl -fsSL "$BASE_URL/$VERSION/manifest.json" --output manifest.json
echo "pinned claude-code $VERSION -- rebuild to apply"
