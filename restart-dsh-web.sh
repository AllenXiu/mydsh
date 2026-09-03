#!/bin/bash
# ============================================================================
#  DeepSeek Harness Web UI - one-click restart helper (macOS)
#  Usage   : ./restart-dsh-web.sh   (or double-click restart-dsh-web.command)
#  What    : stops the dsh web currently listening on $PORT, then relaunches
#            it through the same autostart path the login LaunchAgent uses
#            (update check -> start web --no-open). Mirrors restart-dsh-web.cmd.
#  Port    : change PORT below if your web UI is configured on another port.
# ============================================================================
set -u

PORT="${PORT:-3080}"
LABEL="com.allern.dsh-web"
AUTOSTART="$HOME/.dsh/bin/dsh-web-autostart.sh"
URL="http://127.0.0.1:$PORT"
LOG="$HOME/.dsh/autostart-update.log"

echo "============================================================"
echo " DeepSeek Harness Web UI - restart"
echo " Port : $PORT"
echo " Agent: gui/$(id -u)/$LABEL"
echo "============================================================"

# ---- 1. stop whatever is LISTENING on the port ----
FOUND=0
for PID in $(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null); do
  FOUND=1
  echo "Stopping dsh web PID $PID"
  kill "$PID" 2>/dev/null || true
done
if [ "$FOUND" -eq 0 ]; then
  echo "No dsh web found on port $PORT - nothing to stop."
fi

# ---- 2. let the port release ----
sleep 4

# ---- 3. relaunch through the LaunchAgent (update check + start web) ----
echo "Relaunching via LaunchAgent (this runs the official-dsh update first) ..."
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  # -k kills the current instance, then starts it again (RunAtLoad).
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
else
  echo "[WARN] LaunchAgent $LABEL is not loaded; falling back to direct start."
  if [ -x "$AUTOSTART" ]; then
    nohup bash "$AUTOSTART" >> "$LOG" 2>&1 &
  else
    echo "[ERROR] autostart script not found: $AUTOSTART"
    exit 1
  fi
fi

# ---- 4. wait up to ~40s for the web UI to come back (update check can be slow) ----
echo "Waiting for the web UI to come back ..."
UP=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 4
  if curl -sf -o /dev/null "$URL"; then
    UP=1
    break
  fi
done

echo ""
if [ "$UP" -eq 1 ]; then
  echo "[OK] dsh web is running: $URL"
else
  echo "[WARN] not up yet. The autostart script updates dsh first and can take"
  echo "       longer on the first run. Wait a bit, then check $URL"
  echo "       or see $LOG"
fi
echo ""
