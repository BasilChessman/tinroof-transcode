import AppKit
import MediaCore

/// Displays decoded frames, letterboxed.
final class VideoView: NSView {
    var onDoubleClick: (() -> Void)?
    var onScroll: ((CGFloat, NSEvent.ModifierFlags) -> Void)?
    var onFileDrop: (([URL], NSEvent.ModifierFlags) -> Void)?
    private var message: CATextLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    func showMessage(_ text: String?) {
        message?.removeFromSuperlayer()
        message = nil
        guard let text, let layer else { return }
        let t = CATextLayer()
        t.string = text
        t.fontSize = 14
        t.alignmentMode = .center
        t.foregroundColor = NSColor.secondaryLabelColor.cgColor
        t.contentsScale = window?.backingScaleFactor ?? 2
        t.frame = CGRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 22)
        t.autoresizingMask = [.layerWidthSizable, .layerMinYMargin, .layerMaxYMargin]
        layer.addSublayer(t)
        message = t
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        let d = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : -event.scrollingDeltaX
        onScroll?(d, event.modifierFlags)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
        onFileDrop?(urls, NSEvent.modifierFlags)
        return true
    }
}

/// Timeline with playhead, In/Out selection, cut points and keyframe ticks.
final class TimelineView: NSView {
    var window_: ClosedRange<Double> = 0...1 { didSet { needsDisplay = true } }
    var position: Double = 0 { didSet { needsDisplay = true } }
    var selection: ClosedRange<Double>? { didSet { needsDisplay = true } }
    var cutPoints: [Double] = [] { didSet { needsDisplay = true } }
    var markers: [Double] = [] { didSet { needsDisplay = true } }
    var progress: Double? { didSet { needsDisplay = true } }
    /// Called while dragging; second argument is true when Shift extends the selection.
    var onSeek: ((Double, Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragAnchor: Double?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    private var track: NSRect { bounds.insetBy(dx: 8, dy: 6) }

    private func x(for t: Double) -> CGFloat {
        let span = max(window_.upperBound - window_.lowerBound, 0.000_001)
        return track.minX + CGFloat((t - window_.lowerBound) / span) * track.width
    }

    private func time(for x: CGFloat) -> Double {
        let span = window_.upperBound - window_.lowerBound
        let f = Double(min(max(0, (x - track.minX) / max(track.width, 1)), 1))
        return window_.lowerBound + f * span
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = track
        let bar = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.midY - 4, width: r.width, height: 8), xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.setFill()
        bar.fill()
        if let p = progress {
            NSColor.systemGray.withAlphaComponent(0.4).setFill()
            NSRect(x: r.minX, y: r.midY - 4, width: r.width * CGFloat(p), height: 8).fill()
        }
        if let sel = selection {
            NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
            NSRect(x: x(for: sel.lowerBound), y: r.midY - 6, width: max(1, x(for: sel.upperBound) - x(for: sel.lowerBound)), height: 12).fill()
        }
        NSColor.systemRed.setFill()
        for c in cutPoints where c > window_.lowerBound && c < window_.upperBound {
            NSRect(x: x(for: c) - 1, y: r.minY, width: 2, height: r.height).fill()
        }
        NSColor.systemOrange.setFill()
        for m in markers where m > window_.lowerBound && m < window_.upperBound {
            NSRect(x: x(for: m) - 0.5, y: r.maxY - 5, width: 1, height: 5).fill()
        }
        let px = x(for: position)
        let head = NSBezierPath()
        head.move(to: NSPoint(x: px - 5, y: r.minY))
        head.line(to: NSPoint(x: px + 5, y: r.minY))
        head.line(to: NSPoint(x: px, y: r.minY + 7))
        head.close()
        NSColor.labelColor.setFill()
        head.fill()
        NSRect(x: px - 0.5, y: r.minY, width: 1, height: r.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let t = time(for: convert(event.locationInWindow, from: nil).x)
        let extend = event.modifierFlags.contains(.shift)
        dragAnchor = extend ? position : nil
        onSeek?(t, extend)
    }

    override func mouseDragged(with event: NSEvent) {
        let t = time(for: convert(event.locationInWindow, from: nil).x)
        onSeek?(t, event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) { onDragEnded?() }
}
