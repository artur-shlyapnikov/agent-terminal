import Foundation

// App Nap / sleep suppression (architecture §4.3): holds an NSProcessInfo
// user-initiated activity while at least one working agent exists so hidden
// surfaces keep processing output.

@MainActor public final class RuntimeActivityManager {
    private var activityToken: (any NSObjectProtocol)?
    private var holders = 0

    public init() {}

    /// Begins the activity when the first holder arrives; ref-counted.
    public func beginWorkingActivity() {
        holders += 1
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "AgentTerminal working agents"
        )
    }

    /// Ends the activity when the last holder leaves; ref-counted.
    public func endWorkingActivity() {
        holders = max(0, holders - 1)
        guard holders == 0, let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
    }

    public var isActive: Bool {
        activityToken != nil
    }

    /// Test hook: number of live holders (launches minus balanced ends).
    var activeCount: Int {
        holders
    }
}
