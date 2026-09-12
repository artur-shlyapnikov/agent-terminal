# AgentTerminal

AgentTerminal is a macOS app for running local coding-agent CLIs and shells in
native terminal panes. It keeps a lifecycle record for each agent and exposes a
local Unix-socket control API.

The repository is pre-release source code. It does not contain a downloadable
app or prebuilt libghostty artifacts. The current release evidence is in
[docs/release/stage16-gate-report.md](docs/release/stage16-gate-report.md).

## What it supports

The app includes four built-in adapters:

| Adapter kind | Executable | Session resume | Lifecycle source |
|---|---|---:|---|
| "claude-code" | "claude" | Yes, when a session reference exists | Screen rules, with hook reports for session identity |
| "codex" | "codex" | Yes, when a session reference exists | Screen rules, with hook reports for session identity |
| "opencode" | "opencode" | Yes, when a session reference exists | OpenCode plugin when installed, otherwise screen rules |
| "generic-shell" | "$SHELL", "/bin/zsh", or "/bin/bash" | No | Process monitoring and a shell-prompt screen rule |

The app starts the selected executable in the working folder you choose. It
does not install these CLIs. A plain shell is available when the shell paths
above are executable.

AgentTerminal can keep multiple project folders as workspaces. Each workspace
has its own agents and layout. The canvas shows at most four panes at once.
The acceptance harness creates and tears down 16 live terminal surfaces, but
that test result is not a general production capacity promise.

## Current limits

- The app supports local macOS processes only. There is no remote or SSH agent
  support, and there are no Linux or Windows targets.
- Closing a pane or the window parks the terminal surface. It does not stop the
  child process. Use Stop Agent or quit with the stop option to terminate work.
- A clean quit can request resume for Claude Code, Codex, and OpenCode when the
  adapter captured a valid session reference. A generic shell cannot resume.
- A crash does not auto-start previous agents. Recoverable sessions become
  Recovery Center candidates and wait for a user action.
- The UI's Resume action runs the full relaunch path. The current control-plane
  "agentctl agent resume" endpoint validates the session and records the resume
  event, but it is not wired to that relaunch path.
- The app never auto-approves an agent permission or selection prompt. Screen
  detection marks such requests as terminal-only.
- The release process does not yet include Sparkle, notarization, or a signed
  distribution package.

## How lifecycle state works

The runtime reports one of these lifecycle values in the UI and control API:

| State | Meaning |
|---|---|
| "unknown" | No current trusted evidence exists, or screen rules conflict. |
| "starting" | The agent record exists and its terminal launch is in progress, or the process has started but has not produced a lifecycle observation. |
| "idle" | The integration or screen rules identify an idle prompt. |
| "working" | The integration or screen rules identify an active turn. |
| "waitingForInput" | The agent is waiting for a question, approval, or selection response. |
| "stopping" | A graceful stop was requested and the process has not exited yet. |
| "stopped" | The process exited successfully, either after a user stop or after completing on its own. |
| "failed" | Launch failed, or the process exited with a non-zero status or signal. |

The state machine also tracks process phase, attention, evidence authority, and
state revision. Evidence authority has this order: integration, screen,
process, then unknown. A late screen result cannot resurrect a stopped or
failed process.

The screen detector reads the active terminal screen through libghostty rather
than an OS screenshot. Bundled manifests cover Claude Code, Codex, and
OpenCode. An unmatched or ambiguous screen becomes "unknown". The detector
confirms a waiting state on two matching observations and stabilizes an
idle-after-working result before publishing it. See
[docs/Detection/manifests.md](docs/Detection/manifests.md) for the exact
rules and fixtures.

Attention is separate from lifecycle. The app can mark an agent as
"inputRequired", "completionUnread", or "failure". A hidden agent that finishes
a turn can raise "completionUnread". The sidebar and menu-bar status item keep
showing attention when macOS notification authorization is unavailable.

## Prerequisites

You need:

- an Apple Silicon Mac running macOS 14 or newer;
- full Xcode 16.4 or newer. The Xcode Command Line Tools package is insufficient;
- Homebrew to install "just" and, when needed, "xcodegen";
- network access during setup to resolve GRDB, clone the pinned Ghostty
  revision, and download the exact Zig version used by that revision.

