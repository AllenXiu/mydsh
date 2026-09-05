#!/bin/bash
# ============================================================================
#  Uninstall the macOS deployment for the DeepSeek Harness Web UI.
#  Usage   : bash deploy/macos/uninstall.sh
# ============================================================================
set -eu

LABEL_SERVER="com.allern.dsh-web"
LABEL_UNLOCK="com.allern.dsh-web-unlock"
LA_DIR="$HOME/Library/LaunchAgents"
BIN_DIR="$HOME/.dsh/bin"

echo "==> 1/3 Stop LaunchAgents"
for LABEL in "$LABEL_UNLOCK" "$LABEL_SERVER"; do
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "  bootout $LABEL"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  fi
done

echo "==> 2/3 Remove plists"
rm -f "$LA_DIR/$LABEL_SERVER.plist"
rm -f "$LA_DIR/$LABEL_UNLOCK.plist"

echo "==> 3/3 Remove installed scripts and watcher"
rm -f "$BIN_DIR/dsh-web-autostart.sh"
rm -f "$BIN_DIR/dsh-web-unlock.sh"
rm -f "$BIN_DIR/dsh-web-confirm-update.sh"
rm -f "$BIN_DIR/dsh-web-plugin-compat-check.mjs"
rm -f "$BIN_DIR/dsh-web-unlock-watcher"
rm -f "$HOME/.dsh/current-url.txt"

echo "Uninstalled. The running dsh web process (if any) is left untouched."
echo "Stop it manually if desired:"
echo "  for pid in \$(lsof -tiTCP:3080 -sTCP:LISTEN); do kill \$pid; done"
