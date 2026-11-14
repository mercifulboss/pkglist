#!/usr/bin/env bash
# pkgsync.sh — snapshot explicitly-installed packages on one Arch/CachyOS box
# and reinstall them on another.
#
#   ./pkgsync.sh export [dir]    # on the OLD machine  (default dir: ./pkglist)
#   ./pkgsync.sh install [dir]   # on the NEW machine
#
# Only explicitly installed packages (pacman -Qqe) are captured; dependencies
# get pulled in automatically on install. Flatpak apps are captured too.

set -euo pipefail

DIR="${2:-./pkglist}"

# Packages tied to the OLD machine's hardware or that the new distro's
# installer should own (kernels + NVIDIA kernel modules). Extended regex,
# matched against whole package names. Edit to taste.
EXCLUDE_RE='^(linux|linux-lts|linux-zen|linux-hardened)(-headers)?$|^nvidia(-open)?(-dkms|-lts)?$|^nvidia-open-beta.*$|^intel-ucode$|^thermald$|^(xf86-video-intel|vulkan-intel|intel-media-driver|libva-intel-driver|intel-gpu-tools)$|^(optimus-manager.*|envycontrol|nvidia-prime|bbswitch.*|supergfxctl)$|^lenovolegionlinux.*$|^legion.*$'

log()  { printf '\e[1;34m::\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m!!\e[0m %s\n' "$*" >&2; }

filter() { grep -Ev "$EXCLUDE_RE" || true; }

do_export() {
    mkdir -p "$DIR"

    pacman -Qqen | sort > "$DIR/native.all"
    pacman -Qqem | sort > "$DIR/foreign.all"
    filter < "$DIR/native.all"  > "$DIR/native.txt"
    filter < "$DIR/foreign.all" > "$DIR/foreign.txt"
    # what got dropped, so you can eyeball it
    cat "$DIR/native.all" "$DIR/foreign.all" | sort \
        | comm -23 - <(sort "$DIR/native.txt" "$DIR/foreign.txt") > "$DIR/excluded.txt"
    rm -f "$DIR/native.all" "$DIR/foreign.all"

    if command -v flatpak >/dev/null; then
        flatpak list --app --columns=application | sort -u > "$DIR/flatpak.txt"
    else
        : > "$DIR/flatpak.txt"
    fi

    cp -- "$0" "$DIR/pkgsync.sh" 2>/dev/null || true

    log "Wrote to $DIR:"
    printf '   native.txt   %5d  (repo packages)\n'  "$(wc -l < "$DIR/native.txt")"
    printf '   foreign.txt  %5d  (AUR / local)\n'    "$(wc -l < "$DIR/foreign.txt")"
    printf '   flatpak.txt  %5d  (flatpak apps)\n'   "$(wc -l < "$DIR/flatpak.txt")"
    printf '   excluded.txt %5d  (hardware/kernel, review)\n' "$(wc -l < "$DIR/excluded.txt")"
    log "Copy $DIR to the new machine and run: ./pkgsync.sh install $DIR"
}

aur_helper() {
    for h in paru yay; do command -v "$h" >/dev/null && { echo "$h"; return; }; done
    log "No AUR helper found, bootstrapping paru-bin" >&2
    sudo pacman -S --needed --noconfirm base-devel git >&2
    local tmp; tmp=$(mktemp -d)
    git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin" >&2
    (cd "$tmp/paru-bin" && makepkg -si --noconfirm) >&2
    rm -rf "$tmp"
    echo paru
}

do_install() {
    [[ -f "$DIR/native.txt" ]] || { warn "No $DIR/native.txt — run export first"; exit 1; }

    log "Syncing repos"
    sudo pacman -Syu

    # Split everything by whether the NEW machine's repos carry it. This means
    # stuff that was AUR on Arch but is in CachyOS repos goes through pacman,
    # and anything renamed/dropped is reported instead of aborting the transaction.
    local avail; avail=$(mktemp)
    pacman -Slq | sort -u > "$avail"

    local repo aur missing
    repo=$(mktemp); aur=$(mktemp); missing=$(mktemp)
    sort -u "$DIR/native.txt"  | comm -12 - "$avail"  > "$repo"
    sort -u "$DIR/native.txt"  | comm -23 - "$avail"  > "$missing"
    sort -u "$DIR/foreign.txt" | comm -12 - "$avail" >> "$repo"
    sort -u "$DIR/foreign.txt" | comm -23 - "$avail"  > "$aur"

    if [[ -s "$repo" ]]; then
        log "Installing $(wc -l < "$repo") repo packages"
        sudo pacman -S --needed - < "$repo"
    fi

    if [[ -s "$aur" ]]; then
        local helper; helper=$(aur_helper)
        log "Installing $(wc -l < "$aur") AUR packages with $helper"
        # --needed skips anything already present; failures are listed at the end
        "$helper" -S --needed - < "$aur" || warn "Some AUR builds failed — rerun or install individually"
    fi

    if [[ -s "$DIR/flatpak.txt" ]]; then
        command -v flatpak >/dev/null || sudo pacman -S --needed --noconfirm flatpak
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
        log "Installing $(wc -l < "$DIR/flatpak.txt") flatpaks"
        xargs -a "$DIR/flatpak.txt" flatpak install -y flathub || warn "Some flatpaks failed"
    fi

    if [[ -s "$missing" ]]; then
        cp "$missing" "$DIR/not-in-repos.txt"
        warn "$(wc -l < "$missing") repo packages from the old box aren't in this box's repos (renamed/dropped):"
        sed 's/^/   /' "$missing" >&2
        warn "Saved to $DIR/not-in-repos.txt"
    fi
    rm -f "$avail" "$repo" "$aur" "$missing"

    log "Done. Hardware-specific packages skipped on export are in $DIR/excluded.txt"
}

case "${1:-}" in
    export)  do_export ;;
    install) do_install ;;
    *) echo "usage: $0 {export|install} [dir]"; exit 1 ;;
esac
