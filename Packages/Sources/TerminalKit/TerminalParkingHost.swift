import AppKit

// Hidden bootstrap/parking window (architecture §3.8): created BEFORE any
// surface so every surface is born inside a native window with a correct
// backing view. Parked surfaces keep running (occluded processing was proven
// in the spike) while remaining invisible.

@MainActor public protocol TerminalParkingHosting: AnyObject {
    /// Content view the parked surface views attach to.
    var parkingContentView: NSView { get }
    /// Attaches (re-parents) a view into the parking host.
    func park(_ view: NSView)
}

@MainActor public final class TerminalParkingHost: TerminalParkingHosting {
    public let window: NSWindow
    public let parkingContentView: NSView

    /// Creates the hidden bootstrap window. Call once during app bootstrap,
    /// before any surface exists.
    public init(size: NSSize = NSSize(width: 800, height: 600)) {
        parkingContentView = NSView(frame: NSRect(origin: .zero, size: size))
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentTerminal ParkingHost (hidden)"
        window.isReleasedWhenClosed = false
        window.contentView = parkingContentView
        // Hidden bootstrap window: never ordered front during normal operation.
        window.orderOut(nil)
    }

    public func park(_ view: NSView) {
        if view.window !== window {
            view.removeFromSuperview()
            parkingContentView.addSubview(view)
        }
        // Re-enable autoresizing (mount's constrainFill disables it): otherwise
        // frame/autoresizing below are inert and the parked view keeps a stale
        // frame when the parking window resizes.
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = parkingContentView.bounds
        view.autoresizingMask = [.width, .height]
        parkingContentView.needsLayout = true
    }
}
