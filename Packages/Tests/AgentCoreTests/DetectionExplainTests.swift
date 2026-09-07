import AgentCore
import Foundation
import XCTest

// Round 4 residue: `DetectionExplain.screen` mapping (architecture §3.6).
// Zero prior test references to DetectionExplain/ExplainAuthority. The
// Inspector renders this payload; the "no numeric confidence" law expresses
// ambiguity structurally: an equal-priority conflict must demote authority to
// `.unknown` with a fallbackReason — a matched rule ID must never surface as
// authoritative despite conflicting evidence.

final class DetectionExplainTests: XCTestCase {
    func testScreenBuilderMapsMatchConflictAndIdentityPassthrough() {
        let manifest = ScreenManifest(
            manifestVersion: 3,
            agentKind: .claudeCode,
            foregroundExecutables: ["claude"],
            rules: []
        )
        let match = ScreenEvidencePayload(
            matchedRuleID: "r1",
            resultingLifecycle: .idle,
            supportingRules: ["r1"],
            conflictingRules: []
        )
        let conflict = ScreenEvidencePayload.unknown(reason: ["r1", "r2"])

        // Clean match: screen authority, no fallback reason, identity passthrough.
        let matched = DetectionExplain.screen(
            result: match,
            manifest: manifest,
            revision: 41,
            age: .milliseconds(7)
        )
        XCTAssertEqual(matched.authority, .screen)
        XCTAssertEqual(matched.matchedRuleID, "r1")
        XCTAssertTrue(matched.conflictingRuleIDs.isEmpty)
        XCTAssertNil(matched.fallbackReason)
        XCTAssertEqual(matched.snapshotRevision, 41)
        XCTAssertEqual(matched.observationAge, .milliseconds(7))
        XCTAssertEqual(matched.manifestID, "claude-code")
        XCTAssertEqual(matched.manifestVersion, 3)

        // Equal-priority conflict: unknown authority + structural reason, even
        // though a rule "won" on paper.
        let conflicted = DetectionExplain.screen(
            result: conflict,
            manifest: manifest,
            revision: 41,
            age: .milliseconds(7)
        )
        XCTAssertEqual(conflicted.authority, .unknown)
        XCTAssertNil(conflicted.matchedRuleID)
        XCTAssertEqual(conflicted.conflictingRuleIDs, ["r1", "r2"])
        XCTAssertEqual(conflicted.fallbackReason, "equal-priority rule conflict")
        XCTAssertEqual(conflicted.manifestID, "claude-code")
        XCTAssertEqual(conflicted.manifestVersion, 3)
    }
}
