import AgentCore
@testable import AgentTerminal
import UserNotifications
import XCTest

// Stage-10 attention UX acceptance (§3.4, §3.13, §6.10):
//
//   1. Next Attention ordering — priority beats age (a NEWER inputRequired is
//      selected over an OLDER failure), oldest-first within a group;
//   2. the §6.10 gate — eight agents with mixed priorities: one ⌘⇧U press
//      lands on the oldest highest-priority event;
//   3. cycling visits ONLY attention-flagged rows and wraps;
//   4. visibility policy — completionUnread clears only after ≥500 ms of
//      CONTINUOUS visibility in the ACTIVE app with a focused agent;
//   5. notification suppression — exact §3.13 triple + Pause toggle + dedup;
//   6. menu-bar status text 'N working · M needs input'.

@MainActor
final class Stage10AttentionTests: XCTestCase {
    // MARK: - helpers

    private func summary(
        id: AgentID = AgentID(),
        lifecycle: LifecyclePhase = .idle,
        attention: AttentionState = .none,
        name: String = "agent"
    ) -> AgentSummary {
        let state = AgentState(
            process: .running(pid: 42, processGroupID: 42),
            lifecycle: lifecycle,
            attention: attention,
            authority: .process,
            revision: 1,
            observedAt: .zero
        )
        return AgentSummary(session: AgentSession(
            id: id,
            workspaceID: WorkspaceID(),
            kind: .genericShell,
            displayName: name,
            cwd: "/tmp",
            launchDescriptor: LaunchDescriptor(
                agentKind: .genericShell,
                program: "/bin/sh",
                workingDirectory: "/tmp"
            ),
            resumePolicy: .none,
            state: state,
            createdAt: .zero,
            lastActivityAt: .zero
        ))
    }

    private func failure(sinceNS: Int64) -> AttentionState {
        .failure(since: MonotonicInstant(nanosecondsSinceEpoch: sinceNS), eventID: RuntimeEventID())
    }

    // MARK: 1 — Next Attention ordering (§3.4)

    func testPriorityBeatsAgeNewerInputRequiredOverOlderFailure() {
        let olderFailureItem = SidebarItem.agent(AgentID(rawValue: UUID()))
        let newerInputItem = SidebarItem.agent(AgentID(rawValue: UUID()))
        let targets = AttentionNavigator.targets(attentionByItem: [
            olderFailureItem: failure(sinceNS: 1000),
            newerInputItem: .inputRequired(
                since: MonotonicInstant(nanosecondsSinceEpoch: 9000), requestID: "r"
            ),
        ])
        XCTAssertEqual(targets.count, 2)
        // The NEWER inputRequired still comes first — priority outranks age.
        XCTAssertEqual(targets[0].rank, AttentionRank.inputRequired)
        XCTAssertEqual(targets[0].item, newerInputItem)
        XCTAssertEqual(targets[1].rank, AttentionRank.failure)

        // One press from nothing lands on the newer inputRequired.
        XCTAssertEqual(AttentionNavigator.next(after: nil, in: targets)?.item, newerInputItem)
    }

    func testOldestFirstWithinSamePriorityGroup() {
        var map: [SidebarItem: AttentionState] = [:]
        for ns: Int64 in [7000, 5000, 6000] {
            map[.agent(AgentID(rawValue: UUID()))] = failure(sinceNS: ns)
        }
        let targets = AttentionNavigator.targets(attentionByItem: map)
        XCTAssertEqual(targets.map(\.since.nanosecondsSinceEpoch), [5000, 6000, 7000])
    }

