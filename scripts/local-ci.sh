#!/usr/bin/env bash
#
# Local CI mirror of the `zig` job in .github/workflows/ci.yml.
#
# Run it before opening a pull request to catch what GitHub Actions would catch,
# without waiting on remote runners. The git pre-push hook (.githooks/pre-push)
# invokes this automatically; you can also run it by hand or via `make ci`.
#
# Environment toggles:
#   ZIG=...                 Override the zig binary (default: zig).
#   LOCAL_CI_CROSS=1        Also cross-compile the release targets (slower).
#   LOCAL_CI_DOCS=1         Also build the mdBook docs (needs mdbook installed).
#   SKIP_LOCAL_CI=1         Skip everything (handled by the hook, not here).
#
# Exits non-zero on the first failing step so problems surface immediately.

set -euo pipefail

ZIG="${ZIG:-zig}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mlocal-ci: %s\033[0m\n' "$*" >&2; exit 1; }

if ! command -v "$ZIG" >/dev/null 2>&1; then
  fail "zig not found (set ZIG=/path/to/zig or install Zig 0.16.0)"
fi

bold "local CI — mirroring the GitHub Actions zig job"
"$ZIG" version

# 1. Format check — matches CI `zig fmt --check build.zig src examples`.
step "zig fmt --check"
if ! "$ZIG" fmt --check build.zig src examples; then
  fail "formatting issues above — run 'make fmt' (or 'zig fmt build.zig src examples') to fix"
fi

# 2. Debug build.
step "zig build (Debug)"
"$ZIG" build

# 3. Tests.
step "zig build test"
"$ZIG" build test

# 4. ReleaseSafe build.
step "zig build -Doptimize=ReleaseSafe"
"$ZIG" build -Doptimize=ReleaseSafe

# 5. CLI smoke — matches CI `zig build run -- --version`.
step "CLI smoke (--version)"
"$ZIG" build run -- --version

# Optional: cross-compile the release targets (CI release-smoke job).
if [ "${LOCAL_CI_CROSS:-0}" = "1" ]; then
  for target in x86_64-linux-musl aarch64-linux-musl aarch64-macos; do
    step "cross-compile ReleaseSafe ($target)"
    "$ZIG" build -Doptimize=ReleaseSafe -Dtarget="$target"
  done
fi

# Optional: build the docs (CI docs job).
if [ "${LOCAL_CI_DOCS:-0}" = "1" ]; then
  if command -v mdbook >/dev/null 2>&1; then
    step "mdbook build book/en"
    mdbook build book/en
    step "mdbook build book/zh"
    mdbook build book/zh
  else
    fail "LOCAL_CI_DOCS=1 but mdbook is not installed"
  fi
fi

printf '\n\033[1;32mlocal CI passed\033[0m\n'
