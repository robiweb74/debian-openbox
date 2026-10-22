#!/bin/bash
# ------------------------------------------------------------------
# Debian minimal -> Openbox desktop (browser + terminal + Conky)
# For VMware Workstation. Tested target: Debian 12 / 13.
#
# Usage (as your normal user, NOT logged in as root):
#   chmod +x setup-debian-openbox.sh
#   sudo ./setup-debian-openbox.sh
# ------------------------------------------------------------------
set -euo pipefail

# ---------------- settings you may change -------------------------
BROWSER_PKG="firefox-esr"          # or: chromium
BROWSER_CMD="firefox-esr"          # or: chromium
OMP_THEME="jandedobbeleer"         # any theme from https://ohmyposh.dev/docs/themes
NERD_FONT_ZIP="Meslo"              # Nerd Fonts release name (Meslo, JetBrainsMono, FiraCode...)
TERM_FONT="MesloLGM Nerd Font Mono"
INSTALL_NORDVPN=1                  # 1 = install NordVPN CLI, 0 = skip
# ------------------------------------------------------------------

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo:  sudo $0"; exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  echo "Run this with sudo from your normal user account (not directly as root)."; exit 1
fi
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"

as_user() { sudo -u "$TARGET_USER" -H bash -c "$*"; }

# ------------------------------------------------------------------
log "1/9 Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  xserver-xorg xinit x11-xserver-utils x11-utils \
  openbox obconf picom \
  open-vm-tools open-vm-tools-desktop \
  "$BROWSER_PKG" ffmpeg \
  pulseaudio pavucontrol \
  xfce4-terminal conky-all \
  sudo curl wget unzip git ca-certificates fontconfig \
  fonts-dejavu fonts-noto-color-emoji \
  iproute2 procps

# ------------------------------------------------------------------
log "2/9 Autologin on tty1"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $TARGET_USER --noclear %I \$TERM
EOF
systemctl daemon-reload

# ------------------------------------------------------------------
log "3/9 Starting X automatically after login"
[ -f "$HOME_DIR/.bash_profile" ] && cp -n "$HOME_DIR/.bash_profile" "$HOME_DIR/.bash_profile.bak"
cat > "$HOME_DIR/.bash_profile" <<'EOF'
# load the normal profile (which also loads .bashrc)
[ -f ~/.profile ] && . ~/.profile

# start X on tty1 only
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec startx
fi
EOF

cat > "$HOME_DIR/.xinitrc" <<'EOF'
exec openbox-session
EOF

# ------------------------------------------------------------------
log "4/9 Nerd Font"
FONT_DIR="$HOME_DIR/.local/share/fonts/NerdFonts"
mkdir -p "$FONT_DIR"
TMPZIP="$(mktemp --suffix=.zip)"
if curl -fL "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${NERD_FONT_ZIP}.zip" -o "$TMPZIP"; then
  unzip -oq "$TMPZIP" -x '*.txt' '*.md' 'LICENSE*' 'OFL*' -d "$FONT_DIR" || true
else
  warn "Could not download the Nerd Font. Install it manually later."
fi
rm -f "$TMPZIP"
chown -R "$TARGET_USER:$TARGET_GROUP" "$HOME_DIR/.local"
as_user "fc-cache -f" || true

# ------------------------------------------------------------------
log "5/9 Oh My Posh + terminal config"
as_user "mkdir -p ~/.local/bin ~/.config/ohmyposh"
as_user "curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d \$HOME/.local/bin" \
  || warn "oh-my-posh install failed"
as_user "curl -fsSL -o ~/.config/ohmyposh/theme.omp.json https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/${OMP_THEME}.omp.json" \
  || warn "Could not download Oh My Posh theme"

if ! grep -q 'oh-my-posh init bash' "$HOME_DIR/.bashrc" 2>/dev/null; then
  cat >> "$HOME_DIR/.bashrc" <<'EOF'

# --- Oh My Posh ---
export PATH="$HOME/.local/bin:$PATH"
if command -v oh-my-posh >/dev/null 2>&1; then
  eval "$(oh-my-posh init bash --config ~/.config/ohmyposh/theme.omp.json)"
fi
EOF
fi

