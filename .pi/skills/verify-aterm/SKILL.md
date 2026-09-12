---
name: verify-aterm
description: Drive AgentTerminal (macOS desktop terminal-pane app) the way a user does — launch a hermetic instance, create/prompt/read/stop agents through agentctl, capture proof. Use whenever behavior must be proven against the real app instead of argued from source.
---

# Verify AgentTerminal

AgentTerminal is a macOS desktop app: native terminal panes (libghostty) host
local coding-agent CLIs (claude / codex / opencode) or a plain shell, with a
sidebar, composer, and lifecycle display. Its scriptable surface is
`agentctl`, a CLI over an owner-only (`0600`) Unix socket speaking control
protocol v1 (NDJSON envelopes, `docs/Protocols/control-v1.md`). There is no
TCP listener and no remote target. Verification drives the REAL app through
`agentctl` (bundled at `Contents/MacOS/Helpers/agentctl`) against a HERMETIC instance - never the operator's live session.

## Launch

Build once (full Xcode 16.4+ required; CLT alone is insufficient):

```sh
just gen
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -workspace AgentTerminal.xcworkspace -scheme AgentTerminal \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/aterm-verify-dd build CODE_SIGNING_ALLOWED=NO
# or: just app   (same build, default DerivedData; still needs `just setup` once
# for the pinned libghostty under Vendor/Ghostty/build/)
```

Start one hermetic instance per run (unique `RUN_ID`, e.g. timestamp+pid):

```sh
.pi/skills/verify-aterm/helpers/control-aterm --run-id $RUN_ID launch
```

This starts
`/tmp/aterm-verify-dd/Build/Products/Debug/AgentTerminal.app` with three
overrides that isolate it completely from production:

- `AGENT_TERMINAL_CONTROL_SOCKET=/tmp/aterm-verify-$RUN_ID/control.sock`
- `ATERM_DB_PATH=/tmp/aterm-verify-$RUN_ID/verify.sqlite`
- `ATERM_GHOSTTY_CONFIG_DIR=/tmp/aterm-verify-$RUN_ID/ghostty`

Ready means ALL THREE: the socket file exists AND `agentctl system ping`
answers `{"ok":true,"result":{"protocolVersion":1,...}}` AND `workspace
list` returns at least one workspace. The helper waits up to 90 s and dumps
the app log tail on failure. App log: `/tmp/aterm-verify-$RUN_ID/app.log`.

Fresh-DB scaffolding (marked): a brand-new hermetic DB opens at onboarding
with zero workspaces, and control v1 has no `workspace.create` — the first
workspace is born from the onboarding folder picker, which a headless run
cannot click. When `launch` sees an empty workspace list it stops its own
app, inserts exactly what `adoptWorkspaces()` persists for a first run (one
`Default` row, `sort_index 0`, root = the run work dir), and relaunches so
bootstrap adopts it. The seed row is reported on stdout; production code is
untouched.

Prompt scaffolding (marked): generic-shell `idle` is detected by the
app-side `shell-idle-prompt` screen rule (`App/Sources/DetectionPipeline.swift`),
which matches a live prompt ending in `%`, `$`, `#`, or `>` on the last two
screen lines. A themed login shell (e.g. powerlevel10k ending in `❯`)
never matches, so the probe would sit at `unknown` forever through no fault
of the app. `launch` therefore writes `$RUN_DIR/zdotdir/.zshrc` (plain
`PROMPT='verify-%~$ '`) and starts the app with `ZDOTDIR` pointed at it.
The launch path is unchanged (still `$SHELL -l` through the real
`ShellEnvironmentResolver`); only the dotfiles zsh reads are hermetic.
Bash keeps its default `$`-ending prompt and needs no redirect.

For short-lived checks there is no server to keep alive beyond the run:
launch the hermetic app once per verification run, then drive it with
per-command `control-aterm --run-id $RUN_ID ...` invocations.

Teardown is `cleanup` (see Cleanup). Never launch a second instance sharing a
`RUN_ID`, and never point two runs at one socket.

## Doctor

Run first whenever anything looks off. Read-only; answers "is this instance
worth driving?":

```sh
.pi/skills/verify-aterm/helpers/control-aterm --run-id $RUN_ID doctor
```

It checks: our app PID alive, hermetic socket present with mode `600`,
`system ping` ok with `protocolVersion 1`, `workspace list` answering, and
the hermetic DB file present. `HEALTHY` means drive; `UNHEALTHY` means stop
and read `/tmp/aterm-verify-$RUN_ID/app.log` — do not pile commands onto a
sick instance. The helper refuses to run when the socket is not the run's own
hermetic path, so a missing `--run-id` can never reach the production socket
at `~/Library/Application Support/AgentTerminal/runtime/control.sock`.

## Drive

All driving goes through the helper (thin wrapper over the run's `agentctl`;
prefers the app bundle's `Contents/MacOS/Helpers/agentctl`, falls back to the
SwiftPM build at `Packages/.build/arm64-apple-macosx/debug/agentctl`).
Every command below takes `--run-id $RUN_ID` first. Canonical recipe:

