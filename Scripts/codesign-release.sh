#!/bin/bash
# Stage-16 release engineering (§6.16 gate 7): ad-hoc / identity signing
# verification skeleton for AgentTerminal.app.
#
# Usage:
#   CERT="Developer ID Application: ACME" Scripts/codesign-release.sh <path-to-app>
#   Scripts/codesign-release.sh <path-to-app>          # ad-hoc verification only
#
# Sparkle/notarization are OUT OF SCOPE for the MVP (see
# docs/Architecture/deviations.md). This script documents and verifies the
# signing procedure so a notarization step can be appended later:
#   1. sign embedded helpers FIRST (inside-out ordering),
#   2. sign the app bundle,
#   3. `codesign --verify --deep --strict` must pass,
#   4. (future) `xcrun notarytool submit` + staple.
set -euo pipefail

APP="${1:?usage: codesign-release.sh <path-to-app>}"
CERT="${CERT:-}"

shopt -s nullglob
HELPERS=("$APP"/Contents/Helpers/*)

if [[ -n "$CERT" ]]; then
    echo "== Signing with identity: $CERT"
    for helper in "${HELPERS[@]}"; do
        codesign --force --options runtime --timestamp --sign "$CERT" "$helper"
    done
    codesign --force --options runtime --timestamp \
        --entitlements "$(dirname "$0")/../App/AgentTerminal.entitlements" \
        --sign "$CERT" "$APP"
else
    echo "== Ad-hoc signing (no \$CERT set)"
    for helper in "${HELPERS[@]}"; do
        codesign --force --sign - "$helper"
    done
    codesign --force --sign - "$APP"
fi

echo "== Strict deep verification"
codesign --verify --deep --strict "$APP"
echo "== Gate info"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature" || true
echo "OK: $APP verified"