    /// §6.10 gate: EIGHT agents — 3×completionUnread, 3×failure, 2×inputRequired
    /// with scrambled ages. One ⌘⇧U press must land on the OLDEST inputRequired
    /// (highest-priority group, oldest member).
    func testEightAgentMixedPrioritiesSingleShortcutLandsOnOldestHighestPriority() {
        var map: [SidebarItem: AttentionState] = [:]

        @discardableResult
        func add(rank: Int, sinceNS: Int64) -> SidebarItem {
            let item = SidebarItem.agent(AgentID(rawValue: UUID()))
            let state: AttentionState = switch rank {
            case AttentionRank.completionUnread:
                .completionUnread(
                    since: MonotonicInstant(nanosecondsSinceEpoch: sinceNS),
                    eventID: RuntimeEventID()
                )
            case AttentionRank.failure:
                failure(sinceNS: sinceNS)
            default:
                .inputRequired(
                    since: MonotonicInstant(nanosecondsSinceEpoch: sinceNS), requestID: nil
                )
            }
            map[item] = state
            return item
        }

        // Deliberately hostile insertion/age order.
        add(rank: AttentionRank.completionUnread, sinceNS: 300) // oldest overall…
        add(rank: AttentionRank.failure, sinceNS: 900)
        add(rank: AttentionRank.completionUnread, sinceNS: 100)
        add(rank: AttentionRank.failure, sinceNS: 500)
        add(rank: AttentionRank.inputRequired, sinceNS: 800)
        add(rank: AttentionRank.completionUnread, sinceNS: 200)
        add(rank: AttentionRank.failure, sinceNS: 700)
        let winner = add(rank: AttentionRank.inputRequired, sinceNS: 400) // ← must win

        let targets = AttentionNavigator.targets(attentionByItem: map)

        // All eight flagged rows participate, correctly ordered.
        XCTAssertEqual(targets.count, 8)
        XCTAssertEqual(targets.map(\.rank), [
            AttentionRank.inputRequired, AttentionRank.inputRequired,
            AttentionRank.failure, AttentionRank.failure, AttentionRank.failure,
            AttentionRank.completionUnread, AttentionRank.completionUnread, AttentionRank.completionUnread,
        ])
        XCTAssertEqual(targets[0].since.nanosecondsSinceEpoch, 400) // oldest inputRequired

        // One press from an unfocused shell lands exactly there.
        let landing = AttentionNavigator.next(after: .shell(TerminalID()), in: targets)
        XCTAssertEqual(landing?.item, winner)
    }

    func testCyclingVisitsOnlyFlaggedRowsAndWraps() {
        let flaggedA = SidebarItem.agent(AgentID(rawValue: UUID()))
        let flaggedB = SidebarItem.agent(AgentID(rawValue: UUID()))
        let unflagged = SidebarItem.shell(TerminalID())
        let targets = AttentionNavigator.targets(attentionByItem: [
            flaggedA: .inputRequired(
                since: MonotonicInstant(nanosecondsSinceEpoch: 1), requestID: nil
            ),
            flaggedB: failure(sinceNS: 2),
            unflagged: .none,
        ])
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(AttentionNavigator.next(after: nil, in: targets)?.item, flaggedA)
        XCTAssertEqual(AttentionNavigator.next(after: flaggedA, in: targets)?.item, flaggedB)
        // Wrap-around: after the last flagged row we land back on the first.
        XCTAssertEqual(AttentionNavigator.next(after: flaggedB, in: targets)?.item, flaggedA)
        // An unflagged focus starts at the head.
        XCTAssertEqual(AttentionNavigator.next(after: unflagged, in: targets)?.item, flaggedA)
        XCTAssertNil(AttentionNavigator.next(after: nil, in: []))
    }

    // MARK: 4 — visibility policy (§3.4)

