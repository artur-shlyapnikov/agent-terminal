# Create an agent

Create an agent lets a user start a new terminal-backed agent (a coding CLI or a plain shell) in a workspace from the New Agent sheet or the control API, focus it so its terminal mounts, and confirm it reaches idle in the sidebar and listings.

## Sub-features

- `create-shell` creates a `generic-shell` agent that is always launchable.
- `create-cli` creates a `claude-code|codex|opencode` agent when that CLI is on `PATH`.
- `create-focus` mounts/selects the agent surface so screen detection can observe it.
- `create-list` shows the new agent in listings with its lifecycle and revision.

## How to get to it (user POV)

- Choose File > New Agent (⌘N), pick an adapter, enter display name and working folder, create.
- Run `agent create --workspace ID --kind K --dir PATH --name NAME` through `control-aterm` (same launch pipeline).

## Driving it with control-aterm

Preconditions:

- Hermetic app HEALTHY per `control-aterm --run-id $RUN_ID doctor`.
- A workspace ID from `control-aterm --run-id $RUN_ID workspaces`.
- No agent named `verify-probe` in `control-aterm --run-id $RUN_ID list`.

- **Create shell.** Start a plain shell agent. Run `control-aterm --run-id $RUN_ID create --workspace $WS --kind generic-shell --dir /tmp/aterm-verify-$RUN_ID/work --name "verify-probe"`. Exit code `0` and stdout `{"ok":true,"result":{"agentID":"..."}}`; record the ID as `AGENT_ID`.
- **Focus surface.** Mount the terminal like a sidebar click. Run `control-aterm --run-id $RUN_ID focus $AGENT_ID`. Exit code `0` with `{"ok":true}`.
- **Reach idle.** Wait for the shell prompt to be detected. Run `control-aterm --run-id $RUN_ID wait $AGENT_ID --lifecycle idle --timeout-ms 60000`. Exit code `0` with `{"matched":true,"lifecycle":"idle"}`.
- **Confirm listing.** Read the agent back from a second view. Run `control-aterm --run-id $RUN_ID get $AGENT_ID` and `control-aterm --run-id $RUN_ID list --workspace $WS`. Both show the ID with lifecycle `idle` and rising `stateRevision`.
- **CLI entry.** With the real CLI on `PATH`, create one agent CLI probe. Run `PATH="/path/to/cli:$PATH" control-aterm --run-id $RUN_ID create --workspace $WS --kind claude-code --dir /tmp/aterm-verify-$RUN_ID/work --name "verify-cli"`. Exit `0` when installed; a `launchFailed` error with a missing-executable message is the expected negative proof when it is not installed — record which.
- **Proof.** Save the create receipt, the matched wait, and the `get` output. Run `control-aterm --run-id $RUN_ID get $AGENT_ID > /tmp/aterm-verify-$RUN_ID/artifacts/create-agent/get.json` and `control-aterm --run-id $RUN_ID read $AGENT_ID --source visible > /tmp/aterm-verify-$RUN_ID/artifacts/create-agent/read.txt`. The artifacts identify the run (`verify-probe`), the lifecycle (`idle`), and the revision.

## Gotchas

- Idle detection matches only prompts ending in `%`, `$`, `#`, or `>` (the
  `shell-idle-prompt` rule). A themed prompt such as `❯` never reaches
  `idle` — `launch` installs a hermetic `ZDOTDIR` with a plain prompt for
  exactly this reason. If `wait --lifecycle idle` times out, read the
  screen first: a healthy shell with an exotic prompt is a scaffolding
  gap, not an app bug.

- Creating without a later `focus` can strand screen detection: the agent exists but the surface never mounts and `idle` arrives late or never.
- `create` without `--dir` or with a nonexistent dir fails; always use the run work dir.
- A missing CLI executable fails the create by design (the sheet validates before launch). Do not install shims to fake a CLI create; a stub proves fallback only, never real CLI behavior.
- `agent list` without `--workspace` returns every workspace; filter when asserting membership.
