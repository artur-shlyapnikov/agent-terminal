import AgentCore
import AppKit

// Reparent surface views between the parking host and pane containers
// (architecture §3.8 mount/park): a move never creates a new PTY and never
// changes the generation. Parked surfaces get occlusion=true so libghostty can
// throttle rendering while output keeps flowing.

@MainActor public final class TerminalMountCoordinator {
    private let parkingHost: any TerminalParkingHosting
    /// Live fill constraints per surface view; re-mounting deactivates the
    /// previous set first so repeated park->mount cycles don't accumulate.
    private var fillConstraints: [ObjectIdentifier: [NSLayoutConstraint]] = [:]

    public init(parkingHost: any TerminalParkingHosting) {
        self.parkingHost = parkingHost
    }

    /// Re-parents a parked surface into `container`, filling it.
    public func mount(_ surface: GhosttySurface, into container: NSView, paneID: PaneID) throws {
        guard !surface.isClosing else {
            throw TerminalKitError.surfaceClosing(terminalID: surface.terminalID)
        }
        guard container !== parkingHost.parkingContentView else {
            throw TerminalKitError.mountIntoParkingHost(terminalID: surface.terminalID)
        }
        if surface.view.superview !== container {
            surface.view.removeFromSuperview()
            container.addSubview(surface.view)
        }
        constrainFill(surface.view, to: container)
        surface.presentation = .mounted(paneID)
        // Occlusion follows the host window's live visibility — a surface
        // mounted into a covered/minimized window keeps throttling. The view
        // keeps flipping on NSWindow.didChangeOcclusionState; windowless
        // containers (tests) preserve the unthrottled default. The view's
        // windowVisibleOverride seam (deterministic tests) wins over the live
        // read so both writers agree.
        let windowVisible = surface.view.windowVisibleOverride
            ?? container.window?.occlusionState.contains(.visible) ?? true
        surface.native.setOccluded(!windowVisible)
        surface.native.setFocus(true)
    }

    /// Moves a mounted (or new) surface back into the hidden parking window.
    public func park(_ surface: GhosttySurface) {
        guard !surface.isClosing else { return }
        // Deactivate and drop this view's fill constraints: otherwise the map
        // retains closed terminals' views+containers forever.
        NSLayoutConstraint.deactivate(fillConstraints[ObjectIdentifier(surface.view)] ?? [])
        fillConstraints[ObjectIdentifier(surface.view)] = nil
        parkingHost.park(surface.view)
        surface.presentation = .parked
        surface.native.setFocus(false)
        surface.native.setOccluded(true)
    }

    private func constrainFill(_ view: NSView, to container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.deactivate(fillConstraints[ObjectIdentifier(view)] ?? [])
        let constraints = [
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        fillConstraints[ObjectIdentifier(view)] = constraints
        container.needsLayout = true
    }
}

public enum TerminalKitError: Error, Equatable {
    case surfaceClosing(terminalID: TerminalID)
    case mountIntoParkingHost(terminalID: TerminalID)
    case unknownTerminal(TerminalID)
    case terminalNotLaunched(TerminalID)
    case signalDeliveryFailed(intent: String, status: Int32)
    case launchTicketWriterUnavailable
}
