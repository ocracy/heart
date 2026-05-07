#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Remove legacy builds before installing fresh.
rm -rf /Applications/Stoker.app 2>/dev/null || true
rm -rf /Applications/DevLauncher.app 2>/dev/null || true

./build.sh

DEST="/Applications/Heart.app"

echo "→ Installing to ${DEST}..."
rm -rf "${DEST}"
mv Heart.app "${DEST}"
xattr -cr "${DEST}" || true

echo ""
echo "✓ Installed: ${DEST}"
echo "  Launchpad: search \"Heart\""
echo "  Spotlight: ⌘+Space → \"heart\""
echo "  Or run: open -a Heart"