mkdir -p "$HOME_DIR/.config/xfce4/terminal"
cat > "$HOME_DIR/.config/xfce4/terminal/terminalrc" <<EOF
[Configuration]
FontUseSystem=FALSE
FontName=$TERM_FONT 11
MiscMenubarDefault=FALSE
MiscDefaultGeometry=110x30
ScrollingBar=TERMINAL_SCROLLBAR_NONE
ColorForeground=#D8DEE9
ColorBackground=#2E3440
ColorCursor=#D8DEE9
ColorPalette=#3B4252;#BF616A;#A3BE8C;#EBCB8B;#81A1C1;#B48EAD;#88C0D0;#E5E9F0;#4C566A;#BF616A;#A3BE8C;#EBCB8B;#81A1C1;#B48EAD;#8FBCBB;#ECEFF4
EOF

# ------------------------------------------------------------------
log "6/9 NordVPN CLI"
if [ "$INSTALL_NORDVPN" = "1" ]; then
  if ! command -v nordvpn >/dev/null 2>&1; then
    # -n = non-interactive
    sh <(curl -fsSL https://downloads.nordcdn.com/apps/linux/install.sh) -n \
      || warn "NordVPN install failed. Run the installer manually later."
  fi
  getent group nordvpn >/dev/null && usermod -aG nordvpn "$TARGET_USER" || true
fi

# ------------------------------------------------------------------
log "7/9 Conky"
CONKY_DIR="$HOME_DIR/.config/conky"
mkdir -p "$CONKY_DIR"

IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}' || true)"
if [ -z "$IFACE" ]; then
  IFACE="$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')"
fi
IFACE="${IFACE:-ens33}"
echo "Detected network interface: $IFACE"

cat > "$CONKY_DIR/nord.sh" <<'EOF'
#!/bin/bash
# Helper: prints one field of `nordvpn status`
out=$(nordvpn status 2>/dev/null | tr '\r' '\n')
get() { echo "$out" | grep -i "^ *$1:" | head -n1 | cut -d: -f2- | sed 's/^ *//'; }
case "$1" in
  status)   v=$(get "Status") ;;
  server)   v=$(get "Hostname") ;;
  country)  v=$(get "Country") ;;
  city)     v=$(get "City") ;;
  ip)       v=$(get "IP") ;;
  tech)     v=$(get "Current technology") ;;
  transfer) v=$(get "Transfer") ;;
  uptime)   v=$(get "Uptime") ;;
esac
echo "${v:--}"
EOF
chmod +x "$CONKY_DIR/nord.sh"

cat > "$CONKY_DIR/conky.conf" <<'EOF'
conky.config = {
  alignment = 'top_right',
  gap_x = 20,
  gap_y = 40,
  minimum_width = 290,
  maximum_width = 290,
  update_interval = 2,
  double_buffer = true,
  own_window = true,
  own_window_type = 'desktop',
  own_window_class = 'Conky',
  own_window_transparent = false,
  own_window_argb_visual = true,
  own_window_argb_value = 150,
  own_window_colour = '2E3440',
  own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',
  use_xft = true,
  font = 'MesloLGM Nerd Font Mono:size=10',
  default_color = 'D8DEE9',
  color1 = '88C0D0',
  color2 = 'A3BE8C',
  color3 = 'BF616A',
  border_inner_margin = 12,
  border_outer_margin = 0,
  draw_borders = false,
  draw_shades = false,
  draw_outline = false,
  no_buffers = true,
  cpu_avg_samples = 2,
  net_avg_samples = 2,
  short_units = true,
}

