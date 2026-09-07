# AgentTerminal task runner. Mirrors README "Development" + .github/workflows/ci.yml.
# macOS / Apple Silicon only. Start with `just setup`.
#
# Toolchain: full Xcode 16.4+ selected via xcode-select (setup-dev.sh validates).
# Override per-invocation with e.g. DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer just app.

ws := "AgentTerminal.xcworkspace"
scheme := "AgentTerminal"
scheme_acc := "AgentTerminalAcceptance"
dest := "platform=macOS,arch=arm64"
xcb := "xcodebuild -workspace " + ws + " -scheme " + scheme + " -destination '" + dest + "'"
xcb_acc := "xcodebuild -workspace " + ws + " -scheme " + scheme_acc + " -destination '" + dest + "'"

smoke_dd := "/tmp/aterm-smoke-dd"
smoke_app := smoke_dd + "/Build/Products/Debug/AgentTerminalAcceptance.app/Contents/MacOS/AgentTerminalAcceptance"

# Show available recipes.
default:
    @just --list

# Idempotent bootstrap: xcodegen, SwiftPM resolve, pinned libghostty.
setup:
    ./Scripts/setup-dev.sh

# Regenerate App/AgentTerminal.xcodeproj from App/project.yml (source of truth).
gen:
    (cd App && xcodegen generate)

# SwiftPM package build (canonical build root Packages/.build per AGENTS.md).
build:
    (cd Packages && swift build)

# Fast local gate: package build plus the repository's structural/license checks.
check: law licenses build

# Package test suite. Filter: just test PromptWatchdog
test filter="":
    (cd Packages && swift test --parallel {{ if filter == "" { "" } else { "--filter " + filter } }})

# Warnings-as-errors gate (CI packages job).
strict:
    (cd Packages && swift build --build-tests -Xswiftc -warnings-as-errors)

# Nightly TSan suite (serial by design; 5-15x slower, not part of PR CI).
tsan:
    (cd Packages && swift test --sanitize=thread)

# Full app build.
app: gen
    {{ xcb }} build CODE_SIGNING_ALLOWED=NO

# App-hosted unit tests (App/Tests, TEST_HOST = app bundle).
app-test: gen
    {{ xcb }} test CODE_SIGNING_ALLOWED=NO

# Stage-16 scenario smoke subset (fast; full 30-min soak stays manual: just soak).
smoke: _build-smoke-app
    #!/usr/bin/env bash
    set -euo pipefail
    smoke_data=$(mktemp -d "${TMPDIR:-/tmp}/agent-terminal-smoke.XXXXXX")
    trap 'rm -rf "$smoke_data"' EXIT
    printf 'not a database' > "$smoke_data/corrupt.sqlite3"
    ATERM_SCENARIO=corrupt-db ATERM_DB_PATH="$smoke_data/corrupt.sqlite3" {{ smoke_app }}
    ATERM_SCENARIO=capacity16 ATERM_DB_PATH="$smoke_data/capacity.sqlite3" {{ smoke_app }}
    ATERM_SCENARIO=teardown100 ATERM_DB_PATH="$smoke_data/teardown.sqlite3" {{ smoke_app }}

# Full soak (default 1800s). Quick check: just soak 60
soak secs="1800" db="/tmp/aterm-soak.sqlite3": _build-smoke-app
    ATERM_SCENARIO=soak ATERM_SOAK_SECONDS={{ secs }} ATERM_DB_PATH={{ db }} {{ smoke_app }}

# CI lint job: format check + SwiftLint + dependency law + license audit.
lint:
    swiftformat Packages App Tests --lint
    swiftlint lint
    python3 Scripts/check-dependency-law.py
    ./Scripts/verify-third-party-licenses.sh

# In-place canonical formatting (CI enforces via `just lint`).
format:
    swiftformat Packages App Tests

# Import-graph gate (architecture notes §3.2).
law:
    python3 Scripts/check-dependency-law.py

# Third-party license audit gate.
licenses:
    ./Scripts/verify-third-party-licenses.sh

# Regen App/Sources/Localizable.xcstrings from NSLocalizedString literals.
strings:
    python3 Scripts/generate-localizable-catalog.py

# Ad-hoc verify: just sign /tmp/.../AgentTerminal.app (CERT="Developer ID ..." in env to sign).
sign app:
    ./Scripts/codesign-release.sh {{ app }}

# Provision vendored libghostty (bootstraps zig itself; cached per pin in CI).
ghostty:
    ./Scripts/build-ghostty-xcframework.sh

# Purge stale SwiftPM scratch roots (>6h).
clean:
    ./Scripts/clean-scratch.sh

# Purge scratch roots AND the canonical Packages/.build cache.
clean-all:
    ./Scripts/clean-scratch.sh --all

# Local PR gate: lint + package and app suites + strict + app + acceptance builds.
ci: lint test strict app app-test acceptance

# Acceptance harness build (scenario gates; NOT shipped).
acceptance: gen
    {{ xcb_acc }} build CODE_SIGNING_ALLOWED=NO

[private]
_build-smoke-app: gen
    {{ xcb_acc }} -derivedDataPath {{ smoke_dd }} build CODE_SIGNING_ALLOWED=NO
