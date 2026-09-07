import AgentCore
@testable import AgentTerminal
import XCTest

// Review-fix coverage:
//
//  1. drag roundtrip — the sidebar drag source writes EXACTLY the payload
//     TerminalPaneController.decodeDrop consumes (§3.13 drag-replace);
//  2. process-exit dedup gate — one terminal's exit admits exactly once
//     across both reporting paths;
//  3. sidebar duration label — pure last-activity formatter + non-empty
//     render through the grouping path;
//  4. persistence-health banner mapping driven by DatabaseWriter.Health,
//     never a manual setDegradedBanner call.

@MainActor
final class ReviewFixTests: XCTestCase {
    // MARK: 1 — drag roundtrip

    func testDragRoundtripAgentAndShell() {
        let agentItem = SidebarItem.agent(AgentID(rawValue: UUID()))
        let agentPB = NSPasteboard(name: .init("dev.aterm.sidebar-item.test.agent"))
        agentPB.clearContents()
        TerminalPaneController.writeDrop(item: agentItem, into: agentPB)
        XCTAssertEqual(TerminalPaneController.decodeDrop(agentPB), agentItem)

        // The NSPasteboardItem carrier used by beginDraggingSession must be
        // byte-identical to what the pane decoder expects.
        let pbItem = NSPasteboardItem()
        TerminalPaneController.writeDrop(item: agentItem, into: pbItem)
        let carrier = NSPasteboard(name: .init("dev.aterm.sidebar-item.test.carrier"))
        carrier.clearContents()
        carrier.setData(pbItem.data(forType: NSPasteboard.PasteboardType("dev.aterm.sidebar-item")) ?? Data(),
                        forType: NSPasteboard.PasteboardType("dev.aterm.sidebar-item"))
        XCTAssertEqual(TerminalPaneController.decodeDrop(carrier), agentItem)

        let shellItem = SidebaritemShellHelper.make()
        let shellPB = NSPasteboard(name: .init("dev.aterm.sidebar-item.test.shell"))
        shellPB.clearContents()
        TerminalPaneController.writeDrop(item: shellItem, into: shellPB)
        XCTAssertEqual(TerminalPaneController.decodeDrop(shellPB), shellItem)

        // Foreign payloads decode to nil (never misrouted).
        let foreign = NSPasteboard(name: .init("dev.aterm.sidebar-item.test.foreign"))
        foreign.clearContents()
        foreign.setString("bogus", forType: NSPasteboard.PasteboardType("dev.aterm.sidebar-item"))
        XCTAssertNil(TerminalPaneController.decodeDrop(foreign))
    }

    // MARK: 2 — process-exit dedup

    @MainActor
    func testProcessExitGateAdmitsExactlyOnce() {
        let gate = ProcessExitGate()
        let first = TerminalID()
        let second = TerminalID()

        XCTAssertTrue(gate.admit(first), "first report of an exit is admitted")
        XCTAssertFalse(gate.admit(first), "the duplicate path is dropped")
        XCTAssertTrue(gate.admit(second), "a DIFFERENT terminal exits independently")
        XCTAssertFalse(gate.admit(second))
    }

    // MARK: 3 — sidebar duration / last-activity label

    func testDurationTextFormatterBoundaries() {
        let activity = MonotonicInstant(nanosecondsSinceEpoch: 0)
        func now(_ seconds: Int64) -> MonotonicInstant {
            MonotonicInstant(nanosecondsSinceEpoch: seconds * 1_000_000_000)
        }
        XCTAssertEqual(SidebarGrouping.durationText(lastActivity: activity, now: now(3)), "now")
        XCTAssertEqual(SidebarGrouping.durationText(lastActivity: activity, now: now(42)), "42s")
        XCTAssertEqual(SidebarGrouping.durationText(lastActivity: activity, now: now(5 * 60)), "5m")
        XCTAssertEqual(SidebarGrouping.durationText(lastActivity: activity, now: now(3 * 3600)), "3h")
        XCTAssertEqual(SidebarGrouping.durationText(lastActivity: activity, now: now(72 * 3600)), "3d")
        // Clock skew never renders negative ages.
        XCTAssertEqual(SidebarGrouping.durationText(lastActivity: now(10), now: activity), "now")
    }

