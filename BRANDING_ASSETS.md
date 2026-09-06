# PromptLix — Branding Assets Checklist

Everything below still carries the **old branding** or **placeholder art** and needs real PromptLix artwork. Send replacement images for these and I'll wire them in.

## 1. Wallpaper (most visible)

| Asset | Current state | Needed |
|---|---|---|
| `promptlix-os/assistant/assets/wallpaper.svg` | Tokyo Night gradient + lightning bolt; text says **"PromptLix OS"** (string was auto-renamed, but the art itself is still the old placeholder) | New 1920x1080 wallpaper with the final PromptLix logo/wordmark. **PNG preferred** — the build converts SVG→PNG via `rsvg-convert`, and GNOME sets it as the wallpaper on first login. |

## 2. App & desktop icons (missing entirely — referenced but don't exist)

| Asset | Referenced by | Current state |
|---|---|---|
| `/opt/promptlix/assets/promptlix.png` | `assistant/promptlix.desktop` (`Icon=`) | File doesn't exist — app-grid entry falls back to a generic icon |
| `/opt/promptlix/assets/locakhost.png` | `tools/locakhost.desktop` (`Icon=`) | File doesn't exist |
| `/opt/promptlix/assets/zen-browser.png` | `zen-browser.desktop` uses Zen's own bundled icon | Ships with Zen, no action needed |

**Needed:** a PromptLix app icon (256x256 or 512x512 PNG) and optionally a locakHost icon.

## 3. Installer (Calamares) branding — auto-generated placeholders

These are **generated at build time** by `build/live_build_inner.sh` (solid-color Tokyo Night PNGs, no logo):

| Asset | Location in built OS | Needed |
|---|---|---|
| Installer logo | `/etc/calamares/branding/promptlix/logo.png` (192x192) | Real PromptLix logo |
| Welcome image | `/etc/calamares/branding/promptlix/welcome.png` (800x450) | Real welcome/hero image |

They're declared in `branding.desc` (`productLogo`, `productIcon`, `productWelcome`). Drop replacements into a new `promptlix-os/config/branding/` folder and I'll make the build script copy them instead of generating placeholders.

## 3b. Boot splash (Plymouth) & login screen — auto-generated placeholder

| Asset | Location in built OS | Needed |
|---|---|---|
| Boot splash logo | `/usr/share/plymouth/themes/promptlix/logo.png` (192×192) | Real PromptLix logo (shown center-screen during boot) |
| Login screen background | GDM uses `/opt/promptlix/assets/wallpaper.png` (dark theme applied) | Already branded via wallpaper — replace wallpaper for full effect |

## 4. Text-only branding (already renamed, no images needed)

- Boot menu title: "PromptLix OS" (text, done)
- GNOME dark theme: applied on first login (Tokyo Night via `color-scheme: prefer-dark`)
- GRUB menu entry: "PromptLix" (text, done)
- Window title: "AIDO" (the assistant app) ✅ (text, done)
- GDM login screen: default Debian GDM — unbranded, optional to theme

## 5. Optional extras (none exist today)

- Plymouth boot splash (currently text-mode boot)
- GNOME lock screen artwork
- GRUB background image
- Custom GDM theme

---

### Summary of what to send me

1. **Wallpaper** — 1920x1080 PNG (with final PromptLix logo)
2. **App icon** — 256x256+ PNG (used by the assistant + desktop entries)
3. **Installer logo** — 192x192 PNG
4. **Installer welcome image** — 800x450 PNG
5. *(optional)* locakHost icon
