import AgentCore
@testable import TerminalKit
import XCTest

// Snapshot normalization (§3.7/§3.21): CRLF normalized, trailing spaces
// stripped, last-32-rows / 16 KiB caps, scroll-independent detection reads
// against a fake engine.

final class TerminalSnapshotServiceTests: XCTestCase {
    func testCRLFAndTrailingWhitespaceNormalized() {
        let raw = "line one  \r\nline two\t\r\r\nline three   \r\n"
        let result = TerminalSnapshotService.normalize(raw, maxRows: nil, maxBytes: nil)
        // "\r\r\n" carries an interior blank line (two CRs); only TRAILING
        // blank lines are dropped.
        XCTAssertEqual(result, "line one\nline two\n\nline three")
    }

    func testTrailingBlankLinesDropped() {
        let result = TerminalSnapshotService.normalize("a\nb\n\n\n", maxRows: nil, maxBytes: nil)
        XCTAssertEqual(result, "a\nb")
    }

    func testRowCapKeepsLastRows() {
        let lines = (1 ... 40).map { "row-\($0)" }
        let result = TerminalSnapshotService.normalize(
            lines.joined(separator: "\n"),
            maxRows: TerminalSnapshotService.detectionRowLimit,
            maxBytes: nil
        )
        let kept = result.split(separator: "\n")
        XCTAssertEqual(kept.count, 32)
        XCTAssertEqual(kept.first, "row-9")
        XCTAssertEqual(kept.last, "row-40")
    }

    func testByteCapKeepsTailAtLineBoundary() {
        var lines = [String]()
        for index in 0 ..< 200 {
            lines.append(String(repeating: "x", count: 100) + "-\(index)")
        }
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.utf8.count > TerminalSnapshotService.detectionByteLimit)

        let result = TerminalSnapshotService.normalize(
            text,
            maxRows: nil,
            maxBytes: TerminalSnapshotService.detectionByteLimit
        )

