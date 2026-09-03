#!/bin/bash
# ============================================================================
#  Install the macOS deployment for the DeepSeek Harness Web UI.
#  This mirrors the Windows deployment (Startup autostart) with a macOS twist:
#  because a Mac is rarely rebooted, the "always run the latest official dsh"
#  guarantee is enforced after every SCREEN UNLOCK instead of only at login.
#    - copies the autostart script to ~/.dsh/bin/dsh-web-autostart.sh
#    - compiles + installs the unlock watcher and its sync script
#    - installs two LaunchAgents:
#        com.allern.dsh-web           starts the web UI (owns the process)
#        com.allern.dsh-web-unlock    watches for screen unlock, restarts the
#                                     web UI when a newer official dsh exists
#    - makes restart-dsh-web.sh / .command executable
#  Usage   : bash deploy/macos/install.sh
# ============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="$HOME"
LABEL_SERVER="com.allern.dsh-web"
LABEL_UNLOCK="com.allern.dsh-web-unlock"
LA_DIR="$HOME/Library/LaunchAgents"
BIN_DIR="$HOME/.dsh/bin"
PLIST_SERVER_SRC="$HERE/$LABEL_SERVER.plist"
PLIST_UNLOCK_SRC="$HERE/$LABEL_UNLOCK.plist"
PLIST_SERVER_DST="$LA_DIR/$LABEL_SERVER.plist"
PLIST_UNLOCK_DST="$LA_DIR/$LABEL_UNLOCK.plist"

echo "==> 1/5 Prepare directories"
mkdir -p "$LA_DIR" "$BIN_DIR"

echo "==> 2/5 Install autostart + unlock scripts into $BIN_DIR"
cp "$HERE/dsh-web-autostart.sh" "$BIN_DIR/dsh-web-autostart.sh"
cp "$HERE/dsh-web-unlock.sh" "$BIN_DIR/dsh-web-unlock.sh"
chmod +x "$BIN_DIR/dsh-web-autostart.sh" "$BIN_DIR/dsh-web-unlock.sh"

echo "==> 3/5 Compile the screen-unlock watcher"
if [ ! -x "$BIN_DIR/dsh-web-unlock-watcher" ] || [ "$HERE/dsh-web-unlock-watcher.swift" -nt "$BIN_DIR/dsh-web-unlock-watcher" ]; then
  swiftc -O -o "$BIN_DIR/dsh-web-unlock-watcher" "$HERE/dsh-web-unlock-watcher.swift"
fi
chmod +x "$BIN_DIR/dsh-web-unlock-watcher"

echo "==> 4/5 Install LaunchAgents"
# Substitute the real absolute home path into the plists.
sed -e "s|/Users/allern|$USER_HOME|g" "$PLIST_SERVER_SRC" > "$PLIST_SERVER_DST"
sed -e "s|/Users/allern|$USER_HOME|g" "$PLIST_UNLOCK_SRC" > "$PLIST_UNLOCK_DST"

echo "==> 5/5 Make restart entries executable"
chmod +x "$HERE/../../restart-dsh-web.sh" "$HERE/../../restart-dsh-web.command" 2>/dev/null || true

# Boot the agents now (also covers "start right now" via RunAtLoad).
for LABEL in "$LABEL_SERVER" "$LABEL_UNLOCK"; do
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "==> Reloading existing LaunchAgent $LABEL"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    # launchd needs a beat after bootout before the service name is released;
    # bootstrapping too fast yields "Bootstrap failed: 5: Input/output error".
    sleep 2
  fi
done

boot_or_retry() {
  # shellcheck disable=SC2086
  launchctl bootstrap "gui/$(id -u)" "$1" && return 0
  echo "    bootstrap transient failure; retrying in 2s..."
  sleep 2
  # shellcheck disable=SC2086
  launchctl bootstrap "gui/$(id -u)" "$1"
}
boot_or_retry "$PLIST_SERVER_DST"
boot_or_retry "$PLIST_UNLOCK_DST"
echo ""
echo "Installed. Behavior:"
echo "  - web UI starts at login"
echo "  - after every screen unlock, the watcher checks the official"
echo "    @deepseek-ai/dsh release and restarts the web UI when a newer"
echo "    version is published (macOS is rarely rebooted, so unlock is the"
echo "    'every boot' freshness point)"
echo "To restart it anytime:  $HERE/../../restart-dsh-web.sh"
echo "Log: $HOME/.dsh/autostart-update.log"
