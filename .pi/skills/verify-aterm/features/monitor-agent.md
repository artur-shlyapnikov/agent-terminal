# Monitor an agent

Monitor an agent lets a user watch what the terminal is doing right now: read the visible screen, wait event-driven for a lifecycle transition, follow live change events, and see attention (input needed, unread completion, failure) in the sidebar and menu bar.

## Sub-features

- `monitor-read` reads the current viewport (`visible`) or detector screen (`detection`).
- `monitor-wait` blocks until a lifecycle set matches or the deadline passes.
- `monitor-events` streams live `agentChanged` frames for one or all agents.
- `monitor-attention` surfaces `inputRequired|completionUnread|failure` beside the lifecycle.

## How to get to it (user POV)

- Look at the terminal pane and the sidebar/menu-bar status for the agent.
- Run `agent read`, `agent wait`, `agent get`, and `events subscribe` through `control-aterm`.

## Driving it with control-aterm

Preconditions:

- One `generic-shell` agent at `idle` (see `create-agent.md`), recorded as `AGENT_ID`.
- A long sleep ready to generate an observable transition: text `sleep 20 # monitor-$RUN_ID`.

- **Read viewport.** Show the current screen. Run `control-aterm --run-id $RUN_ID read $AGENT_ID --source visible`. Exit code `0` with `{"text":...,"outputRevision":N}`; the text shows a shell prompt.
- **Read detector.** Show what the lifecycle detector sees. Run `control-aterm --run-id $RUN_ID read $AGENT_ID --source detection`. Exit code `0`; the text is the live bottom screen (may differ from the viewport, never scrollback).
- **Wait match.** Start the sleep, then wait for the turn. Run `control-aterm --run-id $RUN_ID prompt $AGENT_ID "sleep 20 # monitor-$RUN_ID" --policy sendNow` and `control-aterm --run-id $RUN_ID wait $AGENT_ID --lifecycle working --timeout-ms 30000`. The wait exits `0` with `{"matched":true,"lifecycle":"working"}`.
- **Wait deadline.** Wait for a state that will not come. Run `control-aterm --run-id $RUN_ID wait $AGENT_ID --lifecycle stopped --timeout-ms 5000`. Exit code `2` with `{"matched":false,"reason":"timeout"}`; record the `2`, do not treat it as failure of the harness.
- **Follow events.** Stream changes for the agent. Run `timeout 8 control-aterm --run-id $RUN_ID subscribe --agent $AGENT_ID > artifacts/monitor-agent/events.ndjson`. Frames are `{"event":"agentChanged","agent":{...}}` carrying full summaries; a slow consumer may skip intermediate revisions but never ends stale.
- **Attention check.** Read attention beside lifecycle. Run `control-aterm --run-id $RUN_ID get $AGENT_ID`. The agent object shows `"attention":"none"` for a healthy sleep and `"lifecycle":"working"`.
- **Proof.** Save the two reads, the matched and timed-out waits (with exit codes), the events stream, and the `get`. The artifacts share one `AGENT_ID` and rising `stateRevision` values. End the sleep with `control-aterm --run-id $RUN_ID interrupt $AGENT_ID` and wait back to `idle` before leaving.

## Gotchas

- `read` has no scrollback source: only `visible` and `detection` exist. Assert on current-screen content, not history.
- `wait` without `--timeout-ms` defaults to 60 s; always pass an explicit deadline and expect exit `2` for negative proofs.
- `subscribe` runs until Ctrl-C; always wrap it in `timeout` and treat exit `124` from `timeout` as the planned end, not an app error.
- Attention is separate from lifecycle: `idle` with `completionUnread` (hidden agent finished a turn) is healthy, not stuck. Assert the pair, never lifecycle alone.
