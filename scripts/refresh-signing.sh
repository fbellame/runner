#!/usr/bin/env bash
# Reinstall Runner on the iPhone before the free Apple ID's 7-day signature expires.
#
# Run daily by launchd (com.runner.refresh-signing), it does nothing while the last successful
# install is younger than DELAY_DAYS. The install goes over Wi-Fi: the iPhone only has to be on
# the same network and unlocked, never plugged in.
#
#   ./scripts/refresh-signing.sh          # respect the delay
#   ./scripts/refresh-signing.sh --force  # reinstall right now
#
# Enable:   ./scripts/install-refresh-agent.sh
# Disable:  launchctl bootout gui/$UID/com.runner.refresh-signing
set -uo pipefail
cd "$(dirname "$0")/.."

DELAY_DAYS=5          # two days of slack before Apple's seven
ALERT_DAYS=6          # past that, warn: only a day left
STATE="$HOME/.runner-refresh-signing"
LOG="$HOME/Library/Logs/runner-refresh-signing.log"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$(dirname "$LOG")"
note() { echo "$(date '+%Y-%m-%d %H:%M')  $*" >> "$LOG"; }
warn() { osascript -e "display notification \"$1\" with title \"Runner · iPhone\"" >/dev/null 2>&1 || true; }

LAST=$(cat "$STATE" 2>/dev/null || echo 0)
NOW=$(date +%s)
DAYS=$(( (NOW - LAST) / 86400 ))

if [ "${1:-}" != "--force" ] && [ "$DAYS" -lt "$DELAY_DAYS" ]; then
  exit 0  # install still fresh, nothing to do
fi

# The iPhone has to be reachable: paired, on the network, and unlocked.
# Same detection as deploy.sh, so no device identifier is frozen in here.
UDID=$(xcrun devicectl list devices 2>/dev/null \
  | awk '/physical/ && !/unavailable/ && (/ available/ || / connected/) {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i; exit}')
if [ -z "$UDID" ] || ! xcrun devicectl device info details --device "$UDID" --timeout 20 >/dev/null 2>&1; then
  note "iPhone unreachable ($DAYS d since the last install)"
  if [ "$DAYS" -ge "$ALERT_DAYS" ]; then
    warn "iPhone unreachable for $DAYS days. Runner expires soon: unlock it on the Wi-Fi."
  fi
  exit 0  # try again tomorrow
fi

# Reinstalling is not enough on its own. An incremental build re-signs nothing, so the app goes
# back on the phone carrying the SAME embedded profile — same expiry date — and still dies on
# day 7. Deleting our team profiles forces xcodebuild -allowProvisioningUpdates to have Apple
# issue new ones, which changes the signing input and makes Xcode re-sign the bundle.
# Only ours: other projects' profiles (StuSup) are none of our business.
purge_profiles() {
  local dir f name plist
  plist=$(mktemp)
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
             "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.mobileprovision; do
      [ -e "$f" ] || continue
      security cms -D -i "$f" > "$plist" 2>/dev/null || continue
      name=$(plutil -extract Name raw "$plist" 2>/dev/null) || continue
      case "$name" in
        *": com.farid.runner"|*": com.farid.runner."*) rm -f "$f" ;;
      esac
    done
  done
  rm -f "$plist"
}

# Expiry Apple stamped on the profile the app now carries — the date that actually matters.
expiry() {
  local plist app
  app="$1"
  plist=$(mktemp)
  security cms -D -i "$app/embedded.mobileprovision" > "$plist" 2>/dev/null \
    && plutil -extract ExpirationDate raw "$plist" 2>/dev/null
  rm -f "$plist"
}

note "reinstalling (last one $DAYS d ago)…"
purge_profiles
# Pass the identifier we already found: letting deploy.sh re-detect opened a window where the
# iPhone could disappear between the two devicectl calls.
OUTPUT=$(./scripts/deploy.sh "$UDID" 2>&1)
STATUS=$?

# deploy.sh exits 2 when the app installed but iOS refused to launch it. The signature — the only
# thing this script is about — was refreshed all the same, so that counts as a success.
if [ "$STATUS" -eq 0 ] || [ "$STATUS" -eq 2 ]; then
  echo "$NOW" > "$STATE"
  LAUNCHED="done"
  [ "$STATUS" -eq 0 ] || LAUNCHED="done (installed, iOS refused to launch it)"

  APP="$(xcodebuild -project Runner.xcodeproj -scheme Runner -destination "id=$UDID" \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/Runner.app"
  UNTIL=$(expiry "$APP")
  UNTIL_AT=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${UNTIL:-}" +%s 2>/dev/null || echo 0)

  # A reinstall that carries an old profile is the failure this script exists to prevent, and it
  # looks exactly like a success from the outside. Say so rather than sleep through it.
  if [ "$UNTIL_AT" -lt $(( NOW + 3 * 86400 )) ]; then
    note "$LAUNCHED, BUT the profile was not renewed (expires ${UNTIL:-unknown})"
    warn "Runner reinstalled, but its signature was not renewed. See $LOG."
    exit 1
  fi
  note "$LAUNCHED, signed until $UNTIL"
  exit 0
fi

note "FAILED: $(echo "$OUTPUT" | tail -3 | tr '\n' ' ')"
warn "Reinstall failed after $DAYS days. See $LOG."
exit 1
