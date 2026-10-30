import AppKit

/// Content of the empty player: the classic layout with controls disabled. Clicking anywhere
/// opens the Open dialog; dropping files opens them.
final class EmptyPlayerView: ChromeBackgroundView {
    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if highlighted {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 10, yRadius: 10)
            path.lineWidth = 3
            path.setLineDash([10, 6], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { highlighted = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/// The picture area of the empty player: the app logo in a framed box, centred.
final class EmptyPictureView: NSView {
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        let logo = LogoBoxView()
        logo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 118),
            logo.heightAnchor.constraint(equalToConstant: 118),
        ])
        toolTip = "Click to open a video, or drop one here"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor
final class EmptyPlayerWindowController: NSWindowController, NSWindowDelegate {
    private var chrome: PlayerChrome!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PlayerChrome.minimumWidth, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(AppInfo.name) \(AppInfo.version)"
        window.minSize = NSSize(width: PlayerChrome.minimumWidth, height: 420)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let content = EmptyPlayerView(frame: window.contentRect(forFrameRect: window.frame))
        let picture = EmptyPictureView()
        let open = { AppDelegate.shared.openFiles(nil) }
        content.onClick = open
        picture.onClick = open
        content.onDrop = { urls in AppDelegate.shared.open(urls) }
        window.contentView = content
        super.init(window: window)
        chrome = PlayerChrome(in: content, picture: picture)
        chrome.showEmpty()
        window.delegate = self
        window.setFrameAutosaveName("EmptyPlayer")
        if !window.setFrameUsingName("EmptyPlayer") { window.center() }
    }

    required init?(coder: NSCoder) { fatalError() }
}
