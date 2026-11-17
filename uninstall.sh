#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

STATE="$HOME/.local/state/radiata"
SETTINGS_BACKUP="$STATE/gsettings.tsv"
MANIFEST="$STATE/install-manifest.tsv"
DATA_DIR="$HOME/.local/share/radiata"
BASH_BEGIN="# >>> RADIATA THEME >>>"
BASH_END="# <<< RADIATA THEME <<<"
GTK_BEGIN="/* >>> RADIATA THEME >>> */"
GTK_END="/* <<< RADIATA THEME <<< */"

usage() {
    cat <<'EOF'
Usage: ./uninstall.sh [--version]

Restores the desktop settings recorded before Radiata and removes only
Radiata-owned assets. Installed Ubuntu packages are kept.
  --version  Print the Radiata version and exit.
EOF
}

for argument in "$@"; do
    case "$argument" in
        --version) printf 'Radiata %s\n' "$VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $argument" ;;
    esac
done

[[ $EUID -ne 0 ]] || die "Run this as your desktop user, not as root."

manifest_value() {
    local key="$1"
    awk -F '\t' -v key="$key" '$1 == key { print substr($0, length($1) + 2); exit }' "$MANIFEST"
}

preflight() {
    [[ -f "$STATE/.radiata-state" ]] || die "No Radiata-owned installation state exists at $STATE. Nothing was removed."
    [[ -f "$STATE/backup.complete" ]] || die "The Radiata backup is incomplete. Nothing was removed."
    [[ -s "$SETTINGS_BACKUP" ]] || die "The Radiata settings backup is missing or empty. Nothing was removed."
    [[ -s "$MANIFEST" ]] || die "The Radiata install manifest is missing. Nothing was removed."

    THEME_NAME="$(manifest_value THEME_NAME)"
    ICON_THEME_NAME="$(manifest_value ICON_THEME_NAME)"
    CURSOR_THEME_NAME="$(manifest_value CURSOR_THEME_NAME)"
    PTYXIS_PALETTE_NAME="$(manifest_value PTYXIS_PALETTE_NAME)"
    local name
    for name in "$THEME_NAME" "$ICON_THEME_NAME" "$CURSOR_THEME_NAME" "$PTYXIS_PALETTE_NAME"; do
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "The install manifest contains an unsafe or invalid theme name. Nothing was removed."
    done

    THEME_DIR="$HOME/.themes/$THEME_NAME"
    ICON_DIR="$HOME/.local/share/icons/$ICON_THEME_NAME"
    CURSOR_DIR="$HOME/.local/share/icons/$CURSOR_THEME_NAME"
}

restore_settings() {
    log "Restoring the GNOME and terminal settings saved before installation"
    local schema key value failures=0
    while IFS=$'\t' read -r schema key value; do
        [[ -n "$schema" && -n "$key" ]] || continue
        if ! key_exists "$schema" "$key"; then
            warn "Setting is no longer available: $schema $key"
            failures=$((failures + 1))
        elif ! gsettings set "$schema" "$key" "$value"; then
            warn "Could not restore: $schema $key"
            failures=$((failures + 1))
        fi
    done < "$SETTINGS_BACKUP"

    ((failures == 0)) || die "$failures desktop setting(s) could not be restored. Assets and recovery state were kept."
}

restore_files() {
    log "Restoring files that existed before Radiata"
    remove_marked_block "$HOME/.bashrc" "$BASH_BEGIN" "$BASH_END"
    remove_marked_block "$HOME/.config/gtk-4.0/gtk.css" "$GTK_BEGIN" "$GTK_END"

    restore_backed_up_file "$HOME/.config/btop/btop.conf" btop.conf
    restore_backed_up_file "$HOME/.config/gtk-4.0/radiata.css" gtk4-radiata.css
    restore_backed_up_file "$HOME/.config/btop/themes/radiata.theme" btop-radiata.theme
    restore_backed_up_file "$HOME/.config/fastfetch/radiata.jsonc" fastfetch-radiata.jsonc
    restore_backed_up_file "$HOME/.config/fastfetch/radiata-logo.txt" fastfetch-radiata-logo.txt
    restore_backed_up_file "$HOME/.local/share/org.gnome.Ptyxis/palettes/$PTYXIS_PALETTE_NAME.palette" ptyxis-radiata.palette
    restore_backed_up_file "$HOME/.local/share/applications/firefox_firefox.desktop" launcher-firefox.desktop
    restore_backed_up_file "$HOME/.local/share/applications/code_code.desktop" launcher-code.desktop
    restore_backed_up_file "$HOME/.local/share/applications/code_code-url-handler.desktop" launcher-code-url.desktop
    restore_backed_up_file "$HOME/.local/share/applications/telegram-desktop_telegram-desktop.desktop" launcher-telegram.desktop
    restore_backed_up_file "$HOME/.local/share/applications/snap-store_snap-store.desktop" launcher-appstore.desktop
    restore_backed_up_file "$HOME/.local/share/applications/snap-store_show-updates.desktop" launcher-appstore-updates.desktop
    restore_backed_up_file "$HOME/.local/share/applications/snap-store_packagekit-session-installer.desktop" launcher-appstore-packagekit.desktop
    restore_backed_up_file "$HOME/.local/share/applications/spotify_spotify.desktop" launcher-spotify.desktop
    command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
}

restore_gdm_theme() {
    [[ -f "$STATE/gdm-alternative.before" ]] || return 0
    log "Restoring the original GDM login theme"
    local original system_resource
    original="$(cat "$STATE/gdm-alternative.before")"
    system_resource="/usr/local/share/gnome-shell/radiata-gdm-theme.gresource"
    [[ "$original" == /usr/share/gnome-shell/* && -f "$original" ]] || \
        die "The saved GDM alternative is invalid or missing. System login files were not changed."

    sudo update-alternatives --set gdm-theme.gresource "$original"
    if update-alternatives --query gdm-theme.gresource 2>/dev/null | grep -F "Alternative: $system_resource" >/dev/null; then
        sudo update-alternatives --remove gdm-theme.gresource "$system_resource"
    fi
    sudo rm -f -- "$system_resource" /usr/local/share/backgrounds/radiata-login.png
}

remove_owned_directory() {
    local directory="$1"
    if [[ -f "$directory/.radiata-owned" ]]; then
        rm -rf -- "$directory"
    elif [[ -e "$directory" ]]; then
        warn "Leaving unowned directory untouched: $directory"
    fi
}

main() {
    preflight
    restore_gdm_theme
    restore_settings
    restore_files

    log "Removing Radiata-owned themes and artwork"
    remove_owned_directory "$THEME_DIR"
    remove_owned_directory "$ICON_DIR"
    remove_owned_directory "$CURSOR_DIR"
    remove_owned_directory "$DATA_DIR"

    # Recovery state is deleted only after every required restore succeeded.
    rm -rf -- "$STATE"

    printf '\n\033[1;32m[RESTORED]\033[0m Your pre-Radiata desktop settings are active again.\n'
    printf 'Log out and back in once to fully refresh GNOME Shell.\n'
    printf 'Packages installed by install.sh were left installed because they may now be in use.\n\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi