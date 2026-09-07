import AgentCore
import Foundation
import GhosttyBridge

// Thread-safe callback routing (architecture §3.18 "C callbacks"):
//
//   C callback (any thread)
//     → bridge already copied payloads into owned plain-C structs
//     → router converts to a Sendable `GhosttyEvent` value (strings copied)
//     → hops to the main actor
//     → consumer re-validates surface generation before acting
//     → late callback after teardown becomes a no-op.
//
// The router never touches AppKit and never mutates shared state off the
// main actor.

/// Hops to the main thread/actor without creating an unstructured Task:
/// C callbacks may fire while libghostty ticks on the main thread, and
/// Task-based hops interact badly with XCTest-style outer task contexts.
func performOnMain(inlineIfMain: Bool = true,
                   _ body: @escaping @Sendable @MainActor () -> Void)
{
    if inlineIfMain, Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
        }
    }
}

/// Per-surface delivery box. Its address IS the libghostty userdata pointer,
/// so every surface-targeted action resolves back to the right box without a
/// registry lookup. Retained by the owning GhosttySurface until the native
/// free has returned (two-phase teardown phase 3), which guarantees pointer
/// validity for every callback that can still arrive.
public final class SurfaceCallbackBox: @unchecked Sendable {
    /// Recursive on purpose: a sink may legitimately tear its own terminal
    /// down while it is being delivered to (close-view from a close-window
    /// event; parked-exit reclamation from a child-exit event). That path
    /// re-enters this box via `clearSink` on the SAME thread while
    /// `deliver`/`deliverLocked` still hold the lock — a plain NSLock
    /// self-deadlocks there and wedges the main thread inside
    /// `ghostty_app_tick` (sampled 2026-08-26). Cross-thread exclusion is
    /// unchanged: other threads still block for the whole delivery.
    private let lock = NSRecursiveLock()
    private var sink: (@MainActor @Sendable (GhosttyEvent) -> Void)?
    /// Payloads delivered while no sink was installed (early title/pwd/
    /// child-exit events fired during surface creation, before setSink);
    /// flushed oldest-first when a sink arrives.
    private var pendingPayloads: [GhosttyEvent.Payload] = []
    /// Upper bound on buffered pre-sink payloads; oldest are dropped first.
    private static let pendingPayloadLimit = 32
    /// Number of this box's hops currently enqueued on (or executing on)
    /// the serial main queue ahead of any new arrival. Lock-guarded.
    /// While > 0 an on-main delivery MUST NOT run inline — see
    /// deliverLocked for the ordering invariant this enforces.
    private var mainQueueHops = 0
    /// Set while a `.render` hop for this box is queued/executing on the
    /// main queue; further renders fold into that hop (see deliverLocked).
    private var renderHopPending = false

    public let terminalID: TerminalID
    public let generation: SurfaceGeneration

    public init(terminalID: TerminalID, generation: SurfaceGeneration) {
        self.terminalID = terminalID
        self.generation = generation
    }

    /// Installs (or replaces) the main-actor sink. Called at surface setup.
    /// The buffered-payload flush runs while still holding the lock so a
    /// live event arriving mid-flush queues behind it on the lock instead
    /// of overtaking older payloads on the main queue (oldest-first).
    ///
    /// Deadlock note: the sink CAN re-enter this box synchronously (a
    /// close-view or parked-exit reclaim that tears the terminal down from
    /// inside the delivery); the recursive lock makes that same-thread
    /// reentry safe. Cross-thread deliveries still serialize behind the
    /// whole delivery, which is what preserves the oldest-first flush
    /// ordering documented above.
    func setSink(_ sink: @escaping @MainActor @Sendable (GhosttyEvent) -> Void) {
        lock.lock()
        self.sink = sink
        let buffered = pendingPayloads
        pendingPayloads.removeAll()
        for payload in buffered {
            deliverLocked(payload)
        }
        lock.unlock()
    }

    /// Teardown phase 1: late callbacks become no-ops after this returns.
    func clearSink() {
        lock.lock()
        sink = nil
        lock.unlock()
    }

    func deliver(_ payload: GhosttyEvent.Payload) {
        lock.lock()
        deliverLocked(payload)
        lock.unlock()
    }

