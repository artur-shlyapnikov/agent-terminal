# AgentTerminal

**A native macOS app for running AI coding agents in real terminals — with a semantic layer on top.**

Claude Code, Codex, OpenCode, or a plain shell each live in their own GPU-rendered
[Ghostty](https://ghostty.org) surface inside a single native window. On top of the bytes,
AgentTerminal maintains something terminal multiplexers never had: a **lifecycle model per agent**
(`working`, `waitingForInput`, `idle`, …), resolved from process observation, screen detection,
and adapter-reported evidence — so you can see *at a glance* which of your eight agents needs
input, which finished, and which died.

> **Status:** Pre-release. The core MVP is implemented and covered by package, app, and
> acceptance tests; expect breaking changes before the first stable release. The current
> release gate is documented in [`docs/release/stage16-gate-report.md`](docs/release/stage16-gate-report.md).

---

## Why

Agents already run fine in a terminal tab. What's missing is everything around them:

- **You can't tell state from a wall of text.** Is the agent waiting on an approval prompt, or
  still grinding? AgentTerminal reads the **live screen** (full scrollback-backed coordinates,
  not whatever you scrolled into view) against versioned screen manifests, cross-checks it with
  process inspection, and resolves conflicts through an explicit authority chain
  (`integration › screen › process`).
- **Prompts are fire-and-forget.** Here, one deferred prompt per agent sits in a validated
  queue, drains only at confirmed idle, and delivery failures surface as events — never silent
  retries, never double-send (idempotency-keyed, replay-cached).
- **Closing things kills work.** Closing the window *parks* the surfaces and keeps every agent
  running; quitting cleanly persists session identity so agents can be resumed later; a crash
  recovers into a consistent state backed by SQLite.
- **Automation has no handle.** A local CLI + Unix-socket API exposes the whole runtime:
  create, prompt, wait (event-driven, never polling), read, focus, interrupt, stop, resume,
  subscribe to events.

Out of scope by design (for now): remote/SSH agents, persistent PTY after full quit, Linux/Windows,
plugin marketplaces, auto-approving permission prompts. The full boundary is §3.1 of the
[architecture notes](docs/Architecture/).

## Features

- **Workspaces** — one project = one workspace; sidebar navigation across all its agents.
- **Real terminals** — [libghostty](Vendor/Ghostty/README.md)-owned PTYs, pinned to an upstream
  commit, isolated behind our own C bridge; up to 4 visible split panes, 16 live terminals,
  plus fully headless background agents.
- **Lifecycle engine** — typed state machine with authority resolution, turn tracking,
  attention states (`inputRequired`, `completionUnread`, `failure`) driving notifications and
  sidebar badges.
- **Safe prompting** — policies per send: `sendNow`, `queueWhenIdle`, `rejectUnlessIdle`;
  watchdog-guarded delivery.
- **Session resume** — adapters mint resume references at exit; restart the conversation, not
  just the process.
- **Local control plane** — NDJSON over a `0600` Unix socket, closed 18-method v1 contract with
  mandatory version field and exactly-once prompt delivery.
- **Hooks & integrations** — per-generation scoped launch tokens; `integration report/release`
  feed external lifecycle evidence into the same authority pipeline.

## Architecture

Single process, five layers, one dependency law:

```text
┌─────────────────────────────────────────────────────────────────┐
│ AgentTerminal.app                                               │
│                                                                 │
│  ┌────────────────────── Native UI ───────────────────────────┐ │
│  │ Sidebar │ Split Canvas │ Inspector │ Prompt Composer       │ │
│  └────────────────────────────┬────────────────────────────────┘ │
│                               │ MainActor                        │
│                     ┌─────────▼──────────┐                       │
│                     │ AppModel           │                       │
│                     │ UI projection only │                       │
│                     └─────────▲──────────┘                       │
│                               │ RuntimeDelta                     │
│  ┌────────────────────────────┴────────────────────────────────┐ │
│  │ AgentRuntime actor                                          │ │
│  │ state machine │ authority │ prompt queue │ turn tracking    │ │
│  └───────┬─────────────────┬───────────────────────┬───────────┘ │
│          ▼                 ▼                       ▼             │
│  TerminalControlling   DetectionEngine        StateStore         │
│          ▼                 ▼                       ▼             │
│  GhosttyEngine         Process/screen        SQLite (GRDB)       │
│          ▼              observations                            │
│  Pinned libghostty → PTYs/processes                             │
│                                                                 │
│  ControlServer actor ← Unix socket → agentctl / hooks           │
└─────────────────────────────────────────────────────────────────┘
```

Modules and the dependency law enforced by
[`Scripts/check-dependency-law.py`](Scripts/check-dependency-law.py):

| Module | Depends on | Role |
|---|---|---|
| `AgentCore` | Foundation only | Domain model, runtime, detection, state machine |
| `AgentStore` | AgentCore + GRDB | Durable metadata, timeline, migrations |
| `AgentControl` | AgentCore | Wire types, socket server/client, hook auth |
| `TerminalKit` | AgentCore + AppKit + GhosttyBridge | Session manager, surfaces, teardown |
| `GhosttyBridge` | C | The only place that imports `ghostty.h` |
| `AgentLauncher`, `agentctl` | AgentControl only, no AppKit | Helper executables shipped in `Contents/Helpers` |
| App target | all modules | Composition root, scenarios |

Forbidden edges are checked in CI: no AppKit/libghostty/GRDB below their layer, no raw
`ghostty_surface_t` above TerminalKit, C callbacks never touch UI or domain state directly.

Design decisions and their reasoning live in the ADRs
([single-process MVP](docs/Architecture/ADR-0001-single-process-mvp.md),
[libghostty boundary](docs/Architecture/ADR-0002-libghostty-boundary.md),
[agent lifecycle](docs/Architecture/ADR-0003-agent-lifecycle.md)) and the
[deviations ledger](docs/Architecture/deviations.md).
The wire contract is specified in [`docs/Protocols/control-v1.md`](docs/Protocols/control-v1.md);
detection manifests in [`docs/Detection/manifests.md`](docs/Detection/manifests.md).

## Getting started

Requirements: macOS 14+ on Apple Silicon, full Xcode 16.4+, and Homebrew. If
`xcode-select -p` points at the Command Line Tools rather than full Xcode,
set `DEVELOPER_DIR` to the selected Xcode bundle before the `xcodebuild`/SwiftLint
invocations below (`setup-dev.sh` also honors this variable).

```sh
brew install just
git clone https://github.com/artur-shlyapnikov/agent-terminal.git
cd agent-terminal
just setup                 # xcodegen, SwiftPM resolve, and pinned libghostty
```

(`just setup` is `./Scripts/setup-dev.sh`. `just --list` shows all recipes;
the `justfile` mirrors the Development section and `.github/workflows/ci.yml`.)

Then either open the workspace:

```sh
just gen                   # regenerate AgentTerminal.xcodeproj from App/project.yml
open AgentTerminal.xcworkspace
# select the AgentTerminal scheme, Cmd-R
```

or build from the terminal:

```sh
just app                   # full app build (CODE_SIGNING_ALLOWED=NO)
```

The first build provisions `Vendor/Ghostty/build/` (gitignored; cached per pin in CI).
Details on the pin policy, zig provenance, and how to bump the commit:
[`Vendor/Ghostty/README.md`](Vendor/Ghostty/README.md).

The repository does not ship prebuilt binaries yet. `just app` creates an
unsigned development build; sign it with a local identity using
`just sign path/to/AgentTerminal.app`, or open the generated project in Xcode.

### Driving agents from the CLI

With the app running, `agentctl` — shipped inside the app bundle at
`Contents/Helpers/agentctl` — talks to the control socket at
`~/Library/Application Support/AgentTerminal/runtime/control.sock`:

```sh
agentctl system ping
agentctl workspace list
agentctl agent create --workspace "$WS" --kind claude-code --dir ~/src/api --name "API migration"
agentctl agent list

# Send a task; retries are safe — commandID replays the cached receipt.
agentctl agent prompt "$AGENT" "Refactor the auth module to async/await" --policy sendNow

# Event-driven wait: blocks on a state transition, never polls.
agentctl agent wait "$AGENT" --lifecycle idle --timeout-ms 300000

agentctl agent read "$AGENT" --source detection   # what the detector sees
agentctl agent focus "$AGENT"                      # bring its surface frontmost
agentctl agent interrupt "$AGENT"                  # SIGINT-equivalent: end the running turn
agentctl events subscribe                          # stream all deltas until Ctrl-C
agentctl agent stop "$AGENT"                       # SIGTERM group → grace → SIGKILL
```

Beyond these: `agent get`, `agent resume`, `agent cancel-queued-prompt`,
`integration report/release`, `launcher`.
Full method reference: [`docs/Protocols/control-v1.md`](docs/Protocols/control-v1.md).

## Development

`just` recipes are the canonical entry points (raw commands underneath still work):

```sh
just check                 # package build + dependency and license gates
just build                 # cd Packages && swift build (canonical root Packages/.build)
just test                  # package suite, parallel; filter: just test PromptWatchdog
just strict                # warnings-as-errors gate (CI packages job)
just app                   # full app build (implies just gen)
just app-test              # app-hosted unit tests (App/Tests, TEST_HOST = app bundle)
just lint                  # swiftformat --lint + swiftlint + dependency law + license audit
just format                # in-place canonical formatting
just law                   # python3 Scripts/check-dependency-law.py (import-graph gate)
just licenses              # ./Scripts/verify-third-party-licenses.sh (license audit gate)
just smoke                 # fast scenario smoke subset (corrupt-db, capacity16, teardown100)
just soak 60               # full soak harness (default 1800 s); CI never runs the full soak
just ci                    # local PR gate: lint + test + strict + app + app-test + acceptance
```

The app also ships hermetic **scenario harnesses** used by CI's smoke stage — they exercise
real product paths headlessly (`App/Acceptance/Stage16GatesScenario.swift`):

```sh
ATERM_SCENARIO=corrupt-db   ATERM_DB_PATH=/tmp/t.sqlite3 AgentTerminalAcceptance.app/Contents/MacOS/AgentTerminalAcceptance
ATERM_SCENARIO=capacity16   ...   # 16 surfaces alive and responsive, clean teardown
ATERM_SCENARIO=teardown100  ...   # 100 create/free cycles, stable footprint
ATERM_SCENARIO=soak         ATERM_SOAK_SECONDS=1800 ...
ATERM_SCENARIO=broken-hooks ...   # broken hook shim → degraded banner, Repair restores, fallback detection
ATERM_SCENARIO=upgrade-sim  ...   # 'newer' helper version marker → launch proceeds, detection marked fallback
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) gates every PR on: SwiftFormat +
SwiftLint (zero warnings), dependency law, license audit, gitleaks history scan, the full SwiftPM
suite with warnings-as-errors, and an XcodeGen + app build with the scenario smoke subset.
A nightly job ([`nightly-tsan.yml`](.github/workflows/nightly-tsan.yml), `just tsan`) runs
Thread Sanitizer (serial by design, 5–15× slower, not part of PR CI).

Engineering conventions: Swift 5.10 language mode with Swift 6 upcoming-feature strictness on every
target (`AgentCore` pilots `-strict-concurrency=complete`); canonical formatting via `.swiftformat`
with blame-ignore sweeps; hardened runtime enabled, user script sandboxing on.

## Repository layout

```text
justfile             task runner (mirrors Development + CI)
App/                 macOS app target (XcodeGen spec, sources, entitlements)
  Sources/                   composition root, UI, scenario harnesses
  Acceptance/                hermetic Stage-16 scenario gates (ATERM_SCENARIO=…)
  Support/                   Info.plist
  Tests/                     app-hosted unit tests (TEST_HOST = the app bundle)
Packages/            SwiftPM package — all reusable modules + their tests
  Sources/AgentCore/         domain, runtime, detection
  Sources/AgentStore/        SQLite/GRDB persistence
  Sources/AgentControl/      socket server, wire protocol
  Sources/TerminalKit/       session/surface management
  Sources/GhosttyBridge/     the only importer of ghostty.h
  Sources/AgentLauncher/     launch helper
  Sources/agentctl/          CLI
  Tests/                     package test suites
Tests/Fixtures/      shared detection fixtures consumed by package tests
Vendor/Ghostty/      pinned libghostty: commit.txt, patches.md, build script
Scripts/             dev bootstrap, gates, release signing
docs/                architecture, ADRs, protocols, threat model, privacy review
Spike/               throwaway experiments
```

## Security posture

Threat model assumes a trusted local user; the control socket is owner-only (`0600`) AF_UNIX —
there is deliberately no TCP listener anywhere. Launch tickets carry ephemeral per-generation
tokens so a stale helper cannot impersonate a restarted agent. Hardened Runtime is enabled;
the App Sandbox is intentionally off (the app manages arbitrary project directories).
Read the analysis: [`docs/Security/threat-model.md`](docs/Security/threat-model.md),
[`docs/Security/privacy-review.md`](docs/Security/privacy-review.md).
Third-party components and licenses: [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Acknowledgments

Built on [Ghostty](https://ghostty.org) (MIT) via its embedder API, [GRDB](https://github.com/groue/GRDB.swift),
and ideas borrowed from Herdr's semantic-agent model (Apache-2.0). The architecture doc records
what was taken, what was rejected, and why.

## License

AgentTerminal is released under the MIT License. The repository also contains
third-party components with their own terms; see [`LICENSE`](LICENSE) and
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) before redistributing source or binaries.
