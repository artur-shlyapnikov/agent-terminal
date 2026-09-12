# Prompt an agent

Prompt an agent lets a user type in the composer and send text to the live terminal now, watch the turn open (working) and close (idle), and rely on exactly-once delivery when a send is retried with the same command ID.

## Sub-features

- `prompt-send` delivers composer text to the terminal immediately (`sendNow`).
- `prompt-turn` opens a working turn that closes back to idle.
- `prompt-receipt` returns a delivery receipt with a runtime-minted command ID.
- `prompt-retry` replays the cached receipt for an envelope-level `commandID` retry instead of sending twice.

## How to get to it (user POV)

- Select the agent in the sidebar, type in the composer, send.
- Run `agent prompt AGENT_ID TEXT... --policy sendNow` through `control-aterm`.

## Driving it with control-aterm

Preconditions:

- One `generic-shell` agent at `idle` (see `create-agent.md`), recorded as `AGENT_ID`.
- Marker value `MARK=verify-$RUN_ID` unused by any earlier command.

- **Send prompt.** Deliver shell text now. Run `control-aterm --run-id $RUN_ID prompt $AGENT_ID "echo $MARK" --policy sendNow`. Exit code `0` with `{"receipt":{"outcome":"delivered"}}`; record the receipt `commandID`.
- **Turn closes.** Wait for the shell to finish. Run `control-aterm --run-id $RUN_ID wait $AGENT_ID --lifecycle idle --timeout-ms 120000`. Exit code `0` with `{"matched":true,"lifecycle":"idle"}`. (A `working` wait first is best-effort: fast turns like `echo` may never be observable as `working`; do not fail the proof when only the closing `idle` matches.)
- **Confirm effect.** Read the terminal from a second view. Run `control-aterm --run-id $RUN_ID read $AGENT_ID --source visible`. The output text contains the echoed `MARK`.
- **Retry safety.** Resend with the same envelope idempotency key. Run `control-aterm --run-id $RUN_ID prompt $AGENT_ID "echo $MARK-again" --policy sendNow --command-id $RETRY_ID` twice with the same `$RETRY_ID`. Both exits `0` with the identical receipt `commandID`, and `read` shows the text delivered exactly once.
- **Proof.** Save the prompt receipt, the closing wait, and the read text. Run the three commands with output redirected to `artifacts/prompt-agent/`. The artifacts show `delivered`, the `idle` match at a higher `stateRevision`, and the `MARK` in the terminal text.

## Gotchas

- `queueWhenIdle`/`rejectUnlessIdle` are agent-CLI policies; a generic shell rejects queueing. Always use `--policy sendNow` for shell probes.
- Prompt text after a bare `--` is literal: `control-aterm --run-id $RUN_ID prompt $AGENT_ID -- "--socket-looking text"` avoids flag parsing.
- A `waitingForTerminalInput` error means the shell is mid-prompt (e.g. a pager); `interrupt` it and retry rather than stacking prompts.
- The receipt `commandID` (runtime-minted delivery identity) is not the envelope `--command-id` (caller retry key). Record both when proving retry safety.
