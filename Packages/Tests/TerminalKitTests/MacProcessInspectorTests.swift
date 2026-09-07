import AgentCore
import Darwin
@testable import TerminalKit
import XCTest

// MacProcessInspector (§3.6): liveness + foreground executable via libproc,
// graceful degradation for dead/absent pids.

final class MacProcessInspectorTests: XCTestCase {
    private let inspector = MacProcessInspector()

    func testSelfProcessResolvesExecutablePathAndComputesMatch() async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let payload = try await inspector.inspect(
            terminalID: TerminalID(), pid: pid,
            foregroundExecutableCandidates: ["xctest"]
        )

        XCTAssertEqual(payload.pid, pid)
        XCTAssertNotNil(payload.executablePath)
        XCTAssertTrue(payload.executableName?.contains("xctest") ?? false)
        XCTAssertTrue(payload.matchesForegroundExecutables)

        // A non-matching manifest must compute false — the flag is no longer
        // hardcoded to true whenever the path resolves.
        let miss = try await inspector.inspect(
            terminalID: TerminalID(), pid: pid,
            foregroundExecutableCandidates: ["totally-other-agent"]
        )
        XCTAssertTrue(miss.matchesForegroundExecutables == false)

        // Full-path candidates match too.
        let pathHit = try await inspector.inspect(
            terminalID: TerminalID(), pid: pid,
            foregroundExecutableCandidates: [XCTUnwrap(payload.executablePath)]
        )
        XCTAssertTrue(pathHit.matchesForegroundExecutables)

        // Convenience overload without candidates never claims a match.
        let convenience = try await inspector.inspect(terminalID: TerminalID(), pid: pid)
        XCTAssertFalse(convenience.matchesForegroundExecutables)
    }

    func testDeadPidDegradesGracefully() async throws {
        // PID 1 always exists but is not signalable by us; a definitely-dead
        // pid is found via a short-lived child.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let deadPID = process.processIdentifier

        let payload = try await inspector.inspect(
            terminalID: TerminalID(), pid: deadPID,
            foregroundExecutableCandidates: ["anything"]
        )
        XCTAssertNil(payload.executablePath)
        XCTAssertFalse(payload.matchesForegroundExecutables)
        XCTAssertEqual(payload.pid, deadPID, "pid is still reported for diagnostics")
    }

    func testNilAndInvalidPidsProduceEmptyPayload() async throws {
        let nilPayload = try await inspector.inspect(terminalID: TerminalID(), pid: nil)
        XCTAssertNil(nilPayload.executablePath)
        XCTAssertFalse(nilPayload.matchesForegroundExecutables)

        let negativePayload = try await inspector.inspect(terminalID: TerminalID(), pid: -5)
        XCTAssertNil(negativePayload.executablePath)
    }

    // MARK: R21-MI1 — candidate matching case-folds on both sides, for bare

    // names AND absolute paths (MacProcessInspector.swift:51-52)

    func testCandidateMatchingCaseFoldsAcrossBareNamesAndFullPathForms() async throws {
        let pid = ProcessInfo.processInfo.processIdentifier

        // Bare-name candidates fold case.
        let bareUpper = try await inspector.inspect(
            terminalID: TerminalID(), pid: pid,
            foregroundExecutableCandidates: ["XCTEST"]
        )
        XCTAssertTrue(bareUpper.matchesForegroundExecutables)

        // Full-path form folds case too.
        let baseline = try await inspector.inspect(terminalID: TerminalID(), pid: pid)
        let pathUpper = try await inspector.inspect(
            terminalID: TerminalID(), pid: pid,
            foregroundExecutableCandidates: [XCTUnwrap(baseline.executablePath).uppercased()]
        )
        XCTAssertTrue(pathUpper.matchesForegroundExecutables)

        // Mixed-case candidate matches the lowercase process name.
        let mixed = try await inspector.inspect(
            terminalID: TerminalID(), pid: pid,
            foregroundExecutableCandidates: ["XcTeSt"]
        )
        XCTAssertTrue(mixed.matchesForegroundExecutables)

        // Negative control: folding must not WIDEN the match.
        let miss = try await inspector.inspect(
            terminalID: TerminalID(), pid: pid,
            foregroundExecutableCandidates: ["TOTALLY-OTHER-AGENT"]
        )
        XCTAssertFalse(miss.matchesForegroundExecutables)
    }

    // MARK: R21-MI2 — alive-but-unreadable-path degradation (EPERM leg)

    func testAliveButUnreadablePathPidDegradesToLivenessOnlyPayload() async throws {
        // PID 1 (launchd) is root-owned: from a non-root runner where its
        // path is unreadable, both proc_pidpath and kill(pid, 0) fail with
        // EPERM, landing in the alive-but-path-unreadable payload. Under a
        // root runner — or an environment whose proc_pidpath(1) is readable
        // (observed on some hosts) — the EPERM leg is unreachable: SKIP
        // rather than flake.
        try XCTSkipUnless(geteuid() != 0, "EPERM leg requires non-root runner")

        let payload = try await inspector.inspect(
            terminalID: TerminalID(), pid: 1,
            foregroundExecutableCandidates: ["launchd"]
        )
        guard payload.executablePath == nil else {
            throw XCTSkip(
                "proc_pidpath(1) returned \(payload.executablePath ?? "?"); EPERM leg unreachable here"
            )
        }
        XCTAssertNil(payload.executableName, "unreadable path must leave the name nil")
        XCTAssertFalse(payload.matchesForegroundExecutables)
        XCTAssertEqual(payload.pid, 1, "pid is still reported for diagnostics")
    }
}
