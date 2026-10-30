import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MediaCore

/// Name shown in menus and window titles (TinRoof Transcode); set by the bundle (APP_NAME in scripts/build_app.sh).
enum AppInfo {
    static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "TinRoof Transcode"
    }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tinroof.transcode", isDirectory: true)
    }
}

/// Collected log lines shown in the Log window.
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    func add(_ s: String) {
        lines.append("\(formatter.string(from: Date()))  \(s)")
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
    }
    func clear() { lines.removeAll() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    let batch = BatchQueue()
    let immediate = BatchQueue()
    let logStore = LogStore()
    lazy var presets = PresetStore(directory: AppInfo.supportDirectory)
    private(set) var players: [PlayerWindowController] = []
    private weak var activePlayer: PlayerWindowController?
    private var panels: [String: NSWindowController] = [:]
    private var exporters: [NSWindowController] = []
    private var pendingOpen: [URL] = []
    private var launched = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Pref.register()
        NSApp.mainMenu = buildMenu()
        immediate.autoStart = true
        immediate.simultaneousTasks = 4
        for q in [batch, immediate] {
            q.onLog = { [weak self] s in self?.log(s) }
        }
        immediate.onTaskFinished = { [weak self] task in self?.immediateTaskFinished(task) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        if FFmpegLocator.find() == nil {
            log(MediaError.ffmpegMissing.localizedDescription)
        }
        if ProcessInfo.processInfo.environment["TRT_PREVIEW_TEST"] != nil, let s = ProcessInfo.processInfo.environment["TRT_SAMPLE"] {
            PreviewTest.run(samples: s.split(separator: ":").map(String.init)); return
        }
        if let dir = ScreenshotMode.directory { ScreenshotMode.run(in: dir); return }
        if !pendingOpen.isEmpty { open(pendingOpen); pendingOpen = [] }
        else if players.isEmpty { showEmptyPlayer() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { open(urls) } else { pendingOpen += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { if let p = players.first { p.showWindow(nil) } else { showEmptyPlayer() } }
        return true
    }

    // MARK: Empty player

    private var emptyPlayer: EmptyPlayerWindowController?

    /// Shows the empty player (app icon, drop target) used when no clip is open.
    func showEmptyPlayer() {
        if emptyPlayer == nil { emptyPlayer = EmptyPlayerWindowController() }
        emptyPlayer?.showWindow(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = batch.runningCount + immediate.runningCount
        guard running > 0 else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "\(running) task(s) are still running. Quit anyway?"
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        batch.cancelAll(); immediate.cancelAll()
        return .terminateNow
    }

    func log(_ s: String) { logStore.add(s) }

    // MARK: Opening

    @objc func openFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose a file, or several files that form one MPEG stream (they are joined in name order)."
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    /// Opens dropped or chosen files. Several MPEG files are joined into one stream; other files open separately.
    /// Player to close when the next clip opens (Replace in the drop dialog).
    private weak var replacementTarget: PlayerWindowController?

    /// Opens files in place of an existing player: the new clip takes its window position, and the old one closes.
    func open(_ urls: [URL], replacing player: PlayerWindowController) {
        replacementTarget = player
        open(urls)
    }

    func open(_ urls: [URL]) {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var isDir: ObjCBool = false
        if sorted.count == 1, FileManager.default.fileExists(atPath: sorted[0].path, isDirectory: &isDir), isDir.boolValue {
            openDVD(at: sorted[0]); return
        }
        let mpegExt: Set<String> = ["vob", "ts", "m2t", "mts", "mpg", "mpeg", "m2p", "vro", "mod", "tod", "rec", "vid", "tp", "trp", "dat", "pvr", "vdr", "m2v"]
        if sorted.count > 1 && sorted.allSatisfy({ mpegExt.contains($0.pathExtension.lowercased()) }) {
            openSource(sorted)
            return
        }
        for url in sorted {
            let seq = SequenceDetector.sequence(for: url)
            if seq.count > 1 {
                let a = NSAlert()
                a.messageText = "“\(url.lastPathComponent)” is part of a stream split into \(seq.count) files."
                a.informativeText = seq.map(\.lastPathComponent).joined(separator: "\n")
                a.addButton(withTitle: "Open All Together")
                a.addButton(withTitle: "Open This File Only")
                openSource(a.runModal() == .alertFirstButtonReturn ? seq : [url])
            } else {
                openSource([url])
            }
        }
    }

    func openSource(_ locations: [URL], companionAudio: URL? = nil) {
        let companion = companionAudio ?? (locations.count == 1 && locations[0].isFileURL ? SequenceDetector.companionAudio(for: locations[0]) : nil)
        let name = locations.first?.lastPathComponent ?? "stream"
        log("Opening \(name)…")
        Task.detached(priority: .userInitiated) {
            do {
                let src = try SourceMedia.open(locations, companionAudio: companion)
                await MainActor.run {
                    if self.batchIsOpen && self.addingFilesToBatch { return }
                    let doc = PlayerDocument(source: src)
                    let pc = PlayerWindowController(doc: doc)
                    let replaced = self.replacementTarget?.window
                    self.replacementTarget = nil
                    if let old = replaced {
                        // Replace: the new clip takes the old player's place.
                        pc.window?.setFrameTopLeftPoint(NSPoint(x: old.frame.minX, y: old.frame.maxY))
                    } else if let empty = self.emptyPlayer?.window, empty.isVisible {
                        // The first clip opens where the empty player was, replacing it.
                        pc.window?.setFrameTopLeftPoint(NSPoint(x: empty.frame.minX, y: empty.frame.maxY))
                        empty.orderOut(nil)
                    }
                    self.players.append(pc)
                    self.activePlayer = pc
                    self.objectWillChangeForPanels()
                    pc.showWindow(nil)
                    // Close the replaced player only once the new one is registered,
                    // so the empty player doesn't flash up in between.
                    replaced?.close()
                    for l in locations where l.isFileURL { NSDocumentController.shared.noteNewRecentDocumentURL(l) }
                    self.log("Opened \(src.displayName): \(src.info.formatLongName), \(Timecode.format(src.info.duration))")
                }
            } catch {
                await MainActor.run {
                    self.replacementTarget = nil   // keep the current clip if the new one can't be opened
                    self.log("Cannot open \(name): \(error.localizedDescription)")
                    let a = NSAlert(error: error)
                    a.messageText = "“\(name)” could not be opened."
                    a.runModal()
                }
            }
        }
    }

    @objc func openDVD(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a DVD, its VIDEO_TS folder, or any folder of VOB files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openDVD(at: url)
    }

    func openDVD(at url: URL) {
        let titles = DVDScanner.titles(at: url)
        guard !titles.isEmpty else {
            let a = NSAlert(); a.messageText = "No DVD titles were found in “\(url.lastPathComponent)”."; a.runModal(); return
        }
        var chosen = titles.max { $0.totalSize < $1.totalSize }!
        if titles.count > 1 {
            let a = NSAlert()
            a.messageText = "Which title do you want to open?"
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
            for t in titles { popup.addItem(withTitle: t.label) }
            popup.selectItem(at: titles.firstIndex(of: chosen) ?? 0)
            a.accessoryView = popup
            a.addButton(withTitle: batchIsOpen ? "Add to Batch" : "Open")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            chosen = titles[popup.indexOfSelectedItem]
        }
        openSource(chosen.files)
    }

    @objc func openURL(_ sender: Any?) {
        showPanel("openURL", title: "Open URL", size: NSSize(width: 520, height: 230)) { OpenURLView() }
    }

    // MARK: Players

    var currentPlayer: PlayerWindowController? {
        (NSApp.keyWindow?.windowController as? PlayerWindowController)
            ?? (NSApp.mainWindow?.windowController as? PlayerWindowController)
            ?? activePlayer
            ?? players.last
    }

    func activePlayerChanged() {
        if let p = NSApp.keyWindow?.windowController as? PlayerWindowController { activePlayer = p }
        objectWillChangeForPanels()
    }

    func playerClosed(_ p: PlayerWindowController) {
        players.removeAll { $0 === p }
        objectWillChangeForPanels()
        if players.isEmpty { showEmptyPlayer() }
    }

    let panelRefresh = PanelRefresh()
    private func objectWillChangeForPanels() { panelRefresh.tick += 1 }

    // MARK: Jobs

    var batchIsOpen: Bool { panels["batch"]?.window?.isVisible == true }
    var addingFilesToBatch = false

    /// Runs a job now, or adds it to the batch list when the batch window is open.
    func submit(_ spec: JobSpec) {
        if batchIsOpen && Pref.d.bool(forKey: Pref.queueWhileBatchOpen) {
            batch.add(spec)
            log("Added to batch: \(spec.title)")
            panels["batch"]?.window?.orderFront(nil)
        } else {
            immediate.add(spec)
            showProgress(nil)
        }
    }

    private func immediateTaskFinished(_ task: BatchTask) {
        switch task.status {
        case .failed(let message):
            let a = NSAlert()
            a.messageText = "\(task.title) failed."
            a.informativeText = message
            a.alertStyle = .warning
            a.runModal()
        case .completed:
            if case .export(let s) = task.spec.kind, s.kind == .frame { return }
            if case .checkStream = task.spec.kind { showLog(nil) }
            NSApp.requestUserAttention(.informationalRequest)
        default: break
        }
    }

    /// Asks for an output location, then submits the job.
    func chooseOutputAndSubmit(kind: JobKind, request: RenderRequest, suggestedName: String, ext: String, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + (ext.isEmpty ? "" : "." + ext)
        if let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        let handler = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            self.submit(JobSpec(kind: kind, request: request, output: url))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    // MARK: Commands routed through the current player

    @objc func convert(_ sender: NSMenuItem) {
        guard let p = currentPlayer, let target = sender.representedObject as? ConvertTarget else { return }
        guard ensureMatchingClips(p, action: target.title) else { return }
        let allAudio = !Pref.d.bool(forKey: Pref.convertOneAudioTrack) && !target.isDemux
        let req = p.doc.renderRequest(lossless: true, allAudio: allAudio)
        if target.requiresMPEGVideo, let v = p.doc.videoInfo, v.codec != "mpeg2video" && v.codec != "mpeg1video" {
            let a = NSAlert()
            a.messageText = "\(target.title) needs MPEG-1 or MPEG-2 video."
            a.informativeText = "This stream contains \(v.codecLongName). Use a lossless remux (MP4, MOV, MKV, TS) or an Export command instead."
            a.runModal()
            return
        }
        chooseOutputAndSubmit(kind: .convert(target), request: req, suggestedName: p.doc.primary.baseName, ext: target.primaryExtension, from: p.window)
    }

    @objc func saveAs(_ sender: Any?) {
        guard let p = currentPlayer else { return }
        guard ensureMatchingClips(p, action: "Save As") else { return }
        let src = p.doc.primary
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        for f in SaveAsFormat.allCases { popup.addItem(withTitle: f.rawValue) }
        let panel = NSSavePanel()
        panel.accessoryView = popup
        panel.nameFieldStringValue = src.baseName + " edited." + SaveAsFormat.original.fileExtension(source: src)
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: p.window!) { response in
            guard response == .OK, var url = panel.url else { return }
            let format = SaveAsFormat.allCases[popup.indexOfSelectedItem]
            url = url.deletingPathExtension().appendingPathExtension(format.fileExtension(source: src))
            let req = p.doc.renderRequest(lossless: true, allAudio: true)
            self.submit(JobSpec(kind: .saveAs(format), request: req, output: url))
        }
    }

    @objc func exportMovie(_ sender: NSMenuItem) {
        guard let p = currentPlayer, let kind = sender.representedObject as? ExporterKind else { return }
        showExporter(kind: kind, player: p)
    }

    @discardableResult
    func showExporter(kind: ExporterKind, player: PlayerWindowController) -> ExporterModel? {
        if kind != .audio && player.doc.videoStream == nil {
            let a = NSAlert(); a.messageText = "This stream has no video track."; a.runModal(); return nil
        }
        if kind == .audio && player.doc.audioInfo == nil {
            let a = NSAlert(); a.messageText = "This stream has no audio track."; a.runModal(); return nil
        }
        let model = ExporterModel(kind: kind, player: player, presets: presets)
        let view = ExporterView(model: model)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = kind == .frame ? "Export Frame — \(player.doc.title)" : "\(kind.rawValue) Exporter — \(player.doc.title)"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        let wc = NSWindowController(window: w)
        model.close = { [weak self, weak wc] in
            wc?.close()
            self?.exporters.removeAll { $0 === wc }
        }
        exporters.append(wc)
        w.center()
        wc.showWindow(nil)
        return model
    }

    @objc func checkStream(_ sender: Any?) {
        guard let p = currentPlayer else { return }
        let req = p.doc.renderRequest(lossless: true, allAudio: true)
        log("Checking \(p.doc.title)…")
        immediate.add(JobSpec(kind: .checkStream, request: req, output: URL(fileURLWithPath: "/dev/null")))
        showProgress(nil)
    }

    // MARK: Panels

    func showPanel<V: View>(_ key: String, title: String, size: NSSize, resizable: Bool = true, @ViewBuilder _ content: () -> V) {
        if let existing = panels[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content().environmentObject(self.panelRefresh))
        w.center()
        w.setFrameAutosaveName("panel.\(key)")
        let wc = NSWindowController(window: w)
        panels[key] = wc
        wc.showWindow(nil)
    }

    @objc func showBatch(_ sender: Any?) {
        showPanel("batch", title: "Batch List", size: NSSize(width: 720, height: 360)) { BatchView(queue: batch) }
    }
    @objc func showProgress(_ sender: Any?) {
        showPanel("progress", title: "Progress", size: NSSize(width: 560, height: 220)) { ProgressListView(queue: immediate) }
    }
    @objc func showLog(_ sender: Any?) {
        showPanel("log", title: "Log", size: NSSize(width: 640, height: 320)) { LogView(store: logStore) }
    }
    @objc func showEditList(_ sender: Any?) {
        showPanel("editList", title: "Edit List", size: NSSize(width: 480, height: 320)) { EditListView() }
    }
    @objc func showStreamInfo(_ sender: Any?) {
        showPanel("info", title: "Stream Info", size: NSSize(width: 520, height: 480)) { StreamInfoView() }
    }
    @objc func showPreferences(_ sender: Any?) {
        showPanel("prefs", title: "Settings", size: NSSize(width: 520, height: 520), resizable: false) { PreferencesView() }
    }
    private var guide: GuideWindowController?
    @objc func showGuide(_ sender: Any?) {
        if guide == nil { guide = GuideWindowController() }
        guide?.showWindow(nil)
    }

    @objc func addFilesToBatch(_ sender: Any?) { BatchAddFlow.run() }

    // MARK: Menu

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let needsPlayer: Set<Selector> = [#selector(convert(_:)), #selector(saveAs(_:)), #selector(exportMovie(_:)), #selector(checkStream(_:))]
        if let a = item.action, needsPlayer.contains(a) { return currentPlayer != nil }
        return true
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            item.submenu = m
            main.addItem(item)
            return item
        }
        func mi(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, object: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            i.target = target
            i.representedObject = object
            return i
        }
        let sep = { NSMenuItem.separator() }
        let name = AppInfo.name

        _ = sub(name, [
            mi("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            sep(),
            mi("Settings…", #selector(showPreferences(_:)), ",", target: self),
            sep(),
            mi("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            mi("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            mi("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            sep(),
            mi("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ])

        let convertItems: [NSMenuItem] = ConvertTarget.allCases.flatMap { t -> [NSMenuItem] in
            let item = mi(t.rawValue, #selector(convert(_:)), target: self, object: t)
            return t == .demuxM2VAIFF || t == .mp4 ? [sep(), item] : [item]
        }
        let exportItems: [NSMenuItem] = [
            mi("Export to QuickTime…", #selector(exportMovie(_:)), "e", target: self, object: ExporterKind.quickTime),
            mi("Export to MPEG-4…", #selector(exportMovie(_:)), "e", [.command, .shift], target: self, object: ExporterKind.mpeg4),
            mi("Export to AVI…", #selector(exportMovie(_:)), target: self, object: ExporterKind.avi),
            mi("Export to MKV / WebM…", #selector(exportMovie(_:)), target: self, object: ExporterKind.matroska),
            mi("Export to DV…", #selector(exportMovie(_:)), target: self, object: ExporterKind.dv),
            mi("Export to MPEG-2 (DVD)…", #selector(exportMovie(_:)), target: self, object: ExporterKind.mpeg2),
            mi("Export Audio…", #selector(exportMovie(_:)), "e", [.command, .option], target: self, object: ExporterKind.audio),
            mi("Export Frame…", #selector(exportMovie(_:)), "f", [.command, .option], target: self, object: ExporterKind.frame),
        ]
        _ = sub("File", [
            mi("Open Files…", #selector(openFiles(_:)), "o", target: self),
            mi("Open DVD…", #selector(openDVD(_:)), "o", [.command, .shift], target: self),
            mi("Open URL…", #selector(openURL(_:)), "u", target: self),
            mi("Append Clip…", #selector(PlayerWindowController.appendClip(_:)), "a", [.command, .option]),
            sep(),
            mi("Close", #selector(NSWindow.performClose(_:)), "w"),
            mi("Save As…", #selector(saveAs(_:)), "s", [.command, .shift], target: self),
            sep(),
        ] + exportItems + [sep()] + convertItems + [
            sep(),
            mi("Show Stream Info", #selector(showStreamInfo(_:)), "i", target: self),
            mi("Check Stream", #selector(checkStream(_:)), target: self),
        ])

        _ = sub("Edit", [
            mi("Undo", #selector(PlayerWindowController.undo(_:)), "z"),
            mi("Redo", #selector(PlayerWindowController.redo(_:)), "z", [.command, .shift]),
            sep(),
            mi("Cut", #selector(PlayerWindowController.cut(_:)), "x"),
            mi("Copy", #selector(PlayerWindowController.copy(_:)), "c"),
            mi("Paste", #selector(PlayerWindowController.paste(_:)), "v"),
            mi("Select All / Cancel Selection", #selector(PlayerWindowController.selectAll(_:)), "a"),
            sep(),
            mi("Set In", #selector(PlayerWindowController.setIn(_:))),
            mi("Set Out", #selector(PlayerWindowController.setOut(_:))),
            mi("Cancel Selection", #selector(PlayerWindowController.cancelSelection(_:))),
            mi("Trim", #selector(PlayerWindowController.trimSelection(_:)), "t"),
            mi("Revert Trimming", #selector(PlayerWindowController.revertTrimming(_:)), "t", [.command, .shift]),
            mi("Revert All Changes", #selector(PlayerWindowController.revertAllChanges(_:))),
            mi("Delete Audio Track", #selector(PlayerWindowController.deleteAudioTrack(_:))),
            sep(),
            mi("Go to Time…", #selector(PlayerWindowController.goToTime(_:)), "g"),
            mi("Go to In", #selector(PlayerWindowController.goToIn(_:)), "i", [.command, .shift]),
            mi("Go to Out", #selector(PlayerWindowController.goToOut(_:)), "o", [.command, .option]),
            mi("Go to Keyframe", #selector(PlayerWindowController.goToKeyframe(_:)), "k"),
            sep(),
            mi("Fix Timecode Breaks", #selector(PlayerWindowController.fixTimecodeBreaks(_:))),
        ])

        _ = sub("List", [
            mi("Batch List", #selector(showBatch(_:)), "b", target: self),
            mi("Add Files to Batch…", #selector(addFilesToBatch(_:)), "b", [.command, .shift], target: self),
            mi("Progress", #selector(showProgress(_:)), "p", [.command, .option], target: self),
            mi("Edit List", #selector(showEditList(_:)), "l", target: self),
            mi("Log Window", #selector(showLog(_:)), "l", [.command, .shift], target: self),
        ])

        let windowItem = sub("Window", [
            mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            mi("Zoom", #selector(NSWindow.performZoom(_:))),
            sep(),
            mi("Half Size", #selector(PlayerWindowController.halfSize(_:)), "1"),
            mi("Actual Size", #selector(PlayerWindowController.actualSize(_:)), "2"),
            mi("Double Size", #selector(PlayerWindowController.doubleSize(_:)), "3"),
            mi("Full Screen", #selector(PlayerWindowController.playFullScreen(_:)), "0"),
            sep(),
            mi("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = windowItem.submenu

        _ = sub("Help", [mi("\(name) Guide", #selector(showGuide(_:)), "?", target: self)])
        return main
    }
}

/// Lets SwiftUI panels re-read the current player when windows change.
@MainActor
final class PanelRefresh: ObservableObject {
    @Published var tick = 0
}

extension AppDelegate {
    /// Lossless commands copy streams, so joined clips must share one format.
    func ensureMatchingClips(_ p: PlayerWindowController, action: String) -> Bool {
        guard p.doc.hasMixedSources else { return true }
        let a = NSAlert()
        a.messageText = "\(action) can't join clips in different formats."
        a.informativeText = "The appended clips differ in codec, frame size, frame rate or audio format, so they can't be joined without re-encoding. Use an Export command (for example File › Export to MPEG-4) instead."
        a.runModal()
        return false
    }
}
