import AgentCore
import AppKit
import UserNotifications

// Notification coordination (§3.13): UNUserNotificationCenter alerts raised
// ONLY for
//   - input required,
//   - failure,
//   - completed turn of a hidden agent (completionUnread is only ever raised
//     for non-visible agents by AttentionPolicy),
// suppressed when the app is active AND the agent is visible AND its pane is
// focused, and while the menu-bar Pause Notifications toggle is on.
//
// Click → navigation chain (§3.12E): activate app → open/key main window →
// select the agent (canvas select mounts + focuses its pane). No inline reply.
//
// Graceful degradation: when authorization is denied (or not determinable)
// delivery silently no-ops — the sidebar/status item remain the attention
// surface. Nothing in the app depends on notifications being deliverable.

@MainActor
protocol UserNotificationCentering: AnyObject {
    func requestAuthorization() async -> Bool
    func add(identifier: String, title: String, body: String, agentID: AgentID)
}

/// Seam over the process-global UNUserNotificationCenter so test subclasses
/// can construct hermetically: no `UNUserNotificationCenter.current()` call
/// and no global delegate installation unless the production gateway is used.
protocol NotificationCenterGateway: AnyObject {
    func requestAuthorization() async -> Bool
    func add(_ request: UNNotificationRequest) async throws
    /// Installs (or replaces) the strong process-global UN delegate.
    func install(delegate: UNUserNotificationCenterDelegate?)
}

/// Production gateway. Constructed only via LiveNotificationCenter's default
/// argument, so test seams never reach this class. Not actor-isolated:
/// UNUserNotificationCenter is documented thread-safe, and the pre-seam code
/// already reached it (current() + delegate install) from a nonisolated init.
private final class LiveUNGateway: NotificationCenterGateway {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func install(delegate: UNUserNotificationCenterDelegate?) {
        center.delegate = delegate
    }
}

/// Real UNUserNotificationCenter wrapper. The center is reached only through
/// an injectable NotificationCenterGateway; unit tests pass a lightweight
/// gateway stub and never touch the notification subsystem.
///
/// Retain-cycle note: UNUserNotificationCenter.delegate is a STRONG reference
/// (the Apple header marks it retain, not weak) and this object installs
/// itself as that delegate while also holding the center — a deliberate
/// cycle on an effectively app-lifetime object. NotificationCoordinator
/// therefore constructs exactly one shared instance (see its `activate`) so
/// the cycle happens at most once.
/// final removed (R26, orchestrator-authorized): enables file-local test subclasses for auth-path seams
class LiveNotificationCenter: NSObject, UserNotificationCentering, UNUserNotificationCenterDelegate {
    private let gateway: NotificationCenterGateway

    /// Indirection refreshed on every NotificationCoordinator.activate() so
    /// navigation always routes to the most recently activated coordinator
    /// (a later composition root must not inherit the first instance's
    /// closure).
    final class WeakRoute {
        weak var target: NotificationCoordinator?
    }

    let route = WeakRoute()

    init(gateway: NotificationCenterGateway = LiveUNGateway()) {
        self.gateway = gateway
        super.init()
        gateway.install(delegate: self)
    }

    func requestAuthorization() async -> Bool {
        await gateway.requestAuthorization()
    }

    /// Synchronous at the seam so callers (and tests) observe delivery
    ///  ordering; the UNUserNotificationCenter round-trip is async inside.
    func add(identifier: String, title: String, body: String, agentID: AgentID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [NotificationCoordinator.agentIDKey: agentID.rawValue.uuidString]
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        )
        Task { try? await self.gateway.add(request) }
        // §3.13 click-chain routing also works when the app is frontmost and
        // the system suppresses the banner: keep delegate wired (above).
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            if let raw = response.notification.request.content.userInfo[NotificationCoordinator.agentIDKey] as? String,
               let uuid = UUID(uuidString: raw)
            {
                route.target?.navigate?(AgentID(rawValue: uuid))
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([]) // in-app surfacing is the sidebar's job, not banners
    }
}

@MainActor
final class NotificationCoordinator {
    static let agentIDKey = "agentID"
    private weak var model: AppModel?

    /// Test seams: unit tests inject a recording center without touching
    /// UNUserNotificationCenter. Production leaves both nil/false.
    struct TestHooks {
        var center: UserNotificationCentering?
        var authorizedOverride = false
        /// Hermetic activate(): inject a live center without touching the
        /// UNUserNotificationCenter subsystem or the shared-instance slot.
        var liveOverride: LiveNotificationCenter?
    }

    var testHooks = TestHooks()

    /// Pure §3.13 raise/suppress decision, split out for unit testing.
    enum Policy {
        static func shouldRaise(appActive: Bool,
                                agentVisible: Bool,
                                paneFocused: Bool,
                                notificationsPaused: Bool) -> Bool
        {
            guard !notificationsPaused else { return false }
            // Suppressed ONLY under the exact §3.13 triple.
            if appActive, agentVisible, paneFocused {
                return false
            }
            return true
        }
    }

