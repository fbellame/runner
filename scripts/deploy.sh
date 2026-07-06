#!/usr/bin/env bash
# Deploy Runner to a cable-connected iPhone (free Apple ID: re-run weekly).
# First time only, in Xcode: Settings -> Accounts -> add your Apple ID.
# On the iPhone: enable Developer Mode (Settings -> Privacy & Security), trust this Mac,
# and after the first install trust the developer cert (Settings -> General -> VPN & Device Management).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null && xcodegen generate

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
        and device.get("state") == "available"
    ):
        print(hw.get("udid", ""))
        break
PY
)
if [ -z "${UDID}" ]; then
  echo "No iPhone found. Connect it with a cable, unlock it, and tap 'Trust'." >&2
  exit 1
fi
echo "Deploying to device ${UDID}"

BUILD_ARGS=(-project Runner.xcodeproj -scheme Runner -destination "id=${UDID}" -allowProvisioningUpdates)
[ -n "${TEAM_ID:-}" ] && BUILD_ARGS+=("DEVELOPMENT_TEAM=${TEAM_ID}")
xcodebuild "${BUILD_ARGS[@]}" build

PRODUCTS_DIR=$(xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
xcrun devicectl device install app --device "${UDID}" "${PRODUCTS_DIR}/Runner.app"
xcrun devicectl device process launch --device "${UDID}" com.farid.runner || true
echo "Runner deployed. Free-account signature lasts ~7 days; rerun this script weekly."
