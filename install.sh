#!/bin/sh
set -eu

REPO="${SCOOT_INSTALL_REPO:-jamiesun/scoot}"
VERSION="${SCOOT_INSTALL_VERSION:-latest}"
INSTALL_DIR="${SCOOT_INSTALL_DIR:-/usr/local/bin}"
BINARY_NAME="${SCOOT_INSTALL_BINARY:-scoot}"
# Opt-in only: the optional scoot-edge fleet companion is never installed
# unless explicitly requested. Set to any non-empty value to also install it
# alongside core scoot (mirrors the Homebrew `scoot-edge` formula, which
# likewise never installs automatically with `scoot`).
INSTALL_EDGE="${SCOOT_INSTALL_EDGE:-}"

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
  dst_name="$3"
  dst="$dst_dir/$dst_name"

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
  curl -fsSL "$base_url/$artifact" -o "$tmp/$artifact" ||
    die "failed to download $artifact; pin a release that publishes this target"
  curl -fsSL "$base_url/$artifact.sha256" -o "$tmp/$artifact.sha256" ||
    die "failed to download $artifact.sha256"

  log "Verifying checksum"
  verify_checksum "$tmp/$artifact" "$tmp/$artifact.sha256"

  tar -xzf "$tmp/$artifact" -C "$tmp"
  bin="$tmp/scoot/scoot"
  [ -f "$bin" ] || die "archive did not contain expected binary path: scoot/scoot"

  log "Installing to $INSTALL_DIR/$BINARY_NAME"
  install_binary "$bin" "$INSTALL_DIR" "$BINARY_NAME"

  if command -v "$INSTALL_DIR/$BINARY_NAME" >/dev/null 2>&1; then
    "$INSTALL_DIR/$BINARY_NAME" --version
  else
    log "Installed. Add $INSTALL_DIR to PATH if needed."
  fi

  if [ -n "$INSTALL_EDGE" ]; then
    edge_artifact="scoot-edge-$VERSION-$target.tar.gz"

    log "Downloading $edge_artifact (SCOOT_INSTALL_EDGE opt-in)"
    curl -fsSL "$base_url/$edge_artifact" -o "$tmp/$edge_artifact" ||
      die "failed to download $edge_artifact; pin a release that publishes this target"
    curl -fsSL "$base_url/$edge_artifact.sha256" -o "$tmp/$edge_artifact.sha256" ||
      die "failed to download $edge_artifact.sha256"

    log "Verifying checksum"
    verify_checksum "$tmp/$edge_artifact" "$tmp/$edge_artifact.sha256"

    tar -xzf "$tmp/$edge_artifact" -C "$tmp"
    edge_bin="$tmp/scoot-edge/scoot-edge"
    [ -f "$edge_bin" ] || die "archive did not contain expected binary path: scoot-edge/scoot-edge"

    log "Installing to $INSTALL_DIR/scoot-edge"
    install_binary "$edge_bin" "$INSTALL_DIR" "scoot-edge"

    if command -v "$INSTALL_DIR/scoot-edge" >/dev/null 2>&1; then
      "$INSTALL_DIR/scoot-edge" --version
    else
      log "Installed scoot-edge. Add $INSTALL_DIR to PATH if needed."
    fi
  fi
}

main "$@"
