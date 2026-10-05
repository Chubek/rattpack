#!/usr/bin/env bash
set -euo pipefail

NEOVIM_RUNTIME_DIR="${NEOVIM_RUNTIME_DIR:-$HOME/.config/nvim}"

usage() {
    printf 'Usage: %s <plugin-directory>\n' "$0" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage

src=$1

if [[ -z "${NEOVIM_RUNTIME_DIR:-}" ]]; then
    printf '%s: NEOVIM_RUNTIME_DIR is not set\n' "$0" >&2
    exit 1
fi

[[ -d "$src" ]] || {
    printf '%s: not a directory: %s\n' "$0" "$src" >&2
    exit 1
}

mkdir -p "$NEOVIM_RUNTIME_DIR"

# Copy every runtime directory (syntax/, indent/, ftplugin/, plugin/, ...)
# while preserving the directory structure.
for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    [[ -e "$entry" ]] || continue

    name=$(basename "$entry")
    dest="$NEOVIM_RUNTIME_DIR/$name"

    if [[ -d "$entry" ]]; then
        mkdir -p "$dest"
        cp -a "$entry/." "$dest/"
    else
        cp -a "$entry" "$dest"
    fi
done

printf 'Installed %s into %s\n' "$src" "$NEOVIM_RUNTIME_DIR"
