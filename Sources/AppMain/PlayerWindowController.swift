import AppKit
import Combine
import UniformTypeIdentifiers
import MediaCore

/// Content view that receives the player's keyboard shortcuts.
final class PlayerContentView: NSView, NSMenuItemValidation {
    weak var controller: PlayerWindowController?

    // NSWindow handles undo:/redo: itself (with its own, always-empty undo manager) before the
    // window controller is reached, so the content view forwards them to the edit history.
    @objc func undo(_ sender: Any?) { controller?.undo(sender) }
    @objc func redo(_ sender: Any?) { controller?.redo(sender) }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { controller?.validateMenuItem(item) ?? false }

    // Files dropped anywhere on the player window: ask whether to append or replace.
    override func viewDidMoveToWindow() { registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
        controller?.handleDrop(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        ChromeStyle.background.setFill()
        dirtyRect.fill()
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let doc: PlayerDocument
    let engine = PlaybackEngine()
    private let videoView = VideoView()
    private var chrome: PlayerChrome!
    private var timeline: TimelineView { chrome.timeline }
    private var timeLabel: NSTextField { chrome.timeLabel }
    private var videoPopup: NSPopUpButton { chrome.videoPopup }
    private var audioPopup: NSPopUpButton { chrome.audioPopup }
    private var modePopup: NSPopUpButton { chrome.modePopup }
    private var playButton: NSButton { chrome.play }
    /// Volume is set from the keyboard (⌘↑ / ⌘↓); this slider is not shown in the classic layout.
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var cancellables = Set<AnyCancellable>()
    private var uiTimer: Timer?
    private var selectionAnchor: Double?
    private var lastImageSize: CGSize = .zero
    private var shuttleRate = 0.0
    /// Last displayed frame and the view showing it (used by screenshot mode).
    private(set) var currentFrameImage: CGImage?
    var videoArea: NSView? { videoView }

    init(doc: PlayerDocument) {
        self.doc = doc
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: PlayerChrome.minimumWidth, height: 420)
        super.init(window: window)
        shouldCascadeWindows = false   // new players take the place of the empty player or a replaced clip
        window.delegate = self
        window.title = doc.title
        window.representedURL = doc.primary.locations.first?.isFileURL == true ? doc.primary.locations.first : nil
        buildUI()
        bind()
        window.initialFirstResponder = window.contentView
        window.makeFirstResponder(window.contentView)
        doc.buildIndex()
        resizeToFit(scale: 1)
        window.center()
        refreshFrame()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.toolTip = tip
        return b
    }

    private func buildUI() {
        let content = PlayerContentView()
        content.controller = self
        window!.contentView = content

        window?.appearance = NSAppearance(named: .aqua)   // the classic grey player is always light
        chrome = PlayerChrome(in: content, picture: videoView)
        let actions: [Selector] = [#selector(skipBackward(_:)), #selector(reversePlay(_:)), #selector(playStop(_:)),
                                   #selector(forwardPlay(_:)), #selector(skipForward(_:))]
        for (b, a) in zip(chrome.transport, actions) { b.target = self; b.action = a }

        videoPopup.target = self; videoPopup.action = #selector(videoTrackChanged(_:))
        audioPopup.target = self; audioPopup.action = #selector(audioTrackChanged(_:))
        modePopup.target = self; modePopup.action = #selector(audioModeChanged(_:))
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))

        videoView.onDoubleClick = { [weak self] in self?.playStop(nil) }
        videoView.onScroll = { [weak self] delta, mods in
            guard let self, abs(delta) > 0.5 else { return }
            let frames = mods.contains(.option) ? 10.0 : 1.0
            self.move(to: self.doc.position + (delta > 0 ? -1 : 1) * frames * self.doc.frameDuration, extend: mods.contains(.shift))
        }
        // Dropping clips onto a player appends them to the end of its stream (as in MPEG Streamclip).
        videoView.onFileDrop = { [weak self] urls, _ in self?.handleDrop(urls) }
        timeline.onSeek = { [weak self] t, extend in self?.move(to: t, extend: extend) }

        engine.onFrame = { [weak self] image, time in
            guard let self else { return }
            self.videoView.show(image)
            self.currentFrameImage = image
            self.lastImageSize = CGSize(width: image.width, height: image.height)
            if !self.engine.isPlaying { self.doc.position = time }
        }
        engine.onStop = { [weak self] in
            guard let self else { return }
            self.doc.position = self.doc.clampToWindow(self.engine.clock.now())
            self.shuttleRate = 0
            self.updatePlayButton()
            self.refreshFrame()
        }
        engine.volume = 1
        if doc.videoStream == nil {
            videoView.showMessage(doc.primary.info.audioStreams.isEmpty ? "No playable tracks" : "Audio only")
        }
    }

