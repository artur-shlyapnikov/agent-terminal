# ADR-0002: libghostty boundary and commit pinning

- Status: **Accepted** (validated by stage-0 architecture spike, 2026-08-23)
- Pin: Ghostty `da5ddcb0857c0e4ddb32f7a089911e9038d040f3` (main @ v1.3.2-dev), zig 0.16.0
- Evidence: `Spike/RESULTS.md`, harness `cd Spike && swift run spike-harness`
- Local patches to libghostty: **none required** (`Vendor/Ghostty/patches.md` stays empty)

## Decision

AgentTerminal embeds the vendored static `libghostty-internal.a` (arm64,
release_fast) exclusively behind a C bridge owned by `TerminalKit`. No Swift
file outside `TerminalKit` imports `ghostty.h`. The pin is immutable; upgrades
re-run this spike suite as a smoke gate.

## Build recipe (validated)

- `Scripts/build-ghostty-xcframework.sh` → `Vendor/Ghostty/build/`
  - `lib/libghostty-internal.a` (135 MB, non-fat arm64)
  - `include/ghostty.h` + `module.modulemap`
- Spike SwiftPM package links with:
  `-lghostty-internal -lc++` and frameworks `Metal, CoreVideo,
  CoreFoundation, CoreGraphics, CoreText, Foundation, IOSurface, QuartzCore,
  Carbon`.
- Header isolation gotcha: the vendored include dir carries its own
  `module.modulemap` (module `GhosttyKit`) which pollutes the clang module
  graph of dependents. Consumers must compile against an isolated copy of
  `ghostty.h` (the spike keeps a SHA-256-verified copy in
  `Spike/Sources/CGhostty/include/`).

## API findings

1. **Mandatory bootstrap.** Any API call before `ghostty_init(0, &argv)`
   segfaults inside `ghostty_config_new` (null global deref). Every process
   must call `ghostty_init` exactly once before all other calls.
2. **Runtime config is cloned at `ghostty_app_new`.** The `userdata` pointer
   set in `ghostty_runtime_config_s` *after* app creation never reaches
   callbacks (all callbacks then observe NULL userdata). Callback context must
   be installed before `ghostty_app_new`; route through a stable box wired to
   the runtime afterwards.
