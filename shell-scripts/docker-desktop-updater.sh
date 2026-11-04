#!/usr/bin/env bash
set -euo pipefail

NOTES_URL="https://docs.docker.com/desktop/release-notes.md"
DL_DIR="$HOME/Downloads/docker-desktop-updates"
mkdir -p "$DL_DIR"

# Installed version (e.g. 4.97.0-244584 -> 4.97.0)
installed=$(dpkg-query -W -f='${Version}' docker-desktop 2>/dev/null | cut -d- -f1) || installed=""

# Latest version + .deb link (first entry on the page = newest)
page=$(curl -fsSL --max-time 30 "$NOTES_URL") || { echo "Could not download the release page. Check internet."; exit 1; }
latest=$(grep -oP '^## \K[0-9]+\.[0-9]+\.[0-9]+' <<<"$page" | head -1 || true)
deb_url=$(grep -oP 'https://desktop\.docker\.com/linux/main/amd64/[0-9]+/docker-desktop-amd64\.deb' <<<"$page" | head -1 || true)

if [ -z "$latest" ] || [ -z "$deb_url" ]; then
  echo "Could not read version or download link from the release page."; exit 1
fi

echo "Installed: ${installed:-none}"
echo "Latest:    $latest"

# Already up to date?
if [ -n "$installed" ] && [ "$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | tail -1)" = "$installed" ]; then
  echo "You are up to date."; exit 0
fi

# Ask
echo
echo "Note: Docker Desktop will restart and running containers will stop."
read -rp "Download and install $latest? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

# Download (fast with aria2, fallback to curl)
deb="$DL_DIR/docker-desktop-$latest-amd64.deb"
if command -v aria2c >/dev/null 2>&1; then
  aria2c -x 16 -s 16 -k 1M -c --file-allocation=none \
    --allow-overwrite=true --auto-file-renaming=false \
    -d "$DL_DIR" -o "$(basename "$deb")" "$deb_url"
else
  echo "aria2 not installed, using normal download (slower)."
  curl -fL -C - --progress-bar -o "$deb" "$deb_url"
fi

# Verify checksum (best effort)
sum_url="${deb_url%/*}/checksums.txt"
expected=$(curl -fsSL "$sum_url" | grep 'docker-desktop-amd64.deb' | grep -oP '\b[a-f0-9]{64}\b' | head -1 || true)
if [ -n "$expected" ]; then
  actual=$(sha256sum "$deb" | cut -d' ' -f1)
  if [ "$expected" != "$actual" ]; then
    echo "Checksum mismatch: the download is corrupted. Deleting it. Run the script again."
    rm -f "$deb"; exit 1
  fi
  echo "Checksum OK."
else
  echo "Checksum not found, skipping verification."
fi

# Install
systemctl --user stop docker-desktop 2>/dev/null || true

if sudo apt-get install -y "$deb"; then
  rm -f "$deb"
  systemctl --user start docker-desktop 2>/dev/null || true
  echo
  echo "Done. Docker Desktop is now $latest. Installer file deleted."
else
  echo
  echo "=============================================="
  echo " INSTALL FAILED. The file was NOT deleted."
  echo " File: $deb"
  echo "=============================================="
  echo "Install it manually with these steps:"
  echo
  echo "  1. cd \"$DL_DIR\""
  echo "  2. sudo apt-get update"
  echo "  3. sudo apt install ./docker-desktop-$latest-amd64.deb"
  echo "  4. systemctl --user start docker-desktop"
  echo
  echo "If step 3 shows dependency errors, run: sudo apt --fix-broken install"
  echo "and then repeat step 3."
  exit 1
fi