    /// Shared live center: the strong UNUserNotificationCenter.delegate cycle
    /// (see LiveNotificationCenter) makes each instance self-retaining, so
    /// repeated activate() calls must reuse one instance rather than stack
    /// new ones.
    private static var sharedLive: LiveNotificationCenter?
    private var center: UserNotificationCentering?
    private var authorized = false
    /// Last identity delivered per agent — republished deltas must not re-notify.
    private var deliveredIdentity: [AgentID: String] = [:]

    var navigate: ((AgentID) -> Void)?
    var isAgentVisible: ((AgentID) -> Bool)?
    var isPaneFocused: ((AgentID) -> Bool)?

    init(model: AppModel?) {
        self.model = model
    }

    /// Installs the real notification center and requests authorization once.
    /// Denied permission degrades to silent no-op (documented MVP fallback).
    func activate() async {
        let live = testHooks.liveOverride ?? (Self.sharedLive ?? LiveNotificationCenter())
        if testHooks.liveOverride == nil {
            Self.sharedLive = live
        } // unchanged law
        center = live
        // Short-circuit skips the UN authorization round-trip when overridden.
        if testHooks.authorizedOverride {
            authorized = true
        } else {
            authorized = await live.requestAuthorization()
        }
        live.route.target = self
        if !authorized {
            print("[NOTIFY] authorization denied — falling back to silent attention surfaces")
        }
    }

    /// Called after every model delta batch; scans typed attention states.
    /// Default argument uses the nil-pattern because SE-0405 evaluates caller-
    /// side, and callers may be nonisolated while NSApp is main-actor-only.
    func modelDidChange(appActive override: Bool? = nil) {
        let appActive = override ?? NSApp.isActive
        guard let model else { return }
        // Prune dedupe state for agents no longer in the model; otherwise the
        // per-agent identity entry leaks for the whole process lifetime.
        let currentIDs = Set(model.agents.keys)
        deliveredIdentity = deliveredIdentity.filter { currentIDs.contains($0.key) }
        for agent in model.agents.values {
            let state = agent.state.attention
            guard state != .none else { continue }
            // Identity first: an agent can sit in one attention episode for
            // minutes at the per-delta fan-out, and the dedupe guard below
            // must not pay for localized title/body strings it throws away.
            let kind: String
            switch state {
            case .inputRequired: kind = "inputRequired"
            case .failure: kind = "failure"
            case .completionUnread: kind = "completionUnread"
            case .none: continue
            }
            let identity = "\(kind)|\(state.since?.nanosecondsSinceEpoch ?? 0)"
            guard deliveredIdentity[agent.id] != identity else { continue }
            let title: String
            let body: String
            switch state {
            case .inputRequired:
                title = String(
                    format: NSLocalizedString("%@ needs your input",
                                              comment: "Notification title: agent is waiting for operator input"),
                    agent.displayName
                )
                body = String(
                    format: NSLocalizedString(
                        "%@ has finished composing and is waiting for your reply.",
                        comment: "Notification body: agent requires input; %@ is the agent display name"
                    ),
                    agent.displayName
                )
            case .failure:
                title = String(
                    format: NSLocalizedString("%@ failed",
                                              comment: "Notification title: agent hit a failure"),
                    agent.displayName
                )
                body = String(
                    format: NSLocalizedString(
                        "%@ ran into an error. Open it to review what went wrong and retry.",
                        comment: "Notification body: agent failed; %@ is the agent display name"
                    ),
                    agent.displayName
                )
            case .completionUnread:
                title = String(
                    format: NSLocalizedString("%@ finished a turn",
                                              comment: "Notification title: hidden agent completed its turn"),
                    agent.displayName
                )
                body = String(
                    format: NSLocalizedString(
                        "%@ completed its turn while in the background. Open it to read the result.",
                        comment: "Notification body: unread completion of a hidden agent; %@ is the agent display name"
                    ),
                    agent.displayName
                )
            case .none:
                continue
            }
            let visible = isAgentVisible?(agent.id) ?? false
            let focused = isPaneFocused?(agent.id) ?? false
            guard Policy.shouldRaise(
                appActive: appActive,
                agentVisible: visible,
                paneFocused: focused,
                notificationsPaused: model.notificationsPaused
            ) else { continue }
            let center = testHooks.center ?? center
            let authorized = testHooks.authorizedOverride || authorized
            guard authorized, let center else { continue }
            deliveredIdentity[agent.id] = identity
            center.add(
                identifier: "\(agent.id.rawValue.uuidString)-\(identity)",
                title: title,
                body: body,
                agentID: agent.id
            )
        }
    }
}
