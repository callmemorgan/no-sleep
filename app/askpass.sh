#!/bin/bash

# Askpass helper for `sudo -A`, bundled in NoSleep.app and used when the CLI
# must change the system-wide power setting from the menu bar app, which has
# no TTY for sudo to prompt on. Prints the password on stdout; dismissing the
# dialog exits non-zero so sudo reports a failed authorization.
set -u

# The dialog is displayed from an activated app, otherwise it can open behind
# the frontmost window while sudo silently waits here for a password.
exec /usr/bin/osascript \
    -e 'tell application "System Events"' \
    -e 'activate' \
    -e 'display dialog "no-sleep needs your administrator password to change the system power setting." default answer "" with hidden answer with title "no-sleep" buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel"' \
    -e 'end tell' \
    -e 'text returned of result' 2>/dev/null
