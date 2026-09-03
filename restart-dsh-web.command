#!/bin/bash
# Double-clickable Finder entry that runs restart-dsh-web.sh in a Terminal
# window and keeps the window open (mirrors double-clicking restart-dsh-web.cmd
# on Windows, whose final `pause` keeps the console readable).
cd "$(dirname "$0")" || exit 1
./restart-dsh-web.sh
echo "Press Enter to close this window..."
read -r _
