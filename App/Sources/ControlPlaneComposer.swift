import AgentControl
import AgentCore
import Foundation

//  - UnixSocketServer at the production socket path (overridable via
//    AGENT_TERMINAL_CONTROL_SOCKET, symmetric with agentctl's
//    defaultSocketPath()), owner-only permissions;
// Stage-8 control-plane composition (§3.12 flow A, ControlProtocol open items):
//  - router over LiveControlRuntime + a synchronous workspace mirror;
//  - one shared HookAuthenticator + IdempotencyCache;
//  - EventStreamBroker owning the ONLY runtime.deltaStream() subscription —
//    the UI consumes broker subscriptions; control clients fan out through
//    the same broker (no competing raw-stream consumers).

@MainActor
final class ControlPlaneComposer {
    /// Degrades gracefully when the socket cannot be created; the runtime and
    /// UI keep working without the control plane (§3.12A).
    private(set) var server: UnixSocketServer?
    private(set) var startError: String?
    /// Reentrancy guard for start(): reserved synchronously before any await
    /// so overlapping calls cannot both construct servers on one socket path;
    /// rolled back on failure so later retries stay possible (§3.12A).
    private var startInFlight = false

    let hooks: HookAuthenticator
    let idempotency = IdempotencyCache()
    let router: ControlRequestRouter
    let broker: EventStreamBroker

    // Workspaces are NOT mirrored: the runtime owns the authoritative,
    // ordered enumeration (`AgentRuntime.workspaces()`); the router reads
    // it live so control-plane listings can never drift from launch-time
    // identity (one WorkspaceID everywhere, §3.14).

    init(
        runtime: AgentRuntime,
        hooks: HookAuthenticator = HookAuthenticator(),
        launchAgent: (@Sendable (AgentLaunchRequest, WorkspaceID) async throws -> AgentID)? = nil,
        stopAgent: (@Sendable (AgentID, StopMode) async throws -> Void)? = nil,
        focusAgent: (@Sendable (AgentID) async throws -> Void)? = nil
    ) {
        self.hooks = hooks
        broker = EventStreamBroker(streamProvider: EventStreamBroker.provider(for: runtime))
        router = ControlRequestRouter(
            runtime: LiveControlRuntime(
                runtime: runtime,
                launchAgent: launchAgent,
                stopAgent: stopAgent,
                focusAgent: focusAgent
            ),
            hooks: hooks,
            idempotency: idempotency,
            broker: broker
        )
    }

    /// Binds and starts the socket server; a failure only degrades to a
    /// banner, never blocks the runtime (§3.12A). Awaited by the composition
    /// root so `server`/`startError` are settled before callers inspect them.
    func start() async {
        // A previous failure must not poison later attempts: stale sockets
        // are recoverable, so every call retries while no server is bound.
        guard server == nil, !startInFlight else { return }
        startError = nil
        startInFlight = true
        do {
            let router = router
            // Symmetric with agentctl's defaultSocketPath(): secondary
            // instances (hermetic scenarios, multi-instance runs) can own a
            // private control plane instead of degrading against the first
            // instance's socket.
            let socketPath = ProcessInfo.processInfo.environment["AGENT_TERMINAL_CONTROL_SOCKET"]
                ?? UnixSocketServer.defaultPath()
            let server = try UnixSocketServer(path: socketPath) {
                request, connection in
                Task { await router.handle(request, connection: connection) }
            }
            try await server.start()
            let boundPath = await server.path
            self.server = server
            print("[LAUNCH] control plane listening at \(boundPath)")
            startInFlight = false
        } catch {
            startInFlight = false
            startError = "\(error)"
        }
    }
}