3. **Screen reads / POINT semantics — VERDICT for plan §3.7 critical
   validation.** `ghostty_surface_read_text(surface, selection, text_out)`
   with `GHOSTTY_POINT_SCREEN` corners (TOP_LEFT → BOTTOM_RIGHT) returns the
   live active screen including scrollback, **byte-identical regardless of
   viewport scroll position**, and always contains the latest produced rows.
   This satisfies the detection requirement ("snapshot does not depend on user
   scroll") without any vendored patch.
   - Residual limitation: moving the viewport programmatically via
     `ghostty_surface_mouse_scroll` required a large positive delta
     (dy=+30 moved it; small/negative deltas did not). Invariance held under
     all wheel input. Manual UI-phase verification should confirm
     `POINT_VIEWPORT` behaviour on real wheel events; if it ever fails, the
     planned minimal patch
     `agent_ghostty_surface_read_active_screen(surface, bottomRowCount, out)`
     remains the fallback.
4. **Keyboard delivery.** `ghostty_surface_key` with macOS virtual keycodes +
   UTF-8 `text` encodes and echoes correctly once the text pointer is pinned
   for the call duration (Swift caveat: string→pointer bridging inside a
   by-value C struct is not lifetime-guaranteed; use `utf8CString`
   explicitly). Return value `true` = consumed/encoded.
   `ghostty_surface_text` (IME-style commit) works independently and is safe;
   `ghostty_surface_preedit` begin/cancel cycles are crash-safe. Full IME
   composition remains manual-verification scope for stage 5.
5. **Child process exit.** `SHOW_CHILD_EXITED` action fires with payload
   `child_exited.exit_code` — verified in an isolated single-surface runtime
   (`spike-threadprobe`: `/bin/true` → tag 58 exit 0, `/bin/false` → exit 1)
   plus pollable `ghostty_surface_process_exited()`. However, inside the full
   multi-surface harness the action was NOT delivered and `process_exited()`
   stayed false for short-lived commands, even though their output appeared on
   screen (exact-command argv launch itself is proven by the on-screen
   marker). **Open item for stage 3:** reproduce the suppression (suspected
   many-live-surfaces interaction; config sensitivity also observed — adding
   `scrollback-limit` to the app config suppressed delivery) and make
   poll-based `process_exited` the primary lifecycle signal, with the action
   as an accelerator. Upstream additionally notes Darwin exit-code fidelity
   issues for fast exits (`abnormal_command_exit_runtime_ms` path), so exit
   codes must be treated as best-effort regardless.
6. **Exact argv command launch.** `surface_config.command` accepts a full argv
   string parsed without a shell (`/bin/echo MARKER` verified); env vars and
   initial_input are honored.

## Teardown policy (checks 12–13)

**Chosen policy: main-thread-only, two-phase teardown with generation-guarded
callback box.**

1. Mark surface closing (generation guard rejects new UI/runtime commands).
2. Remove surface from the runtime registry (callbacks become inert by
   identity).
3. Call `ghostty_surface_free` on the main thread only.
4. Release the retained callback box only after free returns.

Thread experiment: the isolated probe dispatched `ghostty_surface_free` off
the main thread while ticking was paused, then resumed ticking — it **survived**
(exit 42) in the exercised scenario. Upstream macOS app nevertheless creates
and frees surfaces synchronously on the main thread and threading of
`ghostty_surface_free` is undocumented; we adopt the conservative policy above
regardless of the single observed survival.

## Stability & capacity results

- Park/mount reparent hidden↔visible window: 20 cycles (plan asks ≥20; risk
  register's 100-cycle criterion deferred to TerminalKit integration tests),
  same PTY/generation, output uninterrupted.
- Hidden/occluded processing: full marker stream observed while window ordered
  out + occlusion flagged.
- 16 concurrent long-lived surfaces: all alive, distinct PIDs.
- 100 sequential create/free cycles: completed without crash or hang; footprint
  growth negligible over samples every 25 cycles.

## Open risks / stop-go criteria (plan §5.1)

| Risk | Status | Criterion |
|---|---|---|
| Active-screen API behaves like viewport | **Closed (go)** | Screen read invariant under scroll — verified |
| Hidden surface doesn't run/update | **Closed (go)** | Occluded markers streamed while invisible |
| Reparent instability | **Closed (go)** at 100 cycles | Stage-3 spike-terminalkit ran 100 clean park/mount cycles, generation unchanged, output flowing (see ADR note below) |
| Child-exit action suppressed in multi-surface context | **Open (does not block stage 3)** | Isolated delivery + exit codes proven; poll-based lifecycle primary until reproduced |
| Late callback/UAF on free | **Closed (go)** with policy | Two-phase teardown; sanitizer pass recommended in CI before stage 4 sign-off |
| Internal API drift | Mitigated | Commit pin + this suite as smoke gate |

## Stage-3 addendum: 100-cycle reparent criterion closed

`Spike/Sources/spike-terminalkit` (stage 3) exercised the real TerminalKit
stack over the pinned library and repeated park/mount reparent cycles
**100 times** between the hidden parking window and a second host window:
zero failures, `SurfaceGeneration` unchanged across all cycles, PTY identity
preserved, and detection-grade SCREEN reads still returning fresh child output
afterwards. The risk-register criterion "extend to 20 cycles during stage 3"
is therefore met and closed. Same run also completed 20/20 sequential
create/free teardown cycles through the two-phase teardown queue.

## Verdict

**GO** — proceed to TerminalKit/GhosttyBridge implementation (stage 3+) with
main-thread teardown policy; no libghostty patches required.