    /// Shared locked path: buffers pre-sink payloads (generation guard — a
    /// callback racing teardown finds no sink; the payload drops with the
    /// box at native free, §3.18 step 6/7), otherwise hops the event to the
    /// main actor. MUST be called with `lock` held.
    private func deliverLocked(_ payload: GhosttyEvent.Payload) {
        guard let target = sink else {
            pendingPayloads.append(payload)
            if pendingPayloads.count > Self.pendingPayloadLimit {
                pendingPayloads.removeFirst()
            }
            return
        }
        // `.render` payloads are contentless (the sink re-reads
        // outputRevision), so a render burst collapses into exactly ONE
        // main-queue hop and one sink call: while a hop is pending, further
        // renders are dropped. Non-render payloads are never coalesced, so
        // titles/pwd/child-exited keep their per-event delivery and order.
        // Pre-sink buffered renders above stay as-is (rare).
        let isCoalescedRender: Bool
        if case .render = payload {
            guard !renderHopPending else { return }
            renderHopPending = true
            isCoalescedRender = true
        } else {
            isCoalescedRender = false
        }
        // Ordering invariant (T3): a box's payloads reach its sink in
        // delivery order. A background delivery enqueues its hop on the
        // serial main queue; while such a hop is still queued/executing,
        // an on-main delivery must NOT take performOnMain's synchronous
        // path or it would overtake the older event (e.g. a render
        // coalesce jumping ahead of childExited). So inline execution is
        // allowed only when this box has no hops already on the main
        // queue (`mainQueueHops == 0`); otherwise the new payload joins
        // the same queue and FIFO order restores oldest-first delivery.
        // The counter is read under the same lock that incremented it, so
        // the check is race-free against concurrent background deliveries.
        let runInline = Thread.isMainThread && mainQueueHops == 0
        if !runInline {
            mainQueueHops += 1
        }
        let event = GhosttyEvent(
            terminalID: terminalID,
            generation: generation,
            payload: payload
        )
        performOnMain(inlineIfMain: runInline) { [weak self] in
            target(event)
            if !runInline {
                // This hop has been delivered; later arrivals may go
                // inline again. Same-thread recursive lock, and the sink's
                // re-entrancy note above applies unchanged.
                self?.lock.lock()
                self?.mainQueueHops -= 1
                self?.lock.unlock()
            }
            // The flag clears only AFTER the sink body ran, deferred to the
            // next main-queue turn in both paths (the lock is recursive, so
            // an inline reset would no longer deadlock, but the deferral
            // also keeps the reset out of the sink's synchronous stack —
            // a sink that delivers a nested render must still observe
            // renderHopPending == true):
            //   • sync path: enqueued from inside the lock-held stack, runs
            //     right after it unwinds;
            //   • async path: enqueued after the hop drained the queue.
            // Renders arriving in the brief window before the reset run are
            // contentless duplicates of state the sink already observed.
            if isCoalescedRender {
                DispatchQueue.main.async {
                    self?.setRenderHopPending(false)
                }
            }
        }
    }

    private func setRenderHopPending(_ value: Bool) {
        lock.lock()
        renderHopPending = value
        lock.unlock()
    }
}

/// Owns the C trampolines and the AGTEvent → GhosttyEvent conversion.
/// One instance per engine; its `RuntimeBox` is handed to the bridge as the
/// runtime userdata and stays alive until the runtime is freed.
final class GhosttyCallbackRouter: @unchecked Sendable {
    /// Stable indirection retained by the bridge runtime for its lifetime.
    final class RuntimeBox {
        weak var router: GhosttyCallbackRouter?
    }

    /// Retained by the bridge and deliberately NEVER released (classic
    /// C-userdata pattern): a native trampoline firing after runtime free —
    /// or after a router dropped without shutdown — must always resolve
    /// valid memory. The box is tiny and per-engine; `.router` is weak, so
    /// a dead router resolves to nil.
    let retainedBox: UnsafeMutableRawPointer
    private let runtimeBox = RuntimeBox()

    // MARK: wiring (all set by the engine before the runtime is created)

    weak var delegate: GhosttyEngine?

