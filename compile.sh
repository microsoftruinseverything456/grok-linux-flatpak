#!/usr/bin/env bash
set -euo pipefail

# compile-flatpak.sh
# - Installs npm deps
# - Ensures Electron exists
# - Fixes Electron's chrome-sandbox SUID helper (for running un-snap/un-flatpak builds)
# - Builds Flatpak
# - For Flatpak: installs flatpak-builder if missing, ensures flathub remote, and pins runtimeVersion to baseVersion

# ---------- helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

need_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    sudo -v
  fi
}

die() { echo "Error: $*" >&2; exit 1; }

# Install apt packages only if missing.
# Runs apt-get update only if at least one package is missing.
apt_install_if_missing() {
  local pkgs=("$@")
  local missing=()

  for p in "${pkgs[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      missing+=("$p")
    fi
  done

  if ((${#missing[@]} == 0)); then
    return 0
  fi

  need_sudo
  sudo apt-get update -y
  sudo apt-get install -y "${missing[@]}"
}

require_project_root() {
  [[ -f package.json ]] || die "package.json not found. Run this from the project root."
}

# Only ensure npm exists (no node check). If missing, install via apt.
ensure_npm() {
  echo "[0/6] Checking for npm…"
  if have npm; then
    return 0
  fi

  echo "  npm not found; installing via apt…"
  apt_install_if_missing npm
}

install_deps() {
  echo "[1/6] Installing dependencies…"
  if [[ -f package-lock.json ]]; then
    npm ci
  else
    npm install
  fi
}

ensure_electron_installed() {
  echo "[2/6] Ensuring Electron is installed (dev dependency)…"
  if [[ -x node_modules/.bin/electron ]]; then
    return 0
  fi

  local ELECTRON_VER=""
  ELECTRON_VER="$(node -p "(() => {
    const p=require('./package.json');
    return (p.devDependencies && p.devDependencies.electron) ||
           (p.dependencies && p.dependencies.electron) || '';
  })()" 2>/dev/null || true)"

  if [[ -n "${ELECTRON_VER}" ]]; then
    echo "  electron not found; installing electron@${ELECTRON_VER}…"
    npm install --save-dev "electron@${ELECTRON_VER}"
  else
    echo "  electron not found; installing latest electron…"
    npm install --save-dev electron
  fi
}

find_chrome_sandbox() {
  find node_modules -type f -path '*/electron/dist/chrome-sandbox' -print -quit 2>/dev/null || true
}

fix_chrome_sandbox() {
  echo "[3/6] Fixing Electron chrome-sandbox (SUID helper)…"
  local SANDBOX_PATH=""
  SANDBOX_PATH="$(find_chrome_sandbox)"

  if [[ -z "${SANDBOX_PATH}" ]]; then
    die "chrome-sandbox not found under node_modules/. (Electron may not have installed correctly)"
  fi

  echo "  Found: ${SANDBOX_PATH}"
  need_sudo
  sudo chown root:root "${SANDBOX_PATH}"
  sudo chmod 4755 "${SANDBOX_PATH}"
}

ensure_flatpak_tools() {
  echo "[4/6] Checking for flatpak + flatpak-builder…"
  if have flatpak && have flatpak-builder; then
    echo "  flatpak + flatpak-builder found."
    return 0
  fi
  echo "  Installing flatpak + flatpak-builder (apt)…"
  apt_install_if_missing flatpak flatpak-builder
}

ensure_flathub_remote_user() {
  # bundler usually installs refs into --user, so ensure flathub exists there
  if flatpak remotes --user 2>/dev/null | awk '{print $1}' | grep -qx "flathub"; then
    return 0
  fi
  echo "  Adding Flathub remote for current user…"
  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
}

ensure_electron_builder() {
  echo "[5/6] Ensuring electron-builder exists…"
  if [[ -x node_modules/.bin/electron-builder ]]; then
    return 0
  fi
  echo "  Installing electron-builder (devDependency)…"
  npm install --save-dev electron-builder
}

# Ensure build.flatpak exists and IMPORTANTLY: runtimeVersion matches baseVersion (prevents 20.08 nonsense)
ensure_packagejson_flatpak_config() {
  echo "  Ensuring package.json has build.flatpak and pinned runtimeVersion…"
  node -e "
const fs=require('fs');
const p=JSON.parse(fs.readFileSync('package.json','utf8'));
p.build=p.build||{};
p.build.flatpak=p.build.flatpak||{};
const fp=p.build.flatpak;

fp.base = fp.base || 'org.electronjs.Electron2.BaseApp';
fp.baseVersion = fp.baseVersion || '25.08';

fp.runtime = fp.runtime || 'org.freedesktop.Platform';
fp.sdk = fp.sdk || 'org.freedesktop.Sdk';

fp.runtimeVersion = fp.runtimeVersion || fp.baseVersion; // critical fix

p.build.flatpak = fp;
fs.writeFileSync('package.json', JSON.stringify(p,null,2)+'\n');
"
}

get_flatpak_ver() {
  node -p "(() => {
    const p=require('./package.json');
    const fp=(p.build && p.build.flatpak) ? p.build.flatpak : {};
    return fp.runtimeVersion || fp.baseVersion || '25.08';
  })()"
}

preinstall_flatpak_refs_user() {
  local ver="$1"
  echo "  Pre-installing Flatpak refs for ${ver} (user)…"
  ensure_flathub_remote_user

  # Idempotent installs; ignore failures if already present.
  flatpak install --user -y flathub "org.freedesktop.Platform//${ver}" >/dev/null 2>&1 || true
  flatpak install --user -y flathub "org.freedesktop.Sdk//${ver}" >/dev/null 2>&1 || true
  flatpak install --user -y flathub "org.electronjs.Electron2.BaseApp//${ver}" >/dev/null 2>&1 || true
}

build_flatpak() {
  echo "[6/6] Building Flatpak…"

  ensure_flatpak_tools
  ensure_electron_builder
  ensure_packagejson_flatpak_config

  local ver=""
  ver="$(get_flatpak_ver)"
  preinstall_flatpak_refs_user "${ver}"

  rm -rf dist

  mkdir -p "$HOME/tmp"
  env TMPDIR="$HOME/tmp" DEBUG="@malept/flatpak-bundler" \
    npx electron-builder --linux flatpak

  local FP_PATH=""
  FP_PATH="$(ls -1t dist/*.flatpak 2>/dev/null | head -n 1 || true)"
  [[ -n "${FP_PATH}" ]] || die "No .flatpak found in dist/ after build."

  local APP_ID=""
  APP_ID="$(node -p "require('./package.json').build.appId")"

  echo
  echo "Built flatpak: ${FP_PATH}"
  echo "Install with:"
  echo "  flatpak install --user -y \"${FP_PATH}\""
  echo
  echo "Run with:"
  echo "  flatpak run ${APP_ID}"
  echo

  read -r -p "Install flatpak now (user)? [y/N] " yn
  case "${yn:-N}" in
    y|Y|yes|YES) flatpak install --user -y "${FP_PATH}" ;;
    *) echo "OK — not installing flatpak." ;;
  esac
}

cleanup_prompt() {
  echo
  read -r -p "Remove build artifacts to save space (node_modules, dist/linux-unpacked, caches)? [y/N] " cn
  case "${cn:-N}" in
    y|Y|yes|YES)
      echo "Cleaning up…"
      rm -rf dist/linux-unpacked 2>/dev/null || true
      rm -rf node_modules 2>/dev/null || true
      rm -rf ~/.cache/electron ~/.cache/electron-builder 2>/dev/null || true
      echo "Done."
      ;;
    *)
      echo "OK — keeping files."
      ;;
  esac
}

# ---------- main ----------
require_project_root
ensure_npm
install_deps
ensure_electron_installed
fix_chrome_sandbox
build_flatpak
cleanup_prompt
