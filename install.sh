#!/bin/sh
set -eu

REPO="${SCOOT_INSTALL_REPO:-jamiesun/scoot}"
VERSION="${SCOOT_INSTALL_VERSION:-latest}"
INSTALL_DIR="${SCOOT_INSTALL_DIR:-/usr/local/bin}"
BINARY_NAME="${SCOOT_INSTALL_BINARY:-scoot}"

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

detect_target() {
  os="$(uname -s 2>/dev/null || true)"
  arch="$(uname -m 2>/dev/null || true)"

  case "$os" in
    Linux) os_part="linux" ;;
    Darwin) os_part="macos" ;;
    *) die "unsupported OS: ${os:-unknown}" ;;
  esac

  case "$arch" in
    x86_64|amd64) arch_part="amd64" ;;
    arm64|aarch64) arch_part="arm64" ;;
    armv7l|armv7*|armhf)
      [ "$os_part" = "linux" ] || die "armv7 release artifacts are only published for Linux"
      arch_part="armv7"
      ;;
    *) die "unsupported architecture: ${arch:-unknown}" ;;
  esac

  printf '%s-%s\n' "$os_part" "$arch_part"
}

latest_version() {
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" ||
    die "failed to resolve latest release for $REPO"
  tag="${url##*/}"
  case "$tag" in
    v*) printf '%s\n' "$tag" ;;
    *) die "could not parse latest release tag from: $url" ;;
  esac
}

sha256_file() {
  file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    die "required command not found: sha256sum or shasum"
  fi
}

verify_checksum() {
  archive="$1"
  checksum_file="$2"
  expected="$(sed -n 's/^\([0-9a-fA-F][0-9a-fA-F]*\)[[:space:]].*/\1/p' "$checksum_file" | head -n 1 | tr 'A-F' 'a-f')"
  [ "${#expected}" -eq 64 ] || die "invalid checksum file: $checksum_file"
  actual="$(sha256_file "$archive" | tr 'A-F' 'a-f')"
  [ "$actual" = "$expected" ] || die "checksum mismatch for $archive"
}

install_binary() {
  src="$1"
  dst_dir="$2"
  dst="$dst_dir/$BINARY_NAME"

  if mkdir -p "$dst_dir" 2>/dev/null && [ -w "$dst_dir" ]; then
    install -m 0755 "$src" "$dst"
  else
    if [ "$(id -u)" = "0" ]; then
      install -d "$dst_dir"
      install -m 0755 "$src" "$dst"
    elif command -v sudo >/dev/null 2>&1; then
      sudo install -d "$dst_dir"
      sudo install -m 0755 "$src" "$dst"
    else
      die "cannot write to $dst_dir and sudo is not available; set SCOOT_INSTALL_DIR to a writable directory"
    fi
  fi
}

main() {
  need curl
  need tar
  need awk
  need head
  need id
  need sed
  need tr
  need uname
  need install
  need mktemp

  target="$(detect_target)"
  if [ "$VERSION" = "latest" ]; then
    VERSION="$(latest_version)"
  fi
  case "$VERSION" in
    v*) ;;
    *) VERSION="v$VERSION" ;;
  esac

  artifact="scoot-$VERSION-$target.tar.gz"
  base_url="https://github.com/$REPO/releases/download/$VERSION"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp" >/dev/null 2>&1 || true' EXIT INT TERM

  log "Installing Scoot $VERSION for $target"
  log "Downloading $artifact"
  curl -fsSL "$base_url/$artifact" -o "$tmp/$artifact"
  curl -fsSL "$base_url/$artifact.sha256" -o "$tmp/$artifact.sha256"

  log "Verifying checksum"
  verify_checksum "$tmp/$artifact" "$tmp/$artifact.sha256"

  tar -xzf "$tmp/$artifact" -C "$tmp"
  bin="$tmp/scoot/scoot"
  [ -f "$bin" ] || die "archive did not contain expected binary path: scoot/scoot"

  log "Installing to $INSTALL_DIR/$BINARY_NAME"
  install_binary "$bin" "$INSTALL_DIR"

  if command -v "$INSTALL_DIR/$BINARY_NAME" >/dev/null 2>&1; then
    "$INSTALL_DIR/$BINARY_NAME" --version
  else
    log "Installed. Add $INSTALL_DIR to PATH if needed."
  fi
}

main "$@"
