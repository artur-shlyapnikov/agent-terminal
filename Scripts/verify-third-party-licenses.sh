#!/usr/bin/env bash
# License audit gate for AgentTerminal (cmux project rule).
#
# Enforces the promises made in THIRD_PARTY_NOTICES.md and
# architecture notes §4.1:
#   1. No GPL notice text or GPL/AGPL/LGPL SPDX identifiers in any tracked
#      file. Bare "GPL-x.y" version tags (typical of copied license headers)
#      are allowed only in the cmux EXCLUDED section of THIRD_PARTY_NOTICES.md;
#      SPDX expression forms ("GPL-3.0-or-later") used in exclusion-policy
#      prose are sanctioned mentions.
#   2. No cmux-derived code: the token "cmux" must never appear in any
#     tracked source file (.swift/.c/.h/.m/.mm) — cmux is GPL-3.0-or-later
#     and is used strictly as an architecture reference.
#   3. The GRDB.swift pin in Packages/Package.resolved is 7.x.
#   4. A Ghostty MIT notice is present for the pinned upstream commit
#     (Vendor/Ghostty/commit.txt carries a full 40-hex SHA).
#   5. The cmux exclusion statement is present in THIRD_PARTY_NOTICES.md.
#
# Exits non-zero on any violation. Idempotent; no network access needed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NOTICES="THIRD_PARTY_NOTICES.md"
RESOLVED="Packages/Package.resolved"
PIN_FILE="Vendor/Ghostty/commit.txt"

errors=0
fail() { printf 'FAIL: %s\n' "$*" >&2; errors=$((errors + 1)); }
pass() { printf 'ok:   %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. GPL notice text / identifiers / version tags in tracked files.
HARD_PATTERN='This program is free software|GNU GENERAL PUBLIC LICENSE|General Public License as published by|SPDX-License-Identifier:[[:space:]]*(AGPL|GPL|LGPL)'
SOFT_PATTERN='\b(GPL-[23]\.0|LGPL-[23]\.[01]|AGPL-3\.0)([^-a-zA-Z0-9]|$)'

# Sanctioned zone: everything from the "## cmux" heading to EOF of NOTICES.
CMUX_HEAD="$(mktemp)"
trap 'rm -f "$CMUX_HEAD"' EXIT
sed '/^## cmux/,$d' "$NOTICES" > "$CMUX_HEAD"

while IFS= read -r f; do
  [ -f "$f" ] || continue
  [ "$f" = "Scripts/verify-third-party-licenses.sh" ] && continue
  hits="$(grep -inE "$HARD_PATTERN" "$f" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    fail "GPL notice text/identifier in $f:"
    printf '%s\n' "$hits" >&2
  fi
done < <(git ls-files)

while IFS= read -r f; do
  [ -f "$f" ] || continue
  [ "$f" = "Scripts/verify-third-party-licenses.sh" ] && continue
  orig="$f"
  [ "$f" = "$NOTICES" ] && f="$CMUX_HEAD"   # scan notices minus cmux section
  hits="$(grep -inE "$SOFT_PATTERN" "$f" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    fail "bare GPL version tag outside the sanctioned cmux exclusion section in $orig:"
    printf '%s\n' "$hits" >&2
  fi
done < <(git ls-files)
pass "no GPL notice text or identifiers in tracked files"

# ---------------------------------------------------------------------------
# 2. No cmux-derived code in tracked source files.
code_hits="$(git ls-files '*.swift' '*.c' '*.h' '*.m' '*.mm' \
  | xargs grep -in 'cmux' 2>/dev/null || true)"
if [ -n "$code_hits" ]; then
  fail "possible cmux-derived code (GPL-3.0) in tracked sources:"
  printf '%s\n' "$code_hits" >&2
else
  pass "no cmux references in tracked source files"
fi

# ---------------------------------------------------------------------------
# 3. GRDB pin is 7.x.
if [ ! -f "$RESOLVED" ]; then
  fail "missing $RESOLVED"
else
  # Tolerate both key orderings inside the pin object.
  grdb_version="$(tr -d ' \n' < "$RESOLVED" \
    | sed -n 's/.*"identity":"grdb.swift"[^}]*"version":"\([^"]*\)".*/\1/p')"
  [ -n "$grdb_version" ] || grdb_version="$(tr -d ' \n' < "$RESOLVED" \
    | sed -n 's/.*"version":"\([^"]*\)"[^{]*"identity":"grdb.swift".*/\1/p')"
  case "$grdb_version" in
    7.*) pass "GRDB.swift pinned to $grdb_version (7.x)" ;;
    "")  fail "could not find grdb.swift pin in $RESOLVED" ;;
    *)   fail "GRDB.swift pinned to $grdb_version, expected 7.x" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 4. Ghostty MIT notice present for the pinned commit.
pin="$(awk '{print $1}' "$PIN_FILE" 2>/dev/null | head -n1 || true)"
if [[ "$pin" =~ ^[0-9a-f]{40}$ ]]; then
  pass "Ghostty pinned to upstream commit $pin"
else
  fail "$PIN_FILE does not contain a full 40-hex SHA: '$pin'"
fi
for marker in "## Ghostty" "Copyright (c) Mitchell Hashimoto" "Permission is hereby granted"; do
  if grep -qF "$marker" "$NOTICES"; then
    pass "Ghostty notice contains \"$marker\""
  else
    fail "Ghostty MIT notice missing \"$marker\" in $NOTICES"
  fi
done

# ---------------------------------------------------------------------------
# 5. cmux exclusion statement present.
for marker in "EXCLUDED" "No cmux source code"; do
  if grep -qF "$marker" "$NOTICES"; then
    pass "cmux exclusion statement contains \"$marker\""
  else
    fail "cmux exclusion statement missing \"$marker\" in $NOTICES"
  fi
done

# ---------------------------------------------------------------------------
if [ "$errors" -gt 0 ]; then
  printf '\nlicense audit FAILED with %d error(s)\n' "$errors" >&2
  exit 1
fi
printf '\nlicense audit passed\n'
