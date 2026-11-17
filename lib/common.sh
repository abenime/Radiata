#!/usr/bin/env bash

log() { printf '\033[1;31m[RADIATA]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARNING]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

schema_exists() {
    local schema_id="${1%%:*}"
    # Do not use grep -q here: with `set -o pipefail`, grep can close the
    # pipe early and make gsettings exit on SIGPIPE, turning a match into 141.
    { gsettings list-schemas; gsettings list-relocatable-schemas; } | grep -Fx "$schema_id" >/dev/null
}

key_exists() {
    schema_exists "$1" && gsettings list-keys "$1" 2>/dev/null | grep -Fx "$2" >/dev/null
}

set_setting() {
    local schema="$1" key="$2" value="$3"
    if key_exists "$schema" "$key"; then
        gsettings set "$schema" "$key" "$value"
    else
        warn "Skipping unavailable setting: $schema $key"
    fi
}

backup_setting() {
    local schema="$1" key="$2"
    if key_exists "$schema" "$key"; then
        printf '%s\t%s\t%s\n' "$schema" "$key" "$(gsettings get "$schema" "$key")" >> "$SETTINGS_BACKUP"
    fi
}

backup_setting_once() {
    local schema="$1" key="$2"
    [[ -f "$SETTINGS_BACKUP" ]] || : > "$SETTINGS_BACKUP"
    if awk -F '\t' -v schema="$schema" -v key="$key" '$1 == schema && $2 == key { found=1 } END { exit !found }' "$SETTINGS_BACKUP"; then
        return
    fi
    backup_setting "$schema" "$key"
}

backup_file_once() {
    local file="$1" backup_name="$2" backup_dir="$STATE/file-backups"
    mkdir -p "$backup_dir"
    if [[ -f "$backup_dir/$backup_name.present" || -f "$backup_dir/$backup_name.absent" ]]; then
        return
    fi
    if [[ -e "$file" ]]; then
        cp -a -- "$file" "$backup_dir/$backup_name.present"
    else
        : > "$backup_dir/$backup_name.absent"
    fi
}

restore_backed_up_file() {
    local file="$1" backup_name="$2" backup_dir="$STATE/file-backups"
    if [[ -f "$backup_dir/$backup_name.present" ]]; then
        mkdir -p "$(dirname "$file")"
        cp -a -- "$backup_dir/$backup_name.present" "$file"
    elif [[ -f "$backup_dir/$backup_name.absent" ]]; then
        rm -f -- "$file"
    else
        warn "No original-file record for: $file"
        return 1
    fi
}

remove_marked_block() {
    local file="$1" begin="$2" end="$3" temp begin_count end_count
    [[ -f "$file" ]] || return 0
    begin_count="$(grep -Fxc "$begin" "$file" || true)"
    end_count="$(grep -Fxc "$end" "$file" || true)"
    if [[ "$begin_count" -eq 0 && "$end_count" -eq 0 ]]; then
        return 0
    fi
    if [[ "$begin_count" -ne 1 || "$end_count" -ne 1 ]]; then
        die "Refusing to edit $file because its Radiata markers are unbalanced or duplicated."
    fi
    temp="$(mktemp)"
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { skipping=1; next }
        $0 == end   { skipping=0; next }
        !skipping   { print }
    ' "$file" > "$temp"
    cat "$temp" > "$file"
    rm -f "$temp"
}

append_marked_block() {
    local file="$1" begin="$2" end="$3" content="$4"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    remove_marked_block "$file" "$begin" "$end"
    printf '\n%s\n%s\n%s\n' "$begin" "$content" "$end" >> "$file"
}

prepend_marked_block() {
    local file="$1" begin="$2" end="$3" content="$4" temp
    mkdir -p "$(dirname "$file")"
    touch "$file"
    remove_marked_block "$file" "$begin" "$end"
    temp="$(mktemp)"
    printf '%s\n%s\n%s\n\n' "$begin" "$content" "$end" > "$temp"
    cat "$file" >> "$temp"
    cat "$temp" > "$file"
    rm -f "$temp"
}

claim_directory() {
    local directory="$1"
    if [[ -e "$directory" && ! -f "$directory/.radiata-owned" ]]; then
        die "Refusing to replace existing unowned path: $directory"
    fi
    rm -rf -- "$directory"
    mkdir -p "$directory"
    : > "$directory/.radiata-owned"
}
