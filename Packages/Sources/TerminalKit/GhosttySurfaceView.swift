import AgentCore
import AppKit
import GhosttyBridge

// NSView hosting one terminal surface (architecture §3.8): key events, text
// input/IME, mouse, resize/backing scale, focus transfer and a minimal
// accessibility bridge are passed through into the engine.
//
// SwiftUI never creates or destroys this view; AppKit pane controllers own it.

@MainActor public final class GhosttySurfaceView: NSView {
    weak var surface: GhosttySurface?

    override public var acceptsFirstResponder: Bool {
        true
    }

    override public var isFlipped: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Track mouse movement for hover/link reporting once a surface exists.
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("GhosttySurfaceView is created programmatically only")
    }

    // MARK: layout / scale

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncGeometry()
        if let old = occlusionObservedWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification, object: old
            )
            occlusionObservedWindow = nil
        }
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowOcclusionDidChange),
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
            occlusionObservedWindow = window
            surface?.native.setFocus(false) // focus arrives via explicit mount
        }
        syncOcclusion()
    }

    /// Deterministic seam for the host-window visibility read (§3.8):
    /// production leaves this nil and occlusion follows the live NSWindow
    /// state; tests set an explicit value to drive the mount/flip paths
    /// without a window server (occlusionState never reports .visible in a
    /// headless test runner, so the live read is untestable there).
    /// Consulted by syncOcclusion and by TerminalMountCoordinator.mount so
    /// both occlusion writers agree.
    var windowVisibleOverride: Bool?

    // MARK: window occlusion

    /// Window-level occlusion (§3.8): libghostty's embedded apprt does not
    /// self-detect visibility, so the view forwards NSWindow occlusion flips
    /// — covered, minimized, or moved-off-space windows throttle rendering
    /// while output keeps flowing. Park state still forces occluded=true via
    /// the mount coordinator; the two writers agree because the parking
    /// window is itself never .visible.
    @objc private func windowOcclusionDidChange() {
        syncOcclusion()
    }

    private func syncOcclusion() {
        guard let surface, !surface.isClosing else { return }
        guard let visible = windowVisibleOverride ?? window?.occlusionState.contains(.visible) else { return }
        surface.native.setOccluded(!visible)
    }

    private weak var occlusionObservedWindow: NSWindow?

    override public func layout() {
        super.layout()
        syncGeometry()
    }

    private func syncGeometry() {
        guard let surface, !surface.isClosing, let window else { return }
        let scale = window.backingScaleFactor
        let widthPixels = UInt32(max(1, frame.size.width * scale))
        let heightPixels = UInt32(max(1, frame.size.height * scale))
        // AppKit lays views out far more often than geometry actually changes
        // (window moves, sibling churn, sheet animations); each redundant
        // resize makes libghostty recompute grid metrics. Skip unless the
        // metrics changed OR a different surface now owns this view.
        if surface === lastResizedSurface, widthPixels == lastWidthPixels,
           heightPixels == lastHeightPixels, scale == lastScaleFactor
        {
            return
        }
        surface.native.resize(
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            scaleFactor: Double(scale)
        )
        lastResizedSurface = surface
        lastWidthPixels = widthPixels
        lastHeightPixels = heightPixels
        lastScaleFactor = scale
    }

    private weak var lastResizedSurface: GhosttySurface?
    private var lastWidthPixels: UInt32?
    private var lastHeightPixels: UInt32?
    private var lastScaleFactor: CGFloat?

    // MARK: keyboard

    override public func keyDown(with event: NSEvent) {
        guard let surface, !surface.isClosing,
              let key = InputTranslator.translate(event, action: event.isARepeat ? .repeatKey : .press)
        else {
            super.keyDown(with: event)
            return
        }
        if !surface.native.sendKey(key) {
            // Only unmodified input falls back to the text path so IME-
            // produced commits still reach the child (§3.8); a declined
            // cmd+letter must not inject its modifier-stripped character
            // (standard AppKit insertText gating).
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.shift, .capsLock])
            if modifiers.isEmpty, let text = event.characters, !text.isEmpty {
                surface.native.sendText(text)
            }
        }
    }

    override public func keyUp(with event: NSEvent) {
        guard let surface, !surface.isClosing,
              let key = InputTranslator.translate(event, action: .release)
        else {
            super.keyUp(with: event)
            return
        }
        _ = surface.native.sendKey(key)
    }

    // MARK: mouse

    override public func mouseDown(with event: NSEvent) {
        forwardMouseButton(event, state: .press, button: .left)
    }

    override public func mouseUp(with event: NSEvent) {
        forwardMouseButton(event, state: .release, button: .left)
    }

    override public func rightMouseDown(with event: NSEvent) {
        forwardMouseButton(event, state: .press, button: .right)
    }

    override public func rightMouseUp(with event: NSEvent) {
        forwardMouseButton(event, state: .release, button: .right)
    }

    override public func otherMouseDown(with event: NSEvent) {
        forwardMouseButton(event, state: .press, button: .middle)
    }

    override public func otherMouseUp(with event: NSEvent) {
        forwardMouseButton(event, state: .release, button: .middle)
    }

    private func forwardMouseButton(_ event: NSEvent, state: MouseButtonState, button: MouseButton) {
        guard let surface, !surface.isClosing else { return }
        _ = surface.native.mouseButton(
            state: state,
            button: button,
            modifiers: InputTranslator.modifiers(event)
        )
    }

    override public func mouseMoved(with event: NSEvent) {
        forwardMousePosition(event)
    }

    override public func mouseDragged(with event: NSEvent) {
        forwardMousePosition(event)
    }

    private func forwardMousePosition(_ event: NSEvent) {
        guard let surface, !surface.isClosing else { return }
        let point = convert(event.locationInWindow, from: nil)
        surface.native.mousePosition(
            x: Double(point.x),
            y: Double(frame.height - point.y), // ghostty expects top-left origin
            modifiers: InputTranslator.modifiers(event)
        )
    }

    override public func scrollWheel(with event: NSEvent) {
        guard let surface, !surface.isClosing else {
            super.scrollWheel(with: event)
            return
        }
        // Packed scroll modifiers stay 0 at MVP (plain wheel scrolling); the
        // spike validated plain deltas against this ABI.
        surface.native.mouseScroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, packedModifiers: 0)
    }

    // MARK: accessibility

    override public func isAccessibilityElement() -> Bool {
        true
    }

    override public func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override public func accessibilityLabel() -> String? {
        "Terminal"
    }

    override public func accessibilityValue() -> Any? {
        surface?.snapshot(source: .visible)?.text ?? ""
    }

    override public func isAccessibilityEnabled() -> Bool {
        true
    }
}
