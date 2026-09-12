# AgentTerminal verification map

This directory is the maintained source for verifying the user-facing behavior of AgentTerminal. Read this index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- One hermetic app per run: `control-aterm --run-id $RUN_ID launch` with a unique `RUN_ID`.
- Socket `SOCK=/tmp/aterm-verify-$RUN_ID/control.sock`, DB `ATERM_DB_PATH=/tmp/aterm-verify-$RUN_ID/verify.sqlite`.
- Agent work dir `/tmp/aterm-verify-$RUN_ID/work` exists (the helper creates it).
- `control-aterm --run-id $RUN_ID doctor` reports HEALTHY (ping `protocolVersion 1`, socket mode `600`, workspace listed).
- Verification uses `--kind generic-shell` unless the feature file says otherwise (agent CLIs must be on `PATH`).
- Never drive an instance that was not started by this verification run; never touch the production socket/DB.

## Driving conventions

- Start every recipe from the baseline state unless its preconditions say otherwise.
- `CTL` below means `control-aterm --run-id $RUN_ID`.
- Treat every command as literal. Keep agent IDs, `--lifecycle` tags, and `--policy` values unchanged.
- `agent wait` exit `2` is a deadline (`matched:false`), not success. Record it.
- Run `agent focus AGENT_ID` after create: screen detection needs a mounted live surface.
- Restore seeded state after a mutation. Do not remove proof artifacts during cleanup.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- Shell proof includes the command, stdout/stderr, and exit code plus `agent get` lifecycle/attention and `agent read` text showing the effect.
- Mutation proof includes a read-only second view of the stored value (`agent get`, `agent list`).
- Record the feature ID and entry point used with every artifact under `/tmp/aterm-verify-$RUN_ID/artifacts/`.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with control-aterm` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [Create an agent](./create-agent.md) covers New Agent creation via `agent create`, focus/mount, idle arrival, and listing.
- [Prompt an agent](./prompt-agent.md) covers composer send (`sendNow`), working/idle turns, and delivery receipts.
- [Monitor an agent](./monitor-agent.md) covers reading terminal output, event-driven wait, and attention states.
- [Stop an agent](./stop-agent.md) covers interrupt-survives, graceful stop to `stopped`, and process reaping.