    /// Synchronous, thread-safe clipboard-read policy (an immutable value
    /// captured by the engine from its ClipboardBridge policy). Evaluated in
    /// the callback thread WITHOUT a main-actor hop: libghostty may invoke
    /// callbacks from the main thread during tick, where a blocking hop would
    /// deadlock.
    var clipboardReadPolicy: (@Sendable (ClipboardKind) -> Bool)?

    init() {
        retainedBox = Unmanaged.passRetained(runtimeBox).toOpaque()
        // Phase 1 complete: safe to publish self into the box's weak ref so
        // the C trampolines can resolve the router from the userdata pointer.
        // Without this every runtime-level callback resolved to nil.
        runtimeBox.router = self
    }

    deinit {
        // No release here: the retained box is deliberately leaked (see
        // `retainedBox`) so a late native trampoline can never
        // takeUnretainedValue() freed memory.
    }

    // MARK: C trampolines (no captures → valid C function pointers)

    func installCallbacks(into callbacks: inout AGTRuntimeCallbacks) {
        callbacks.userdata = retainedBox
        callbacks.wakeup = { rawPointer in
            GhosttyCallbackRouter.handleWakeup(userdata: rawPointer)
        }
        callbacks.event = { event, userdata in
            GhosttyCallbackRouter.handleEvent(event: event, userdata: userdata)
        }
        callbacks.read_clipboard = { clipboard, userdata in
            GhosttyCallbackRouter.handleReadClipboard(clipboard: clipboard, userdata: userdata)
        }
        callbacks.confirm_read_clipboard = { prompt, request, userdata in
            GhosttyCallbackRouter.handleConfirmReadClipboard(
                prompt: prompt, request: request, userdata: userdata
            )
        }
        callbacks.write_clipboard = { clipboard, mime, data, userdata in
            GhosttyCallbackRouter.handleWriteClipboard(
                clipboard: clipboard, mime: mime, data: data, userdata: userdata
            )
        }
        callbacks.close_surface = { processAlive, userdata in
            GhosttyCallbackRouter.handleCloseSurface(processAlive: processAlive, userdata: userdata)
        }
    }

    private static func router(from userdata: UnsafeMutableRawPointer?) -> GhosttyCallbackRouter? {
        guard let userdata else { return nil }
        return Unmanaged<RuntimeBox>
            .fromOpaque(userdata)
            .takeUnretainedValue()
            .router
    }

    static func handleWakeup(userdata: UnsafeMutableRawPointer?) {
        guard let delegate = router(from: userdata)?.delegate else { return }
        performOnMain {
            delegate.engineWantsTick()
        }
    }

    static func handleEvent(event: UnsafePointer<AGTEvent>?, userdata: UnsafeMutableRawPointer?) {
        guard let event,
              let payload = convert(event.pointee)
        else {
            return
        }
        if let context = event.pointee.surface_context {
            // Surface-targeted: route through the per-surface box (generation
            // guard + main-actor hop happen inside the box). Taking the box
            // unretained is safe: it outlives the native surface by policy.
            let box = Unmanaged<SurfaceCallbackBox>
                .fromOpaque(context)
                .takeUnretainedValue()
            box.deliver(payload)
        } else {
            // App-targeted event (close-window request etc.). Uses the same
            // performOnMain hop as surface delivery and handleCloseSurface:
            // Task { @MainActor } has no mutual ordering with the box's
            // main-queue hops, so a closeWindowRequested could otherwise be
            // observed before a logically-earlier childExited.
            guard let delegate = router(from: userdata)?.delegate else { return }
            let event = GhosttyEvent(
                terminalID: nil,
                generation: nil,
                payload: payload
            )
            performOnMain {
                delegate.eventSink?(event)
            }
        }
    }

    static func handleCloseSurface(processAlive: Bool, userdata: UnsafeMutableRawPointer?) {
        guard let delegate = router(from: userdata)?.delegate else { return }
        performOnMain {
            delegate.eventSink?(GhosttyEvent(
                terminalID: nil,
                generation: nil,
                payload: .closeWindowRequested(processAlive: processAlive)
            ))
        }
    }

    static func handleReadClipboard(clipboard: Int32, userdata: UnsafeMutableRawPointer?) -> Bool {
        // Policy lives in an immutable captured value — no actor hop, no
        // deadlock when the callback fires on the main thread during tick.
        guard let policy = router(from: userdata)?.clipboardReadPolicy else {
            return false // deny by default (OSC52 reads off by default)
        }
        return policy(ClipboardKind(rawValue: clipboard) ?? .standard)
    }

