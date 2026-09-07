@testable import AgentCore
import XCTest

// Stage-16 gate 6c: manifest adapterVersionRange demotion logic.

final class AdapterVersionRangeTests: XCTestCase {
    func testParseAndSatisfy() {
        XCTAssertTrue(AdapterVersionRange.violates(range: ">=0.4 <2.0", version: "999.0"))
        XCTAssertFalse(AdapterVersionRange.violates(range: ">=0.4 <2.0", version: "0.9.2"))
        XCTAssertFalse(AdapterVersionRange.violates(range: ">=0.4 <2.0", version: "1.99.99"))
        XCTAssertTrue(AdapterVersionRange.violates(range: ">=1.0 <3.0", version: "3.0.0"))
        XCTAssertTrue(AdapterVersionRange.violates(range: ">=1.0 <3.0", version: "0.9"))
        XCTAssertFalse(AdapterVersionRange.violates(range: ">=1.0 <3.0", version: "1.0"))
        XCTAssertFalse(AdapterVersionRange.violates(range: ">=1.0 <3.0", version: "2.99"))
        // Equality constraint.
        XCTAssertTrue(AdapterVersionRange.violates(range: "=2.1", version: "2.2"))
        XCTAssertFalse(AdapterVersionRange.violates(range: "=2.1", version: "2.1"))
        // Missing components pad to zero.
        XCTAssertTrue(AdapterVersionRange.violates(range: "<=1.0", version: "1.0.1"))
    }

    func testMissingInputsNeverViolate() {
        // Absence of evidence must not demote detection (§3.7).
        XCTAssertFalse(AdapterVersionRange.violates(range: nil, version: "1.0"))
        XCTAssertFalse(AdapterVersionRange.violates(range: ">=1.0", version: nil))
        XCTAssertFalse(AdapterVersionRange.violates(range: "", version: ""))
        XCTAssertFalse(AdapterVersionRange.violates(range: "garbage", version: "not-a-version"))
    }

    func testExtractVersionFromProbeLine() {
        XCTAssertEqual(AdapterVersionRange.extractVersion(from: "opencode 999.0.0"), "999.0.0")
        XCTAssertEqual(AdapterVersionRange.extractVersion(from: "1.2.9"), "1.2.9")
        XCTAssertEqual(AdapterVersionRange.extractVersion(from: "claude-code v4, build 7"), "4")
        XCTAssertNil(AdapterVersionRange.extractVersion(from: "no digits here"))
        XCTAssertNil(AdapterVersionRange.extractVersion(from: ""))
    }

    func testBundledManifestRangesRejectNewerMarker() throws {
        let opencode = try ScreenManifestLoader.loadBundled(named: "opencode")
        let reason = Stage16FallbackReasonStub.evaluate(
            range: opencode.adapterVersionRange, detectedLine: "opencode 999.0.0"
        )
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("999") == true)

        let claude = try ScreenManifestLoader.loadBundled(named: "claude-code")
        XCTAssertNotNil(Stage16FallbackReasonStub.evaluate(
            range: claude.adapterVersionRange, detectedLine: "claude 8.0"
        ))
    }
}

/// Test seam mirroring DetectionPipeline.fallbackReason wiring.
enum Stage16FallbackReasonStub {
    static func evaluate(range: String?, detectedLine: String) -> String? {
        let version = AdapterVersionRange.extractVersion(from: detectedLine)
        guard AdapterVersionRange.violates(range: range, version: version) else { return nil }
        return "adapter version \(version ?? "?") outside manifest range \(range ?? "?")"
    }
}
