import AgentCore
import AppKit

// Canvas host view: positions pane views from the planner and draws/handles
// divider drag-resize (ratio clamped to LayoutTree.ratioRange).

@MainActor protocol CanvasViewDelegate: AnyObject {
    func canvasFrames() -> [CanvasFrameRequest]
    func canvasLayoutSubviews()
    func canvasDividers() -> [DividerGeometry]
    func canvasResize(path: [Int], ratio: Double)
}

@MainActor
final class CanvasView: NSView {
    weak var delegate: (any CanvasViewDelegate)?

    private var dragDivider: DividerGeometry?
    private var dragStartLocation: NSPoint = .zero
    private var dragStartRatio: Double = 0.5

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        delegate?.canvasLayoutSubviews()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        for divider in delegate?.canvasDividers() ?? [] {
            NSColor.separatorColor.setFill()
            divider.rect.fill()
        }
    }

    // MARK: divider drag

    /// Half-width of the grab zone around the visual 2pt band; ±5pt gives a
    /// 10pt total hit/cursor target while draw() keeps painting the 2pt rect.
    private static let hitMargin: CGFloat = 5

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hitDivider(at: point) else {
            super.mouseDown(with: event)
            return
        }
        dragDivider = hit
        dragStartLocation = point
        // Ratio at drag start: position along the parent bounds. If the frame
        // cannot be resolved (stale path mid-rebuild), abort the drag entirely.
        guard let startRatio = currentRatio(of: hit) else {
            dragDivider = nil
            return
        }
        dragStartRatio = startRatio
    }

    override func mouseDragged(with event: NSEvent) {
        guard let divider = dragDivider else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let nodeFrame = frame(ofSplitAtPath: divider.path) else { return }
        let delta: CGFloat
        let span: CGFloat
        if divider.axis == .horizontal {
            delta = point.x - dragStartLocation.x
            span = nodeFrame.width
        } else {
            delta = point.y - dragStartLocation.y
            span = nodeFrame.height
        }
        guard span > 0 else { return }
        let fraction = Double(delta) / Double(span)
        let newRatio = min(
            max(dragStartRatio + fraction, LayoutTree.ratioRange.lowerBound),
            LayoutTree.ratioRange.upperBound
        )
        delegate?.canvasResize(path: divider.path, ratio: newRatio)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragDivider = nil
        super.mouseUp(with: event)
    }

    override func resetCursorRects() {
        for divider in delegate?.canvasDividers() ?? [] {
            addCursorRect(divider.rect.insetBy(dx: -Self.hitMargin, dy: -Self.hitMargin),
                          cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    private func hitDivider(at point: NSPoint) -> DividerGeometry? {
        delegate?.canvasDividers().first {
            $0.rect.insetBy(dx: -Self.hitMargin, dy: -Self.hitMargin).contains(point)
        }
    }

    // MARK: nested-split geometry

    /// Frame of the split node owning the divider at `path`, or nil when any
    /// ancestor divider is missing (stale path during a rebuild): returning a
    /// partially resolved frame would make drags compute a wild fraction.
    /// Dividers carry only their band rect, so the frame is rebuilt top-down:
    /// each ancestor divider's position inside its already-resolved parent
    /// frame yields that ancestor's ratio, which yields the child frame —
    /// mirroring CanvasLayoutPlanner's geometry. Measuring drags against this
    /// frame (not the whole canvas) keeps sibling splits unaffected.
    private func frame(ofSplitAtPath path: [Int]) -> CGRect? {
        guard let lastIndex = path.indices.last else { return bounds }
        var frame = bounds
        for depth in 0 ... lastIndex {
            guard let ancestor = divider(at: Array(path[0 ..< depth])) else { return nil }
            let ratio = Self.clamp(ratio(of: ancestor, in: frame))
            switch ancestor.axis {
            case .horizontal:
                let leadingWidth = frame.width * CGFloat(ratio)
                frame = path[depth] == 0
                    ? CGRect(x: frame.minX, y: frame.minY, width: leadingWidth, height: frame.height)
                    : CGRect(x: frame.minX + leadingWidth, y: frame.minY,
                             width: frame.width - leadingWidth, height: frame.height)
            case .vertical:
                let leadingHeight = frame.height * CGFloat(ratio)
                frame = path[depth] == 0
                    ? CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: leadingHeight)
                    : CGRect(x: frame.minX, y: frame.minY + leadingHeight,
                             width: frame.width, height: frame.height - leadingHeight)
            }
        }
        return frame
    }

    private func divider(at path: [Int]) -> DividerGeometry? {
        delegate?.canvasDividers().first { $0.path == path }
    }

    /// Current ratio of the split owning `divider`, measured against that
    /// node's own frame — not the whole canvas — so nested splits stay put.
    private func currentRatio(of divider: DividerGeometry) -> Double? {
        frame(ofSplitAtPath: divider.path).map { ratio(of: divider, in: $0) }
    }

    private func ratio(of divider: DividerGeometry, in frame: CGRect) -> Double {
        switch divider.axis {
        case .horizontal:
            Double((divider.rect.midX - frame.minX) / max(frame.width, 1))
        case .vertical:
            Double((divider.rect.midY - frame.minY) / max(frame.height, 1))
        }
    }

    private static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, LayoutTree.ratioRange.lowerBound), LayoutTree.ratioRange.upperBound)
    }
}