The package uses Swift 5.10 settings and Swift 6 upcoming-feature checks. The
build scripts honor DEVELOPER_DIR when the active xcode-select path does
not point to the full Xcode bundle.

Install the external agent CLIs separately if you plan to use them. The New
Agent sheet checks the executable on PATH before launch and shows an error
when the selected CLI is missing.

## Build and run

Install "just", clone the repository, and run the setup script:

~~~sh
brew install just
git clone https://github.com/artur-shlyapnikov/agent-terminal.git
cd agent-terminal
just setup
~~~

"just setup" checks for full Xcode, installs "xcodegen" through Homebrew when
it is missing, resolves SwiftPM dependencies, and builds the pinned libghostty
artifacts under Vendor/Ghostty/build/. It does not generate the Xcode
project. The Ghostty script keeps its source clone outside the repository at
~/Library/Caches/agentterminal/ghostty and bootstraps the pinned Zig version
under ~/.local/share/agentterminal-tools/.

Generate the ignored Xcode project and run the workspace from Xcode:

~~~sh
just gen
open AgentTerminal.xcworkspace
~~~

Select the AgentTerminal scheme and press Cmd-R. Xcode runs the app with its
development settings. AgentTerminalAcceptance is a separate test harness
and is not the shipping target.

For a command-line build, use:

~~~sh
just app
~~~

This recipe regenerates the Xcode project and builds an unsigned app with
CODE_SIGNING_ALLOWED=NO. It does not start the app and it does not build
libghostty. Run "just setup" first, or run "just ghostty" when the vendored
build is missing.

If the selected developer directory is not full Xcode, set it for the recipe:

~~~sh
DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer just app
~~~

To build and run with a predictable output directory, use the same command
shape as CI:

~~~sh
just gen
xcodebuild -workspace AgentTerminal.xcworkspace -scheme AgentTerminal -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/agent-terminal-derived-data build CODE_SIGNING_ALLOWED=NO
open /tmp/agent-terminal-derived-data/Build/Products/Debug/AgentTerminal.app
~~~

## First run

1. Launch AgentTerminal. On a fresh database, the onboarding window lists
   detected agent CLIs.
2. Choose a project folder. "Skip" creates a workspace rooted at your home
   directory and still lets you start a plain shell.
3. Press Cmd-N or choose File > New Agent. Select an adapter, enter a display
   name, choose a working folder, and create the agent. The display name and
   working folder are required. A task summary is optional.
4. Select the new agent in the sidebar and type a prompt in the composer. For
   an approval or selection request, answer in the terminal pane.
5. Cmd-W or Close View parks the selected pane. The process continues and the
   agent remains in the sidebar. Use Agent > Stop Agent to send a graceful
   stop. The stop path sends SIGTERM to the process group, waits two seconds,
   then sends SIGKILL if the process is still alive.

The first-run window also links to integration settings. The installer can
manage its own entries in these files:

- ~/.claude/settings.json;
- ~/.codex/config.toml;
- ~/.config/opencode/config.json.

It validates the file format, creates a backup before changing an existing
file, and refuses to overwrite a user-modified managed entry. Integration
setup does not install or update the external CLIs.

## Control the app with agentctl

The app bundle contains Contents/Helpers/agentctl. The control server starts
with the app when bootstrap succeeds. Its default socket is:

~~~text
~/Library/Application Support/AgentTerminal/runtime/control.sock
~~~

The socket is an owner-only (0600) Unix socket. There is no TCP listener.
Use --socket PATH or AGENT_TERMINAL_CONTROL_SOCKET when running a separate
instance or a test harness.

Set CTL to the helper in the app you built, then replace the IDs with values
returned by the list commands. "events subscribe" is a top-level command.

~~~sh
CTL="/path/to/AgentTerminal.app/Contents/Helpers/agentctl"

"$CTL" system ping
"$CTL" workspace list

WORKSPACE_ID="paste-a-workspace-id"
"$CTL" agent create --workspace "$WORKSPACE_ID" --kind claude-code --dir "$PWD" --name "API migration"
"$CTL" agent list --workspace "$WORKSPACE_ID"

