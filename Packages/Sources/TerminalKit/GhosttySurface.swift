import AgentCore
import AppKit
import GhosttyBridge

// Native surface owner (architecture §3.8): one instance per TerminalID.
// Owns the native surface handle, the surface view, the callback box, the
// generation, output revision, title/pwd/progress metadata and teardown state.
//
// Deliberately NOT an AgentSession: presentation state (parked/mounted) lives
// here, lifecycle semantics live in AgentCore.

@MainActor public protocol GhosttySurfaceDelegate: AnyObject {
    /// Every typed event after local state application; the delegate (the
    /// session manager) re-validates identity before propagating.
    func surface(_ surface: GhosttySurface, didProduceEvent event: GhosttyEvent)
}

public enum SurfacePresentation: Equatable, Sendable {
    case parked
    case mounted(PaneID)
}

@MainActor public final class GhosttySurface {
    public let terminalID: TerminalID
    public let generation: SurfaceGeneration
    let native: any NativeTerminalSurface
    public let view: GhosttySurfaceView
    let callbackBox: SurfaceCallbackBox

    public weak var delegate: (any GhosttySurfaceDelegate)?

    public private(set) var outputRevision: UInt64 = 0
    public private(set) var title: String?
    public private(set) var pwd: String?
    public private(set) var progress: GhosttyProgressState?
    /// Poll-backed child-exit evidence (primary signal; ADR-0002 finding 5).
    /// Updated by `pollProcessExit()`; `.childExited` events only accelerate.
    public private(set) var processExited = false
    public private(set) var lastReportedExitCode: UInt32?
    public internal(set) var presentation: SurfacePresentation = .parked

    /// Teardown phase 1 marker; rejects all new commands while true.
    public private(set) var isClosing = false

    init(
        engine: any TerminalEngine,
        terminalID: TerminalID,
        generation: SurfaceGeneration,
        spec: TerminalLaunchSpec,
        // Called between view creation and native surface creation so the
        // caller can place the view inside a (parking) window FIRST — §3.8:
        // a surface is always born inside a native window.
        onViewCreated: ((GhosttySurfaceView) -> Void)? = nil
    ) throws {
        self.terminalID = terminalID
        self.generation = generation
        callbackBox = SurfaceCallbackBox(terminalID: terminalID, generation: generation)

        let view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.view = view
        onViewCreated?(view)
        do {
            native = try engine.createSurface(view: view, spec: spec, box: callbackBox)
        } catch {
            // onViewCreated may already have parked the view in the parking
            // window; without a surface there is no registry entry to tear it
            // down later, so detach it before propagating the failure.
            view.removeFromSuperview()
            throw error
        }
        view.surface = self
    }

    // MARK: event handling (main actor)

    /// Installs the callback sink. Call AFTER wiring `delegate`: setSink
    /// flushes events buffered during `engine.createSurface` (e.g. an instant
    /// `.childExited`) and they must observe the delegate.
    func activateEventSink() {
        callbackBox.setSink { [weak self] event in
            self?.handle(event)
        }
    }

    func handle(_ event: GhosttyEvent) {
        guard !isClosing else { return }
        switch event.payload {
        case .render:
            outputRevision += 1
            if outputRevision % 20 ==
                1
            {
                print("[UIX-DEBUG] render #\(outputRevision) tid=\(terminalID.rawValue.uuidString.prefix(8))")
            }
        case let .title(value):
            title = value
        case let .pwd(value):
            pwd = value
        case let .childExited(code):
            // The caller forwards the original event below; synthesize only
            // on the poll path to avoid a double delivery.
            applyProcessExit(reportedCode: code, notifyDelegate: false)
        case let .progress(value):
            progress = value
        case .commandFinished:
            break // metadata only at MVP
        case .bell, .selectionChanged, .notification, .openURL, .mouseShape:
            break
        case .closeWindowRequested:
            break // app-targeted events never route here
        }
        delegate?.surface(self, didProduceEvent: event)
    }

    /// Poll-based exit evidence — PRIMARY lifecycle signal (ADR-0002).
    /// Returns true when this call observed the running→exited transition.
    @discardableResult
    func pollProcessExit() -> Bool {
        guard !processExited, !isClosing else { return false }
        guard native.isProcessExited() else { return false }
        applyProcessExit(reportedCode: nil, notifyDelegate: true)
        return true
    }

    private func applyProcessExit(reportedCode: UInt32?, notifyDelegate: Bool) {
        processExited = true
        if reportedCode != nil {
            lastReportedExitCode = reportedCode
        }
        guard notifyDelegate, let code = lastReportedExitCode else { return }
        delegate?.surface(self, didProduceEvent: GhosttyEvent(
            terminalID: terminalID,
            generation: generation,
            payload: .childExited(exitCode: code)
        ))
    }

    // MARK: queries

    public func foregroundPID() -> UInt64 {
        isClosing ? 0 : native.foregroundPID()
    }

    public func gridSize() -> (columns: UInt32, rows: UInt32)? {
        isClosing ? nil : native.gridSize()
    }

    /// Snapshot via TerminalSnapshotService; detection reads are SCREEN-space
    /// and therefore independent of user scroll (§3.7).
    public func snapshot(source: TerminalReadSource) -> TerminalSnapshot? {
        guard !isClosing else { return nil }
        switch source {
        case .visible:
            // Visible reads are cosmetic: a failed viewport read yields an
            // empty snapshot, never nil.
            let raw = native.readViewport() ?? ""
            return TerminalSnapshot(
                text: TerminalSnapshotService.normalize(raw, maxRows: nil, maxBytes: nil),
                outputRevision: outputRevision,
                generation: generation
            )
        case .detection:
            // Detection reads feed the detection pipeline: a failed screen
            // read means no evidence, so propagate nil.
            guard let raw = native.readScreen() else { return nil }
            let normalized = TerminalSnapshotService.normalize(
                raw,
                maxRows: TerminalSnapshotService.detectionRowLimit,
                maxBytes: TerminalSnapshotService.detectionByteLimit
            )
            return TerminalSnapshot(
                text: normalized,
                outputRevision: outputRevision,
                generation: generation
            )
        }
    }

    // MARK: teardown (two-phase, ADR-0002)

    /// Phase 1: mark closing → drop callbacks → reject commands. The native
    /// free itself happens later on the main thread (phase 2), performed by
    /// TerminalTeardownQueue.
    public func beginTeardown() {
        guard !isClosing else { return }
        isClosing = true
        callbackBox.clearSink()
        native.setFocus(false)
        view.removeFromSuperview()
    }

    /// Phase 2: native free in a confirmed main-thread context. Called exactly
    /// once by the teardown queue; the callback box dies with this instance,
    /// i.e. strictly after the native free returned.
    public func performNativeFree() {
        guard !isClosingFreeDone else { return }
        isClosingFreeDone = true
        native.performFree()
    }

    private var isClosingFreeDone = false
}