    static func handleConfirmReadClipboard(
        prompt: UnsafePointer<CChar>?,
        request: Int32,
        userdata: UnsafeMutableRawPointer?
    ) {
        guard let delegate = router(from: userdata)?.delegate else { return }
        let text = prompt.map { String(cString: $0) }
        let kind = ClipboardRequestKind(rawValue: request)
        performOnMain {
            delegate.clipboardBridge?.confirmRead(prompt: text, request: kind)
        }
    }

    static func handleWriteClipboard(
        clipboard: Int32,
        mime: UnsafePointer<CChar>?,
        data: UnsafePointer<CChar>?,
        userdata: UnsafeMutableRawPointer?
    ) {
        guard let delegate = router(from: userdata)?.delegate else { return }
        let mimeString = mime.map { String(cString: $0) }
        let dataString = data.map { String(cString: $0) }
        let kind = ClipboardKind(rawValue: clipboard)
        performOnMain {
            delegate.clipboardBridge?.write(kind: kind, mime: mimeString, data: dataString)
        }
    }

    // MARK: AGTEvent → typed payload conversion (copies all borrowed strings)

    static func convert(_ event: AGTEvent) -> GhosttyEvent.Payload? {
        if event.kind == AGTEventRender {
            return .render
        }
        if event.kind == AGTEventTitle {
            return .title(copy(event.title) ?? "")
        }
        if event.kind == AGTEventPwd {
            return .pwd(copy(event.pwd) ?? "")
        }
        if event.kind == AGTEventChildExited {
            return .childExited(exitCode: event.exit_code)
        }
        if event.kind == AGTEventCommandFinished {
            return .commandFinished(
                exitCode: event.command_exit_code,
                durationNanoseconds: event.duration_ns
            )
        }
        if event.kind == AGTEventProgress {
            return .progress(GhosttyProgressState(
                value: progressValue(event.progress_state),
                percent: event.progress_percent
            ))
        }
        if event.kind == AGTEventBell {
            return .bell
        }
        if event.kind == AGTEventSelectionChanged {
            return .selectionChanged
        }
        if event.kind == AGTEventNotification {
            return .notification(
                title: copy(event.title) ?? "",
                body: copy(event.body) ?? ""
            )
        }
        if event.kind == AGTEventOpenURL {
            return .openURL(kind: urlKind(event.url_kind), url: copy(event.url) ?? "")
        }
        if event.kind == AGTEventMouseShape {
            return .mouseShape(mouseShape(event.mouse_shape))
        }
        if event.kind == AGTEventCloseWindow {
            return .closeWindowRequested(processAlive: true)
        }
        return nil
    }

    private static func copy(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }

    /// ghostty_action_progress_report_state_e (ghostty.h): REMOVE=0 SET=1
    /// ERROR=2 INDETERMINATE=3 PAUSE=4. Anything outside the real range is
    /// not a progress report — fall back to .indeterminate (non-committal)
    /// rather than inventing a determinate `.set` report.
    private static func progressValue(_ raw: Int32) -> GhosttyProgressState.Value {
        switch raw {
        case 0: .remove
        case 1: .set
        case 2: .error
        case 3: .indeterminate
        case 4: .pause
        default: .indeterminate
        }
    }

    private static func urlKind(_ raw: Int32) -> TerminalURLKind {
        switch raw {
        case 1: .text
        case 2: .html
        case 3: .osc8
        default: .unknown
        }
    }

    /// ghostty_action_mouse_shape_e (ghostty.h): DEFAULT=0 POINTER=3
    /// PROGRESS=4 WAIT=5 CROSSHAIR=7 TEXT=8. Raw 0 is the plain default
    /// cursor — "no shape request", mapped to .unknown so default-cursor
    /// frames don't surface as exotic shapes.
    private static func mouseShape(_ raw: Int32) -> GhosttyMouseShape {
        switch raw {
        case 0: .unknown
        case 3: .pointer
        case 4: .progress
        case 5: .wait
        case 7: .crosshair
        case 8: .text
        default: .other(raw)
        }
    }
}