AGENT_ID="paste-an-agent-id"
"$CTL" agent prompt "$AGENT_ID" "Refactor the auth module" --policy sendNow
"$CTL" agent wait "$AGENT_ID" --lifecycle idle --timeout-ms 300000
"$CTL" agent read "$AGENT_ID" --source detection
"$CTL" events subscribe --agent "$AGENT_ID"
"$CTL" agent stop "$AGENT_ID"
~~~

The user-facing commands are system ping, workspace list, and the agent
actions create, list, get, prompt, cancel-queued-prompt, focus, read, wait,
interrupt, stop, and resume. integration and launcher commands are
authenticated protocol paths used by installed hooks and the bundled launcher.

agent prompt accepts these policies:

- sendNow writes to the terminal immediately when the current lifecycle allows
  the prompt and a terminal is available;
- queueWhenIdle keeps one prompt per supported agent until a validated "idle"
  state. Generic shells do not support this policy;
- rejectUnlessIdle fails unless the lifecycle is already "idle".

The queue is one slot. A second queued prompt fails instead of replacing the
first one. A prompt with a client --command-id can be retried safely because
the receipt is cached in memory. The cache is not persisted across app runs.

agent wait checks the current state, subscribes to changes, and checks the
state again before waiting. It does not poll. Its default timeout is 60
seconds, the maximum is 24 hours, and a timeout prints a successful JSON
response with reason "timeout" and exits with status 2. All other CLI
errors exit with status 1.

The full NDJSON envelope, method list, error codes, and authenticated hook
fields are in [docs/Protocols/control-v1.md](docs/Protocols/control-v1.md).

## Storage, permissions, and privacy

The app stores its SQLite database at:

~~~text
~/Library/Application Support/AgentTerminal/AgentTerminal.sqlite
~~~

It stores its app-specific Ghostty configuration under
~/Library/Application Support/AgentTerminal/ghostty/. A corrupt database is
moved to the backups directory and replaced with a fresh database; the app
shows the quarantine path in a persistent banner.

The app does not persist prompt text or terminal output. It persists workspace
and agent metadata, lifecycle history, layout, and opaque session references.

App/AgentTerminal.entitlements contains no App Sandbox or JIT entitlement.
The project enables Hardened Runtime. The app can therefore launch local
CLIs and access the working folders selected by the user, subject to normal
macOS privacy controls for protected locations. The app does not use Screen
Recording or Accessibility APIs for lifecycle detection. It reads the
terminal buffer through libghostty.

The app requests macOS alert and sound notification authorization during an
interactive launch. Denying it does not disable agents or the control API.
The sidebar and menu-bar status item still show attention. The app sources do
not contain an HTTP client or telemetry uploader. Setup scripts do use the
network to fetch dependencies and the pinned Ghostty toolchain.

See [docs/Security/privacy-review.md](docs/Security/privacy-review.md) and
[docs/Security/threat-model.md](docs/Security/threat-model.md) for the
security boundaries.

## Development checks

The justfile is the canonical list of local recipes. Common checks are:

~~~sh
just check       # package build, dependency-law check, and license audit
just build       # SwiftPM package build
just test        # SwiftPM tests
just strict      # package build with warnings as errors
just app-test    # app-hosted unit tests
just lint        # SwiftFormat, SwiftLint, dependency law, and license audit
just smoke       # corrupt-db, capacity16, and teardown100 scenarios
just soak 60     # short soak; the default is 1800 seconds
just ci          # local PR gate, including package, app, and acceptance checks
~~~

"just lint" expects swiftformat, swiftlint, and Python 3. "just setup"
installs only xcodegen, so install the linters separately when needed:

~~~sh
brew install swiftformat swiftlint
~~~

"just format" changes Swift source files in place. The acceptance app and
scenario harnesses are for repository checks, not normal app use.

## Repository layout

~~~text
App/                 macOS app target, XcodeGen spec, UI, and app tests
Packages/            SwiftPM modules and package tests
Tests/Fixtures/      anonymized screen-detection fixtures
Vendor/Ghostty/      pinned commit metadata and build instructions
Scripts/             setup, Ghostty build, checks, and signing scripts
docs/                architecture, detection, protocol, security, and release notes
~~~

Architecture decisions are in [docs/Architecture/](docs/Architecture/).
The Ghostty pin and build details are in
[Vendor/Ghostty/README.md](Vendor/Ghostty/README.md).

## License

AgentTerminal is released under the MIT License. Third-party components keep
their own terms. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
