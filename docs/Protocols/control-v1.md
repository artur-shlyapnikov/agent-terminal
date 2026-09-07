# Control protocol v1 (`agentctl` / hooks / automation)

- Status: **Implemented** — Stage 13 (control protocol + CLI), per
  architecture notes §3.16 and the §4.5 `AgentControl` file table.
- Transport: NDJSON over a Unix domain socket at

  ```text
  ~/Library/Application Support/AgentTerminal/runtime/control.sock
  ```

  mode `0600`, owner read/write. There is no TCP listener anywhere in this
  module; the only transport is AF_UNIX.
- Sources: `Packages/Sources/AgentControl/*`, CLI:
  `Packages/Sources/agentctl`.

## Decision

The control plane is a closed v1 wire contract: versioned envelopes over one
Unix socket, an 18-method dispatch table onto `AgentRuntime` commands,
per-process-generation hook tokens for launcher/integration reports, a
bounded commandID-keyed replay cache for exactly-once prompt delivery, and a
race-closed, event-driven `agent.wait`. Binding invariants:

1. Protocol version field is mandatory in every envelope; mismatch → error,
   no fallback interpretation.
2. `agent.wait` is event-driven (socket subscription / `AsyncStream`), never
   polling.
3. Mutating commands are idempotency-keyed by `commandID`; retries replay the
   cached response instead of re-executing — a prompt MUST NOT send twice.
4. The socket is owner-only (0600); the threat model is a trusted local user.

---

## Framing and limits

- One JSON object per line (NDJSON). Trailing `\r` before `\n` is tolerated.
- Maximum message size: **1 MiB** (1 048 576 bytes) per frame. A frame that
  exceeds the limit receives a structured rejection and the connection is
  closed immediately — there is no resynchronization inside an oversized
  frame:

  ```json
  {"requestID":"","ok":false,"error":{"code":"payloadTooLarge","message":"frame exceeds 1048576 byte limit"}}
  ```

- A line that fails to parse receives:

  ```json
  {"requestID":"","ok":false,"error":{"code":"badRequest","message":"malformed JSON frame"}}
  ```

  The connection stays usable afterwards.
- Per connection, requests are processed **serially** (§3.18 isolation
  table): each request runs to completion before the next line on that
  connection is dispatched. Clients that need concurrency open additional
  connections (the CLI does this for `agent wait`).