    func testSidebarRowsCarryNonEmptyDurationWhenNowProvided() throws {
        var session = AgentSession(
            id: AgentID(),
            workspaceID: WorkspaceID(),
            kind: .genericShell,
            displayName: "aged",
            cwd: "/tmp",
            launchDescriptor: LaunchDescriptor(
                agentKind: .genericShell, program: "/bin/sh", workingDirectory: "/tmp"
            ),
            state: .fresh(at: .zero),
            createdAt: .zero,
            lastActivityAt: .zero
        )
        session.state.observedAt = MonotonicInstant(nanosecondsSinceEpoch: 90_000_000_000)
        let summary = AgentSummary(session: session)
        let now = MonotonicInstant(nanosecondsSinceEpoch: 150_000_000_000)

        let sections = SidebarGrouping.sections(agents: [summary], shells: [TestShell()], now: now)
        let row = try XCTUnwrap(sections.flatMap(\.rows).first { $0.title == "aged" })
        XCTAssertEqual(row.durationText, "1m")

        // Without a clock the label stays empty (never a stale lie).
        let bare = SidebarGrouping.sections(agents: [summary], shells: [TestShell()])
        XCTAssertTrue(bare.flatMap(\.rows).allSatisfy(\.durationText.isEmpty))
    }

    // MARK: 4 — persistence health → banner mapping

    @MainActor
    func testPersistenceHealthMappingDrivesBanner() {
        let model = AppModel()
        model.apply(persistenceHealth: .degraded(reason: "disk full"))
        XCTAssertEqual(model.degradedBanner, "Persistence degraded — disk full")

        model.apply(persistenceHealth: .healthy)
        XCTAssertNil(model.degradedBanner, "recovery clears the banner")
    }

    /// Round 7: a corruption-quarantine banner is STICKY — it survives
    /// recovery to `.healthy` (stage-16 gate 6a), while a plain transient
    /// degradation still clears. Stickiness does not freeze the message:
    /// later degradations update the text.
    @MainActor
    func testCorruptionBannerIsStickyAcrossHealthyRecoveryWhileTransientClears() {
        let model = AppModel()
        // Arrange-level stand-in for the composition-root quarantine call.
        model.setDegradedBanner("previous store quarantined", sticky: true)

        model.apply(persistenceHealth: .healthy)
        XCTAssertEqual(
            model.degradedBanner, "previous store quarantined",
            "the operator's only quarantine record must survive healthy recovery"
        )

        // A transient degradation must NOT overwrite the sticky quarantine
        // text: it would inherit stickiness and survive recovery as stale
        // text. The quarantine notice stays authoritative; the transient
        // reason is recorded to the diagnostics ring instead.
        model.apply(persistenceHealth: .degraded(reason: "disk full"))
        XCTAssertEqual(
            model.degradedBanner, "previous store quarantined",
            "a transient degradation must not replace the sticky quarantine notice"
        )

        // A NON-sticky degradation still clears on recovery (transient law).
        model.setDegradedBanner("Persistence degraded — x")
        model.apply(persistenceHealth: .healthy)
        XCTAssertNil(model.degradedBanner)
    }

    // MARK: Round 15 D1 — suppressed transient degradation mirrors into the ring

    /// A transient degradation arriving while a STICKY quarantine banner is
    /// up must leave the banner untouched AND still mirror the suppressed
    /// reason into DiagnosticsLogRing — otherwise a transient disk-full
    /// during quarantine recovery is invisible everywhere.
    @MainActor
    func testSuppressedTransientDegradationMirrorsIntoTheDiagnosticsRing() {
        let model = AppModel()
        // Arrange-level stand-in for the composition-root quarantine call.
        model.setDegradedBanner("previous store quarantined", sticky: true)
        /// Multiset snapshot, NOT a set: sibling tests in this suite record
        /// the IDENTICAL literal ("degraded: Persistence degraded — disk
        /// full", via setDegradedBanner) into the shared 500-cap FIFO ring,
        /// so a set-diff would silently miss our mirror. Counting occurrences
        /// keeps the "exactly one NEW line" law deterministic.
        func lineCounts(_ lines: [String]) -> [String: Int] {
            Dictionary(grouping: lines, by: { $0 }).mapValues(\.count)
        }
        let beforeCounts = lineCounts(DiagnosticsLogRing.shared.lines)

        model.apply(persistenceHealth: .degraded(reason: "disk full"))

        // The suppressed reason reaches the diagnostics ring, exactly once,
        // with the same wording setDegradedBanner would have used.
        let afterCounts = lineCounts(DiagnosticsLogRing.shared.lines)
        let expected = "degraded: Persistence degraded — disk full"
        let gained = afterCounts.filter { name, count in
            count > (beforeCounts[name] ?? 0)
        }.map { name, count in
            Array(repeating: name, count: count - (beforeCounts[name] ?? 0))
        }.flatMap { $0 }
        XCTAssertEqual(gained.count, 1, "expected exactly one new ring record, got: \(gained)")
        // Ring records carry a "[timestamp] " prefix; the mirrored payload
        // must equal the suppressed reason verbatim.
        let mirrored = gained.first ?? ""
        XCTAssertTrue(
            mirrored.hasSuffix(expected),
            "expected the suppressed-reason mirror '\(expected)', got: \(mirrored)"
        )
        // Positive control restating the pinned banner law: the sticky
        // quarantine notice stays authoritative and untouched.
        XCTAssertEqual(model.degradedBanner, "previous store quarantined")
        // Record-time redaction law: the mirrored line passes sanitize unchanged.
        for line in gained {
            XCTAssertEqual(DiagnosticRedactor.sanitize(line), line, "unsanitized line: \(line)")
        }
    }

