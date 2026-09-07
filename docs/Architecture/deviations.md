# Sanctioned Deviations from architecture notes

Stage-16 hardening record. Each entry cites the section it deviates from.
The architecture document itself is never edited.

## D1. Corrupt-database handling (§3.15 Recovery Center scope)

**Deviation.** A corrupted SQLite file does not route into the Recovery
Center; instead `AgentDatabase.openWithCorruptionQuarantine` quarantines the
corrupt file byte-for-byte under `backups/AgentTerminal.corrupt-<timestamp>.sqlite`,
opens a fresh store, and raises a persistent degraded banner naming the backup
path.

**Rationale.** The Recovery Center is designed around crash-recovery
CANDIDATES (agents to re-launch). A corrupt store has no candidates — the
operator needs a visible quarantine notice, not a resume list. §3.15's law
"never silent data loss" is honored: corrupt bytes are preserved and the
banner is shown before any agent starts.

## D2. Broken-hook Repair semantics in the live gate (§5.3 step 5)

**Deviation.** None in product code — the gate proves that `install()` REFUSES
to overwrite a user-modified managed section (outcome `.conflict`) instead of
silently repairing it. "Repair" therefore restores health only after the
operator restores the drifted content (or deletes our section); uninstall is
fingerprint-gated for the same reason.

## D3. Inspector-level UI assertions in automation gates (§3.17/§3.22)

**Deviation.** The broken-hooks gate asserts the inspector's PROJECTION
(`RuntimeSeam.healthText(for:)` + `canRepair`) rather than pixel-level AppKit
state; the upgrade-sim gate composes the exact warning line the inspector
renders (`WARNING: screen detection fallback — <reason>`) and verifies the
pipeline records it per-agent. Rationale: headless scenario runs cannot
reliably assert rendered NSTextView contents; the rendering path itself is a
one-line mapping of the asserted projection.

## D4. Soak duration (§6.16 DoD: 30-minute soak target)

**Status at gate time:** the soak harness runs an operator-configurable window
(`ATERM_SOAK_SECONDS`, default 600 s; the driver passes 1800 for the full DoD
window) with 30-second CPU/footprint sampling and a least-squares leak-slope
assertion. Both 10-minute and full 30-minute runs are supported by the same
code path; see the stage-16 gate report for which durations were actually
executed and their measured numbers.

**Executed evidence:** docs/release/stage16-gate-report.md — full-window run
recorded 2026-08-23: 1811 s, 8 agents, 8/8 alive at end, leak slope
9 785 B/s (gate < 100 000 B/s), exit 0.

## D5. Sparkle / notarization (§4.6 distribution)

Out of scope for the MVP as sanctioned at stage 0. `Scripts/codesign-release.sh`
documents the inside-out signing order (helpers → app bundle), hardened-runtime
options, strict verification (`codesign --verify --deep --strict`), and the
insertion point for a future `notarytool submit` + staple step.

## D6. adapterVersionRange enforcement site (§3.7 Manifest format (adapterVersionRange))

**Deviation.** The bundled manifests carried `adapterVersionRange` since stage 7,
but enforcement now lives in the DETECTION PIPELINE (app layer): when the
detected adapter version violates the manifest range, launch proceeds, screen
detection remains the state source, but the source is MARKED fallback
(`DetectionPipeline.versionFallbacks`) and the inspector renders a warning.
Pure comparison logic is unit-covered (`AdapterVersionRange`,
AgentCore). The engine/hysteresis behavior is unchanged.

## D7. Sleep/wake, display lock, App Nap (§4.3 / DoD adverse conditions)

**Coverage at stage-16.**
- Automated: `RuntimeActivityManager` holds a `.userInitiated`
  `NSProcessInfo.beginActivity` token ref-counted per working surface
  (`TerminalSessionManager` begins on running-phase entry, ends exactly once
  on close/exit); the token's existence while agents work is observable via
  `isActive`. The teardown100/capacity16 gates exercise the begin/end
  transitions implicitly across hundreds of surfaces.
- Manual checklist (not automatable headlessly):
  1. Start a long-running agent; close the lid → on wake, output continues
     and no lifecycle regression occurred (verify timeline).
  2. With NO working agents, confirm App Nap is possible (Activity Manager →
     App Nap: Yes for idle AgentTerminal).
  3. With a working agent, confirm App Nap is inhibited (Process Tolerance).
  4. Lock the screen (⌘⇧Q … / Ctrl+⌘Q) during a working turn; unlock and
     verify attention states raised while locked still appear in ⌘⇧U.
  5. System sleep countdown must be postponed while a working agent exists
     (`pmset -g assertions | grep AgentTerminal` shows user-initiated
     assertion held).