- Long-lived operations (`events.subscribe`) stream frames after their
  initial response header; see [Streaming](#streaming).

## Versioning policy

Every request carries `"protocolVersion": N`.

- The server interprets the envelope only when `N == 1` (exact match).
- Any other value → structured rejection, no best-effort decoding:

  ```json
  {"requestID":"…","ok":false,"error":{"code":"unsupportedProtocolVersion","message":"unsupported protocolVersion 2; supported: 1"}}
  ```

- Additive changes within v1 keep the constant at `1` and MUST be limited to
  optional result fields that old clients ignore. Breaking changes bump to 2
  behind a deprecation window; there is no negotiation handshake beyond the
  client's `system.ping`, whose result echoes the server's protocol version.

## Envelopes

Request (field names are part of the contract):

```json
{"protocolVersion":1,"requestID":"<uuid>","commandID":"<uuid>","method":"agent.prompt","params":{…}}
```

| Field | Presence | Meaning |
|---|---|---|
| `protocolVersion` | required | must equal `1` |
| `requestID` | required | echoed in the response |
| `commandID` | optional | idempotency key (see below) |
| `method` | required | one of the closed method set |
| `params` | required object | method-specific; empty `{}` when none |

Response:

```json
{"requestID":"<uuid>","ok":true,"result":{…},"stateRevision":42}
{"requestID":"<uuid>","ok":false,"error":{"code":"…","message":"…"}}
```

| Field | Presence | Meaning |
|---|---|---|
| `requestID` | always | matches the request |
| `ok` | always | success discriminator |
| `result` | on success | method-specific object |
| `error` | on failure | `{code, message}` |
| `stateRevision` | optional | revision of the agent state the call observed |

### Idempotency semantics

Any request that carries `commandID` is keyed in a bounded replay cache
(1024 entries, 5-minute TTL, oldest-inserted evicted). A retry with the same
`commandID` returns the **cached response verbatim** (only `requestID` is
rewritten to the new request's ID) instead of re-executing. Consequences:

- `agent.prompt` retried after an ambiguous failure returns the original
  receipt; the text is delivered to the terminal **exactly once**
  (verified by integration test counting terminal deliveries).
- Errors are cached too: retrying a failed command replays the same failure.
- Streaming headers (`events.subscribe`) are cached so a retry does not
  subscribe twice; event frames themselves are never replayed.
- Because per-connection processing is serial and the server handles each
  request to completion before reading the next line, there is no in-flight
  window: a duplicate can only arrive after the original result was cached.

---

## Methods (closed set)

Any other method string → `unknownMethod`. `params` shown as typed fields;
all results are JSON objects.

### `system.ping`
Params: none.
Result: `{"protocolVersion":1,"implementation":"agent-terminal-control"}`.
Used by clients as the version handshake.

### `workspace.list`
Params: none.
Result: `{"workspaces":[{"id","name","rootPath","agents":[agentID…]}]}`.

### `agent.create`
Params: `workspaceID`, `kind` (`claude-code|codex|opencode|generic-shell`),
`workingDirectory`, `displayName`, `taskSummary?`.
Result: `{"agentID"}`. Creates the agent in `starting`; the actual launch is
reported by `launcher.started`.
Errors: `launchFailed` (unknown kind / adapter refusal), `agentNotFound`
(unknown workspace).

### `agent.list`
Params: `workspaceID?` (filter).
Result: `{"agents":[AgentSummary…]}`.

### `agent.get`
Params: `agentID`.
Result: `{"agent":AgentSummary}`, `stateRevision` set.
Errors: `agentNotFound`.

### `agent.prompt`
Params: `agentID`, `text`, `policy?` = `sendNow` (default) |
`queueWhenIdle` | `rejectUnlessIdle`.
Result: `{"receipt":{"commandID","agentID","outcome":"delivered"|"queued"}}`
— `commandID` here is the runtime-minted delivery identity (distinct from
the envelope's idempotency key).
Errors: `invalidLifecycle`, `waitingForTerminalInput`,
`queuedPromptAlreadyExists`, `terminalUnavailable`, `agentNotFound`.
Semantics follow §3.11 exactly (queued prompts drain only at validated idle;
delivery failures surface as events, never auto-retries).

### `agent.cancelQueuedPrompt`
Params: `agentID`. Result: `{}`. Removes only the queued prompt; the agent
does not change (§3.18 cancellation rules).

### `agent.focus`
Params: `agentID`. Result: `{}`. Marks the agent visible/active for
attention bookkeeping.

### `agent.read`
Params: `agentID`, `source?` = `visible` (default) | `detection`.
MVP sources per §3.16: `visible` (current viewport) and `detection` (live
bottom screen used by the detector). `recent scrollback` is NOT promised
until the Ghostty API confirms it.
Result: `{"text","outputRevision","generation"}`.
Errors: `semanticStateUnavailable`, `terminalUnavailable`, `agentNotFound`.

### `agent.wait`

Params:

| Field | Type | Meaning |
|---|---|---|
| `agentID` | uuid | agent to watch |
| `targetLifecycle` | string[] | subset of the closed vocabulary below |
| `minStateRevision` | uint? | succeed only at revisions ≥ this value |
| `timeoutMs` | uint? | default 60000 |

Closed lifecycle vocabulary (no arbitrary code execution):
`unknown, starting, idle, working, waitingForInput, stopping, stopped, failed`.

Result (matched): `{"matched":true,"stateRevision":N,"lifecycle":"idle"}`.
Result (deadline): `{"matched":false,"reason":"timeout","lastKnownRevision":N}`.

**Algorithm** (implemented once in `waitForLifecycle`; no polling anywhere):

1. Read the current state.
2. Check the predicate against it.
3. Subscribe to the runtime delta stream.
4. RE-check the revision after subscribing — any transition between step 1
   and step 3 is already reflected in this second read, closing the
   lost-wakeup race deterministically (integration-tested with scripted
   reads and zero deltas).
5. Await a matching event or the timeout.
6. On client disconnect return structured cancellation
   (`{"code":"cancelled", …}`); the subscription is torn down cleanly.

### `agent.interrupt`
Params: `agentID`. Result: `{}`. SIGINT-equivalent intent (§3.11).

### `agent.stop`
Params: `agentID`, `mode?` = `gracefulStop` (default) | `closeView`.
(`interrupt` has its own method.) Result: `{}`.
`gracefulStop` = SIGTERM process group + 2 s grace + SIGKILL; `closeView`
detaches without signalling.

### `agent.resume`
Params: `agentID`. Result: `{}`.
Errors: `resumeUnsupported`, `resumeReferenceMissing`.

### `events.subscribe` {#streaming}

Params: `agentID?` (filter; omit for all agents).

Response header:
`{"requestID":"…","ok":true,"result":{"subscriptionID":"…"}}`.

Afterwards the server streams one notification frame per state change until
the client disconnects (Ctrl-C on the CLI):

```json
{"subscriptionID":"…","event":"agentChanged","agent":{AgentSummary}}
```

Backpressure policy: each subscriber keeps only the most recent deltas
(buffer capacity 64); slower consumers coalesce intermediate deltas away.
This is lossless for state-based consumers because every `agentChanged`
frame carries the full current summary — dropping intermediates skips
intermediate revisions but never stale-ends the current state. Consumers
needing every intermediate transition must use the persisted timeline, not
the live stream.

Disconnect teardown is active: a close watcher on the socket detaches the
subscriber even if no frames were ever flowing.

## AgentSummary shape

```json
{"id","workspaceID","kind","displayName","taskSummary",
 "lifecycle":"idle|working|…","processPhase":"running|exited|…",
 "authority":"integration|screen|process|unknown",
 "attention":"none|completionUnread|inputRequired|failure",
 "stateRevision":N,
 "hasQueuedPrompt":bool,"turnActive":bool,"hasSessionReference":bool}
```

---

## Hook authentication

Each process generation gets a random scoped token:

- minted by the app at launch time, handed to the child through the
  ephemeral launch environment (`AGENT_TERMINAL_TOKEN` inside the launch
  ticket), never persisted;
- validated by `HookAuthenticator` against the registry of the CURRENT
  generation; restart invalidates the old token when the app registers the
  successor generation;
- prevents accidental cross-agent reports.

Report methods:

### `integration.report`

Params: `agentID`, `terminalID?`, `surfaceGeneration`, `source`, `seq?`,
`lifecycle?` (closed tag), `sessionReference?` (opaque object), `token`.

Verdicts:

| Condition | Response |
|---|---|
| token wrong / agent unregistered | `unauthorized` error |
| generation ≠ registered generation, or source already released | `staleGeneration` error |
| `seq ≤ lastAcceptedSeq` for (agent, source) | ok:true `{"accepted":false,"duplicate":true,"lastAcceptedSequence":N}` — ack without creating an event (§3.6) |
| otherwise | ok:true `{"accepted":true}`; evidence ingested into the runtime |

Sequence gaps are accepted but recorded in diagnostics (§3.6). `observedAt`
is never used for ordering — external clocks are untrusted; the server
stamps its own monotonic receipt time.

### `integration.release`

Params: `agentID`, `surfaceGeneration`, `source`, `token`.
Validates like a report, then releases the lease and runs the runtime's
integration-expiry fallback (§3.5 last row). Later reports from that source
are rejected as stale. Result: `{"released":true}`.


#### Helper wire shape

The launcher sends these reports as standard v1 request envelopes over the
same NDJSON socket — identical framing to every other client request, one
object per line:

```json
{"protocolVersion":1,"requestID":"<uuid>","method":"launcher.started",
 "params":{"agentID":"<uuid>","terminalID":"<uuid>","surfaceGeneration":42,
           "pid":1234,"processGroupID":1234,"token":"<ticket token>"}}
{"protocolVersion":1,"requestID":"<uuid>","method":"launcher.failed",
 "params":{"agentID":"<uuid>","surfaceGeneration":7,
           "reason":"execve errno 2","token":"<ticket token>"}}
```

The `token` is the ticket's `integrationToken` (the generation-scoped hook
token). Reports are strictly fire-and-forget: the helper never reads the ack
and treats every send failure as silent (§3.9).

### `launcher.started`

Params: `agentID`, `terminalID`, `surfaceGeneration`, `token`, `pid?`,
`processGroupID?`, `seq?`. Validates the ticket-generation token, then
forwards `surfaceCreated` into the runtime (§3.5 row 2).
Result: `{"acknowledged":true}`.

### `launcher.failed`

Params: `agentID`, `surfaceGeneration`, `reason`, `token`, `seq?`.
Validates the token, then feeds a failed lifecycle observation from the
`launcher` source. Result: `{"acknowledged":true}`.

### Threat-model boundary

The token protects against *accidental* cross-agent or stale-generation
reports. It is **not** a defense against a malicious process running as the
same Unix user: any local user process can connect to a 0600 socket it owns
and could read the environment of its own children. The app threat model is
a **trusted local user** (§3.16). Hardening beyond that (peer credential
checks, per-report nonces) is deliberately out of scope for v1.

---

## Error codes (stable)

Clients branch on `code` only; messages may change freely.

| Code | Source |
|---|---|
| `badRequest` | malformed envelope/params |
| `unsupportedProtocolVersion` | version mismatch |
| `unknownMethod` | method outside the closed set |
| `payloadTooLarge` | >1 MiB frame (connection closes) |
| `cancelled` | long-running operation cancelled (disconnect/server) |
| `commandInFlight` | same commandID already executing on another connection; retry to obtain the idempotency-cached result (§3.16 exactly-once) |
| `unauthorized` | hook token wrong or unregistered generation |
| `staleGeneration` | superseded surface generation / released source |
| `agentNotFound`, `terminalUnavailable`, `invalidLifecycle`, `waitingForTerminalInput`, `queuedPromptAlreadyExists`, `semanticStateUnavailable`, `resumeUnsupported`, `resumeReferenceMissing`, `launchFailed`, `promptDeliveryUnconfirmed`, `timeout`, `persistenceDegraded` | 1:1 mapping of the §3.11 runtime taxonomy |
| `internalError` | catch-all; message is generic by design (no internals leaked) |

---

## `agentctl` CLI

```text
agentctl [--socket PATH] <command>
  system ping
  workspace list
  agent create --workspace ID --kind K --dir PATH --name NAME [--task-summary S]
  agent list [--workspace ID]
  agent get AGENT_ID
  agent prompt AGENT_ID TEXT... [--policy P] [--command-id UUID]
  agent wait AGENT_ID --lifecycle idle,working [--min-revision N] [--timeout-ms N]
  agent read AGENT_ID [--source visible|detection]
  agent focus|interrupt|stop|resume|cancel-queued-prompt AGENT_ID
  events subscribe [--agent AGENT_ID]        # streams NDJSON until Ctrl-C
  integration report|release …               # hook scripts; token from
                                             # --token or $AGENT_TERMINAL_TOKEN
  launcher started|failed …                  # helper-process reports
```

- Output is the raw response envelope as JSON on stdout; exit code 0 on
  `ok:true`, 1 on errors (2 on an unmatched wait deadline).
- Every invocation performs the `system.ping` version handshake first.
- `agent wait` is implemented EVENT-DRIVEN via `events.subscribe`: initial
  read → predicate → subscribe → re-read → await matching frames until the
  deadline. No polling loops.