    // MARK: R20-AM1 — delivery-slot stale-clear guard + removal cascade

    /// clearUnconfirmedDelivery must IGNORE a stale poll whose commandID no
    /// longer matches the slot; remove(agent:) cascades agentTerminal,
    /// agentCwd AND unconfirmedDeliveries away (no ghost-terminal routing).
    func testStaleDeliveryClearDoesNotEraseNewerCommandAndRemoveAgentCascadeDropsAssociations() {
        let model = AppModel()
        let agent = AgentID(rawValue: UUID())
        let cmd1 = CommandID()
        let cmd2 = CommandID()

        model.setUnconfirmedDelivery(agentID: agent, commandID: cmd1)

        // A STALE poll's clear (older command id) must not blank the slot.
        model.clearUnconfirmedDelivery(agentID: agent, commandID: cmd2)
        XCTAssertEqual(model.unconfirmedDeliveries[agent], cmd1,
                       "an older poll's clear must not erase a newer command's surfaced state")

        // Matching clear empties the slot.
        model.clearUnconfirmedDelivery(agentID: agent, commandID: cmd1)
        XCTAssertNil(model.unconfirmedDeliveries[agent])

        // remove(agent:) drops ALL per-agent associations.
        model.setUnconfirmedDelivery(agentID: agent, commandID: cmd2)
        let terminal = TerminalID()
        model.associate(terminal: terminal, cwd: "/tmp/proj", for: agent)
        model.remove(agent: agent)
        XCTAssertNil(model.agentTerminal[agent], "terminal association dies with the agent")
        XCTAssertNil(model.agentCwd[agent], "cwd association dies with the agent")
        XCTAssertNil(model.unconfirmedDeliveries[agent], "delivery slot dies with the agent")
    }

    // MARK: R20-AM2 — SidebarGrouping.durationText boundary ladder

    func testDurationTextBoundariesNeverShowNegativeOrWrongUnit() {
        func at(_ seconds: Int64) -> MonotonicInstant {
            MonotonicInstant(nanosecondsSinceEpoch: seconds * 1_000_000_000)
        }
        func text(lastActivity last: Int64, now: Int64) -> String {
            SidebarGrouping.durationText(lastActivity: at(last), now: at(now))
        }

        // Clock skew / zero elapsed never render a negative age.
        XCTAssertEqual(text(lastActivity: 10, now: 10), "now", "zero elapsed stays now")
        XCTAssertEqual(text(lastActivity: 20, now: 10), "now", "negative elapsed stays now")

        // Sub-five-second ages stay relative — including a TRUE 4.999s
        // (the ladder truncates to whole seconds: 4s → now).
        XCTAssertEqual(SidebarGrouping.durationText(
            lastActivity: MonotonicInstant(nanosecondsSinceEpoch: 0),
            now: MonotonicInstant(nanosecondsSinceEpoch: 4_999_000_000)
        ), "now")
        XCTAssertEqual(text(lastActivity: 0, now: 5), "5s", "the 5s boundary flips to seconds")
        XCTAssertEqual(text(lastActivity: 0, now: 59), "59s")
        XCTAssertEqual(text(lastActivity: 0, now: 60), "1m")
        XCTAssertEqual(text(lastActivity: 0, now: 59 * 60), "59m")
        XCTAssertEqual(text(lastActivity: 0, now: 60 * 60), "1h")

        // Hours hold until exactly 48h — which renders DAYS.
        XCTAssertEqual(text(lastActivity: 0, now: 47 * 3600 + 59 * 60 + 59), "47h",
                       "47h59m59s still renders hours")
        XCTAssertEqual(text(lastActivity: 0, now: 48 * 3600), "2d", "exactly 48h renders days")
        XCTAssertEqual(text(lastActivity: 0, now: 48 * 3600 + 1), "2d")
    }

    // MARK: R27-AM1 — onAgentRemoved removal-hook laws

