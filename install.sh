#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=theme.conf
source "$ROOT/theme.conf"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

STATE="$HOME/.local/state/radiata"
SETTINGS_BACKUP="$STATE/gsettings.tsv"
MANIFEST="$STATE/install-manifest.tsv"
DATA_DIR="$HOME/.local/share/radiata"
THEME_DIR="$HOME/.themes/$THEME_NAME"
ICON_DIR="$HOME/.local/share/icons/$ICON_THEME_NAME"
CURSOR_DIR="$HOME/.local/share/icons/$CURSOR_THEME_NAME"
GTK4_CSS="$HOME/.config/gtk-4.0/gtk.css"
BASH_BEGIN="# >>> RADIATA THEME >>>"
BASH_END="# <<< RADIATA THEME <<<"
GTK_BEGIN="/* >>> RADIATA THEME >>> */"
GTK_END="/* <<< RADIATA THEME <<< */"
SKIP_PACKAGES=false

usage() {
    cat <<'EOF'
Usage: ./install.sh [--skip-packages] [--version]

Installs and applies the Radiata desktop theme for Ubuntu GNOME.
  --skip-packages  Do not run apt; required tools must already be installed.
  --version        Print the Radiata version and exit.
EOF
}

for argument in "$@"; do
    case "$argument" in
        --skip-packages) SKIP_PACKAGES=true ;;
        --version) printf 'Radiata %s\n' "$VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $argument" ;;
    esac
done

[[ $EUID -ne 0 ]] || die "Run this as your desktop user, not as root. The script asks for sudo only for packages and GDM files."
command -v gsettings >/dev/null || die "gsettings is required. This theme targets Ubuntu GNOME."
[[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* || "${XDG_CURRENT_DESKTOP:-}" == *gnome* ]] || warn "GNOME was not detected; files will install, but GNOME settings may not apply."

