import AgentCore
import AppKit
import Foundation
@testable import TerminalKit

// Shared fake-based doubles: zero libghostty involvement (§4.3 test law).

@MainActor final class FakeNativeSurface: NativeTerminalSurface {
    struct Call: Equatable {
        let kind: String
        let detail: String
    }

    private(set) var calls: [Call] = []
    var screenText: String?
    var viewportText: String?
    var processExitedFlag = false
    var foregroundPIDValue: UInt64 = 0
    var gridValue: (columns: UInt32, rows: UInt32)?
    private(set) var freed = false

    func record(_ kind: String, _ detail: String = "") {
        calls.append(Call(kind: kind, detail: detail))
    }

    func setFocus(_ focused: Bool) {
        record("setFocus", focused ? "1" : "0")
    }

    func setOccluded(_ occluded: Bool) {
        record("setOccluded", occluded ? "1" : "0")
    }

    func resize(widthPixels: UInt32, heightPixels: UInt32, scaleFactor: Double) {
        record("resize", "\(widthPixels)x\(heightPixels)@\(scaleFactor)")
    }

    func sendText(_ text: String) {
        record("sendText", text)
    }

    func sendKey(_ key: GhosttyKeyEvent) -> Bool {
        record("sendKey", "code=\(key.keycode) action=\(key.action) text=\(key.text ?? "-")")
        return true
    }

    func sendPreedit(_ text: String?) {
        record("sendPreedit", text ?? "")
    }

    func mouseButton(state _: MouseButtonState, button _: MouseButton, modifiers _: KeyModifiers) -> Bool {
        record("mouseButton"); return true
    }

    func mousePosition(x _: Double, y _: Double, modifiers _: KeyModifiers) {
        record("mousePosition")
    }

    func mouseScroll(dx _: Double, dy _: Double, packedModifiers _: Int32) {
        record("mouseScroll")
    }

    func isProcessExited() -> Bool {
        processExitedFlag
    }

    func foregroundPID() -> UInt64 {
        foregroundPIDValue
    }

    func gridSize() -> (columns: UInt32, rows: UInt32)? {
        gridValue
    }

    func readScreen() -> String? {
        screenText
    }

    func readViewport() -> String? {
        viewportText
    }

    func performFree() {
        freed = true; record("free")
    }

    var lastText: String? {
        calls.reversed().first(where: { $0.kind == "sendText" })?.detail
    }
}

@MainActor final class FakeEngine: TerminalEngine {
    var eventSink: (@MainActor (GhosttyEvent) -> Void)?
    private(set) var surfaces: [FakeNativeSurface] = []
    /// Launch specs handed to createSurface, in creation order.
    private(set) var createdSpecs: [TerminalLaunchSpec] = []
    private(set) var tickCount = 0
    private(set) var shutdownCount = 0
    /// Surfaces created since the last reset — used for cycle counting.
    var nextScreenText: ((TerminalLaunchSpec) -> String?)?
    /// Test-only hook: observes the SurfaceCallbackBox handed to
    /// createSurface so a test can deliver payloads WHILE no sink is
    /// installed (reproduces an instantly-exiting command's buffered
    /// `.childExited`, §3.18 pre-sink buffering).
    var onCreateSurfaceBox: ((SurfaceCallbackBox) -> Void)?

    func tick() {
        tickCount += 1
    }

    func createSurface(
        view: NSView,
        spec: TerminalLaunchSpec,
        box: SurfaceCallbackBox
    ) throws -> any NativeTerminalSurface {
        let surface = FakeNativeSurface()
        surface.screenText = nextScreenText?(spec)
        surfaces.append(surface)
        view.wantsLayer = true
        createdSpecs.append(spec)
        onCreateSurfaceBox?(box)
        return surface
    }

    func shutdown() {
        shutdownCount += 1
    }
}

@MainActor final class FakeParkingHost: TerminalParkingHosting {
    let parkingContentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private(set) var parkedViews: [NSView] = []

    func park(_ view: NSView) {
        view.removeFromSuperview()
        parkingContentView.addSubview(view)
        parkedViews.append(view)
    }

    func contains(_ view: NSView) -> Bool {
        view.superview === parkingContentView
    }
}
