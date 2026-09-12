# Stop an agent

Stop an agent lets a user interrupt a running command without killing the shell, or terminate the agent gracefully (SIGTERM to the process group, 2 s grace, then SIGKILL) and confirm the process is reaped, the lifecycle is `stopped`, and no attention remains.

## Sub-features

- `stop-interrupt` sends SIGINT-equivalent intent; the process survives.
- `stop-graceful` ends the agent as `stopped` and reaps the process.
- `stop-closeview` detaches the view only (parks, like ⌘W) without signalling.
- `stop-quiet` leaves a stopped agent attention-free.

## How to get to it (user POV)

- Choose Agent > Stop Agent, or close the pane (parks the surface, process continues).
- Run `agent interrupt AGENT_ID` or `agent stop AGENT_ID [--mode gracefulStop|closeView]` through `control-aterm`.

## Driving it with control-aterm

Preconditions:

- One `generic-shell` agent at `idle` (see `create-agent.md`), recorded as `AGENT_ID`.

- **Interrupt survives.** Start a sleep, interrupt it, prove the shell lives. Run `control-aterm --run-id $RUN_ID prompt $AGENT_ID "sleep 30 # stop-$RUN_ID" --policy sendNow`, then `control-aterm --run-id $RUN_ID interrupt $AGENT_ID` (exit `0`), then `control-aterm --run-id $RUN_ID wait $AGENT_ID --lifecycle idle --timeout-ms 30000` (exit `0`, matched). A following `read --source visible` still shows a live shell prompt.
- **Graceful stop.** Terminate the agent. Run `control-aterm --run-id $RUN_ID stop $AGENT_ID` (exit `0`; default `--mode gracefulStop`). Then run `control-aterm --run-id $RUN_ID wait $AGENT_ID --lifecycle stopped --timeout-ms 30000`. Exit `0` with `{"matched":true,"lifecycle":"stopped"}`.
- **Quiet stopped.** Confirm no lingering attention. Run `control-aterm --run-id $RUN_ID get $AGENT_ID`. The agent shows `"lifecycle":"stopped"` with `"attention":"none"`.
- **Process reaped.** Confirm the child is gone at the OS level. Run `control-aterm --run-id $RUN_ID read $AGENT_ID --source visible`; the call now reports `terminalUnavailable` (or the `get` shows an exited process phase) instead of live screen text.
- **Proof.** Save the interrupt receipt, the post-interrupt `idle` wait, the stop receipt, the `stopped` wait, and the final `get`. The artifacts share one `AGENT_ID` with a monotonically rising `stateRevision` ending at `stopped`/attention `none`.

## Gotchas

- Closing a pane or the window PARKS the surface; it never stops the child. Only `stop` (or quit-with-stop) terminates work — do not prove stopping with `closeView`.
- `stop --mode closeView` is the park path by design; asserting `stopped` after it fails honestly. Use it only to prove detach semantics, never as teardown.
- A crash or `failed` lifecycle is not a stop: it carries attention `failure`. Assert `stopped` plus attention `none` together.
- Always `cleanup` the run after stopping the probe so the hermetic app exits; a stopped agent does not end the app process.
