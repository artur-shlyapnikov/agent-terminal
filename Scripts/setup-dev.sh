#!/usr/bin/env bash
# AgentTerminal development environment bootstrap.
# Idempotent; safe to re-run.
set -euo pipefail

# Prefer an explicit toolchain selected by the caller. The fallback works on
# machines whose active xcode-select path points at the Command Line Tools.
DEVELOPER_DIR_EXPECTED="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

say() { printf '\n==> %s\n' "$1"; }

# 1. Full Xcode presence (the global xcode-select may point at CLT only).
if [ ! -x "$DEVELOPER_DIR_EXPECTED/usr/bin/xcodebuild" ]; then
  echo "error: Full Xcode not found at $DEVELOPER_DIR_EXPECTED" >&2
  echo "Install Xcode 16.4+ (CI pins Xcode 16.4 on macos-15 runners)." >&2
  exit 1
fi
export DEVELOPER_DIR="$DEVELOPER_DIR_EXPECTED"
say "Xcode found: $(xcodebuild -version | head -n1)"

# 2. xcodegen (App/AgentTerminal.xcodeproj generator). Not preinstalled.
if ! command -v xcodegen >/dev/null 2>&1; then
  say "Installing xcodegen via Homebrew"
  brew install xcodegen
else
  say "xcodegen already installed: $(xcodegen --version)"
fi

# 3. Resolve SwiftPM dependencies so the first offline build works.
say "Resolving SwiftPM dependencies"
(cd Packages && swift package resolve)

# 3b. Vendored libghostty (gitignored build products; same provisioning the
# CI workflow performs, cache-miss path). Required to link GhosttyBridge.
if [ ! -f "Vendor/Ghostty/build/lib/libghostty-internal.a" ]; then
  say "Vendored libghostty missing; building from pinned commit (bootstraps zig)"
  ./Scripts/build-ghostty-xcframework.sh
else
  say "Vendored libghostty already present at Vendor/Ghostty/build"
fi

say "Setup complete. Next steps:"
cat <<'EOF'
  ./Scripts/verify-third-party-licenses.sh    # license audit gate
  (cd App && xcodegen generate)               # regenerate AgentTerminal.xcodeproj
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -workspace AgentTerminal.xcworkspace -scheme AgentTerminal \
    -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
EOF