validate_configuration() {
    local name color
    for name in "$THEME_NAME" "$ICON_THEME_NAME" "$CURSOR_THEME_NAME" "$PTYXIS_PALETTE_NAME"; do
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Theme names may contain only letters, numbers, dots, underscores, and dashes: $name"
    done
    for color in "$BG" "$BG_ALT" "$PANEL" "$SURFACE" "$SURFACE_HOVER" "$ACCENT" "$ACCENT_BRIGHT" "$ACCENT_DIM" "$TEXT" "$MUTED" "$GREEN" "$CYAN" "$YELLOW"; do
        [[ "$color" =~ ^#[0-9A-Fa-f]{6}$ ]] || die "Invalid six-digit hex color in theme.conf: $color"
    done
    [[ "$FONT" =~ ^[A-Za-z0-9._[:space:]-]+$ ]] || die "FONT contains unsupported characters: $FONT"
}

manifest_value() {
    local key="$1"
    awk -F '\t' -v key="$key" '$1 == key { print substr($0, length($1) + 2); exit }' "$MANIFEST"
}

initialize_state() {
    if [[ -d "$STATE" && ! -f "$STATE/.radiata-state" ]]; then
        die "Refusing to use unowned state directory: $STATE"
    fi
    mkdir -p "$STATE"
    : > "$STATE/.radiata-state"

    if [[ -f "$MANIFEST" ]]; then
        [[ "$(manifest_value THEME_NAME)" == "$THEME_NAME" && \
           "$(manifest_value ICON_THEME_NAME)" == "$ICON_THEME_NAME" && \
           "$(manifest_value CURSOR_THEME_NAME)" == "$CURSOR_THEME_NAME" && \
           "$(manifest_value PTYXIS_PALETTE_NAME)" == "$PTYXIS_PALETTE_NAME" ]] || \
            die "Theme names changed after installation. Run ./uninstall.sh before changing names."
    else
        printf 'THEME_NAME\t%s\nICON_THEME_NAME\t%s\nCURSOR_THEME_NAME\t%s\nPTYXIS_PALETTE_NAME\t%s\n' \
            "$THEME_NAME" "$ICON_THEME_NAME" "$CURSOR_THEME_NAME" "$PTYXIS_PALETTE_NAME" > "$MANIFEST"
    fi
}

on_error() {
    local line="$1"
    printf '\n\033[1;31m[ERROR]\033[0m Installation stopped near line %s. The recovery state remains at %s.\n' "$line" "$STATE" >&2
    [[ -f "$STATE/backup.complete" ]] && printf 'Run %s/uninstall.sh to roll back any changes already applied.\n' "$ROOT" >&2
}
trap 'on_error "$LINENO"' ERR

install_packages() {
    $SKIP_PACKAGES && { log "Skipping package installation"; return; }
    local packages=(
        gnome-tweaks
        gnome-shell-extensions
        papirus-icon-theme
        fonts-jetbrains-mono
        librsvg2-bin
        libgio-2.0-dev-bin
        x11-apps
        btop
        fastfetch
        cmatrix
    )
    local missing=() package
    for package in "${packages[@]}"; do
        dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep '^ii ' >/dev/null || missing+=("$package")
    done
    if ((${#missing[@]} == 0)); then
        log "All Ubuntu theme tools are already installed"
        return
    fi
    log "Installing missing Ubuntu tools: ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y "${missing[@]}"
}

require_tools() {
    local missing=() tool
    for tool in gsettings rsvg-convert xcursorgen python3 gnome-extensions gtk-update-icon-cache fastfetch btop cmatrix glib-compile-resources update-alternatives; do
        command -v "$tool" >/dev/null || missing+=("$tool")
    done
    ((${#missing[@]} == 0)) || die "Missing required tools: ${missing[*]}. Run without --skip-packages."
    [[ -d /usr/share/themes/Yaru-dark ]] || die "Yaru-dark is missing from /usr/share/themes/Yaru-dark."
    [[ -f /usr/share/gnome-shell/theme/Yaru/gnome-shell.css ]] || die "The Yaru GNOME Shell stylesheet is missing."
    [[ -d /usr/share/icons/Papirus-Dark ]] || die "Papirus-Dark is missing from /usr/share/icons/Papirus-Dark."
}

get_ptyxis_profile_schema() {
    local uuid
    schema_exists org.gnome.Ptyxis || return 1
    uuid="$(gsettings get org.gnome.Ptyxis default-profile-uuid 2>/dev/null | tr -d "'")"
    [[ -n "$uuid" ]] || return 1
    printf 'org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/%s/' "$uuid"
}

backup_initial_state() {
    mkdir -p "$STATE"
    if [[ -f "$STATE/backup.complete" ]]; then
        log "Keeping the original backup and journaling any newly available settings"
    else
        log "Backing up current desktop settings"
        : > "$SETTINGS_BACKUP"
    fi

    local schema key ptyxis_profile
    while IFS='|' read -r schema key; do
        backup_setting_once "$schema" "$key"
    done <<'EOF'
org.gnome.desktop.interface|gtk-theme
org.gnome.desktop.interface|icon-theme
org.gnome.desktop.interface|cursor-theme
org.gnome.desktop.interface|cursor-size
org.gnome.desktop.interface|font-name
org.gnome.desktop.interface|document-font-name
org.gnome.desktop.interface|monospace-font-name
org.gnome.desktop.interface|color-scheme
org.gnome.desktop.interface|accent-color
org.gnome.desktop.background|picture-uri
org.gnome.desktop.background|picture-uri-dark
org.gnome.desktop.background|picture-options
org.gnome.desktop.background|primary-color
org.gnome.desktop.screensaver|picture-uri
org.gnome.desktop.screensaver|primary-color
org.gnome.desktop.wm.preferences|theme
org.gnome.shell|enabled-extensions
org.gnome.shell.extensions.user-theme|name
org.gnome.shell.extensions.dash-to-dock|dock-position
org.gnome.shell.extensions.dash-to-dock|dash-max-icon-size
org.gnome.shell.extensions.dash-to-dock|extend-height
org.gnome.shell.extensions.dash-to-dock|dock-fixed
org.gnome.shell.extensions.dash-to-dock|custom-background-color
org.gnome.shell.extensions.dash-to-dock|background-color
org.gnome.shell.extensions.dash-to-dock|background-opacity
org.gnome.shell.extensions.dash-to-dock|apply-glossy-effect
org.gnome.shell.extensions.dash-to-dock|unity-backlit-items
org.gnome.shell.extensions.dash-to-dock|transparency-mode
org.gnome.shell.extensions.dash-to-dock|custom-theme-shrink
org.gnome.shell.extensions.dash-to-dock|custom-theme-customize-running-dots
org.gnome.shell.extensions.dash-to-dock|custom-theme-running-dots-color
org.gnome.shell.extensions.dash-to-dock|custom-theme-running-dots-border-color
org.gnome.shell.extensions.dash-to-dock|running-indicator-style
org.gnome.Ptyxis|interface-style
org.gnome.Ptyxis|font-name
org.gnome.Ptyxis|use-system-font
org.gnome.Ptyxis|cursor-shape
EOF

    if ptyxis_profile="$(get_ptyxis_profile_schema)"; then
        backup_setting_once "$ptyxis_profile" palette
        backup_setting_once "$ptyxis_profile" opacity
        backup_setting_once "$ptyxis_profile" bold-is-bright
    fi

    backup_file_once "$HOME/.config/btop/btop.conf" btop.conf
    backup_file_once "$HOME/.config/gtk-4.0/radiata.css" gtk4-radiata.css
    backup_file_once "$HOME/.config/btop/themes/radiata.theme" btop-radiata.theme
    backup_file_once "$HOME/.config/fastfetch/radiata.jsonc" fastfetch-radiata.jsonc
    backup_file_once "$HOME/.config/fastfetch/radiata-logo.txt" fastfetch-radiata-logo.txt
    backup_file_once "$HOME/.local/share/org.gnome.Ptyxis/palettes/$PTYXIS_PALETTE_NAME.palette" ptyxis-radiata.palette
    backup_file_once "$HOME/.local/share/applications/firefox_firefox.desktop" launcher-firefox.desktop
    backup_file_once "$HOME/.local/share/applications/code_code.desktop" launcher-code.desktop
    backup_file_once "$HOME/.local/share/applications/code_code-url-handler.desktop" launcher-code-url.desktop
    backup_file_once "$HOME/.local/share/applications/telegram-desktop_telegram-desktop.desktop" launcher-telegram.desktop
    backup_file_once "$HOME/.local/share/applications/snap-store_snap-store.desktop" launcher-appstore.desktop
    backup_file_once "$HOME/.local/share/applications/snap-store_show-updates.desktop" launcher-appstore-updates.desktop
    backup_file_once "$HOME/.local/share/applications/snap-store_packagekit-session-installer.desktop" launcher-appstore-packagekit.desktop
    backup_file_once "$HOME/.local/share/applications/spotify_spotify.desktop" launcher-spotify.desktop

    : > "$STATE/backup.complete"
}

render_template() {
    local source_file="$1" destination="$2"
    sed \
        -e "s|@BG@|$BG|g" \
        -e "s|@BG_ALT@|$BG_ALT|g" \
        -e "s|@PANEL@|$PANEL|g" \
        -e "s|@SURFACE@|$SURFACE|g" \
        -e "s|@SURFACE_HOVER@|$SURFACE_HOVER|g" \
        -e "s|@ACCENT@|$ACCENT|g" \
        -e "s|@ACCENT_BRIGHT@|$ACCENT_BRIGHT|g" \
        -e "s|@ACCENT_DIM@|$ACCENT_DIM|g" \
        -e "s|@TEXT@|$TEXT|g" \
        -e "s|@MUTED@|$MUTED|g" \
        -e "s|@GREEN@|$GREEN|g" \
        -e "s|@CYAN@|$CYAN|g" \
        -e "s|@YELLOW@|$YELLOW|g" \
        -e "s|@FONT@|$FONT|g" \
        "$source_file" > "$destination"
}

generate_wallpaper() {
    log "Generating the 4K matrix-rain wallpaper and lock-screen image"
    claim_directory "$DATA_DIR"
    cp "$ROOT/assets/wallpaper/spider-lily.png" "$DATA_DIR/spider-lily.png"
    render_template "$ROOT/templates/wallpaper.svg" "$DATA_DIR/radiata-wallpaper.svg"
    rsvg-convert -w 3840 -h 2160 "$DATA_DIR/radiata-wallpaper.svg" -o "$DATA_DIR/radiata-wallpaper.png"
}

install_gtk_and_shell_theme() {
    log "Building GTK, libadwaita, window-border, and GNOME Shell themes"
    claim_directory "$THEME_DIR"
    cp -a /usr/share/themes/Yaru-dark/. "$THEME_DIR/"
    : > "$THEME_DIR/.radiata-owned"

    if [[ -f "$THEME_DIR/index.theme" ]]; then
        sed -i \
            -e "s/^Name=.*/Name=$THEME_NAME/" \
            -e "s/^GtkTheme=.*/GtkTheme=$THEME_NAME/" \
            -e "s/^MetacityTheme=.*/MetacityTheme=$THEME_NAME/" \
            "$THEME_DIR/index.theme"
    fi

    local gtk_override="$DATA_DIR/gtk-overrides.css"
    render_template "$ROOT/templates/gtk-overrides.css" "$gtk_override"
    for version in gtk-3.0 gtk-4.0; do
        [[ -f "$THEME_DIR/$version/gtk.css" ]] && {
            printf '\n' >> "$THEME_DIR/$version/gtk.css"
            cat "$gtk_override" >> "$THEME_DIR/$version/gtk.css"
        }
    done

    # Yaru-dark ships this entry as a relative symlink into /usr/share.
    # After copying into ~/.themes the preserved link points into ~/gnome-shell
    # and becomes dangling, so replace it with this theme's real directory.
    rm -f -- "$THEME_DIR/gnome-shell"
    mkdir -p "$THEME_DIR/gnome-shell"
    cp /usr/share/gnome-shell/theme/Yaru/gnome-shell.css "$THEME_DIR/gnome-shell/gnome-shell.css"
    render_template "$ROOT/templates/shell-overrides.css" "$DATA_DIR/shell-overrides.css"
    printf '\n' >> "$THEME_DIR/gnome-shell/gnome-shell.css"
    cat "$DATA_DIR/shell-overrides.css" >> "$THEME_DIR/gnome-shell/gnome-shell.css"

    mkdir -p "$HOME/.config/gtk-4.0"
    cp "$gtk_override" "$HOME/.config/gtk-4.0/radiata.css"
    prepend_marked_block "$GTK4_CSS" "$GTK_BEGIN" "$GTK_END" '@import url("radiata.css");'
}

install_themed_launcher() {
    local source_file="$1" icon_name="$2" target
    [[ -f "$source_file" ]] || return 0
    target="$HOME/.local/share/applications/$(basename "$source_file")"
    mkdir -p "$HOME/.local/share/applications"
    cp -a -- "$source_file" "$target"
    sed -i "s|^Icon=.*|Icon=$icon_name|" "$target"
}

install_icon_theme() {
    log "Installing expanded red circuit icons and Snap launcher overrides"
    claim_directory "$ICON_DIR"
    mkdir -p "$ICON_DIR/scalable/places" "$ICON_DIR/scalable/apps" "$ICON_DIR/scalable/actions" "$ICON_DIR/scalable/status"

    cat > "$ICON_DIR/index.theme" <<EOF
[Icon Theme]
Name=$ICON_THEME_NAME
Comment=Radiata circuit icons with Papirus Dark fallbacks
Inherits=Papirus-Dark,hicolor
Directories=scalable/places,scalable/apps,scalable/actions,scalable/status

[scalable/places]
Size=128
Type=Scalable
MinSize=16
MaxSize=512
Context=Places

[scalable/apps]
Size=128
Type=Scalable
MinSize=16
MaxSize=512
Context=Applications

[scalable/actions]
Size=128
Type=Scalable
MinSize=16
MaxSize=512
Context=Actions

[scalable/status]
Size=128
Type=Scalable
MinSize=16
MaxSize=512
Context=Status
EOF

    local name
    for name in folder folder-open folder-remote folder-saved-search folder-recent \
        folder-desktop folder-documents folder-download folder-downloads folder-music \
        folder-pictures folder-publicshare folder-templates folder-videos user-home \
        inode-directory network-workgroup; do
        cp "$ROOT/assets/icons/folder.svg" "$ICON_DIR/scalable/places/$name.svg"
    done

    for name in start-here distributor-logo ubuntu-logo system-logo; do
        cp "$ROOT/assets/icons/start-here.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in view-app-grid view-app-grid-symbolic view-app-grid-user-symbolic \
        view-app-grid-ubuntu-symbolic view-app-grid-gnome-symbolic application-menu-symbolic; do
        cp "$ROOT/assets/icons/menu.svg" "$ICON_DIR/scalable/apps/$name.svg"
        cp "$ROOT/assets/icons/menu.svg" "$ICON_DIR/scalable/actions/$name.svg"
    done
    for name in org.gnome.Ptyxis utilities-terminal gnome-terminal terminal; do
        cp "$ROOT/assets/icons/terminal.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in firefox firefox-esr org.mozilla.firefox web-browser radiata-firefox; do
        cp "$ROOT/assets/icons/browser.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.Nautilus nautilus system-file-manager; do
        cp "$ROOT/assets/icons/folder.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.Settings gnome-control-center preferences-system; do
        cp "$ROOT/assets/icons/settings.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in snap-store app-center io.snapcraft.Store org.gnome.Software software-store radiata-appstore; do
        cp "$ROOT/assets/icons/appstore.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.TextEditor org.gnome.gedit gedit accessories-text-editor; do
        cp "$ROOT/assets/icons/editor.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.SystemMonitor gnome-system-monitor utilities-system-monitor; do
        cp "$ROOT/assets/icons/monitor.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.Calculator gnome-calculator accessories-calculator calculator; do
        cp "$ROOT/assets/icons/calculator.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.DiskUtility gnome-disks palimpsest drive-harddisk radiata-disks; do
        cp "$ROOT/assets/icons/disks.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in code code-oss visual-studio-code vscode radiata-vscode; do
        cp "$ROOT/assets/icons/vscode.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in telegram telegram-desktop org.telegram.desktop radiata-telegram; do
        cp "$ROOT/assets/icons/telegram.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.Snapshot org.gnome.Camera camera webcam; do
        cp "$ROOT/assets/icons/camera.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.Calendar gnome-calendar calendar; do
        cp "$ROOT/assets/icons/calendar.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.clocks org.gnome.Clocks gnome-clocks clocks; do
        cp "$ROOT/assets/icons/clocks.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in net.nokyan.Resources resources system-monitor radiata-resources; do
        cp "$ROOT/assets/icons/resources.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in vlc org.videolan.VLC radiata-vlc; do
        cp "$ROOT/assets/icons/vlc.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in spotify spotify-client radiata-spotify; do
        cp "$ROOT/assets/icons/spotify.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in gparted org.gnome.GParted radiata-gparted; do
        cp "$ROOT/assets/icons/gparted.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.baobab baobab; do
        cp "$ROOT/assets/icons/disks.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.Papers org.gnome.Evince evince; do
        cp "$ROOT/assets/icons/editor.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done
    for name in org.gnome.Loupe eog org.gnome.eog; do
        cp "$ROOT/assets/icons/camera.svg" "$ICON_DIR/scalable/apps/$name.svg"
    done

    install_themed_launcher /var/lib/snapd/desktop/applications/firefox_firefox.desktop radiata-firefox
    install_themed_launcher /var/lib/snapd/desktop/applications/code_code.desktop radiata-vscode
    install_themed_launcher /var/lib/snapd/desktop/applications/code_code-url-handler.desktop radiata-vscode
    install_themed_launcher /var/lib/snapd/desktop/applications/telegram-desktop_telegram-desktop.desktop radiata-telegram
    install_themed_launcher /var/lib/snapd/desktop/applications/snap-store_snap-store.desktop radiata-appstore
    install_themed_launcher /var/lib/snapd/desktop/applications/snap-store_show-updates.desktop radiata-appstore
    install_themed_launcher /var/lib/snapd/desktop/applications/snap-store_packagekit-session-installer.desktop radiata-appstore
    install_themed_launcher /var/lib/snapd/desktop/applications/spotify_spotify.desktop radiata-spotify

    gtk-update-icon-cache -f -t "$ICON_DIR" >/dev/null
    command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
}

compile_cursor() {
    local cursor_name="$1" svg_name="$2" hotspot_x="$3" hotspot_y="$4"
    local config="$DATA_DIR/cursor-build/$cursor_name.conf" size png scaled_x scaled_y
    : > "$config"
    for size in 24 32 48 64; do
        png="$DATA_DIR/cursor-build/${cursor_name}-${size}.png"
        rsvg-convert -w "$size" -h "$size" "$ROOT/assets/cursors/$svg_name.svg" -o "$png"
        scaled_x=$((hotspot_x * size / 64))
        scaled_y=$((hotspot_y * size / 64))
        printf '%s %s %s %s\n' "$size" "$scaled_x" "$scaled_y" "$png" >> "$config"
    done
    xcursorgen "$config" "$CURSOR_DIR/cursors/$cursor_name"
}

alias_cursors() {
    local target="$1" alias_name
    shift
    for alias_name in "$@"; do
        ln -sfn "$target" "$CURSOR_DIR/cursors/$alias_name"
    done
}

install_cursor_theme() {
    log "Compiling the custom neon-red cursor set"
    claim_directory "$CURSOR_DIR"
    mkdir -p "$CURSOR_DIR/cursors" "$DATA_DIR/cursor-build"
    cat > "$CURSOR_DIR/index.theme" <<EOF
[Icon Theme]
Name=$CURSOR_THEME_NAME
Comment=Neon red Radiata cursor theme
Inherits=Yaru,Adwaita
EOF

    compile_cursor left_ptr arrow 4 4
    compile_cursor pointer hand 25 9
    compile_cursor xterm text 32 32
    compile_cursor crosshair crosshair 32 32
    compile_cursor watch wait 32 32
    compile_cursor fleur move 32 32
    compile_cursor size_hor resize-h 32 32
    compile_cursor size_ver resize-v 32 32
    compile_cursor size_fdiag resize-d1 32 32
    compile_cursor size_bdiag resize-d2 32 32
    compile_cursor not-allowed forbidden 32 32
    compile_cursor help help 5 5

    alias_cursors left_ptr default arrow top_left_arrow left-arrow
    alias_cursors pointer hand hand1 hand2 pointing_hand link openhand grab grabbing closedhand copy alias dnd-copy dnd-link
    alias_cursors xterm text ibeam vertical-text
    alias_cursors crosshair cross cross_reverse diamond_cross cell tcross
    alias_cursors watch wait progress left_ptr_watch half-busy
    alias_cursors fleur move all-scroll dnd-move
    alias_cursors size_hor ew-resize col-resize h_double_arrow sb_h_double_arrow 028006030e0e7ebffc7f7070c0600140 14fef782d02440884392942c11205230
    alias_cursors size_ver ns-resize row-resize v_double_arrow sb_v_double_arrow 00008160000006810000408080010102 2870a09082c103050810ffdffffe0204
    alias_cursors size_fdiag nwse-resize bd_double_arrow top_left_corner bottom_right_corner fcf1c3c7cd4491d801f1e1c78f100000
    alias_cursors size_bdiag nesw-resize fd_double_arrow top_right_corner bottom_left_corner c7088f0f3e6c8088236ef8e1e3e70000
    alias_cursors not-allowed forbidden crossed_circle no-drop dnd-no-drop 03b6e0fcb3499374a867c041f52298f0
    alias_cursors help question_arrow whats_this left_ptr_help
}

install_terminal_theme() {
    log "Styling Ptyxis, btop, fastfetch, and the Bash prompt"
    local palette_dir="$HOME/.local/share/org.gnome.Ptyxis/palettes"
    mkdir -p "$palette_dir" "$HOME/.config/btop/themes" "$HOME/.config/fastfetch"

    cat > "$palette_dir/$PTYXIS_PALETTE_NAME.palette" <<EOF
[Palette]
Name=$PTYXIS_PALETTE_NAME
Background=$BG
Foreground=$TEXT
Cursor=$ACCENT
Color0=#090a0d
Color1=$ACCENT
Color2=$GREEN
Color3=$YELLOW
Color4=#b43b62
Color5=#df5cff
Color6=$CYAN
Color7=$TEXT
Color8=#6e444b
Color9=$ACCENT_BRIGHT
Color10=#70ffa0
Color11=#ffdf8a
Color12=#ff6680
Color13=#ef8aff
Color14=#8aeaff
Color15=#ffffff
EOF

    cat > "$HOME/.config/btop/themes/radiata.theme" <<EOF
# Radiata btop theme
theme[main_bg]="$BG"
theme[main_fg]="$TEXT"
theme[title]="$ACCENT_BRIGHT"
theme[hi_fg]="$ACCENT"
theme[selected_bg]="$ACCENT_DIM"
theme[selected_fg]="#ffffff"
theme[inactive_fg]="$MUTED"
theme[graph_text]="$TEXT"
theme[meter_bg]="#251018"
theme[proc_misc]="$CYAN"
theme[cpu_box]="$ACCENT_DIM"
theme[mem_box]="$ACCENT_DIM"
theme[net_box]="$ACCENT_DIM"
theme[proc_box]="$ACCENT_DIM"
theme[div_line]="$ACCENT_DIM"
theme[temp_start]="$GREEN"
theme[temp_mid]="$YELLOW"
theme[temp_end]="$ACCENT"
theme[cpu_start]="$ACCENT_DIM"
theme[cpu_mid]="$ACCENT"
theme[cpu_end]="$ACCENT_BRIGHT"
theme[free_start]="$ACCENT_DIM"
theme[free_mid]="$ACCENT"
theme[free_end]="$ACCENT_BRIGHT"
theme[cached_start]="#481326"
theme[cached_mid]="#9e2141"
theme[cached_end]="$ACCENT_BRIGHT"
theme[available_start]="#3d1423"
theme[available_mid]="$ACCENT_DIM"
theme[available_end]="$ACCENT"
theme[used_start]="$ACCENT_DIM"
theme[used_mid]="$ACCENT"
theme[used_end]="#ffffff"
theme[download_start]="$ACCENT_DIM"
theme[download_mid]="$ACCENT"
theme[download_end]="$ACCENT_BRIGHT"
theme[upload_start]="#5c1630"
theme[upload_mid]="#d52a57"
theme[upload_end]="#ff8ba1"
EOF

    local btop_config="$HOME/.config/btop/btop.conf"
    touch "$btop_config"
    if grep -qE '^[[:space:]]*color_theme[[:space:]]*=' "$btop_config"; then
        sed -i 's/^[[:space:]]*color_theme[[:space:]]*=.*/color_theme = "radiata"/' "$btop_config"
    else
        printf '\ncolor_theme = "radiata"\ntheme_background = True\n' >> "$btop_config"
    fi

    cat > "$HOME/.config/fastfetch/radiata-logo.txt" <<'EOF'
        /\
   ____/  \____
  /  RADIATA   \
 <  [ ACCESS ]  >
  \___  FF17 __/
      \  /
       \/
EOF

    cat > "$HOME/.config/fastfetch/radiata.jsonc" <<EOF
{
  "logo": {
    "type": "file",
    "source": "$HOME/.config/fastfetch/radiata-logo.txt",
    "color": { "1": "red" },
    "padding": { "right": 3 }
  },
  "display": {
    "separator": "  ➜  ",
    "color": { "keys": "red", "title": "light_red", "separator": "red" }
  },
  "modules": [
    "title", "separator", "os", "host", "kernel", "uptime", "packages",
    "shell", "display", "de", "wm", "terminal", "cpu", "gpu", "memory",
    "disk", "localip", "break"
  ]
}
EOF

    local bash_block
    bash_block="$(cat <<'EOF'
# Neon two-line prompt: identity, directory, Git branch, then access glyph.
_radiata_git_branch() {
    command git symbolic-ref --quiet --short HEAD 2>/dev/null | sed 's/^/ git:/'
}
export PS1='\[\e[38;2;255;23;56m\]┌─[\u@\h]\[\e[38;2;125;20;40m\]─[\[\e[38;2;247;233;236m\]\w\[\e[38;2;255;77;104m\]$(_radiata_git_branch)\[\e[38;2;125;20;40m\]]\n\[\e[38;2;255;23;56m\]└─ACCESS❯\[\e[0m\] '
export LS_COLORS="di=1;31:ln=91:so=35:pi=33:ex=1;91:bd=31;46:cd=31;43:su=37;41:sg=30;43:tw=30;42:ow=34;42"
alias ll='ls -alF --color=auto'
alias grep='grep --color=auto'
alias matrix='cmatrix -C red'
alias sys='fastfetch --config "$HOME/.config/fastfetch/radiata.jsonc"'
alias monitor='btop'

# Show the system HUD once when a top-level interactive terminal opens.
if [[ $- == *i* && ${SHLVL:-1} -le 2 && -z ${RADIATA_HUD_SHOWN:-} ]] && command -v fastfetch >/dev/null; then
    export RADIATA_HUD_SHOWN=1
    fastfetch --config "$HOME/.config/fastfetch/radiata.jsonc"
fi
EOF
)"
    append_marked_block "$HOME/.bashrc" "$BASH_BEGIN" "$BASH_END" "$bash_block"
}

install_gdm_theme() {
    [[ "$(basename "$(cat /etc/X11/default-display-manager 2>/dev/null || true)")" == "gdm3" ]] || {
        warn "GDM is not the active display manager; skipping the login-screen theme."
        return
    }

    log "Building and installing the reversible GDM login theme"
    local source_resource="/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
    local build_dir="$DATA_DIR/gdm-build"
    local resource_out="$DATA_DIR/radiata-gdm-theme.gresource"
    local system_resource="/usr/local/share/gnome-shell/radiata-gdm-theme.gresource"
    local system_wallpaper="/usr/local/share/backgrounds/radiata-login.png"
    local relative path

    [[ -f "$source_resource" ]] || die "The Yaru GDM resource is missing: $source_resource"
    rm -rf -- "$build_dir"
    mkdir -p "$build_dir"

    while IFS= read -r path; do
        relative="${path#/org/gnome/shell/theme/}"
        mkdir -p "$build_dir/$(dirname "$relative")"
        gresource extract "$source_resource" "$path" > "$build_dir/$relative"
    done < <(gresource list "$source_resource")

    render_template "$ROOT/templates/gdm-overrides.css" "$DATA_DIR/gdm-overrides.css"
    printf '\n' >> "$build_dir/gdm.css"
    cat "$DATA_DIR/gdm-overrides.css" >> "$build_dir/gdm.css"

    python3 - "$source_resource" "$build_dir/radiata-gdm.gresource.xml" <<'PY'
from pathlib import PurePosixPath
from xml.sax.saxutils import escape
import subprocess
import sys
resource, output = sys.argv[1:]
prefix = "/org/gnome/shell/theme/"
paths = subprocess.check_output(["gresource", "list", resource], text=True).splitlines()
with open(output, "w", encoding="utf-8") as stream:
    stream.write('<?xml version="1.0" encoding="UTF-8"?>\n<gresources>\n')
    stream.write(f'  <gresource prefix="{prefix.rstrip(chr(47))}">\n')
    for path in paths:
        relative = path.removeprefix(prefix)
        stream.write(f'    <file>{escape(str(PurePosixPath(relative)))}</file>\n')
    stream.write('  </gresource>\n</gresources>\n')
PY

    glib-compile-resources "$build_dir/radiata-gdm.gresource.xml" \
        --sourcedir="$build_dir" --target="$resource_out"
    gresource list "$resource_out" | grep -Fx '/org/gnome/shell/theme/gdm.css' >/dev/null || \
        die "The compiled GDM resource failed validation."

    if [[ ! -f "$STATE/gdm-alternative.before" ]]; then
        readlink -f /etc/alternatives/gdm-theme.gresource > "$STATE/gdm-alternative.before"
    fi

    sudo install -d -m 0755 /usr/local/share/gnome-shell /usr/local/share/backgrounds
    sudo install -m 0644 "$resource_out" "$system_resource"
    sudo install -m 0644 "$DATA_DIR/radiata-wallpaper.png" "$system_wallpaper"
    sudo update-alternatives --install /usr/share/gnome-shell/gdm-theme.gresource \
        gdm-theme.gresource "$system_resource" 25
    sudo update-alternatives --set gdm-theme.gresource "$system_resource"
}

enable_user_theme_extension() {
    local metadata uuid current updated
    metadata="$(find /usr/share/gnome-shell/extensions "$HOME/.local/share/gnome-shell/extensions" \
        -maxdepth 2 -path '*user-theme*/metadata.json' -print -quit 2>/dev/null || true)"
    if [[ -z "$metadata" ]]; then
        warn "GNOME User Themes extension was not found; GTK works, but the top bar may need a logout after package setup."
        return
    fi

    uuid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["uuid"])' "$metadata")"
    current="$(gsettings get org.gnome.shell enabled-extensions)"
    updated="$(python3 - "$uuid" "$current" <<'PY'
import ast
import sys
uuid = sys.argv[1]
raw = sys.argv[2].strip()
if raw.startswith('@as '):
    raw = raw[4:]
items = ast.literal_eval(raw)
if uuid not in items:
    items.append(uuid)
print(repr(items))
PY
)"
    gsettings set org.gnome.shell enabled-extensions "$updated"
    if gnome-extensions info "$uuid" >/dev/null 2>&1; then
        gnome-extensions enable "$uuid" || warn "User Themes could not be enabled in the current session; log out and back in."
    else
        warn "GNOME will discover the newly installed User Themes extension after you log out and back in."
    fi
    set_setting org.gnome.shell.extensions.user-theme name "'$THEME_NAME'"
}

apply_desktop_settings() {
    log "Applying dark mode, wallpaper, fonts, icons, cursor, panel, and dock"
    local wallpaper_uri ptyxis_profile
    wallpaper_uri="$(python3 - "$DATA_DIR/radiata-wallpaper.png" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_uri())
PY
)"

    set_setting org.gnome.desktop.interface gtk-theme "'$THEME_NAME'"
    set_setting org.gnome.desktop.interface icon-theme "'$ICON_THEME_NAME'"
    set_setting org.gnome.desktop.interface cursor-theme "'$CURSOR_THEME_NAME'"
    set_setting org.gnome.desktop.interface cursor-size 24
    set_setting org.gnome.desktop.interface color-scheme "'prefer-dark'"
    set_setting org.gnome.desktop.interface accent-color "'red'"
    set_setting org.gnome.desktop.interface font-name "'$FONT 10'"
    set_setting org.gnome.desktop.interface document-font-name "'$FONT 10'"
    set_setting org.gnome.desktop.interface monospace-font-name "'$FONT 11'"
    set_setting org.gnome.desktop.wm.preferences theme "'$THEME_NAME'"

    set_setting org.gnome.desktop.background picture-uri "'$wallpaper_uri'"
    set_setting org.gnome.desktop.background picture-uri-dark "'$wallpaper_uri'"
    set_setting org.gnome.desktop.background picture-options "'zoom'"
    set_setting org.gnome.desktop.background primary-color "'$BG'"
    set_setting org.gnome.desktop.screensaver picture-uri "'$wallpaper_uri'"
    set_setting org.gnome.desktop.screensaver primary-color "'$BG'"

    set_setting org.gnome.shell.extensions.dash-to-dock dock-position "'BOTTOM'"
    set_setting org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 42
    set_setting org.gnome.shell.extensions.dash-to-dock extend-height false
    set_setting org.gnome.shell.extensions.dash-to-dock dock-fixed true
    set_setting org.gnome.shell.extensions.dash-to-dock custom-background-color true
    set_setting org.gnome.shell.extensions.dash-to-dock background-color "'$PANEL'"
    set_setting org.gnome.shell.extensions.dash-to-dock background-opacity 0.0
    set_setting org.gnome.shell.extensions.dash-to-dock apply-glossy-effect false
    set_setting org.gnome.shell.extensions.dash-to-dock unity-backlit-items false
    set_setting org.gnome.shell.extensions.dash-to-dock transparency-mode "'FIXED'"
    set_setting org.gnome.shell.extensions.dash-to-dock custom-theme-shrink true
    set_setting org.gnome.shell.extensions.dash-to-dock custom-theme-customize-running-dots true
    set_setting org.gnome.shell.extensions.dash-to-dock custom-theme-running-dots-color "'$ACCENT'"
    set_setting org.gnome.shell.extensions.dash-to-dock custom-theme-running-dots-border-color "'$ACCENT_BRIGHT'"
    set_setting org.gnome.shell.extensions.dash-to-dock running-indicator-style "'DOTS'"

    set_setting org.gnome.Ptyxis interface-style "'dark'"
    set_setting org.gnome.Ptyxis use-system-font false
    set_setting org.gnome.Ptyxis font-name "'$FONT 11'"
    set_setting org.gnome.Ptyxis cursor-shape "'block'"
    if ptyxis_profile="$(get_ptyxis_profile_schema)"; then
        set_setting "$ptyxis_profile" palette "'$PTYXIS_PALETTE_NAME'"
        set_setting "$ptyxis_profile" opacity 0.90
        set_setting "$ptyxis_profile" bold-is-bright true
    fi

    enable_user_theme_extension
}

main() {
    printf '\n\033[1;31m  RADIATA %s // VISUAL SUBSYSTEM INSTALLER\033[0m\n\n' "$VERSION"
    validate_configuration
    initialize_state
    install_packages
    require_tools
    backup_initial_state
    generate_wallpaper
    install_gtk_and_shell_theme
    install_icon_theme
    install_cursor_theme
    install_terminal_theme
    install_gdm_theme
    apply_desktop_settings

    printf '\n\033[1;32m[COMPLETE]\033[0m Radiata is installed.\n'
    printf 'Log out and back in once to load the GNOME Shell theme and all cursor aliases.\n'
    printf 'Open a new terminal for the prompt and HUD. Run \033[1msys\033[0m, \033[1mmatrix\033[0m, or \033[1mmonitor\033[0m there.\n'
    printf 'Restore the previous desktop with: \033[1m%s/uninstall.sh\033[0m\n\n' "$ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi