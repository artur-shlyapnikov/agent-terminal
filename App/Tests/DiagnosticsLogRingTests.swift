@testable import AgentTerminal
import XCTest

// Round-3 Suite J (R3-5): DiagnosticsLogRing 500-line eviction + record-time
// redaction. The test exercises a fresh DiagnosticsLogRing instance so the
// process-global shared ring is never polluted.

@MainActor
final class DiagnosticsLogRingTests: XCTestCase {
    func testRingCapsAtFiveHundredLinesAndRedactsAtRecordTime() throws {
        let ring = DiagnosticsLogRing()
        let baseline = ring.lines.count

        // Record 505 distinct numbered lines; one carries a hostile secret.
        let secretSlot = 250
        for i in 1 ... 505 {
            let entryNumber = baseline + i
            if i == secretSlot {
                ring.record("export ATERM_TOKEN=supersecret value")
            } else {
                ring.record("diag-entry[\(entryNumber)]")
            }
        }

        // Capped at exactly 500 entries (baseline + 505 evicts down to 500).
        XCTAssertEqual(ring.lines.count, 500)

        // The LAST line is the sanitized 505th message.
        let last = try XCTUnwrap(ring.lines.last)
        XCTAssertTrue(
            last.contains("diag-entry[\(baseline + 505)]"),
            "unexpected last line: \(last)"
        )

        // Oldest-evicted arithmetic: exactly 500 of baseline+505 lines are
        // retained, so the FIRST retained line is entry
        // `baseline + 505 − 500 + 1` and its predecessor is gone.
        let first = try XCTUnwrap(ring.lines.first)
        XCTAssertTrue(
            first.contains("diag-entry[\(baseline + 505 - 500 + 1)]"),
            "unexpected first retained line: \(first)"
        )
        XCTAssertFalse(
            ring.lines.contains { $0.contains("diag-entry[\(baseline + 5)]") },
            "entry beyond the cap must have been evicted"
        )

        // Record-time redaction: the stored line carries the placeholder and
        // never the raw secret (render-time scrubbing alone is not trusted).
        let secretLines = ring.lines.filter { $0.contains("ATERM_TOKEN") }
        XCTAssertEqual(secretLines.count, 1, "the secret line must be retained exactly once")
        let secretLine = try XCTUnwrap(secretLines.first)
        XCTAssertTrue(secretLine.contains("ATERM_TOKEN=<redacted>"))
        XCTAssertFalse(secretLine.contains("supersecret"))

        // Every stored line carries the "[" timestamp prefix from record().
        XCTAssertTrue(ring.lines.allSatisfy { $0.hasPrefix("[") })
    }
}
