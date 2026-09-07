#!/usr/bin/env bash
# Build the pinned libghostty embeddable library for AgentTerminal.
#
# Reads Vendor/Ghostty/commit.txt, checks out that commit in a cached
# upstream clone (outside this repo), bootstraps the exact zig version
# required by that commit's build.zig.zon, and produces:
#
#   Vendor/Ghostty/build/GhosttyKit.xcframework   (macos-arm64 slice)
#   Vendor/Ghostty/build/lib/libghostty-internal.a
#   Vendor/Ghostty/build/include/ghostty.h
#
# Apple Silicon (aarch64) macOS only, per the AgentTerminal architecture.
# Idempotent: safe to re-run; artifacts are rebuilt from the pin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/Vendor/Ghostty"
PIN_FILE="$VENDOR_DIR/commit.txt"
OUT_DIR="$VENDOR_DIR/build"

UPSTREAM_URL="${GHOSTTY_UPSTREAM_URL:-https://github.com/ghostty-org/ghostty.git}"
SRC_DIR="${GHOSTTY_SRC_DIR:-$HOME/Library/Caches/agentterminal/ghostty}"
TOOLS_DIR="${GHOSTTY_TOOLS_DIR:-$HOME/.local/share/agentterminal-tools}"
OPTIMIZE="${GHOSTTY_OPTIMIZE:-ReleaseFast}"

log() { printf '[build-ghostty] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Resolve pin
[[ -f "$PIN_FILE" ]] || { echo "error: missing $PIN_FILE" >&2; exit 1; }
PIN="$(awk '{print $1}' "$PIN_FILE" | head -n1)"
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || { echo "error: commit.txt does not contain a full 40-hex SHA: '$PIN'" >&2; exit 1; }
log "pinned upstream commit: $PIN"

# ---------------------------------------------------------------------------
# 2. Ensure upstream clone (cached outside the repo; never committed here)
if [[ ! -d "$SRC_DIR/.git" ]]; then
  log "cloning upstream into $SRC_DIR"
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone "$UPSTREAM_URL" "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch --quiet origin main
git -C "$SRC_DIR" checkout --quiet --detach "$PIN"
log "checked out $(git -C "$SRC_DIR" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# 3. Bootstrap exact zig version required by this commit
ZIG_MIN="$(sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' "$SRC_DIR/build.zig.zon" | head -n1)"
[[ -n "$ZIG_MIN" ]] || { echo "error: could not parse minimum_zig_version from build.zig.zon" >&2; exit 1; }
log "upstream requires zig $ZIG_MIN"

ZIG_BIN="$TOOLS_DIR/zig-$ZIG_MIN/zig"
if [[ ! -x "$ZIG_BIN" ]]; then
  log "installing zig $ZIG_MIN into $TOOLS_DIR (official ziglang.org tarball, not brew)"
  case "$(uname -m)" in
    arm64) ZIG_ARCH="aarch64" ;;
    x86_64) ZIG_ARCH="x86_64" ;;
    *) echo "error: unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac
  TARBALL="zig-${ZIG_ARCH}-macos-${ZIG_MIN}.tar.xz"
  URL="https://ziglang.org/download/${ZIG_MIN}/${TARBALL}"
  mkdir -p "$TOOLS_DIR"
  TMP="$(mktemp -d)"
  curl -fsSL "$URL" -o "$TMP/$TARBALL"
  tar -xJf "$TMP/$TARBALL" -C "$TMP"
  rm -rf "$TOOLS_DIR/zig-$ZIG_MIN"
  mv "$TMP/zig-${ZIG_ARCH}-macos-${ZIG_MIN}" "$TOOLS_DIR/zig-$ZIG_MIN"
  rm -rf "$TMP"
fi
ZIG_VERSION="$("$ZIG_BIN" version)"
[[ "$ZIG_VERSION" == "$ZIG_MIN" ]] || { echo "error: zig $ZIG_VERSION found, upstream requires $ZIG_MIN" >&2; exit 1; }
log "using zig $ZIG_VERSION at $ZIG_BIN"

# ---------------------------------------------------------------------------
# 4. Build (arm64 macOS, embedder library + xcframework)
# Full Xcode is required for xcodebuild -create-xcframework.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
log "building (optimize=$OPTIMIZE, target=macos arm64)…"
(cd "$SRC_DIR" && "$ZIG_BIN" build \
  -Doptimize="$OPTIMIZE" \
  -Dapp-runtime=none \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false)

XCF="$SRC_DIR/macos/GhosttyKit.xcframework"
[[ -d "$XCF" ]] || { echo "error: expected $XCF after build" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. Stage artifacts under Vendor/Ghostty/build
log "staging artifacts into $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/lib" "$OUT_DIR/include"
cp -R "$XCF" "$OUT_DIR/GhosttyKit.xcframework"
SLICE="$OUT_DIR/GhosttyKit.xcframework/macos-arm64"
cp "$SLICE"/Headers/ghostty.h "$OUT_DIR/include/ghostty.h"
[[ -f "$SLICE/Headers/module.modulemap" ]] && cp "$SLICE/Headers/module.modulemap" "$OUT_DIR/include/"
find "$SLICE" -name 'libghostty*.a' -exec cp {} "$OUT_DIR/lib/" \;

log "done:"
find "$OUT_DIR" -maxdepth 2 \( -name '*.a' -o -name '*.h' -o -name '*.xcframework' \) -exec ls -ld {} \;
