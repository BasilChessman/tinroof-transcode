import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MediaCore

// MARK: - Batch

struct TaskRow: View {
    @ObservedObject var task: BatchTask
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).lineLimit(1)
                Text(task.spec.output.path == "/dev/null" ? "" : task.spec.output.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if case .running(let p) = task.status {
                ProgressView(value: p).frame(width: 120)
            }
            Text(task.status.label).font(.caption).foregroundStyle(statusColor).lineLimit(1).frame(width: 150, alignment: .trailing)
        }
        .help(task.log.suffix(8).joined(separator: "\n"))
    }
    private var statusColor: Color {
        switch task.status {
        case .failed: return .red
        case .completed: return .green
        case .held: return .orange
        default: return .secondary
        }
    }
}

struct BatchView: View {
    @ObservedObject var queue: BatchQueue
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(queue.tasks) { TaskRow(task: $0).tag($0.id) }
            }
            .overlay {
                if queue.tasks.isEmpty {
                    Text("While this window is open, Save As, Convert, Demux and Export commands are added here instead of running immediately. Drop files here or click Add Files.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(40)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                var urls: [URL] = []
                let group = DispatchGroup()
                for p in providers {
                    group.enter()
                    _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { urls.append(url) }; group.leave() }
                }
                group.notify(queue: .main) { BatchAddFlow.run(preselected: urls) }
                return true
            }
            Divider()
            HStack {
                Button("Add Files…") { BatchAddFlow.run() }
                Button(queue.isProcessing ? "Stop" : "Go") { queue.isProcessing ? queue.stopAfterCurrent() : queue.start() }
                    .keyboardShortcut(.defaultAction)
                Button("Stop All") { queue.cancelAll() }.disabled(queue.runningCount == 0)
                Divider().frame(height: 18)
                Button("Hold") { queue.toggleHold(selection) }.disabled(selection.isEmpty)
                Button("Repeat") { queue.repeatTasks(selection) }.disabled(selection.isEmpty)
                Button { if let id = selection.first { queue.move(id, by: -1) } } label: { Image(systemName: "arrow.up") }.disabled(selection.count != 1)
                Button { if let id = selection.first { queue.move(id, by: 1) } } label: { Image(systemName: "arrow.down") }.disabled(selection.count != 1)
                Button("Delete") { queue.remove(selection); selection.removeAll() }.disabled(selection.isEmpty)
                Button("Clear") { queue.clear(); selection.removeAll() }
                Button("Redirect…") {
                    let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
                    if p.runModal() == .OK, let u = p.url { queue.redirect(selection.isEmpty ? Set(queue.tasks.map(\.id)) : selection, to: u) }
                }
            }
            .padding(.horizontal, 10).padding(.top, 8)
            HStack {
                Toggle("Automatic start", isOn: $queue.autoStart)
                Stepper("Simultaneous tasks: \(queue.simultaneousTasks)", value: $queue.simultaneousTasks, in: 1...16)
                Spacer()
                Text(queue.completionScript.map { "Script: \($0.lastPathComponent)" } ?? "No completion script").font(.caption).foregroundStyle(.secondary)
                Button("Script…") {
                    let p = NSOpenPanel()
                    p.message = "Choose an AppleScript, shell script or app to run when all tasks are completed."
                    if p.runModal() == .OK { queue.completionScript = p.url } else { queue.completionScript = nil }
                }
            }
            .padding(10)
        }
    }
}

struct ProgressListView: View {
    @ObservedObject var queue: BatchQueue
    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(queue.tasks.reversed()) { TaskRow(task: $0) }
            }
            .overlay { if queue.tasks.isEmpty { Text("No conversions yet").foregroundStyle(.secondary) } }
            Divider()
            HStack {
                Button("Stop") { queue.cancelAll(); queue.autoStart = true }.disabled(queue.runningCount == 0)
                Spacer()
                Button("Clear Finished") { queue.remove(Set(queue.tasks.filter { !$0.status.isRunning }.map(\.id))) }
            }
            .padding(10)
        }
    }
}

// MARK: - Log

