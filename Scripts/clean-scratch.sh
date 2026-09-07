#!/bin/bash
# Purges stale SwiftPM scratch build roots that isolated test/agent sessions
# leave behind (each one costs ~0.5-1 GB). See AGENTS.md "SwiftPM scratch dirs".
#
# Removed when older than CLEAN_SCRATCH_AGE_MINUTES (default 360 = 6 h):
#   Packages/.build-*   (isolated --scratch-path roots)
#   .build-*            (repo-root scratch roots, e.g. .build-integr)
#   Spike/.build*
# Canonical cache Packages/.build is kept unless --all is passed.
#
# Usage: Scripts/clean-scratch.sh [--all]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
AGE_MIN="${CLEAN_SCRATCH_AGE_MINUTES:-360}"
ALL=0
[[ "${1:-}" == "--all" ]] && ALL=1

cutoff=$(( $(date +%s) - AGE_MIN * 60 ))
before_kb=$(df -k "$REPO" | awk 'NR==2{print $4}')

shopt -s nullglob
for path in "$REPO"/Packages/.build* "$REPO"/.build* "$REPO"/Spike/.build*; do
    # Canonical package-local cache: keep warm, it is the default scratch path.
    if (( ! ALL )) && [[ "$path" == "$REPO/Packages/.build" ]]; then
        continue
    fi
    if (( ALL )) || [[ $(stat -f %m "$path") -lt $cutoff ]]; then
        rm -rf "$path"
        printf 'removed %s\n' "${path#"$REPO"/}"
    fi
done

after_kb=$(df -k "$REPO" | awk 'NR==2{print $4}')
printf 'clean-scratch: freed %d MB\n' $(( (after_kb < before_kb ? before_kb - after_kb : 0) / 1024 ))
