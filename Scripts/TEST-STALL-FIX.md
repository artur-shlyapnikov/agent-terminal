# Full-suite test stall: root cause and fix (2026-08-23)

## Symptom

`swift test` over the whole AgentTerminal package reproducibly suspended
mid-run (observed at `PromptWatchdogTests.testTimeoutAfterFiveSecondsWithoutSignals`;
an earlier run wedged inside `PromptQueueTests`). Every suite passed in
isolation. That result did not indicate cross-suite interference.

## Root cause

A virtual-clock arming race in the watchdog unit test, amplified by Swift
concurrency actor-isolation rules:

1. `PromptWatchdogTests` is `@MainActor`, so the unstructured task
   `Task { await watchdog.watch(commandID:) }` inherits MainActor isolation.
   It cannot run while the test body holds the main actor, i.e. not before the
   test's first suspension point.
2. The test advanced `FakeClock` by 4 999 ms + 1 ms **synchronously** before
   that suspension could let `watch` arm.
3. When `watch` finally ran, `deadline = clock.now + .seconds(5)` was computed
   from the already-advanced clock (~5 s), so its sleeper deadline landed at
   ~10 s of virtual time that nobody would ever advance to.
4. The test then awaited `watchTask.value` forever. XCTest's async-test waiter
   parked the main thread in a runloop wait (`XCTWaiter _performWait`,
   `CFRunLoopRunSpecific`, and `mach_msg`). This froze the whole xctest worker
   and the parallel full-suite run.

Sampling evidence (`sample <wedged xctest pid>`): the main thread parked in
mach_msg inside XCTWaiter's runloop. The cooperative pool made no progress. The
armed sleeper waited for a virtual instant that never arrived.

Isolation runs passed when timing let `watch` arm before the first `advance`.
That timing was not guaranteed after hundreds of earlier tests had warmed the
process. The result was "passes alone, hangs in the full suite".

## Fix (test-side)

`Packages/Tests/AgentCoreTests/PromptWatchdogTests.swift`
(`testTimeoutAfterFiveSecondsWithoutSignals`): arm the watch at virtual time
zero **before** moving the clock, using the same guard already present in
`testWrongCommandIDDoesNotResolveWatch`:

```swift
let watchTask = Task { await watchdog.watch(commandID: commandID) }
await eventually("watch armed") { await watchdog.isWatching(commandID: commandID) }
clock.advance(by: .milliseconds(4_999))
clock.advance(by: .milliseconds(1))
```

No production code changes were needed: runtime-level tests already arm-wait
via `eventually("watch armed") { await runtime.isDeliveryWatchArmed(...) }`
before advancing the shared `FakeClock`.

CI (`.github/workflows/ci.yml`) keeps per-target parallel workers
(`swift test --parallel`, made explicit).

## Residual notes

- `FakeClock.sleepUntil` treats an already-elapsed deadline as immediate
  return, so arming after an advance is safe as long as tests don't rely on a
  *future* virtual deadline computed from post-advance time. Keep the
  arm-before-advance pattern for any new virtual-time test.
- Vendored libghostty lives in repo-root `Vendor/Ghostty/build/`.
  `Packages/Package.swift` resolves that path from the package directory, so no
  `Packages/Vendor` symlink is required. CI and local builds must still
  provision the built library before `swift build` can link TerminalKit
  targets.
