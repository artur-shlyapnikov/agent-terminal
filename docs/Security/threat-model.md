# Local-user threat model

- Status: Placeholder — owned by Stage 4 (secure launch pipeline) and Stage 13
  (control protocol), per architecture notes §6.4/§6.13.
- Will record: assets (launch tickets, control socket, hook tokens, SQLite DB),
  adversaries (other local processes, malicious agent CLIs, hostile prompt
  content), and mitigations: 0600 one-shot launch tickets consumed by the fixed
  `AgentLauncher` helper (no shell-string argv assembly), per-process-generation
  scoped socket tokens, idempotency cache against duplicate prompts,
  terminal-only approval semantics, App Sandbox off + Hardened Runtime on with
  justification (architecture §3.9, §3.16, §3.20).

## Decision

(pending Stages 4/13) — Binding until then:

1. The app never builds shell command strings from untrusted parameters; all
   launches go through ticket files with restrictive permissions.
2. Every automation caller authenticates with a scoped token; no token, no
   mutation.
3. No code path may auto-confirm permission/approval prompts.