struct LogView: View {
    @ObservedObject var store: LogStore
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(store.lines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .onChange(of: store.lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            Divider()
            HStack {
                Button("Check Stream") { AppDelegate.shared.checkStream(nil) }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.lines.joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { store.clear() }
            }
            .padding(10)
        }
    }
}

// MARK: - Edit list and stream info (follow the active player)

struct EditListView: View {
    @EnvironmentObject var refresh: PanelRefresh
    var body: some View {
        let _ = refresh.tick
        if let p = AppDelegate.shared.currentPlayer {
            EditListContent(document: p.doc, player: p)
        } else {
            Text("No stream is open").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct EditListContent: View {
    @ObservedObject var document: PlayerDocument
    let player: PlayerWindowController
    @State private var selected: Int?

    var body: some View {
        let edit = document.edit
        let starts = edit.segmentStarts
        VStack(spacing: 0) {
            Table(of: Row.self, selection: $selected) {
                TableColumn("#") { Text("\($0.id + 1)") }.width(30)
                TableColumn("Start") { Text(Timecode.format($0.start)).monospacedDigit() }
                TableColumn("Duration") { Text(Timecode.format($0.duration)).monospacedDigit() }
                TableColumn("Source") { Text($0.source).lineLimit(1) }
            } rows: {
                ForEach(edit.segments.indices, id: \.self) { i in
                    let s = edit.segments[i]
                    TableRow(Row(id: i, start: starts[i], duration: s.duration, source: "\(document.sources[s.sourceID]?.displayName ?? "?") @ \(Timecode.format(s.start))"))
                }
            }
            .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { ids in if let i = ids.first { select(i) } }
            if document.fixTimecodeBreaks, let breaks = document.primaryIndex?.breaks, !breaks.isEmpty {
                Text("Timecode breaks: " + breaks.map { Timecode.format($0) }.joined(separator: ", ")).font(.caption).padding(6)
            }
            Divider()
            HStack {
                Text("\(edit.segments.count) segment(s), total \(Timecode.format(edit.duration))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Select") { if let i = selected { select(i) } }.disabled(selected == nil)
            }
            .padding(10)
        }
    }

    struct Row: Identifiable { let id: Int; let start: Double; let duration: Double; let source: String }

    private func select(_ i: Int) {
        let starts = document.edit.segmentStarts
        guard document.edit.segments.indices.contains(i) else { return }
        let a = starts[i], b = a + document.edit.segments[i].duration
        player.move(to: a, extend: false)
        document.inPoint = document.clampToWindow(a)
        document.outPoint = document.clampToWindow(b)
    }
}

struct StreamInfoView: View {
    @EnvironmentObject var refresh: PanelRefresh
    var body: some View {
        let _ = refresh.tick
        if let p = AppDelegate.shared.currentPlayer {
            StreamInfoContent(document: p.doc)
        } else {
            Text("No stream is open").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StreamInfoContent: View {
    @ObservedObject var document: PlayerDocument
    var body: some View {
        let src = document.primary
        let info = src.info
        Form {
            Section("File") {
                LabeledContent("Name", value: src.displayName)
                if src.locations.count > 1 {
                    LabeledContent("Files", value: src.locations.map(\.lastPathComponent).joined(separator: ", "))
                }
                if let c = src.companionAudio { LabeledContent("Audio file", value: c.lastPathComponent) }
                LabeledContent("Format", value: info.formatLongName)
                let size = src.isRemote ? info.fileSize : src.totalFileSize
                if size > 0 { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                LabeledContent("Duration", value: Timecode.format(info.duration))
                if info.bitRate > 0 { LabeledContent("Total bit rate", value: String(format: "%.2f Mbps", Double(info.bitRate) / 1e6)) }
                if let idx = document.primaryIndex {
                    LabeledContent("Keyframes", value: "\(idx.keyframes.count)")
                    if idx.corruptPackets > 0 { LabeledContent("Corrupt packets", value: "\(idx.corruptPackets)") }
                    if !idx.breaks.isEmpty { LabeledContent("Timecode breaks", value: "\(idx.breaks.count)") }
                }
            }
            Section("Edit") {
                LabeledContent("Trimming", value: "\(Timecode.format(document.window.lowerBound)) – \(Timecode.format(document.window.upperBound))")
                LabeledContent("In / Out", value: "\(Timecode.format(document.selection.lowerBound)) – \(Timecode.format(document.selection.upperBound))")
                LabeledContent("Segments", value: "\(document.edit.segments.count)")
            }
            ForEach(info.streams) { s in
                Section("\(s.kind.rawValue.capitalized) — \(s.streamID > 0 ? String(format: "PID/ID 0x%X", s.streamID) : "#\(s.index)")") {
                    LabeledContent("Codec", value: s.codecLongName + (s.profile.isEmpty || s.profile == "unknown" ? "" : " (\(s.profile))"))
                    if s.kind == .video {
                        LabeledContent("Frame size", value: "\(s.width) × \(s.height)  (\(s.displayAspectNum):\(s.displayAspectDen))")
                        LabeledContent("Frame rate", value: (s.variableFrameRate ? "~" : "") + String(format: "%.3f fps", s.frameRate))
                        LabeledContent("Scan", value: s.fieldOrder.label)
                        LabeledContent("Pixel format", value: s.pixelFormat)
                    }
                    if s.kind == .audio {
                        LabeledContent("Sample rate", value: "\(s.sampleRate) Hz")
                        LabeledContent("Channels", value: s.channelLayout.isEmpty ? "\(s.channels)" : s.channelLayout)
                        if !s.language.isEmpty { LabeledContent("Language", value: s.language) }
                        if document.edit.deletedAudioStreams.contains(s.index) { Text("Deleted").foregroundStyle(.red) }
                    }
                    if s.bitRate > 0 { LabeledContent("Bit rate", value: String(format: "%.0f kbps", Double(s.bitRate) / 1000)) }
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }
}

// MARK: - Preferences

struct PreferencesView: View {
    @AppStorage(Pref.fixDataBreaks) var fixDataBreaks = false
    @AppStorage(Pref.preserveGOPs) var preserveGOPs = false
    @AppStorage(Pref.convertOneAudioTrack) var convertOneAudioTrack = false
    @AppStorage(Pref.resample48k) var resample48k = false
    @AppStorage(Pref.mp2Bitrate) var mp2Bitrate = 224
    @AppStorage(Pref.skipInterval) var skipInterval = 10.0
    @AppStorage(Pref.defaultAudioMode) var defaultAudioMode = 0
    @AppStorage(Pref.queueWhileBatchOpen) var queueWhileBatchOpen = true
    @AppStorage(Pref.resolveWebPages) var resolveWebPages = true
    @AppStorage(Pref.maxDisplayWidth) var maxDisplayWidth = 1920
    @AppStorage(FFmpegLocator.overrideKey) var ffmpegPath = ""

    var body: some View {
        Form {
            Section("Conversion") {
                Toggle("Fix streams with data breaks", isOn: $fixDataBreaks)
                Toggle("Preserve GOPs at In/Out (lossless commands)", isOn: $preserveGOPs)
                Toggle("Convert only the selected audio track", isOn: $convertOneAudioTrack)
                Toggle("Resample converted audio to 48 kHz", isOn: $resample48k)
                Picker("MP2 encoding bit rate", selection: $mp2Bitrate) {
                    ForEach([128, 160, 192, 224, 256, 320, 384], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Toggle("Queue commands while the Batch List is open", isOn: $queueWhileBatchOpen)
            }
            Section("Player") {
                HStack {
                    Text("Skip buttons interval")
                    TextField("", value: $skipInterval, format: .number).frame(width: 60)
                    Text("seconds")
                }
                Picker("Default surround downmix", selection: $defaultAudioMode) {
                    ForEach(AudioMixMode.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Maximum display resolution", selection: $maxDisplayWidth) {
                    Text("1280 pixels wide").tag(1280); Text("1920 pixels wide").tag(1920); Text("3840 pixels wide").tag(3840)
                }
            }
            Section("Internet") {
                Toggle("Find the video in web pages with yt-dlp (if installed)", isOn: $resolveWebPages)
                Text(PageResolver.ytDLP().map { "yt-dlp: \($0.path)" } ?? "yt-dlp is not installed (brew install yt-dlp).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ffmpeg") {
                TextField("Custom ffmpeg path", text: $ffmpegPath, prompt: Text("automatic"))
                    .onSubmit { EncoderAvailability.reset() }
                Text(FFmpegLocator.find().map { "Using \($0.path)" } ?? "ffmpeg not found. Install with: brew install ffmpeg")
                    .font(.caption).foregroundStyle(FFmpegLocator.find() == nil ? .red : .secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Open URL

struct OpenURLView: View {
    enum Action: String, CaseIterable { case open = "Open", download = "Download" }
    @State private var text = ""
    @State private var action: Action = .open
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            TextField("URL", text: $text, prompt: Text("https://example.com/movie.mp4"))
            Picker("Action", selection: $action) { ForEach(Action.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.segmented)
            Text(action == .open
                 ? "Opens the stream for playback, editing and conversion directly over the network."
                 : "Saves the file to disk. If the Batch List is open, the download is added to it.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(action == .open ? "Open" : "Download…") { go() }.keyboardShortcut(.defaultAction).disabled(busy || URL(string: text)?.scheme == nil)
            }
        }
        .formStyle(.grouped)
    }

    private func go() {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { return }
        busy = true; error = nil
        Task.detached {
            var media = url
            if !PageResolver.looksLikeMedia(url) && UserDefaults.standard.bool(forKey: Pref.resolveWebPages), let direct = PageResolver.resolve(url) {
                media = direct
            }
            await MainActor.run {
                busy = false
                switch action {
                case .open:
                    AppDelegate.shared.openSource([media])
                case .download:
                    let panel = NSSavePanel()
                    var name = media.lastPathComponent
                    if name.isEmpty || !name.contains(".") { name = (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent) + ".mp4" }
                    panel.nameFieldStringValue = name
                    guard panel.runModal() == .OK, let out = panel.url else { return }
                    let req = RenderRequest(sources: [], segments: [Segment(sourceID: UUID(), start: 0, end: 1)], videoStream: nil, audioStreams: [])
                    AppDelegate.shared.submit(JobSpec(kind: .download(media), request: req, output: out))
                }
            }
        }
    }
}

// MARK: - Guide

struct GuideView: View {
    var body: some View {
        ScrollView {
            Text(Self.text).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static var text: AttributedString {
        if let url = Bundle.main.url(forResource: "Guide", withExtension: "md"), let s = try? String(contentsOf: url, encoding: .utf8),
           let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return a
        }
        return AttributedString("The guide is in README.md next to the application's source.")
    }
}

// MARK: - Add Files to batch

@MainActor
enum BatchAddFlow {
    enum Task_: Hashable {
        case convert(ConvertTarget), export(ExporterKind), saveAs
        var title: String {
            switch self {
            case .convert(let t): return t.title
            case .export(let k): return "Export to \(k.rawValue)"
            case .saveAs: return "Save As (lossless copy)"
            }
        }
    }

    private static var lastFolder: URL?
    private static var lastTask: Task_?
    private static var lastExportSettings: [ExporterKind: ExportSettings] = [:]

    static func rememberExportSettings(_ s: ExportSettings) { lastExportSettings[s.kind] = s }

    static func run(preselected: [URL] = []) {
        var urls = preselected
        if urls.isEmpty {
            let p = NSOpenPanel()
            p.allowsMultipleSelection = true
            p.message = "Choose the files to add to the batch list."
            guard p.runModal() == .OK else { return }
            urls = p.urls
        }
        urls.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let tasks: [Task_] = ConvertTarget.allCases.map { .convert($0) } + [.saveAs] +
            [ExporterKind.quickTime, .mpeg4, .avi, .matroska, .dv, .mpeg2, .audio].map { .export($0) }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 26))
        for t in tasks { popup.addItem(withTitle: t.title) }
        if let last = lastTask, let i = tasks.firstIndex(of: last) { popup.selectItem(at: i) }
        let fix = NSButton(checkboxWithTitle: "Fix timecode breaks", target: nil, action: nil)
        let join = NSButton(checkboxWithTitle: "Join files into one stream", target: nil, action: nil)
        let reuse = NSButton(checkboxWithTitle: "Use previous folder and settings", target: nil, action: nil)
        reuse.isEnabled = lastFolder != nil
        let stack = NSStackView(views: [popup, fix, join, reuse])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 110)
        let alert = NSAlert()
        alert.messageText = "Add \(urls.count) file(s) to the batch list"
        alert.informativeText = "Choose the task to perform on each file."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let task = tasks[popup.indexOfSelectedItem]
        lastTask = task

        var folder = lastFolder
        if reuse.state != .on || folder == nil {
            let p = NSOpenPanel()
            p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
            p.message = "Choose the destination folder."
            guard p.runModal() == .OK, let f = p.url else { return }
            folder = f
        }
        lastFolder = folder

        let groups: [[URL]] = join.state == .on ? [urls] : urls.map { SequenceDetector.sequence(for: $0) }.reduce(into: [[URL]]()) { acc, g in
            if !acc.contains(g) { acc.append(g) }
        }
        AppDelegate.shared.showBatch(nil)
        AppDelegate.shared.log("Reading \(groups.count) file(s) for the batch list…")
        Task.detached(priority: .userInitiated) {
            var sources: [SourceMedia] = []
            for g in groups {
                do { sources.append(try SourceMedia.open(g, companionAudio: g.count == 1 ? SequenceDetector.companionAudio(for: g[0]) : nil)) }
                catch { await MainActor.run { AppDelegate.shared.log("Skipped \(g[0].lastPathComponent): \(error.localizedDescription)") } }
            }
            let ready = sources
            await MainActor.run { finish(task: task, sources: ready, folder: folder!, fix: fix.state == .on, reuseSettings: reuse.state == .on) }
        }
    }

    private static func finish(task: Task_, sources: [SourceMedia], folder: URL, fix: Bool, reuseSettings: Bool) {
        let batch = AppDelegate.shared.batch
        switch task {
        case .export(let kind):
            if reuseSettings, let s = lastExportSettings[kind] {
                let model = ExporterModel(kind: kind, player: nil, presets: AppDelegate.shared.presets)
                model.settings = s
                model.batchSources = sources
                model.batchFolder = folder
                model.make()
            } else {
                let model = ExporterModel(kind: kind, player: nil, presets: AppDelegate.shared.presets)
                model.batchSources = sources
                model.batchFolder = folder
                if let v = sources.first?.info.videoStreams.first, kind != .audio {
                    model.settings.frameSize = CommandBuilder.defaultFrameSize(for: model.settings, source: v)
                }
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                w.title = "\(kind.rawValue) Exporter — \(sources.count) file(s)"
                w.contentView = NSHostingView(rootView: ExporterView(model: model))
                w.isReleasedWhenClosed = false
                let wc = NSWindowController(window: w)
                model.close = { wc.close() }
                holdWindows.append(wc)
                w.center()
                wc.showWindow(nil)
            }
        case .convert(let target):
            for src in sources {
                let video = src.info.videoStreams.first?.index ?? -1
                let audio = Pref.d.bool(forKey: Pref.convertOneAudioTrack) || target.isDemux
                    ? Array(src.info.audioStreams.prefix(1).map(\.index)) : src.info.audioStreams.map(\.index)
                var req = RenderRequest(sources: [src], segments: [Segment(sourceID: src.id, start: 0, end: src.info.duration)],
                                        videoStream: video >= 0 ? video : nil, audioStreams: audio)
                req.fixDataBreaks = fix
                req.applyPreferences()
                let out = folder.appendingPathComponent(src.baseName).appendingPathExtension(target.primaryExtension)
                batch.add(JobSpec(kind: .convert(target), request: req, output: out))
            }
        case .saveAs:
            for src in sources {
                var req = RenderRequest(sources: [src], segments: [Segment(sourceID: src.id, start: 0, end: src.info.duration)],
                                        videoStream: src.info.videoStreams.first?.index, audioStreams: src.info.audioStreams.map(\.index))
                req.fixDataBreaks = fix
                req.applyPreferences()
                let out = folder.appendingPathComponent(src.baseName + " copy").appendingPathExtension(SaveAsFormat.original.fileExtension(source: src))
                batch.add(JobSpec(kind: .saveAs(.original), request: req, output: out))
            }
        }
    }

    private static var holdWindows: [NSWindowController] = []
}
