# ADR-0003: Agent lifecycle state machine and authority

- Status: Placeholder — authored by Stage 2 (pure AgentCore) and Stage 8
  (runtime orchestration), per architecture notes §6.2/§6.8.
- Will record: the `AgentState` transition table, `StateAuthorityResolver`
  evidence precedence, turn tracking rules, and anti-flicker hysteresis
  (architecture §3.4–§3.6).

## Decision

(pending) — Until this ADR is filled in, the binding rules are:

1. Only `AgentRuntime` may mutate `AgentState` (architecture §3.5).
2. Authority precedence: full lifecycle integration > screen manifest >
   process observation (§3.6).
3. No screen rule may ever generate an automatic approval action; prompts are
   terminal-only by default (§5.1, critical risk).