        XCTAssertLessThanOrEqual(result.utf8.count, TerminalSnapshotService.detectionByteLimit)
        // Cut must start at a line boundary — every retained line is intact.
        for line in result.split(separator: "\n") where line.contains("-") {
            guard let dash = line.lastIndex(of: "-"),
                  let n = Int(line[line.index(after: dash)...]) else { continue }
            let expectedLength = 100 + 1 + String(n).count
            XCTAssertEqual(line.count, expectedLength, "line \(n) must be intact")
            XCTAssertTrue(line.hasPrefix(String(repeating: "x", count: 100)))
        }
    }

    /// Bridge decode contract (review finding 6): `out_length` excludes the
    /// terminator but the payload may contain embedded NULs — decoding must
    /// use the exact byte count, not String(cString:), which truncates at the
    /// first NUL.
    @MainActor
    func testBridgeTextDecodePreservesEmbeddedNULs() {
        let bytes: [CChar] = [97, 0, 98, 99] // "a\0bc", length 4
        let decoded = bytes.withUnsafeBufferPointer { buffer -> String in
            GhosttySurfaceHandle.decodeBridgeText(buffer.baseAddress!, length: buffer.count)
        }
        XCTAssertEqual(decoded, "a\u{0}bc")

        // Zero-length reads decode to the empty string, not a crash.
        let empty = bytes.withUnsafeBufferPointer { buffer -> String in
            GhosttySurfaceHandle.decodeBridgeText(buffer.baseAddress!, length: 0)
        }
        XCTAssertEqual(empty, "")
    }

    @MainActor
    func testDetectionReadUsesFakeEngineScreenAndCarriesIdentity() async throws {
        let engine = FakeEngine()
        engine.nextScreenText = { _ in
            (1 ... 40).map { "screen-row-\($0)" }.joined(separator: "\r\n") + "\r\n"
        }
        let parking = FakeParkingHost()
        let manager = TerminalSessionManager(engine: engine, parkingHost: parking)

        let session = try manager.launchDirect(
            workspaceID: WorkspaceID(),
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )

        let detection = try await manager.read(session.id, source: .detection)
        XCTAssertNotNil(detection)
        XCTAssertEqual(detection?.generation, session.surfaceGeneration)
        XCTAssertEqual(detection?.text.split(separator: "\n").count, 32,
                       "detection snapshot must be capped at the last 32 rows")
        XCTAssertTrue(try XCTUnwrap(detection?.text.contains("screen-row-40")))
        XCTAssertTrue(try XCTUnwrap(detection?.text.hasPrefix("screen-row-9")))

        let visible = try await manager.read(session.id, source: .visible)
        XCTAssertNotNil(visible)
    }

    /// Round 7: a SINGLE line longer than the cap keeps its TAIL mid-line —
    /// the old code fell through to `return ""` when no LF existed in the
    /// retained window, silently starving screen detection on full-screen
    /// TUI/base64/progress-bar output.
    func testByteCapSingleLongLineKeepsTailMidLineInsteadOfEmptySnapshot() {
        let limit = TerminalSnapshotService.detectionByteLimit

        // (a) ASCII single line: exact tail retention.
        let longLine = String(repeating: "x", count: 40000)
        let result = TerminalSnapshotService.normalize(longLine, maxRows: nil, maxBytes: limit)
        XCTAssertFalse(result.isEmpty, "no-LF snapshot must not normalize to empty")
        XCTAssertLessThanOrEqual(result.utf8.count, limit)
        XCTAssertEqual(result, String(longLine.suffix(limit)),
                       "detection must see the LAST screen state, where prompts live")

        // (b) Multiline input still cuts at a LINE boundary (contrast arm).
        var lines = [String]()
        for index in 0 ..< 200 {
            lines.append(String(repeating: "y", count: 100) + "-\(index)")
        }
        let multiline = lines.joined(separator: "\n")
        let multilineResult = TerminalSnapshotService.normalize(multiline, maxRows: nil, maxBytes: limit)
        XCTAssertFalse(multilineResult.isEmpty)
        XCTAssertLessThanOrEqual(multilineResult.utf8.count, limit)
        for line in multilineResult.split(separator: "\n") where line.contains("-") {
            guard let dash = line.lastIndex(of: "-"),
                  let n = Int(line[line.index(after: dash)...]) else { continue }
            XCTAssertEqual(line.count, 100 + 1 + String(n).count,
                           "line \(n) must stay intact at the cut boundary")
        }

        // (c) Cut landing inside a multi-byte UTF-8 sequence decodes lossily
        // instead of crashing or dropping the snapshot.
        let accented = String(repeating: "é", count: 20000)
        let accentedResult = TerminalSnapshotService.normalize(accented, maxRows: nil, maxBytes: limit)
        XCTAssertFalse(accentedResult.isEmpty)
        XCTAssertLessThanOrEqual(accentedResult.utf8.count, limit)
    }

    // MARK: - Round 16 (test-design-16): two-layer nil-propagation contract (fd5417e)

    /// Service-layer law: a NIL read is no-evidence, NOT an empty screen — a
    /// closing/failed surface must never classify as a clean idle terminal.
    func testNilReadIsNoEvidenceNotAnEmptyScreenForDetection() {
        XCTAssertNil(
            TerminalSnapshotService.snapshot(
                read: { nil }, source: .detection,
                generation: .initial, outputRevision: 0
            ),
            "a failed detection read propagates nil so consumers see no-evidence"
        )

        // Positive control: an EMPTY read still yields a NON-nil snapshot —
        // the nil branch is about read failure, not content normalization.
        let empty = TerminalSnapshotService.snapshot(
            read: { "" }, source: .detection,
            generation: .initial, outputRevision: 0
        )
        XCTAssertNotNil(empty)
        XCTAssertEqual(empty?.text, "")
    }

    /// The SAME guard covers `.visible`: uniform nil-in-nil-out at the service
    /// level. Cosmetic masking lives in the SURFACE layer (GhosttySurface
    /// masks before normalizing itself); moving the mask down here would make
    /// the detection leg above fail loudly — intended tripwire coupling.
    func testNilReadPropagatesForVisibleSourceToo_MaskingIsTheSurfaceLayerSJob() {
        XCTAssertNil(
            TerminalSnapshotService.snapshot(
                read: { nil }, source: .visible,
                generation: .initial, outputRevision: 0
            )
        )

        // Non-nil visible reads pass through UNCLIPPED: no detectionRowLimit
        // on this arm of the switch (second service law, same guard).
        let long = Array(repeating: "row", count: TerminalSnapshotService.detectionRowLimit + 10)
            .joined(separator: "\n")
        let visible = TerminalSnapshotService.snapshot(
            read: { long }, source: .visible,
            generation: .initial, outputRevision: 0
        )
        XCTAssertEqual(visible?.text, long, "visible snapshots are never row-capped by the service")
    }

    /// Surface-layer asymmetry (GhosttySurface.snapshot(source:)): `.visible`
    /// masks a failed viewport read to a NON-nil EMPTY snapshot while
    /// `.detection` propagates a failed screen read as nil.
    @MainActor
    func testSurfaceVisibleMasksFailedReadsWhileDetectionPropagatesThem() throws {
        let engine = FakeEngine()
        let surface = try GhosttySurface(
            engine: engine, terminalID: TerminalID(), generation: .initial,
            spec: TerminalLaunchSpec(workingDirectory: "/tmp", command: "/bin/cat")
        )
        let native = try XCTUnwrap(surface.native as? FakeNativeSurface)
        XCTAssertFalse(surface.isClosing, "fixture precondition: the surface must be live")

        // Leg 1: failed viewport read → cosmetic mask to empty, never nil.
        native.viewportText = nil
        let visible = surface.snapshot(source: .visible)
        XCTAssertNotNil(visible, "cosmetic failures mask to empty; they are never no-evidence")
        XCTAssertTrue(try XCTUnwrap(visible?.text.isEmpty))

        // Leg 2: failed screen read → nil (no-evidence for the pipeline).
        native.screenText = nil
        XCTAssertNil(surface.snapshot(source: .detection))

        // Leg 3: positive control — canned reads flow through unchanged.
        native.viewportText = "hello"
        let canned = try XCTUnwrap(surface.snapshot(source: .visible))
        XCTAssertTrue(canned.text.contains("hello"))
    }
}
