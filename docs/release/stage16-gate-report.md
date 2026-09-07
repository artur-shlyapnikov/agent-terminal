# Stage-16 Gate Report — Release Evidence

Executed on the delivery machine against the committed MVP tree
(`App/AgentTerminal.app`, Debug build, hermetic DB + ghostty config dirs).

## Soak gate (DoD §3.24 item 4, §3.21)

Command:

```bash
ATERM_SCENARIO=soak ATERM_SOAK_SECONDS=1800 \
  ATERM_DB_PATH=<hermetic>/soak.sqlite \
  ATERM_GHOSTTY_CONFIG_DIR=<hermetic> \
  <app>/Contents/MacOS/AgentTerminal
```

Result: **exit 0**, `stage16-soak`, 8 concurrent shell agents alive for the full window.

| Metric | Value |
|---|---|
| Duration | 1811 s (~30.2 min) |
| Samples | 60 @ 30 s |
| Start footprint | 287.5 MiB |
| End footprint | 319.9 MiB |
| Peak footprint | 322.1 MiB |
| Growth | 32.4 MiB / 30 min |
| Leak slope | 9 785 B/s (gate < 100 000 B/s — pass with ~10× margin) |
| CPU total (all agents) | 111.2 s CPU over 1811 s wall |

Raw samples: `/tmp/aterm-s16-soak-samples.json` (transient; regenerate via the
command above — the gate itself asserts the slope and aliveness).

## Other stage-16 gates

Machine-verified in-tree (see `App/Sources/Stage16GatesScenario.swift` +
package/app test suites): capacity-16 surfaces, 100 create/free teardown
cycles through `TerminalSessionManager`, corrupt-DB quarantine,
broken-hook fallback + §5.3 conflict semantics, adapter version-range
fallback, approval→idle socket semantics, codesign/license/privacy audits.
CI runs the fast smoke subset (`corrupt-db`, `capacity16`, `teardown100`).

Manual-pending (deviations D5/D7): Sparkle/notarization procedure, physical
sleep/wake + display-lock + App Nap matrix checklist.
