#!/usr/bin/env bash
# Deploy Runner to a connected iPhone (free Apple ID: re-run weekly).
#   ./scripts/deploy.sh          # find the iPhone itself
#   ./scripts/deploy.sh <udid>   # use that device (what refresh-signing.sh passes in)
# First time only, in Xcode: Settings -> Accounts -> add your Apple ID.
# On the iPhone: enable Developer Mode (Settings -> Privacy & Security), trust this Mac,
# and after the first install trust the developer cert (Settings -> General -> VPN & Device Management).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null && xcodegen generate

if [ -n "${1:-}" ]; then
  UDID="$1"
else
JSON=$(mktemp)
trap 'rm -f "$JSON"' EXIT
xcrun devicectl list devices --json-output "$JSON" >/dev/null
UDID=$(python3 - "$JSON" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
for device in data.get("result", {}).get("devices", []):
    hw = device.get("hardwareProperties", {})
    conn = device.get("connectionProperties", {})
    if (
        hw.get("platform") == "iOS"
        and conn.get("pairingState", "paired") == "paired"
        and hw.get("reality") == "physical"
    ):
        print(hw.get("udid", ""))
        break
PY
)
fi
if [ -z "${UDID}" ]; then
  echo "No iPhone found. Connect it with a cable, unlock it, and tap 'Trust'." >&2
  exit 1
fi
echo "Deploying to device ${UDID}"

if [ -z "${TEAM_ID:-}" ]; then
  TEAM_ID=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | awk -F'= ' '/teamID/{gsub(/[; ]/, "", $2); print $2; exit}')
fi

# Build for a generic iPhone, not for this one: a device destination makes xcodebuild wait on the
# Wi-Fi connection ("Connecting to iPhone…") and it hung for 30 min on 2026-09-26 and 09-28.
# Compiling and signing never needed the phone; only the install below does.
BUILD_ARGS=(-project Runner.xcodeproj -scheme Runner -destination "generic/platform=iOS" -allowProvisioningUpdates)
if [ -n "${TEAM_ID:-}" ]; then
  echo "Using development team ${TEAM_ID}"
  BUILD_ARGS+=("DEVELOPMENT_TEAM=${TEAM_ID}")
fi
xcodebuild "${BUILD_ARGS[@]}" build

PRODUCTS_DIR=$(xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
# Over Wi-Fi the phone can take a while to answer, or be locked for a minute: retry.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  xcrun devicectl device install app --device "${UDID}" "${PRODUCTS_DIR}/Runner.app" && break
  if [ "$attempt" -eq 10 ]; then
    echo "Install failed: is the iPhone unlocked and on the same Wi-Fi?" >&2
    exit 1
  fi
  echo "Install attempt ${attempt} failed, retrying in 30 s…" >&2
  sleep 30
done
if ! xcrun devicectl device process launch --device "${UDID}" com.farid.runner; then
  echo "Runner installed, but iOS refused to launch it." >&2
  echo "On the iPhone, trust the developer profile in Settings -> General -> VPN & Device Management, then rerun this script." >&2
  exit 2
fi
echo "Runner deployed. Free-account signature lasts ~7 days; rerun this script weekly."
