#!/usr/bin/env bash
# Install (or reinstall) the launchd agent that keeps Runner's signature from expiring.
# Safe to re-run: it replaces whatever is loaded.
#
#   ./scripts/install-refresh-agent.sh             # install and load
#   ./scripts/install-refresh-agent.sh --uninstall # stop and remove
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$(pwd -P)

LABEL="com.runner.refresh-signing"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"

# bootout on a label that is not loaded returns non-zero; that is fine either way.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$TARGET"
  echo "$LABEL removed. Runner will no longer reinstall itself — do it by hand every 7 days."
  exit 0
fi

mkdir -p "$(dirname "$TARGET")"
sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" \
  launchd/$LABEL.plist > "$TARGET"
launchctl bootstrap "gui/$UID" "$TARGET"

echo "$LABEL loaded. It checks at 10:00, 14:00, 18:00 and 21:00 and reinstalls when the signature is 5 days old."
echo "Log:       ~/Library/Logs/runner-refresh-signing.log"
echo "Run now:   ./scripts/refresh-signing.sh --force"