conky.text = [[
${color1}${font :bold:size=12}SYSTEM${font}${color}
${hr 1}
Host: $nodename
Uptime: $uptime_short

${color1}CPU${color}  ${cpu cpu0}%  ${alignr}${freq_g} GHz
${cpubar 6}
${cpugraph 30,265 88C0D0 5E81AC}

${color1}RAM${color}  $mem / $memmax  ${alignr}$memperc%
${membar 6}

${color1}DISK /${color}  ${fs_used /} / ${fs_size /}  ${alignr}${fs_used_perc /}%
${fs_bar 6 /}
Read: ${diskio_read}  ${alignr}Write: ${diskio_write}

${color1}${font :bold:size=12}NETWORK (__IFACE__)${font}${color}
${hr 1}
${if_up __IFACE__}IP: ${addr __IFACE__}
Down: ${downspeed __IFACE__}  ${alignr}Up: ${upspeed __IFACE__}
${color2}${downspeedgraph __IFACE__ 25,128 A3BE8C A3BE8C}${color} ${color3}${upspeedgraph __IFACE__ 25,128 BF616A BF616A}${color}
Total: ${totaldown __IFACE__} down  ${alignr}${totalup __IFACE__} up${else}Disconnected${endif}

${color1}${font :bold:size=12}NORDVPN${font}${color}
${hr 1}
Status: ${execi 5 ~/.config/conky/nord.sh status}
Server: ${execi 5 ~/.config/conky/nord.sh server}
Location: ${execi 5 ~/.config/conky/nord.sh city}, ${execi 5 ~/.config/conky/nord.sh country}
VPN IP: ${execi 5 ~/.config/conky/nord.sh ip}
Tech: ${execi 5 ~/.config/conky/nord.sh tech}
Transfer: ${execi 5 ~/.config/conky/nord.sh transfer}
Uptime: ${execi 5 ~/.config/conky/nord.sh uptime}
${if_up nordlynx}Down: ${downspeed nordlynx}  ${alignr}Up: ${upspeed nordlynx}
${color2}${downspeedgraph nordlynx 25,128 A3BE8C A3BE8C}${color} ${color3}${upspeedgraph nordlynx 25,128 BF616A BF616A}${color}${endif}${if_up tun0}Down: ${downspeed tun0}  ${alignr}Up: ${upspeed tun0}${endif}
]];
EOF
sed -i "s/__IFACE__/$IFACE/g" "$CONKY_DIR/conky.conf"

# ------------------------------------------------------------------
log "8/9 Openbox config"
OB_DIR="$HOME_DIR/.config/openbox"
mkdir -p "$OB_DIR"

cat > "$OB_DIR/autostart" <<EOF
# VMware integration (clipboard, drag and drop, auto-resize)
if command -v vmware-user-suid-wrapper >/dev/null 2>&1; then
  vmware-user-suid-wrapper &
fi

# no screen blanking / power saving
xset s off -dpms &

# background color (Nord)
xsetroot -solid "#2E3440" &

# compositor (needed for Conky transparency)
picom -b &

# Conky
(sleep 3 && conky -c ~/.config/conky/conky.conf) &

# apps
$BROWSER_CMD &
xfce4-terminal &
EOF

if [ ! -f "$OB_DIR/rc.xml" ]; then
  cp /etc/xdg/openbox/rc.xml "$OB_DIR/rc.xml"
fi

if ! grep -q 'W-Return' "$OB_DIR/rc.xml"; then
  SNIP="$(mktemp)"
  cat > "$SNIP" <<EOF
    <keybind key="W-Return">
      <action name="Execute"><command>xfce4-terminal</command></action>
    </keybind>
    <keybind key="W-b">
      <action name="Execute"><command>$BROWSER_CMD</command></action>
    </keybind>
EOF
  sed -i "/<\/keyboard>/e cat $SNIP" "$OB_DIR/rc.xml"
  rm -f "$SNIP"
fi

# ------------------------------------------------------------------
log "9/9 Firefox policy: uBlock Origin + no first-run noise"
if [ "$BROWSER_PKG" = "firefox-esr" ]; then
  mkdir -p /etc/firefox/policies
  cat > /etc/firefox/policies/policies.json <<'EOF'
{
  "policies": {
    "DisableTelemetry": true,
    "DontCheckDefaultBrowser": true,
    "OverrideFirstRunPage": "",
    "ExtensionSettings": {
      "uBlock0@raymondhill.net": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"
      }
    }
  }
}
EOF
fi

# ------------------------------------------------------------------
chown -R "$TARGET_USER:$TARGET_GROUP" \
  "$HOME_DIR/.config" "$HOME_DIR/.local" \
  "$HOME_DIR/.bash_profile" "$HOME_DIR/.xinitrc" "$HOME_DIR/.bashrc"

log "Done!"
cat <<EOF

Next steps:
  1. Reboot:            sudo reboot
  2. It will auto-login as '$TARGET_USER' and start Openbox with the browser, terminal and Conky.
  3. In the terminal:   nordvpn login
                        nordvpn set technology nordlynx
                        nordvpn connect
  4. Shortcuts:         Win+Enter = terminal, Win+B = browser, right-click desktop = menu

VMware tip: enable "Accelerate 3D graphics" in the VM display settings.
EOF
