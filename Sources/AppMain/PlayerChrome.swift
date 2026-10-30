import AppKit
import MediaCore

/// Classic player layout shared by the empty player and the clip player, after MPEG Streamclip:
/// a caption header, a recessed grey picture well, the timeline, and one bar of controls
/// (Video PID, Audio PID, Audio Mode, transport, In ⇔ Out, Trimming).
enum ChromeStyle {
    static let background = NSColor(white: 0.60, alpha: 1)
    static let headerBand = NSColor(white: 0.70, alpha: 1)
    static let wellFill = NSColor(white: 0.55, alpha: 1)
    static let wellBorder = NSColor(white: 0.36, alpha: 1)
    static let caption = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let time = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
}

/// Solid background for the player window.
class ChromeBackgroundView: NSView {
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        ChromeStyle.background.setFill()
        dirtyRect.fill()
    }
}

/// The recessed panel the picture (or the logo) sits in.
final class WellView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        ChromeStyle.wellFill.setFill()
        bounds.fill()
        ChromeStyle.wellBorder.setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        p.stroke()
        // Inner highlight along the bottom and right, as in a bevelled inset.
        NSColor(white: 0.68, alpha: 1).setStroke()
        let h = NSBezierPath()
        h.move(to: NSPoint(x: 1.5, y: 1.5)); h.line(to: NSPoint(x: bounds.maxX - 1.5, y: 1.5)); h.line(to: NSPoint(x: bounds.maxX - 1.5, y: bounds.maxY - 1.5))
        h.lineWidth = 1
        h.stroke()
    }
}

/// The app icon in a thin square frame, centred in the empty well.
final class LogoBoxView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(image: Bundle.main.image(forResource: "AppIcon") ?? NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.unregisterDraggedTypes()
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalTo: widthAnchor, constant: -14),
            icon.heightAnchor.constraint(equalTo: heightAnchor, constant: -14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        p.stroke()
    }
}

/// Rounded inset holding the In and Out times.
final class InOutBoxView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor(white: 0.52, alpha: 1).setFill()
        p.fill()
        NSColor(white: 0.38, alpha: 1).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

@MainActor
final class PlayerChrome {
    let well = WellView()
    let timeline = TimelineView()
    let videoPopup = NSPopUpButton(), audioPopup = NSPopUpButton(), modePopup = NSPopUpButton()
    let stateLabel = NSTextField(labelWithString: "■")
    let timeLabel = NSTextField(labelWithString: "0:00:00.00")
    let inLabel = NSTextField(labelWithString: "0:00:00.00")
    let outLabel = NSTextField(labelWithString: "0:00:00.00")
    let trimStartLabel = NSTextField(labelWithString: "0:00:00.00")
    let trimEndLabel = NSTextField(labelWithString: "0:00:00.00")
    let skipBack: NSButton, reverse: NSButton, play: NSButton, forward: NSButton, skipForward: NSButton
    var transport: [NSButton] { [skipBack, reverse, play, forward, skipForward] }

    /// Height of every group in the bottom bar, so captions and controls line up.
    static let barHeight: CGFloat = 46
    static let tagline = "High-quality converter for MPEG files, transport streams and modern video"
    static var subtitle: String { "\(AppInfo.name) \(AppInfo.version)  –  Free" }

