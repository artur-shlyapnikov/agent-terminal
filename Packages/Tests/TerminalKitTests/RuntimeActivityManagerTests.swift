@testable import TerminalKit
import XCTest

// Round 8 Suite D (R8-7): RuntimeActivityManager §4.3 ref-count laws —
// token acquired at the FIRST holder, released at the LAST, `end` clamps at
// zero (no underflow/double-release), and re-acquisition works after release.
// Failure modes defended: App Nap suspending a hidden working agent (stall
// that looks like a hang) or a leaked userInitiated activity draining battery.

@MainActor
final class RuntimeActivityManagerTests: XCTestCase {
    func testActivityLatchesAtFirstHolderReleasesAtLastAndClampsBelowZero() {
        // 1. Fresh manager: no activity, no holders.
        let manager = RuntimeActivityManager()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.activeCount, 0)

        // 2. Two begins: token acquired ONCE at the first holder; the second
        // begin only bumps the count.
        manager.beginWorkingActivity()
        manager.beginWorkingActivity()
        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(manager.activeCount, 2)

        // 3. One end: the latch must HOLD for the remaining holder — a
        // premature release would let App Nap suspend a working agent.
        manager.endWorkingActivity()
        XCTAssertTrue(manager.isActive, "activity released while a holder remained")
        XCTAssertEqual(manager.activeCount, 1)

        // 4. Second end: last holder left → token released exactly once.
        manager.endWorkingActivity()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.activeCount, 0)

        // 5. Unbalanced third end: count clamps at zero, still inactive, no
        // crash (underflow regression would trap or double-release the token).
        manager.endWorkingActivity()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.activeCount, 0)

        // 6. Re-acquisition after release works again — a stuck-nil/stuck-
        // token regression shows here.
        manager.beginWorkingActivity()
        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(manager.activeCount, 1)

        // Balance the final holder so no NSProcessInfo activity leaks past
        // the test process.
        manager.endWorkingActivity()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.activeCount, 0)
    }
}
