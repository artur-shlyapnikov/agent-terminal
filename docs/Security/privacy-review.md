# Privacy review: §3.20 checklist (stage-16 gate 7)

Status: **reviewed for the stage-16 release gate**. Evidence pointers are grep
audits over the current tree; each item lists where the guarantee lives and how
it was verified. Re-run the greps after any change touching persistence,
diagnostics, or the control plane.

## 1. What leaves the machine?

Nothing leaves the machine during normal app operation. AgentTerminal is a
local-only application: it uses one Unix-domain socket at
`~/Library/Application Support/AgentTerminal/runtime/control.sock`, mode
`0600` (§3.16), plus a SQLite store in `~/Library/Application Support/AgentTerminal/`.
The app has no HTTP client, telemetry, or crash-reporter uploader. Setup and
build scripts are different. They fetch SwiftPM dependencies, the pinned
Ghostty source, and the matching Zig toolchain.

Evidence: `grep -rn "URLSession\|dataTask\|NWConnection" Packages/Sources App/Sources`
found no matches outside test fixtures.

## 2. Prompts must not be persisted or logged

| Surface | Guarantee | Evidence |
|---|---|---|
| SQLite store | Prompt text is never written; agent rows carry lifecycle tokens + opaque session references only (`AgentRow` schema, §3.14) | `grep -rn "prompt" Packages/Sources/AgentStore` finds only queued-prompt bookkeeping without text payload; EventPayloadCodec tests assert no free text |
| Diagnostics bundle | `DiagnosticRedactor` scrubs env-style assignments and prompt-shaped lines before export | App/Sources/DiagnosticsExport.swift (redaction law comment, DoD #14); unit-tested in App tests |
| DiagnosticsLogRing | Receives entries only from explicit lifecycle sites. It never receives prompts or output. | DiagnosticsExport.swift class doc; call sites audited: launch, restore, shutdown, install-recording failures |
| Logs | `print` lines carry state transitions, pids, and paths. They never carry composer text. | `grep -rn "text)" App/Sources | grep print` audit clean |

## 3. Environment variables must not be persisted or logged

Launch tickets embed `AGENT_TERMINAL_TOKEN` etc., but tickets are one-shot
`0600` files deleted by `AgentLauncher` immediately after spawn
(LaunchTicketWriter + TicketConsumer). The diagnostics redactor also
scrubs `VAR=value` shapes from exported lines
(`DiagnosticRedactor.sanitize`, exercised by ReviewFixTests).

## 4. Terminal output must not be persisted

Screen snapshots live only in engine memory. The detection pipeline evaluates
them in-process and forwards LIFECYCLE verdicts, never text, to the runtime.
The SQLite schema has no output column (§3.14 table set).

Evidence: `grep -rn "output\|snapshot" Packages/Sources/AgentStore` found no
schema or storage hits.
DetectionPipeline ingests `.screen(payload)` with rule IDs only.

## 5. Access control on IPC

- Socket: mode-checked `0600` at accept time; protocol handshake requires
  `protocolVersion == 1`.
- Hook reports: per-process-generation random token (`HookAuthenticator`,
  §3.16); wrong or stale tokens return `unauthorized` or `staleGeneration`.
- Threat model boundary: trusted local user (docs/Security/threat-model.md).

## 6. Data minimization in persisted installs

Integration fingerprints record location identity and generated boilerplate
content only (`ManagedEntryFingerprint`). They never record user file content
beyond the managed sections. The diagnostics exporter prints paths and marker
presence, not content (DiagnosticsExport.swift says managed content is
AgentTerminal-generated boilerplate).

## 7. Retention & deletion

Quarantined corrupt databases are preserved byte-for-byte under
`Application Support/AgentTerminal/backups/` (stage-16 gate 6a) so an operator
can delete them deliberately; nothing else outlives the workspace.

## 8. Known residual risks

1. `agentctl` CLI output includes agent summaries (state, cwd). This is
   acceptable because the same Unix user already owns these processes.
2. OS crash logs may include stack frames. This is standard macOS behavior, and
   no prompt content is passed into crashing APIs.