    func testVisibilityPolicyRequiresActiveAppWindowAndContinuousSpan() {
        let t0 = Date()
        let early = t0.addingTimeInterval(0.49)
        let late = t0.addingTimeInterval(0.51)

        // Inactive app never clears, even past the span.
        XCTAssertFalse(FocusCoordinator.VisibilityPolicy.shouldMarkSeen(
            appActive: false, mainWindowVisible: true,
            focusedAgentSince: t0, now: late
        ))
        // Hidden window never clears.
        XCTAssertFalse(FocusCoordinator.VisibilityPolicy.shouldMarkSeen(
            appActive: true, mainWindowVisible: false,
            focusedAgentSince: t0, now: late
        ))
        // No focused agent.
        XCTAssertFalse(FocusCoordinator.VisibilityPolicy.shouldMarkSeen(
            appActive: true, mainWindowVisible: true,
            focusedAgentSince: nil, now: late
        ))
        // Below 500 ms continuous visibility.
        XCTAssertFalse(FocusCoordinator.VisibilityPolicy.shouldMarkSeen(
            appActive: true, mainWindowVisible: true,
            focusedAgentSince: t0, now: early
        ))
        // All conditions met; boundary counts as ≥500 ms.
        XCTAssertTrue(FocusCoordinator.VisibilityPolicy.shouldMarkSeen(
            appActive: true, mainWindowVisible: true,
            focusedAgentSince: t0, now: late
        ))
        XCTAssertTrue(FocusCoordinator.VisibilityPolicy.shouldMarkSeen(
            appActive: true, mainWindowVisible: true,
            focusedAgentSince: t0, now: t0.addingTimeInterval(0.5)
        ))
    }

    // MARK: 5 — notification suppression (§3.13)

    func testNotificationSuppressionMatrix() {
        // Fires when hidden or unfocused, regardless of activity.
        XCTAssertTrue(NotificationCoordinator.Policy.shouldRaise(
            appActive: false, agentVisible: false, paneFocused: false,
            notificationsPaused: false
        ))
        XCTAssertTrue(NotificationCoordinator.Policy.shouldRaise(
            appActive: true, agentVisible: true, paneFocused: false,
            notificationsPaused: false
        ))
        // Suppressed ONLY under the exact §3.13 triple.
        XCTAssertFalse(NotificationCoordinator.Policy.shouldRaise(
            appActive: true, agentVisible: true, paneFocused: true,
            notificationsPaused: false
        ))
        // Pause toggle suppresses everything.
        XCTAssertFalse(NotificationCoordinator.Policy.shouldRaise(
            appActive: false, agentVisible: false, paneFocused: false,
            notificationsPaused: true
        ))
    }

    func testNotificationDeduplicatesRepublishedDeltas() {
        let model = AppModel()
        let coordinator = NotificationCoordinator(model: model)
        coordinator.isAgentVisible = { _ in false }
        coordinator.isPaneFocused = { _ in false }
        let center = RecordingNotificationCenter()
        coordinator.testHooks.center = center
        coordinator.testHooks.authorizedOverride = true

        let agentID = AgentID()
        model.upsert(agent: summary(id: agentID, attention: failure(sinceNS: 1), name: "f"))
        coordinator.modelDidChange(appActive: false)
        // Republished delta — SAME agent, SAME failure instance.
        model.upsert(agent: summary(id: agentID, attention: failure(sinceNS: 1), name: "f"))
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 1, "republished delta must not re-notify")