    private func bind() {
        doc.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refreshControls() }
        }.store(in: &cancellables)
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engine.isPlaying else { return }
                let t = self.engine.clock.now()
                self.timeline.position = t
                self.timeLabel.stringValue = Timecode.format(t)
            }
        }
        refreshControls()
    }

    func refreshControls() {
        let d = doc
        timeline.window_ = d.window.upperBound > d.window.lowerBound ? d.window : 0...max(1, d.window.upperBound)
        if !engine.isPlaying { timeline.position = d.position }
        timeline.selection = d.hasSelection ? d.selection : nil
        timeline.cutPoints = d.edit.cutPoints
        timeline.progress = d.indexingProgress
        timeline.markers = d.fixTimecodeBreaks ? (d.primaryIndex?.breaks ?? []) : []
        timeLabel.stringValue = Timecode.format(d.position)
        chrome.inLabel.stringValue = Timecode.format(d.selection.lowerBound)
        chrome.outLabel.stringValue = Timecode.format(d.selection.upperBound)
        chrome.trimStartLabel.stringValue = Timecode.format(d.window.lowerBound)
        chrome.trimEndLabel.stringValue = Timecode.format(d.window.upperBound)
        chrome.stateLabel.stringValue = engine.isPlaying ? "▶" : "■"
        window?.isDocumentEdited = d.history.isModified

        videoPopup.removeAllItems()
        for v in d.primary.info.videoStreams { videoPopup.addItem(withTitle: v.shortTitle); videoPopup.lastItem?.tag = v.index; videoPopup.lastItem?.toolTip = v.menuTitle }
        if videoPopup.numberOfItems == 0 { videoPopup.addItem(withTitle: "None") }
        if let v = d.videoStream { videoPopup.selectItem(withTag: v) }

        audioPopup.removeAllItems()
        if let companion = d.primary.companionAudio {
            audioPopup.addItem(withTitle: companion.lastPathComponent)
        } else {
            for a in d.availableAudio { audioPopup.addItem(withTitle: a.shortTitle); audioPopup.lastItem?.tag = a.index; audioPopup.lastItem?.toolTip = a.menuTitle }
            if audioPopup.numberOfItems == 0 { audioPopup.addItem(withTitle: "None") }
            if let a = d.audioStream { audioPopup.selectItem(withTag: a) }
        }
        // Audio Mode: downmix choices for surround audio; a dash otherwise (as in the original).
        modePopup.removeAllItems()
        if (d.audioInfo?.channels ?? 0) > 2 {
            for m in AudioMixMode.allCases { modePopup.addItem(withTitle: m.label) }
            modePopup.selectItem(at: d.audioMode.rawValue)
            modePopup.isEnabled = true
        } else {
            modePopup.addItem(withTitle: "–")
            modePopup.isEnabled = false
        }
        videoPopup.toolTip = d.videoInfo?.menuTitle
        audioPopup.toolTip = d.audioInfo?.menuTitle
    }

    private func updatePlayButton() {
        playButton.image = NSImage(systemSymbolName: engine.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        chrome.stateLabel.stringValue = engine.isPlaying ? "▶" : "■"
    }

    private var displaySize: CGSize? {
        guard let v = doc.videoInfo, v.height > 0 else { return nil }
        var h = Double(v.height)
        var w = (h * v.displayAspect / 2).rounded() * 2
        let maxW = Double(max(320, Pref.d.integer(forKey: Pref.maxDisplayWidth)))
        if w > maxW { h = (h * maxW / w / 2).rounded() * 2; w = maxW }
        return CGSize(width: w, height: h)
    }

    var snapshot: PlaybackSnapshot {
        var video: [UUID: Int] = [:], audio: [UUID: Int] = [:]
        for id in doc.sources.keys {
            let st = doc.streams(for: id)
            video[id] = st.video
            audio[id] = st.audio
        }
        return PlaybackSnapshot(edit: doc.edit, sources: doc.sources, videoStreams: video, audioStreams: audio,
                                audioMode: doc.audioMode, displaySize: displaySize)
    }

    // MARK: Appending clips

    /// Appends dropped or chosen files to the end of this player's stream.
    func appendClips(_ urls: [URL]) {
        let files = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else { return }
        engine.stop(notify: false)
        updatePlayButton()
        AppDelegate.shared.log("Appending \(files.count) clip(s) to \(doc.title)…")
        Task.detached(priority: .userInitiated) {
            var loaded: [SourceMedia] = []
            var failures: [String] = []
            for url in files {
                do { loaded.append(try SourceMedia.open([url], companionAudio: SequenceDetector.companionAudio(for: url))) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            let ready = loaded, failed = failures
            await MainActor.run {
                for src in ready {
                    self.doc.append(src)
                    AppDelegate.shared.log("Appended \(src.displayName) (\(Timecode.format(src.info.duration))).")
                }
                if !ready.isEmpty {
                    self.engine.setPosition(self.doc.position)
                    self.refreshFrame()
                    if self.doc.hasMixedSources {
                        AppDelegate.shared.log("The joined clips have different formats: use an Export command to join them (lossless commands need matching formats).")
                    }
                }
                if !failed.isEmpty {
                    let a = NSAlert()
                    a.messageText = failed.count == 1 ? "A clip could not be appended." : "\(failed.count) clips could not be appended."
                    a.informativeText = failed.joined(separator: "\n")
                    a.runModal()
                }
            }
        }
    }

    /// A drop on a player that already holds a clip: append the files, or replace the clip with them.
    func handleDrop(_ urls: [URL]) {
        guard let window else { return }
        let names = urls.map(\.lastPathComponent)
        let alert = NSAlert()
        alert.messageText = names.count == 1
            ? "Append “\(names[0])” to this clip, or replace it?"
            : "Append \(names.count) clips to this clip, or replace it?"
        var info = "Append adds the new \(names.count == 1 ? "clip" : "clips") to the end of “\(doc.title)”. Replace closes “\(doc.title)” and opens the new \(names.count == 1 ? "clip" : "clips") in this window."
        if doc.history.isModified { info += "\n\nReplacing discards your edits to “\(doc.title)”." }
        alert.informativeText = info
        alert.addButton(withTitle: "Append")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: self.appendClips(urls)
            case .alertSecondButtonReturn: AppDelegate.shared.open(urls, replacing: self)
            default: break
            }
        }
    }

    @objc func appendClip(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = "Choose clips to add to the end of “\(doc.title)”."
        panel.prompt = "Append"
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            self.appendClips(panel.urls)
        }
    }

    func refreshFrame() {
        guard doc.videoStream != nil else { return }
        engine.showFrame(at: doc.position, snapshot)
    }

    // MARK: Navigation

    func move(to t: Double, extend: Bool) {
        let wasPlaying = engine.isPlaying
        if wasPlaying { engine.stop(notify: false); updatePlayButton() }
        let d = doc
        let target = d.clampToWindow(t)
        if extend {
            if selectionAnchor == nil || !d.hasSelection {
                selectionAnchor = d.position
            }
            let a = selectionAnchor!
            d.inPoint = min(a, target)
            d.outPoint = max(a, target)
        } else {
            selectionAnchor = nil
        }
        d.position = target
        engine.setPosition(target)
        refreshFrame()
    }

    @objc func playStop(_ sender: Any?) {
        if engine.isPlaying {
            engine.stop()
            return
        }
        if NSEvent.modifierFlags.contains(.option) && doc.hasSelection {
            playSelectionLoop()
            return
        }
        var start = doc.position
        if start >= doc.window.upperBound - 0.05 { start = doc.window.lowerBound }
        shuttleRate = 1
        engine.play(from: start, rate: 1, snapshot)
        updatePlayButton()
    }

    private func playSelectionLoop() {
        let sel = doc.selection
        var snap = snapshot
        snap.edit.window = sel
        engine.onStop = { [weak self] in
            guard let self else { return }
            if self.shuttleRate == 1 && self.engine.clock.now() >= sel.upperBound - 0.1 {
                self.engine.play(from: sel.lowerBound, rate: 1, snap)
            } else {
                self.doc.position = self.doc.clampToWindow(self.engine.clock.now())
                self.shuttleRate = 0
                self.updatePlayButton()
                self.restoreStopHandler()
            }
        }
        shuttleRate = 1
        engine.play(from: sel.lowerBound, rate: 1, snap)
        updatePlayButton()
    }

    private func restoreStopHandler() {
        engine.onStop = { [weak self] in
            guard let self else { return }
            self.doc.position = self.doc.clampToWindow(self.engine.clock.now())
            self.shuttleRate = 0
            self.updatePlayButton()
            self.refreshFrame()
        }
    }

    /// J/L shuttle: doubles speed in the pressed direction, halves it when pressed against the motion.
    func shuttle(_ direction: Double, slow: Bool) {
        var r = engine.isPlaying ? engine.rate : 0
        if slow {
            r = r * direction > 0 && abs(r) < 1 ? r / 2 : direction * 0.5
            if abs(r) < 1.0 / 16 { r = direction / 16 }
        } else if r == 0 || r * direction < 0 && abs(r) <= 1 {
            r = direction
        } else if r * direction > 0 {
            r = min(32, abs(r) * 2) * direction
        } else {
            r /= 2
        }
        let start = engine.isPlaying ? engine.clock.now() : doc.position
        engine.stop(notify: false)
        restoreStopHandler()
        shuttleRate = r
        engine.play(from: start, rate: r, snapshot)
        updatePlayButton()
    }

    @objc func forwardPlay(_ sender: Any?) { shuttle(1, slow: NSEvent.modifierFlags.contains(.option)) }
    @objc func reversePlay(_ sender: Any?) { shuttle(-1, slow: NSEvent.modifierFlags.contains(.option)) }

    @objc func skipForward(_ sender: Any?) {
        let amount = NSEvent.modifierFlags.contains(.option) ? 60 : Pref.skip
        move(to: currentTime + amount, extend: NSEvent.modifierFlags.contains(.shift))
    }

    @objc func skipBackward(_ sender: Any?) {
        let amount = NSEvent.modifierFlags.contains(.option) ? 60 : Pref.skip
        move(to: currentTime - amount, extend: NSEvent.modifierFlags.contains(.shift))
    }

    var currentTime: Double { engine.isPlaying ? engine.clock.now() : doc.position }

    func stepFrames(_ n: Int, extend: Bool) {
        move(to: currentTime + Double(n) * doc.frameDuration + (n > 0 ? 0.0001 : 0), extend: extend)
    }

    func stepKeyframe(_ direction: Int, extend: Bool) {
        if let k = doc.keyframe(from: currentTime, direction: direction) {
            move(to: k, extend: extend)
        } else {
            stepFrames(direction * 12, extend: extend)
        }
    }

    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = mods.contains(.shift), option = mods.contains(.option), command = mods.contains(.command), control = mods.contains(.control)
        switch e.specialKey {
        case .leftArrow?:
            if option { move(to: doc.selection.lowerBound, extend: false) } else { stepFrames(-1, extend: shift) }
            return true
        case .rightArrow?:
            if option { move(to: doc.selection.upperBound, extend: false) } else { stepFrames(1, extend: shift) }
            return true
        case .upArrow?:
            if command || control { adjustVolume(shift ? 0.25 : 0.1); return true }
            if option { engine.volume = engine.volume > 0 ? engine.volume : 1; volumeSlider.floatValue = engine.volume; return true }
            stepKeyframe(-1, extend: shift); return true
        case .downArrow?:
            if command || control { adjustVolume(-0.1); return true }
            if option { engine.volume = 0; volumeSlider.floatValue = 0; return true }
            stepKeyframe(1, extend: shift); return true
        case .pageUp?: skipBackward(nil); return true
        case .pageDown?: skipForward(nil); return true
        case .home?: move(to: currentTime - 60, extend: shift); return true
        case .end?: move(to: currentTime + 60, extend: shift); return true
        default: break
        }
        guard !command, let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        switch ch {
        case " ": playStop(nil)
        case "j": shuttle(-1, slow: option)
        case "l": shuttle(1, slow: option)
        case "k":
            if option && doc.hasSelection { playSelectionLoop() } else { engine.stop() }
        case "i": setIn(nil)
        case "o": setOut(nil)
        case "x": cancelSelection(nil)
        case "0":
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        case "\u{1b}":
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) } else { engine.stop() }
        default: return false
        }
        return true
    }

    private func adjustVolume(_ delta: Float) {
        engine.volume = min(2, max(0, engine.volume + delta))
        volumeSlider.floatValue = min(1, engine.volume)
    }

    // MARK: Track pop-ups

    @objc func videoTrackChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, doc.primary.info.videoStreams.contains(where: { $0.index == item.tag }) else { return }
        doc.videoStream = item.tag
        engine.invalidateDecoders()
        refreshFrame()
    }

    @objc func audioTrackChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, doc.primary.info.audioStreams.contains(where: { $0.index == item.tag }) else { return }
        restartAfter { self.doc.audioStream = item.tag }
    }

    @objc func audioModeChanged(_ sender: NSPopUpButton) {
        restartAfter { self.doc.audioMode = AudioMixMode(rawValue: sender.indexOfSelectedItem) ?? .stereoMix }
    }

    @objc func volumeChanged(_ sender: NSSlider) { engine.volume = sender.floatValue }

    private func restartAfter(_ change: () -> Void) {
        let playing = engine.isPlaying && engine.rate == 1
        let t = currentTime
        if playing { engine.stop(notify: false) }
        change()
        if playing { engine.play(from: t, rate: 1, snapshot) }
        updatePlayButton()
    }

    // MARK: Edit menu

    @objc func setIn(_ sender: Any?) {
        doc.inPoint = currentTime
        if let o = doc.outPoint, o < currentTime { doc.outPoint = nil }
    }

    @objc func setOut(_ sender: Any?) {
        doc.outPoint = currentTime
        if let i = doc.inPoint, i > currentTime { doc.inPoint = nil }
    }

    @objc func cancelSelection(_ sender: Any?) { doc.cancelSelection(); selectionAnchor = nil }
    @objc override func selectAll(_ sender: Any?) { doc.cancelSelection() }

    @objc func cut(_ sender: Any?) { engine.stop(notify: false); doc.cut(); afterEdit() }
    @objc func copy(_ sender: Any?) { doc.copy() }
    @objc func paste(_ sender: Any?) { engine.stop(notify: false); doc.paste(); afterEdit() }
    @objc func trimSelection(_ sender: Any?) { engine.stop(notify: false); doc.trim(); afterEdit() }
    @objc func revertTrimming(_ sender: Any?) { doc.revertTrimming(); afterEdit() }
    @objc func revertAllChanges(_ sender: Any?) { doc.revertAll(); afterEdit() }
    @objc func undo(_ sender: Any?) { engine.stop(notify: false); doc.undo(); afterEdit() }
    @objc func redo(_ sender: Any?) { engine.stop(notify: false); doc.redo(); afterEdit() }
    @objc func deleteAudioTrack(_ sender: Any?) { doc.deleteAudioTrack(); engine.invalidateDecoders(); afterEdit() }

    private func afterEdit() {
        updatePlayButton()
        engine.setPosition(doc.position)
        refreshFrame()
    }

    @objc func goToIn(_ sender: Any?) { move(to: doc.selection.lowerBound, extend: false) }
    @objc func goToOut(_ sender: Any?) { move(to: doc.selection.upperBound, extend: false) }
    @objc func goToKeyframe(_ sender: Any?) {
        let t = currentTime
        let before = doc.keyframe(from: t + 0.0005, direction: -1) ?? t
        let after = doc.keyframe(from: t, direction: 1) ?? t
        move(to: abs(after - t) < abs(t - before) ? after : before, extend: false)
    }

    @objc func goToTime(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Time"
        alert.informativeText = "Enter a time (1:02:03.50 or 10203), “T-” to set In, “-T” to set Out, or “A-B” to select."
        let field = NSTextField(string: doc.hasSelection
            ? "\(Timecode.format(doc.selection.lowerBound))-\(Timecode.format(doc.selection.upperBound))"
            : Timecode.format(currentTime))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let req = Timecode.parseGoTo(field.stringValue) else { return }
        switch req {
        case .time(let t): move(to: t, extend: false)
        case .setIn(let t): doc.inPoint = doc.clampToWindow(t)
        case .setOut(let t): doc.outPoint = doc.clampToWindow(t)
        case .selection(let a, let b):
            doc.inPoint = doc.clampToWindow(a)
            doc.outPoint = doc.clampToWindow(b)
            move(to: a, extend: false)
            doc.inPoint = doc.clampToWindow(a)
            doc.outPoint = doc.clampToWindow(b)
        }
    }

    @objc func fixTimecodeBreaks(_ sender: Any?) {
        doc.fixTimecodeBreaks.toggle()
        guard doc.fixTimecodeBreaks else { AppDelegate.shared.log("Timecode repair disabled for \(doc.title)."); return }
        let report = { [weak self] in
            guard let self, let idx = self.doc.primaryIndex else { return }
            if idx.breaks.isEmpty {
                AppDelegate.shared.log("Fix Timecode Breaks: no timecode breaks found in \(self.doc.title). Timestamps will be regenerated on conversion.")
            } else {
                AppDelegate.shared.log("Fix Timecode Breaks: \(idx.breaks.count) break(s) in \(self.doc.title); timestamps will be regenerated on conversion.")
                for b in idx.breaks { AppDelegate.shared.log("  timecode break at \(Timecode.format(b))") }
            }
            self.refreshControls()
        }
        if doc.primaryIndex != nil { report() } else {
            doc.buildIndex()
            var c: AnyCancellable?
            c = doc.$indexes.dropFirst().sink { _ in DispatchQueue.main.async { report() }; c?.cancel() }
        }
    }

    // MARK: Window menu

    @objc func halfSize(_ sender: Any?) { resizeToFit(scale: 0.5) }
    @objc func actualSize(_ sender: Any?) { resizeToFit(scale: 1) }
    @objc func doubleSize(_ sender: Any?) { resizeToFit(scale: 2) }

    func resizeToFit(scale: Double) {
        guard let window, window.styleMask.contains(.fullScreen) == false else { return }
        let size = displaySize ?? CGSize(width: 640, height: 0)
        var w = size.width * scale, h = size.height * scale
        if let screen = window.screen ?? NSScreen.main {
            let maxW = screen.visibleFrame.width * 0.95, maxH = screen.visibleFrame.height * 0.85
            let f = min(1, maxW / max(w, 1), maxH / max(h, 1))
            w *= f; h *= f
        }
        let controlsHeight: CGFloat = PlayerChrome.chromeHeight + 8
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: max(PlayerChrome.minimumWidth, w + 32), height: h + controlsHeight))
        var origin = window.frame.origin
        origin.y += window.frame.height - frame.height
        window.setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: false)
    }

    @objc func playFullScreen(_ sender: Any?) { window?.toggleFullScreen(nil) }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            item.title = doc.history.undoName.map { "Undo \($0)" } ?? "Undo"
            return doc.history.canUndo
        case #selector(redo(_:)):
            item.title = doc.history.redoName.map { "Redo \($0)" } ?? "Redo"
            return doc.history.canRedo
        case #selector(paste(_:)): return !EditClipboard.isEmpty
        case #selector(cut(_:)), #selector(trimSelection(_:)): return doc.hasSelection
        case #selector(revertTrimming(_:)): return doc.window != 0...doc.edit.duration
        case #selector(revertAllChanges(_:)): return doc.history.isModified
        case #selector(deleteAudioTrack(_:)): return doc.audioStream != nil && doc.availableAudio.count > 0
        case #selector(fixTimecodeBreaks(_:)):
            item.state = doc.fixTimecodeBreaks ? .on : .off
            return !doc.primary.isRemote
        default: return true
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        engine.stop(notify: false)
        uiTimer?.invalidate()
        AppDelegate.shared.playerClosed(self)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard doc.history.isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "Close “\(doc.title)” and discard your edits?"
        alert.informativeText = "Edits are never written to the source files. Use Save As or a conversion to keep them. The clipboard is kept."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder === window { window?.makeFirstResponder(window?.contentView) }
        AppDelegate.shared.activePlayerChanged()
    }

    func windowDidResize(_ notification: Notification) {}
}