```sh
CTL=".pi/skills/verify-aterm/helpers/control-aterm --run-id $RUN_ID"
$CTL doctor
$CTL workspaces                                   # pick a workspace ID
$CTL create --workspace $WS --kind generic-shell --dir /tmp/aterm-verify-$RUN_ID/work --name "verify-probe"
$CTL focus AGENT_ID                               # mount/select: screen detection needs a live surface
$CTL wait AGENT_ID --lifecycle idle --timeout-ms 60000
$CTL prompt AGENT_ID "echo verify-$RUN_ID" --policy sendNow
$CTL wait AGENT_ID --lifecycle working --timeout-ms 30000 || true   # fast turns may skip working
$CTL wait AGENT_ID --lifecycle idle --timeout-ms 120000
$CTL read AGENT_ID --source visible
$CTL stop AGENT_ID                                # gracefulStop: SIGTERM group, 2 s grace, SIGKILL
$CTL get AGENT_ID
```

Notes grounded in this repo (not generic advice):

- `--kind generic-shell` always works (`$SHELL`/`/bin/zsh`/`/bin/bash`).
  `claude-code|codex|opencode` kinds require that CLI on `PATH` — the New
  Agent sheet refuses missing executables, and so does the launch path.
- `generic-shell` supports only `--policy sendNow`. `queueWhenIdle` /
  `rejectUnlessIdle` are for agent CLIs with validated idle; queueing to a
  shell fails.
- `agent wait` is event-driven, never polling. Exit `0` = matched, exit `2`
  = deadline with `{"matched":false,"reason":"timeout"}` (still `ok:true`),
  exit `1` = real error. Lifecycle vocabulary:
  `unknown,starting,idle,working,waitingForInput,stopping,stopped,failed`.
- `agent read --source visible` is the viewport; `--source detection` is the
  live bottom screen the detector feeds on. There is no scrollback source.
- `stop` default `--mode gracefulStop`; `--mode closeView` only detaches the
  view and leaves the process running (parks, like ⌘W) — never use it to
  "stop" a probe.
- Raw `agentctl` remains available for hook/launcher paths:
  `$CTL prompt ...` covers users; `integration report|release` and `launcher
  started|failed` are hook-script protocol paths, not user paths.
- Acceptance scenarios (`just smoke`, `ATERM_SCENARIO=capacity16|soak|
  teardown100|corrupt-db ...` in `AgentTerminalAcceptance`) are repo gates,
  not verification driving: they prove capacity/soak/adverse behavior but do
  not substitute for driving a user feature listed in `features/`.

The per-feature recipes live in `features/`; start every recipe from the
baseline above unless its Preconditions say otherwise.

## Evidence

Proof artifacts go to `/tmp/aterm-verify-$RUN_ID/artifacts/` (printable via
`control-aterm --run-id $RUN_ID evidence-dir`). Capture per drive:

- the exact command, stdout, stderr, and exit code (`agent wait` timeouts
  exit `2` — record that, do not re-label it success);
- the resulting state from a second view: `agent get` (lifecycle/attention/
  `stateRevision`) and `agent read` text showing the effect;
- side effects: files written under the run work dir, DB rows via a fresh
  `agent list`, spawned-process exit (reaped or not);
- for GUI-visible claims, a screenshot with the app identity visible
  (`screencapture -l <window-id> $EVIDENCE/artifacts/<name>.png`) alongside
  the `agent read` text — a screenshot alone is not state proof.
- when piping `agentctl` through `tee`, assert `${PIPESTATUS[0]}`: the bare
  `$?` is `tee`'s. `control-aterm` itself `exec`s `agentctl`, so bare
  invocations preserve exit codes (`0` matched, `2` wait deadline, `1`
  error) end to end.

Proof standards: exercise the real user path (`create` → `focus` → `prompt`
→ `wait` → `read` → `stop`), never internal setters or test-only hooks;
capture the action AND the resulting state, not just the final screen; verify
side effects (process reaped, `stopped` with attention `none`) alongside what
is visible; mocks only where a production boundary already isolates the
external system (stub CLIs on `PATH` for adapter-kind coverage — a stub
proves launch/detection fallback, never real agent behavior). No dry-run
mode exists in this app: every `prompt` writes to a live terminal, so always
drive the hermetic instance.

## Cleanup

```sh
.pi/skills/verify-aterm/helpers/control-aterm --run-id $RUN_ID cleanup
```

Kills ONLY the PID this run started (`app.pid`: SIGTERM, 10 s grace,
SIGKILL), removes the socket and work dir, and lists the preserved evidence.
Cleanup never deletes `/tmp/aterm-verify-$RUN_ID/artifacts/` or the app log;
confirm the evidence still exists afterwards (`ls`). It never kills by
process name, never touches `~/Library/Application Support/AgentTerminal/`,
and never touches another run's `/tmp/aterm-verify-<other>/` dir. To erase a
run fully after the proof is recorded: `HARD_DELETE=1 rm -rf
/tmp/aterm-verify-$RUN_ID`. Run cleanup after every failed iteration too, so
broken attempts don't strand processes and sockets.

## Helpers

- `helpers/control-aterm` (executable): the only driver. Subcommands
  `launch|doctor|ping|workspaces|create|list|get|prompt|wait|read|focus|
  interrupt|resume|cancel-queued-prompt|stop|subscribe|evidence-dir|cleanup`.
  Global flags: `--run-id ID` (required, or `ATERM_RUN_ID`), `--app PATH`
  (or `ATERM_APP`), `--ctl PATH` (or `ATERM_CTL`). `agent` subcommand flags
  are `agentctl`'s own (`--workspace/--kind/--dir/--name/--task-summary/
  --policy/--command-id/--lifecycle/--min-revision/--timeout-ms/--source/
  --mode/--agent`); see Drive for the verified subset.