        // A NEW failure instance (new since) raises again.
        model.upsert(agent: summary(id: agentID, attention: failure(sinceNS: 2), name: "f"))
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 2)
    }

    /// Removing an agent from the model must prune its deliveredIdentity
    /// entry (per-agent dictionary otherwise grows for the process lifetime).
    /// Observable contract: after remove + re-add with the SAME failure
    /// instance, the coordinator raises again — impossible while the stale
    /// identity survived.
    func testModelChangePrunesDeliveredIdentityForRemovedAgents() {
        let model = AppModel()
        let coordinator = NotificationCoordinator(model: model)
        coordinator.isAgentVisible = { _ in false }
        coordinator.isPaneFocused = { _ in false }
        let center = RecordingNotificationCenter()
        coordinator.testHooks.center = center
        coordinator.testHooks.authorizedOverride = true

        let agentID = AgentID()
        model.upsert(agent: summary(id: agentID, attention: failure(sinceNS: 1), name: "f"))
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 1)

        model.remove(agent: agentID)
        coordinator.modelDidChange(appActive: false)
        // Re-add with the SAME failure instance: pruning must have dropped
        // the old identity, so this is a fresh notification.
        model.upsert(agent: summary(id: agentID, attention: failure(sinceNS: 1), name: "f"))
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 2,
                       "identity entry must be pruned when its agent leaves the model")

        // And present agents keep their dedupe semantics across prunes.
        model.upsert(agent: summary(id: agentID, attention: failure(sinceNS: 1), name: "f"))
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 2, "republished delta still dedupes")
    }

    func testPausedToggleSuppressesDeliveryButModelStillTracksAttention() {
        let model = AppModel()
        let coordinator = NotificationCoordinator(model: model)
        coordinator.isAgentVisible = { _ in false }
        coordinator.isPaneFocused = { _ in false }
        let center = RecordingNotificationCenter()
        coordinator.testHooks.center = center
        coordinator.testHooks.authorizedOverride = true

        model.setNotificationsPaused(true)
        model.upsert(agent: summary(
            lifecycle: .waitingForInput(InputRequestDescriptor(
                kind: .approval, summary: "allow?",
                safeReplyMode: .terminalOnly, source: .integration
            )),
            attention: .inputRequired(
                since: MonotonicInstant(nanosecondsSinceEpoch: 1), requestID: nil
            )
        ))
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 0)
        XCTAssertTrue(model.notificationsPaused)
        XCTAssertEqual(model.attentionCount, 1, "sidebar surfaces stay live while paused")
    }

    // MARK: 6 — menu-bar status text (§3.13)

    func testMenuBarStatusText() {
        XCTAssertEqual(StatusItemController.statusText(working: 3, attention: 1),
                       "3 working · 1 needs input")
        XCTAssertEqual(StatusItemController.statusText(working: 0, attention: 0), "idle")
        XCTAssertEqual(StatusItemController.statusText(working: 0, attention: 2),
                       "2 needs input")
        XCTAssertEqual(StatusItemController.statusText(working: 2, attention: 0),
                       "2 working")
    }

    // MARK: 7 — WeakRoute retargeting (§3.12E, commit 907aaee)

    /// A later activate() must reroute the ONE live center to the newest
    /// coordinator: both activations share the same injected instance, and
    /// the route target moves coordA → coordB without stacking delegates.
    func testLaterActivateRetargetsSharedLiveRouteToNewestCoordinatorWithoutStacking() async {
        let live = LiveNotificationCenter(gateway: InertGateway())
        let coordA = NotificationCoordinator(model: AppModel())
        coordA.testHooks.liveOverride = live
        coordA.testHooks.authorizedOverride = true
        await coordA.activate()
        XCTAssertTrue(live.route.target === coordA,
                      "first activation routes the injected live at coordA")

        // Second composition root activates through the SAME live center.
        let coordB = NotificationCoordinator(model: AppModel())
        coordB.testHooks.liveOverride = live
        coordB.testHooks.authorizedOverride = true
        await coordB.activate()

        XCTAssertTrue(live.route.target === coordB,
                      "later activate() must retarget the shared live to the newest coordinator")
        XCTAssertFalse(live.route.target === coordA,
                       "the route must no longer point at the first coordinator")
    }

    /// The WeakRoute box holds its target WEAKLY: releasing the last strong
    /// reference to the coordinator must nil route.target so post-teardown
    /// notification taps degrade to a no-op instead of messaging a zombie
    /// kept alive by its own notification center.
    func testWeakRouteDoesNotRetainDeactivatedCoordinator() async {
        let live = LiveNotificationCenter(gateway: InertGateway())
        var coordB: NotificationCoordinator? = NotificationCoordinator(model: AppModel())
        coordB?.testHooks.liveOverride = live
        coordB?.testHooks.authorizedOverride = true
        await coordB?.activate()
        XCTAssertTrue(live.route.target === coordB)

        coordB = nil
        await Task.yield()
        await Task.yield()

        XCTAssertNil(live.route.target,
                     "the WeakRoute box must not retain the deactivated coordinator")
    }

    /// Round 26 (N1): with `authorizedOverride = true`, activate() must
    /// install the route WITHOUT calling `requestAuthorization()` at all;
    /// without the override it calls it exactly once. Both paths still set
    /// `route.target`. A regression that always awaits the UN round-trip
    /// would keep every test green while spamming the real permission prompt.
    func testAuthorizedOverrideShortCircuitsAuthorizationRoundTrip() async {
        // Act 1: override set — zero authorization requests, route installed.
        let counting = CountingAuthCenter()
        let coordA = NotificationCoordinator(model: AppModel())
        coordA.testHooks.liveOverride = counting
        coordA.testHooks.authorizedOverride = true
        await coordA.activate()
        XCTAssertEqual(counting.authRequests, 0,
                       "the short-circuit must skip requestAuthorization entirely")
        XCTAssertTrue(counting.route.target === coordA,
                      "the overridden path still installs the route")

        // Act 2: no override — exactly one real requestAuthorization call.
        let fresh = CountingAuthCenter()
        let coordB = NotificationCoordinator(model: AppModel())
        coordB.testHooks.liveOverride = fresh
        await coordB.activate()
        XCTAssertEqual(fresh.authRequests, 1,
                       "without the override activate() requests authorization once")
        XCTAssertTrue(fresh.route.target === coordB,
                      "the requested path installs the route too")
    }

    /// Round 26 (N2): an activation through `liveOverride` must NOT write the
    /// static shared slot (`sharedLive` is assigned only when liveOverride ==
    /// nil). The slot is private and unobservable directly; the hermetic proxy
    /// is a subsequent PRODUCTION-path activation constructing its own center
    /// — it must not retarget the injected test center's route to itself.
    func testLiveOverrideActivationLeavesSharedSlotCleanForProductionPath() async {
        let live = LiveNotificationCenter(gateway: InertGateway())
        let coordA = NotificationCoordinator(model: AppModel())
        coordA.testHooks.liveOverride = live
        coordA.testHooks.authorizedOverride = true
        await coordA.activate()
        XCTAssertTrue(live.route.target === coordA)

        // Production-path composition root: NO liveOverride.
        let coordC = NotificationCoordinator(model: AppModel())
        coordC.testHooks.authorizedOverride = true
        await coordC.activate()

        XCTAssertTrue(live.route.target === coordA,
                      "the injected test center must never be retargeted by a later production activation")
        XCTAssertFalse(live.route.target === coordC,
                       "a poisoned shared slot would navigate the test center into coordC")
    }

    // MARK: 8 — unauthorized graceful degradation (§3.13 fallback)

    /// With authorization NOT granted (no activate(), no override), every
    /// raise must degrade to a SILENT no-op — and because the authorization
    /// gate precedes the deliveredIdentity recording, the withheld FIRST
    /// notification is still delivered once authorization is granted later.
    /// Hoisting `deliveredIdentity[agent.id] = identity` above the gate
    /// would permanently swallow that first notification; deleting the gate
    /// would spam UN banners from a permission-less process.
    func testUnauthorizedCoordinatorDeliversNothingWithoutConsumingTheIdentity() {
        let model = AppModel()
        let coordinator = NotificationCoordinator(model: model)
        coordinator.isAgentVisible = { _ in false }
        coordinator.isPaneFocused = { _ in false }
        let center = RecordingNotificationCenter()
        coordinator.testHooks.center = center
        // Deliberately NO authorizedOverride and NO activate().

        let agentID = AgentID()
        model.upsert(agent: summary(id: agentID, attention: failure(sinceNS: 1), name: "f"))

        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 0,
                       "denied permission must degrade to silent attention surfaces")

        // SAME agent, SAME failure instance, now authorized.
        coordinator.testHooks.authorizedOverride = true
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 1,
                       "the withheld first notification must deliver on grant")
    }

    /// Round 26 (N3): when requestAuthorization returns FALSE through the
    /// real activate() path (denied branch), activate() still completes with
    /// the center installed, modelDidChange delivers NOTHING even for a
    /// hidden failure agent, and deliveredIdentity stays unconsumed — a later
    /// grant delivers exactly once. Extends the gate-only test above by
    /// pinning activate()'s denied branch itself.
    func testDeniedAuthorizationViaActivateDegradesSilentlyWithoutConsumingIdentity() async {
        let model = AppModel()
        let coordinator = NotificationCoordinator(model: model)
        coordinator.isAgentVisible = { _ in false }
        coordinator.isPaneFocused = { _ in false }
        let center = RecordingNotificationCenter()
        coordinator.testHooks.center = center
        // NO authorizedOverride — the real denied branch runs.
        let denying = DenyingAuthCenter()
        coordinator.testHooks.liveOverride = denying
        await coordinator.activate()

        XCTAssertTrue(denying.route.target === coordinator,
                      "activate() completes and installs the route even on denial")

        let agentID = AgentID()
        model.upsert(agent: summary(id: agentID, attention: failure(sinceNS: 1), name: "f"))
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 0,
                       "denied authorization degrades to silent attention surfaces")

        // SAME agent, SAME failure instance — now granted.
        coordinator.testHooks.authorizedOverride = true
        model.upsert(agent: summary(id: agentID, attention: failure(sinceNS: 1), name: "f"))
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 1,
                       "the identity was withheld during denial, not consumed")
    }

    // MARK: 9 — equal-rank/equal-since queue determinism (⌘⇧U tiebreak)

    /// With rank AND age tied, targets(_:) breaks ties by item.sortKey
    /// ("a-<uuid>" / "s-<uuid>"). Swift's sort is NOT guaranteed stable and
    /// dictionary iteration order is randomized per process run — without
    /// the tiebreak clause the ⌘⇧U queue order is unspecified for
    /// simultaneous attentions (flaky, order-dependent cycling).
    func testEqualRankEqualSinceQueueOrderIsDeterministicBySortKey() {
        var items: [SidebarItem] = []
        var map: [SidebarItem: AttentionState] = [:]
        // Deliberately hostile construction: three agents, identical rank
        // and age, inserted in arbitrary map order.
        for _ in 0 ..< 3 {
            let item = SidebarItem.agent(AgentID())
            items.append(item)
            map[item] = failure(sinceNS: 42)
        }

        let targets = AttentionNavigator.targets(attentionByItem: map)

        XCTAssertEqual(targets.count, 3)
        let expected = items.sorted { $0.sortKey < $1.sortKey }
        XCTAssertEqual(targets.map(\.item), expected,
                       "equal-rank/equal-age ties must break by sortKey — exact sequence, not a set")
    }

    // MARK: 10 — notification identity lifecycle laws

    /// Identity is "kind|since" — the KIND switch is half of the dedupe key.
    /// An agent escalating failure → inputRequired at the SAME since value
    /// must re-notify; collapsing identity to the timestamp alone silently
    /// swallows the escalation (the operator never hears that a failing
    /// agent now needs input).
    func testAttentionKindEscalationRedeliversEvenWhenSinceIsUnchanged() {
        let model = AppModel()
        let coordinator = NotificationCoordinator(model: model)
        coordinator.isAgentVisible = { _ in false }
        coordinator.isPaneFocused = { _ in false }
        let center = RecordingNotificationCenter()
        coordinator.testHooks.center = center
        coordinator.testHooks.authorizedOverride = true

        let agentID = AgentID()
        model.upsert(agent: summary(id: agentID, attention: failure(sinceNS: 1), name: "esc"))
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 1)

        // SAME since value, DIFFERENT kind.
        model.upsert(agent: summary(
            id: agentID,
            lifecycle: .waitingForInput(InputRequestDescriptor(
                kind: .approval, summary: "allow?",
                safeReplyMode: .terminalOnly, source: .integration
            )),
            attention: .inputRequired(
                since: MonotonicInstant(nanosecondsSinceEpoch: 1), requestID: nil
            ),
            name: "esc"
        ))
        coordinator.modelDidChange(appActive: false)

        XCTAssertEqual(center.added.count, 2,
                       "kind escalation must re-deliver at an identical since")
        XCTAssertTrue(center.added[0].identifier.hasSuffix("-failure|1"), center.added[0].identifier)
        XCTAssertTrue(center.added[1].identifier.hasSuffix("-inputRequired|1"),
                      center.added[1].identifier)
        XCTAssertEqual(center.added[0].title, "esc failed")
        XCTAssertEqual(center.added[1].title, "esc needs your input")
    }

    /// modelDidChange(appActive override:) must consult the OVERRIDE, never
    /// NSApp.isActive (nondeterministic under the test host — hence the
    /// SE-0405 nil-pattern default). And because the §3.13 policy guard
    /// PRECEDES the deliveredIdentity write, a raise suppressed by the
    /// active+visible+focused triple leaves the identity untouched — the
    /// un-focused delivery still happens later.
    func testExplicitAppActiveOverrideDrivesTripleAndSuppressedRaiseDoesNotConsumeIdentity() {
        let model = AppModel()
        let coordinator = NotificationCoordinator(model: model)
        coordinator.isAgentVisible = { _ in true }
        coordinator.isPaneFocused = { _ in true }
        let center = RecordingNotificationCenter()
        coordinator.testHooks.center = center
        coordinator.testHooks.authorizedOverride = true

        model.upsert(agent: summary(attention: .inputRequired(
            since: MonotonicInstant(nanosecondsSinceEpoch: 1), requestID: nil
        )))

        // Act 1: app ACTIVE under the full visible+focused triple — suppress.
        coordinator.modelDidChange(appActive: true)
        XCTAssertEqual(center.added.count, 0)

        // Act 2: SAME state, now INACTIVE — proves BOTH that the override
        // parameter drove the decision AND that the suppressed attempt did
        // not consume the identity.
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 1,
                       "suppression must not permanently mute the notification")
    }

    /// A row returning through a projection replacement starts a fresh
    /// notification episode after its old dedupe entry is pruned.
    func testVanishedAgentReturningWithUnchangedAttentionRenotifiesAfterReplacement() {
        let model = AppModel()
        let coordinator = NotificationCoordinator(model: model)
        coordinator.isAgentVisible = { _ in false }
        coordinator.isPaneFocused = { _ in false }
        let center = RecordingNotificationCenter()
        coordinator.testHooks.center = center
        coordinator.testHooks.authorizedOverride = true

        let vanished = AgentID()
        let payload = summary(id: vanished, attention: failure(sinceNS: 7), name: "v")
        model.upsert(agent: payload)
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 1)

        model.replaceAll(agents: [])
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 1, "absent agent contributes no delivery")

        model.replaceAll(agents: [payload]) // IDENTICAL summary, new projection
        coordinator.modelDidChange(appActive: false)
        XCTAssertEqual(center.added.count, 2,
                       "a replacement projection must re-notify a returned agent")
    }
}