    private static func roundButton(_ symbol: String, _ tip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))!
        let b = NSButton(image: image, target: nil, action: nil)
        b.bezelStyle = .circular
        b.controlSize = .small
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    private static func caption(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = ChromeStyle.caption
        l.textColor = NSColor(white: 0.1, alpha: 1)
        l.alignment = .center
        return l
    }

    private static func group(_ title: String, _ control: NSView) -> NSStackView {
        let s = NSStackView(views: [caption(title), control])
        s.orientation = .vertical
        s.spacing = 2
        s.alignment = .centerX
        s.distribution = .equalSpacing
        s.heightAnchor.constraint(equalToConstant: barHeight).isActive = true
        return s
    }

    /// Builds the layout into `content`; `picture` is placed inside the well, filling it.
    init(in content: NSView, picture: NSView) {
        skipBack = Self.roundButton("backward.fill", "Skip back (Page Up). Option: 1 minute")
        reverse = Self.roundButton("arrowtriangle.backward.fill", "Play backwards / faster (J). Option: slow motion")
        play = Self.roundButton("play.fill", "Play / Stop (Space). Option: loop selection")
        forward = Self.roundButton("arrowtriangle.forward", "Play faster (L). Option: slow motion")
        skipForward = Self.roundButton("forward.fill", "Skip forward (Page Down). Option: 1 minute")

        // Header: a light band with the tagline, then the subtitle.
        let band = NSView()
        band.wantsLayer = true
        band.layer?.backgroundColor = ChromeStyle.headerBand.cgColor
        let tag = NSTextField(labelWithString: Self.tagline)
        tag.font = .systemFont(ofSize: 12, weight: .bold)
        tag.textColor = .white
        tag.alignment = .center
        let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.35); shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.shadowBlurRadius = 1
        tag.shadow = shadow
        let sub = NSTextField(labelWithString: Self.subtitle)
        sub.font = .systemFont(ofSize: 12, weight: .bold)
        sub.textColor = .black
        sub.alignment = .center

        // Picture well.
        picture.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(picture)

        // Bottom bar.
        [videoPopup, audioPopup, modePopup].forEach { $0.controlSize = .small; $0.font = .systemFont(ofSize: 11) }
        videoPopup.widthAnchor.constraint(equalToConstant: 96).isActive = true
        audioPopup.widthAnchor.constraint(equalToConstant: 140).isActive = true
        modePopup.widthAnchor.constraint(equalToConstant: 110).isActive = true

        for l in [timeLabel, inLabel, outLabel] { l.font = ChromeStyle.time; l.textColor = .black }
        for l in [trimStartLabel, trimEndLabel] { l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); l.textColor = .black }
        stateLabel.font = .systemFont(ofSize: 9, weight: .bold)
        stateLabel.textColor = .black

        let timeRow = NSStackView(views: [stateLabel, NSView(), timeLabel])
        timeRow.distribution = .fill
        let buttons = NSStackView(views: transport)
        buttons.spacing = 3
        let transportGroup = NSStackView(views: [timeRow, buttons])
        transportGroup.orientation = .vertical
        transportGroup.spacing = 1
        transportGroup.alignment = .width
        transportGroup.distribution = .equalSpacing
        transportGroup.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true

        let inOutBox = InOutBoxView()
        let inCap = Self.caption("In"), arrow = Self.caption("⇔"), outCap = Self.caption("Out")
        let capRow = NSStackView(views: [inCap, arrow, outCap]); capRow.distribution = .equalCentering
        let timesRow = NSStackView(views: [inLabel, outLabel]); timesRow.spacing = 10
        let inOut = NSStackView(views: [capRow, timesRow])
        inOut.orientation = .vertical; inOut.spacing = 1; inOut.alignment = .width
        inOut.translatesAutoresizingMaskIntoConstraints = false
        inOutBox.addSubview(inOut)
        NSLayoutConstraint.activate([
            inOut.leadingAnchor.constraint(equalTo: inOutBox.leadingAnchor, constant: 10),
            inOut.trailingAnchor.constraint(equalTo: inOutBox.trailingAnchor, constant: -10),
            inOut.topAnchor.constraint(equalTo: inOutBox.topAnchor, constant: 3),
            inOut.bottomAnchor.constraint(equalTo: inOutBox.bottomAnchor, constant: -3),
        ])

        let trimming = NSStackView(views: [Self.caption("Trimming"), trimStartLabel, trimEndLabel])
        trimming.orientation = .vertical; trimming.spacing = 0; trimming.alignment = .trailing
        trimming.distribution = .equalSpacing
        trimming.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true
        inOutBox.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true

        let bar = NSStackView(views: [Self.group("Video PID", videoPopup), Self.group("Audio PID", audioPopup),
                                      Self.group("Audio Mode", modePopup), transportGroup, inOutBox, trimming])
        bar.spacing = 12
        bar.alignment = .centerY
        bar.distribution = .fill

        for v in [band, sub, well, timeline, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        tag.translatesAutoresizingMaskIntoConstraints = false
        band.addSubview(tag)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: content.topAnchor),
            band.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            band.heightAnchor.constraint(equalToConstant: 20),
            tag.centerXAnchor.constraint(equalTo: band.centerXAnchor),
            tag.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            sub.topAnchor.constraint(equalTo: band.bottomAnchor, constant: 4),
            sub.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            well.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 8),
            well.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            well.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            picture.topAnchor.constraint(equalTo: well.topAnchor, constant: 1),
            picture.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 1),
            picture.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -1),
            picture.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -1),

            timeline.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 4),
            timeline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            timeline.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            timeline.heightAnchor.constraint(equalToConstant: 24),

            bar.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 2),
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    /// Width the bottom bar needs; windows use it as their minimum width.
    static let minimumWidth: CGFloat = 760
    /// Height of everything except the picture.
    static let chromeHeight: CGFloat = 20 + 4 + 16 + 8 + 4 + 24 + 2 + 52 + 10 + 2

    /// Empty state: placeholder track menus, controls disabled, times at zero.
    func showEmpty() {
        for p in [videoPopup, audioPopup, modePopup] {
            p.removeAllItems()
            p.addItem(withTitle: "–")
            p.isEnabled = false
        }
        transport.forEach { $0.isEnabled = false }
        for l in [timeLabel, inLabel, outLabel, trimStartLabel, trimEndLabel] { l.stringValue = Timecode.format(0) }
        timeline.window_ = 0...1
        timeline.position = 0
        timeline.selection = nil
        timeline.alphaValue = 0.5
    }
}

extension StreamInfo {
    /// Compact pop-up title, as in the original's PID menus: the PID/stream ID, plus the format for audio.
    var shortTitle: String {
        let id = streamID > 0 ? String(format: "0x%X", streamID) : "#\(index)"
        switch kind {
        case .audio:
            let layout = channelLayout.isEmpty ? "\(channels) ch" : channelLayout
            return "\(id)  \(codec.uppercased()) \(layout)" + (language.isEmpty ? "" : " [\(language)]")
        default:
            return id
        }
    }
}