    /// remove(agent:) fires onAgentRemoved with the removed id STRICTLY
    /// before the observable change — seam-side bookkeeping cleanup must
    /// precede UI invalidation. replaceAll reports ONLY vanished agents: a
    /// rebuild with no vanish must not spam seam-side cleanup.
    func testRemoveAgentFiresOnAgentRemovedWithIdBeforeEmitAndReplaceAllReportsOnlyVanished() {
        let model = AppModel()
        var events: [String] = []
        model.onAgentRemoved = { events.append("removed:\($0.rawValue.uuidString)") }
        model.onChange = { events.append("emit") }

        func summary(_ id: AgentID, _ name: String) -> AgentSummary {
            AgentSummary(session: AgentSession(
                id: id,
                workspaceID: WorkspaceID(),
                kind: .genericShell,
                displayName: name,
                cwd: "/tmp",
                launchDescriptor: LaunchDescriptor(
                    agentKind: .genericShell, program: "/bin/sh", workingDirectory: "/tmp"
                ),
                state: .fresh(at: .zero),
                createdAt: .zero,
                lastActivityAt: .zero
            ))
        }

        let a = AgentID()
        let b = AgentID()
        model.upsert(agent: summary(a, "a"))
        model.upsert(agent: summary(b, "b"))
        events.removeAll() // upserts emit — baseline the removal laws from zero

        // 1. remove(agent:): callback carries the id, fires exactly once,
        //    STRICTLY before the observable change.
        model.remove(agent: a)
        XCTAssertEqual(
            events, ["removed:\(a.rawValue.uuidString)", "emit"],
            "callback must carry the id and precede emit"
        )

        // 2. replaceAll over {a, b} → [b]: exactly the VANISHED agent fires.
        //    Independent model — leg 1 consumed `a`, and this law needs both
        //    agents present (the vanished one here is a, not b).
        let model2 = AppModel()
        var events2: [String] = []
        model2.onAgentRemoved = { events2.append("removed:\($0.rawValue.uuidString)") }
        model2.onChange = { events2.append("emit") }
        model2.upsert(agent: summary(a, "a"))
        model2.upsert(agent: summary(b, "b"))
        events2.removeAll() // upserts emit — baseline the replacement law from zero
        model2.replaceAll(agents: [summary(b, "b")])
        XCTAssertEqual(
            events2, ["removed:\(a.rawValue.uuidString)", "emit"],
            "the vanished agent fires; the surviving one must not"
        )

        // 3. Identical rebuild: no vanish — no callback, still one emit.
        model2.replaceAll(agents: [summary(b, "b")])
        XCTAssertEqual(
            events2, ["removed:\(a.rawValue.uuidString)", "emit", "emit"],
            "a rebuild with no vanish must not spam seam-side cleanup"
        )
    }

    // MARK: R29-S4 — replaceAll tolerates duplicate snapshot IDs (last wins)

    /// A snapshot carrying the SAME agent id twice must not trap (pre-fix
    /// behavior: `Dictionary(uniqueKeysWithValues:)` fatalError — a remote
    /// crash of the app model), must keep the LAST summary for the id, must
    /// NOT fire onAgentRemoved for a deduplicated id, and emits exactly once.
    func testReplaceAllWithDuplicateIDsKeepsLastSummaryWithoutTrapOrRemoval() {
        let model = AppModel()
        var events: [String] = []
        model.onAgentRemoved = { events.append("removed:\($0.rawValue.uuidString)") }
        model.onChange = { events.append("emit") }

        /// Local mirror of the R27-AM1 summary builder — file-local by house
        /// style, deliberately not hoisted into a shared helper.
        func summary(_ id: AgentID, _ name: String) -> AgentSummary {
            AgentSummary(session: AgentSession(
                id: id,
                workspaceID: WorkspaceID(),
                kind: .genericShell,
                displayName: name,
                cwd: "/tmp",
                launchDescriptor: LaunchDescriptor(
                    agentKind: .genericShell, program: "/bin/sh", workingDirectory: "/tmp"
                ),
                state: .fresh(at: .zero),
                createdAt: .zero,
                lastActivityAt: .zero
            ))
        }

        let a = AgentID()
        let b = AgentID()
        model.upsert(agent: summary(a, "old"))
        model.upsert(agent: summary(b, "b"))
        events.removeAll() // upserts emit — baseline the replacement laws from zero

        model.replaceAll(agents: [summary(a, "first"), summary(a, "second"), summary(b, "b")])

        XCTAssertEqual(
            model.agents[a]?.displayName, "second",
            "LAST occurrence wins, never first-wins"
        )
        XCTAssertEqual(model.agents.count, 2, "the duplicate collapses; both agents survive")
        XCTAssertEqual(events, ["emit"], "no removal may fire and exactly ONE emit recorded")
    }
}

private enum SidebaritemShellHelper {
    static func make() -> SidebarItem {
        .shell(TerminalID())
    }
}

private struct TestShell: ShellInfoProtocol {
    var terminalID = TerminalID()
    var name = "Shell 1"
    var cwd = "/tmp"
}