/// Records notification deliveries instead of touching UNUserNotificationCenter.
@MainActor
private final class RecordingNotificationCenter: UserNotificationCentering {
    private(set) var added: [(identifier: String, title: String, agentID: AgentID)] = []

    func requestAuthorization() async -> Bool {
        true
    }

    func add(identifier: String, title: String, body _: String, agentID: AgentID) {
        added.append((identifier, title, agentID))
    }
}

/// Counts requestAuthorization calls; construction-only otherwise (never
/// add/didReceive). Proves activate()'s authorization short-circuit without
/// touching the UNUserNotificationCenter subsystem — the gateway stub means
/// construction never calls UNUserNotificationCenter.current() and never
/// installs a process-global delegate.
@MainActor
private final class CountingAuthCenter: LiveNotificationCenter {
    private(set) var authRequests = 0

    init() {
        super.init(gateway: InertGateway())
    }

    override func requestAuthorization() async -> Bool {
        authRequests += 1
        return true
    }
}

/// Denies authorization like a real UN round-trip rejection; construction-
/// only otherwise. Drives activate()'s denied branch hermetically via the
/// same gateway stub (no UN subsystem contact, no global delegate).
@MainActor
private final class DenyingAuthCenter: LiveNotificationCenter {
    init() {
        super.init(gateway: InertGateway())
    }

    override func requestAuthorization() async -> Bool {
        false
    }
}

/// Lightweight NotificationCenterGateway stub: no-op storage, no UN calls.
/// Not actor-isolated — the protocol's requirements are nonisolated.
private final class InertGateway: NotificationCenterGateway {
    func requestAuthorization() async -> Bool {
        false
    }

    func add(_: UNNotificationRequest) async throws {}
    func install(delegate _: UNUserNotificationCenterDelegate?) {}
}
