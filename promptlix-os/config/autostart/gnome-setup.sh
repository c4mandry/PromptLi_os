#!/bin/bash
# PromptLix OS — one-time GNOME preset (Tokyo Night)
# Runs once per user at first login, then removes itself.

MARK=~/.config/promptlix/gnome-setup-done
[ -f "$MARK" ] && exit 0

# ── Color scheme ────────────────────────────────────────
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
gsettings set org.gnome.desktop.interface icon-theme 'Adwaita'

# ── Fonts (JetBrains Mono ships with PromptLix) ─────────
gsettings set org.gnome.desktop.interface font-name 'JetBrains Mono 10'
gsettings set org.gnome.desktop.interface document-font-name 'JetBrains Mono 10'
gsettings set org.gnome.desktop.interface monospace-font-name 'JetBrains Mono 10'
gsettings set org.gnome.desktop.interface font-antialiasing 'rgba'
gsettings set org.gnome.desktop.interface font-hinting 'slight'

# ── Wallpaper (PNG generated from the SVG at build time) ──
WALLPAPER='file:///opt/promptlix/assets/wallpaper.png'
gsettings set org.gnome.desktop.background picture-uri "$WALLPAPER"
gsettings set org.gnome.desktop.background picture-uri-dark "$WALLPAPER"
gsettings set org.gnome.desktop.background picture-options 'zoom'

# ── Window & shell behavior (macOS-style) ────────────────
gsettings set org.gnome.desktop.wm.preferences button-layout 'close,minimize,maximize:'
gsettings set org.gnome.desktop.wm.preferences titlebar-font 'JetBrains Mono Bold 10'
gsettings set org.gnome.mutter center-new-windows true
gsettings set org.gnome.desktop.interface enable-animations true

# ── Files ───────────────────────────────────────────────
gsettings set org.gnome.nautilus.preferences default-folder-viewer 'icon-view'
gsettings set org.gnome.nautilus.preferences show-delete-permanently true

# ── GNOME Terminal: Tokyo Night palette ─────────────────
PROFILE_ID="$(cat /proc/sys/kernel/random/uuid)"
dconf write "/org/gnome/terminal/legacy/profiles:/:${PROFILE_ID}/visible-name" "'PromptLix'"
dconf write "/org/gnome/terminal/legacy/profiles:/:${PROFILE_ID}/use-theme-colors" "false"
dconf write "/org/gnome/terminal/legacy/profiles:/:${PROFILE_ID}/foreground-color" "'#c0caf5'"
dconf write "/org/gnome/terminal/legacy/profiles:/:${PROFILE_ID}/background-color" "'#1a1b26'"
dconf write "/org/gnome/terminal/legacy/profiles:/:${PROFILE_ID}/palette" "['#15161e', '#f7768e', '#9ece6a', '#e0af68', '#7aa2f7', '#bb9af7', '#7dcfff', '#a9b1d6', '#414868', '#f7768e', '#9ece6a', '#e0af68', '#7aa2f7', '#bb9af7', '#7dcfff', '#c0caf5']"
dconf write "/org/gnome/terminal/legacy/profiles:/list" "['b1dcc9dd-5262-4d8d-a863-c897e6d979b9', '${PROFILE_ID}']"
dconf write "/org/gnome/terminal/legacy/profiles:/default" "'${PROFILE_ID}'"

# ── Super+I → PromptLix installer (Calamares) ───────────
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']"
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ name 'Install PromptLix'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ command 'sudo -E calamares'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ binding '<Super>i'

# ── Dock favorites ──────────────────────────────────────
gsettings set org.gnome.shell favorite-apps "['org.gnome.Terminal.desktop', 'org.gnome.Nautilus.desktop', 'promptlix.desktop', 'zen-browser.desktop', 'org.gnome.Software.desktop']"

# ── Extensions (enabled only if installed — dash-to-dock ships with PromptLix) ──
if gnome-extensions list 2>/dev/null | grep -q 'dash-to-dock'; then
    gnome-extensions enable 'dash-to-dock@micxgx.gmail.com' 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM' 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed true 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock background-opacity 0.85 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock running-indicator-style 'DOTS' 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 48 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock show-trash false 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock show-mounts false 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock hot-keys false 2>/dev/null || true
fi

touch "$MARK"
rm -f ~/.config/autostart/promptlix-gnome-setup.desktop
