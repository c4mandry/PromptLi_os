#!/bin/bash
# promptLi OS — autostart script
# Runs after i3 starts

# Start compositor for transparency/shadows
picom --config /etc/promptli/picom.conf &

# Set wallpaper
feh --bg-fill /opt/promptli/assets/wallpaper.png &

# Network manager applet
nm-applet &

# Start promptLi assistant minimized to tray
promptli &

# Start promptLi daemon if not running
if ! pgrep -f promptli_daemon.py > /dev/null; then
    sudo python3 /opt/promptli/promptli_daemon.py &
fi
