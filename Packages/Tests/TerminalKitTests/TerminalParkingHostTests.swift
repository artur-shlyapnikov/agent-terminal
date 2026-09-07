import AppKit
@testable import TerminalKit
import XCTest

// Gap #9 — the REAL `TerminalParkingHost.park`: window-identity guard skips
// re-parenting for views already inside the parking window (even nested),
// while frame/autoresizing fixup runs unconditionally, and foreign-window
// views are adopted. Creating a hidden NSWindow headless is established
// practice in this suite; every created window is closed at test end.

@MainActor
final class TerminalParkingHostTests: XCTestCase {
    private func makeHost(size: NSSize = NSSize(width: 800, height: 600)) -> TerminalParkingHost {
        TerminalParkingHost(size: size)
    }

    // MARK: G1

    func testParkAdoptsOrphanViewSetFrameAutoresizingExactlyOnce() {
        let host = makeHost()
        defer { host.window.close() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))

        host.park(view)
        host.park(view) // idempotence probe

        XCTAssertTrue(view.superview === host.parkingContentView)
        XCTAssertEqual(
            host.parkingContentView.subviews.filter { $0 === view }.count, 1,
            "the window-identity guard must prevent remove/add churn on re-park"
        )
        XCTAssertTrue(NSEqualRects(view.frame, host.parkingContentView.bounds))
        XCTAssertTrue(view.autoresizingMask.contains(.width))
        XCTAssertTrue(view.autoresizingMask.contains(.height))
    }

    // MARK: G2

    func testResizeOfParkingContentPropagatesToParkedViewViaAutoresizingMask() {
        let host = makeHost()
        defer { host.window.close() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        host.park(view)

        host.parkingContentView.setFrameSize(NSSize(width: 320, height: 240))
        host.parkingContentView.layoutSubtreeIfNeeded()

        XCTAssertLessThan(abs(view.frame.width - 320), 0.5)
        XCTAssertLessThan(abs(view.frame.height - 240), 0.5)
    }

    // MARK: G3

    func testWindowIdentityGuardKeepsNestedViewsInPlaceButAdoptsForeignWindowViews() {
        let host = makeHost()
        defer { host.window.close() }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.park(container)
        let nested = NSView(frame: NSRect(x: 5, y: 5, width: 20, height: 20))
        container.addSubview(nested)

        // Foreign window kept unreleased so its view stays valid for asserts.
        let foreignWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        foreignWindow.isReleasedWhenClosed = false
        foreignWindow.orderOut(nil)
        defer { foreignWindow.close() }
        let foreign = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        foreignWindow.contentView?.addSubview(foreign)

        host.park(nested)
        host.park(foreign)

        // Identity shortcut: already inside the parking WINDOW — no
        // reparenting out of the mid-level container…
        XCTAssertTrue(nested.superview === container,
                      "a view nested inside the parking window must stay put")
        // …but the frame fixup still ran unconditionally.
        XCTAssertTrue(NSEqualRects(nested.frame, host.parkingContentView.bounds))

        // Cross-window adoption happened into the parking content view.
        XCTAssertTrue(foreign.superview === host.parkingContentView)
        XCTAssertTrue(foreign.window === host.window)
    }

    // MARK: PH-A

    func testBootstrapWindowIsHiddenBorderlessRetainedAndSized() {
        let host = makeHost(size: NSSize(width: 320, height: 240))
        defer { host.window.close() }

        XCTAssertEqual(host.window.styleMask, [.borderless])
        XCTAssertFalse(host.window.isReleasedWhenClosed, "teardown safety depends on the window surviving close")
        XCTAssertFalse(host.window.isVisible, "the hidden bootstrap window is never ordered front")
        XCTAssertTrue(host.window.contentView === host.parkingContentView)
        XCTAssertTrue(
            NSEqualRects(
                host.parkingContentView.frame,
                NSRect(origin: .zero, size: NSSize(width: 320, height: 240))
            ),
            "the custom bootstrap size must be honored"
        )
    }

    // MARK: PH-B

    func testParkRestoresAutoresizingMaskSemanticsOnConstraintLaidOutView() {
        let host = makeHost()
        defer { host.window.close() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        host.parkingContentView.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        // Simulates the post-constrainFill mount state exactly: edge pins to
        // the superview (a constant-width anchor would itself override the
        // autoresizing frame at layout time — verified — and does not model
        // constrainFill). These stay ACTIVE through every assert below.
        let pins = [
            view.leadingAnchor.constraint(equalTo: host.parkingContentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.parkingContentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.parkingContentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.parkingContentView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(pins)

        host.park(view)

        XCTAssertTrue(
            view.translatesAutoresizingMaskIntoConstraints,
            "park must re-enable autoresizing semantics the mount's constrainFill disabled"
        )
        XCTAssertTrue(
            NSEqualRects(view.frame, host.parkingContentView.bounds),
            "explicit frame must win over stale constraints"
        )

        // Resize propagates despite the still-installed, still-ACTIVE stale
        // edge constraints: autoresizing wins only because
        // translatesAutoresizingMaskIntoConstraints is true again.
        XCTAssertTrue(pins.allSatisfy(\.isActive), "the stale constraint set must remain active through the resize")
        host.parkingContentView.setFrameSize(NSSize(width: 320, height: 240))
        host.parkingContentView.layoutSubtreeIfNeeded()

        XCTAssertLessThan(abs(view.frame.width - 320), 0.5)
        XCTAssertLessThan(abs(view.frame.height - 240), 0.5)
    }
}
