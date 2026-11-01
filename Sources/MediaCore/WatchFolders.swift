import Foundation
import Combine

/// One encoding applied to every file dropped into a watch folder.
public struct WatchOutput: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var kind: JobKind

    public init(name: String, kind: JobKind) {
        self.name = name
        self.kind = kind
    }

    /// False for picture outputs given a file without video.
    public func accepts(_ source: SourceMedia) -> Bool {
        if !source.info.videoStreams.isEmpty { return true }
        switch kind {
        case .export(let s): return s.kind == .audio
        case .convert(let t): return [.demuxAIFF, .demuxM1A, .demuxAC3, .mp4, .mov, .mkv].contains(t)
        default: return true
        }
    }

    /// Extension of the file this output writes for `source`.
    public func fileExtension(for source: SourceMedia) -> String {
        switch kind {
        case .export(let s): return s.outputExtension
        case .convert(let t): return t.primaryExtension
        case .saveAs(let f): return f.fileExtension(source: source)
        case .checkStream, .download: return "out"
        }
    }
}

/// A folder whose new files are encoded automatically (like Adobe Media Encoder's watch folders).
public struct WatchFolder: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var path: String
    public var enabled = true
    public var outputs: [WatchOutput] = []
    /// Where results go; nil = an "Output" folder inside the watch folder.
    public var outputPath: String?

    public init(path: String) { self.path = path }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var name: String { url.lastPathComponent }
    /// The watch folder itself is never used, or its results would be picked up as new files.
    public var outputURL: URL {
        if let outputPath, URL(fileURLWithPath: outputPath).standardizedFileURL.path != url.standardizedFileURL.path {
            return URL(fileURLWithPath: outputPath, isDirectory: true)
        }
        return url.appendingPathComponent(WatchFolderManager.outputFolderName)
    }
    public var sourceURL: URL { url.appendingPathComponent(WatchFolderManager.sourceFolderName) }
    public var failedURL: URL { url.appendingPathComponent(WatchFolderManager.failedFolderName) }
}

/// Polls watch folders, queues new files once they have finished copying, and files the originals
/// into Source (all outputs succeeded) or Failed afterwards.
@MainActor
public final class WatchFolderManager: ObservableObject {
    nonisolated public static let outputFolderName = "Output"
    nonisolated public static let sourceFolderName = "Source"
    nonisolated public static let failedFolderName = "Failed"

    @Published public var folders: [WatchFolder] = [] { didSet { save() } }
    @Published public var autoEncode = false { didSet { save(); if autoEncode { scanNow() } } }
    /// Recent events, newest first.
    @Published public private(set) var activity: [String] = []
    /// Files queued or encoding, by path.
    @Published public private(set) var inFlightCount = 0

    /// Seconds between scans. A file is queued once its size and date are unchanged across two scans.
    public var interval: TimeInterval = 2
    /// Applies app preferences to each request before queueing.
    public var prepare: ((inout RenderRequest) -> Void)?
    public var onLog: ((String) -> Void)?
    /// Set false to keep changes in memory only.
    public var persists = true

    private let queue: BatchQueue
    private let storeURL: URL
    private var timer: Timer?
    private var observed: [String: (size: Int64, modified: Date, stableScans: Int)] = [:]
    private struct InFlight { var folder: UUID; var taskIDs: Set<UUID>; var failed: Bool; var probing: Bool }
    private var inFlight: [String: InFlight] = [:] { didSet { inFlightCount = inFlight.count } }
    private var loading = false

    public init(queue: BatchQueue, storeDirectory: URL) {
        self.queue = queue
        storeURL = storeDirectory.appendingPathComponent("WatchFolders.json")
        loading = true
        if let data = try? Data(contentsOf: storeURL), let state = try? JSONDecoder().decode(Stored.self, from: data) {
            folders = state.folders
            autoEncode = state.autoEncode
        }
        loading = false
        let previous = queue.onTaskFinished
        queue.onTaskFinished = { [weak self] task in
            previous?(task)
            self?.taskFinished(task)
        }
    }

    private struct Stored: Codable { var folders: [WatchFolder]; var autoEncode: Bool }

    private func save() {
        guard persists, !loading else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(Stored(folders: folders, autoEncode: autoEncode)).write(to: storeURL, options: .atomic)
    }

    // MARK: Folders

    public func addFolder(_ url: URL) {
        guard !folders.contains(where: { $0.path == url.path }) else { return }
        folders.append(WatchFolder(path: url.path))
        log("Watching \(url.lastPathComponent)")
    }

    public func removeFolder(_ id: UUID) { folders.removeAll { $0.id == id } }

    public func update(_ folder: WatchFolder) {
        if let i = folders.firstIndex(where: { $0.id == folder.id }) { folders[i] = folder }
    }

    // MARK: Scanning

    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanNow() }
        }
        scanNow()
    }

    public func stop() { timer?.invalidate(); timer = nil }

    /// Looks for new, finished files in every enabled folder.
    public func scanNow() {
        guard autoEncode else { return }
        let fm = FileManager.default
        var seen = Set<String>()
        for folder in folders where folder.enabled && !folder.outputs.isEmpty {
            guard let items = try? fm.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                                          options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }
            for item in items {
                guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                let ext = item.pathExtension.lowercased()
                guard SequenceDetector.videoExtensions.contains(ext) || SequenceDetector.audioExtensions.contains(ext) else { continue }
                let path = item.path
                seen.insert(path)
                guard inFlight[path] == nil else { continue }
                let size = Int64(values.fileSize ?? 0), modified = values.contentModificationDate ?? .distantPast
                // Wait until the file stops changing: it may still be copying in.
                if let prev = observed[path], prev.size == size, prev.modified == modified, size > 0 {
                    observed[path] = (size, modified, prev.stableScans + 1)
                } else {
                    observed[path] = (size, modified, 0)
                }
                if observed[path]!.stableScans >= 1 {
                    observed[path] = nil
                    enqueue(item, folder: folder)
                }
            }
        }
        observed = observed.filter { seen.contains($0.key) }
        forgetRemovedTasks()
    }

    private func enqueue(_ file: URL, folder: WatchFolder) {
        inFlight[file.path] = InFlight(folder: folder.id, taskIDs: [], failed: false, probing: true)
        log("Found \(file.lastPathComponent) in \(folder.name)")
        Task.detached(priority: .userInitiated) {
            let result = Result { try SourceMedia.open([file], companionAudio: SequenceDetector.companionAudio(for: file)) }
            await MainActor.run { self.queueJobs(file, folder: folder, probe: result) }
        }
    }

    private func queueJobs(_ file: URL, folder: WatchFolder, probe: Result<SourceMedia, Error>) {
        guard case .success(let src) = probe else {
            if case .failure(let e) = probe { log("Cannot read \(file.lastPathComponent): \(e.localizedDescription)") }
            inFlight[file.path] = nil
            fileAway(file, to: folder.failedURL)
            return
        }
        let outputs = folder.outputs.filter { $0.accepts(src) }
        guard !outputs.isEmpty else {
            log("No output suits \(file.lastPathComponent) (it has no video)")
            inFlight[file.path] = nil
            fileAway(file, to: folder.failedURL)
            return
        }
        try? FileManager.default.createDirectory(at: folder.outputURL, withIntermediateDirectories: true)
        var ids = Set<UUID>()
        for output in outputs {
            var req = RenderRequest(sources: [src], segments: [Segment(sourceID: src.id, start: 0, end: src.info.duration)],
                                    videoStream: src.info.videoStreams.first?.index,
                                    audioStreams: Self.audioStreams(for: output.kind, src))
            prepare?(&req)
            let suffix = folder.outputs.count > 1 ? " - \(output.name)" : ""
            let target = Self.uniqueURL(folder.outputURL.appendingPathComponent(src.baseName + suffix)
                .appendingPathExtension(output.fileExtension(for: src)))
            queue.add(JobSpec(kind: output.kind, request: req, output: target))
            if let task = queue.tasks.last { ids.insert(task.id) }
        }
        inFlight[file.path] = InFlight(folder: folder.id, taskIDs: ids, failed: false, probing: false)
        log("Queued \(file.lastPathComponent): \(folder.outputs.map(\.name).joined(separator: ", "))")
        if autoEncode { queue.start() }
    }

    static func audioStreams(for kind: JobKind, _ src: SourceMedia) -> [Int] {
        switch kind {
        case .export: return Array(src.info.audioStreams.prefix(1).map(\.index))
        case .convert(let t) where t.isDemux: return Array(src.info.audioStreams.prefix(1).map(\.index))
        default: return src.info.audioStreams.map(\.index)
        }
    }

    // MARK: Completion

    private func taskFinished(_ task: BatchTask) {
        guard let match = inFlight.first(where: { $0.value.taskIDs.contains(task.id) }) else { return }
        let path = match.key
        var entry = match.value
        // A stopped job may be restarted from the batch list, so only completion or failure settles it.
        guard task.status == .completed || task.status.isFailure else { return }
        entry.taskIDs.remove(task.id)
        if task.status != .completed { entry.failed = true }
        inFlight[path] = entry
        if entry.taskIDs.isEmpty { settle(path) }
    }

    /// Jobs taken out of the batch list count as failed, so their source is not encoded again.
    private func forgetRemovedTasks() {
        let live = Set(queue.tasks.map(\.id))
        for (path, entry) in inFlight where !entry.probing {
            let gone = entry.taskIDs.subtracting(live)
            guard !gone.isEmpty else { continue }
            var e = entry
            e.taskIDs.subtract(gone)
            e.failed = true
            inFlight[path] = e
            if e.taskIDs.isEmpty { settle(path) }
        }
    }

    private func settle(_ path: String) {
        guard let entry = inFlight.removeValue(forKey: path), let folder = folders.first(where: { $0.id == entry.folder }) else { return }
        let file = URL(fileURLWithPath: path)
        if entry.failed {
            log("Failed: \(file.lastPathComponent) moved to \(Self.failedFolderName)")
            fileAway(file, to: folder.failedURL)
        } else {
            log("Done: \(file.lastPathComponent) moved to \(Self.sourceFolderName)")
            fileAway(file, to: folder.sourceURL)
        }
    }

    private func fileAway(_ file: URL, to folder: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = Self.uniqueURL(folder.appendingPathComponent(file.lastPathComponent))
        do { try fm.moveItem(at: file, to: target) } catch { log("Could not move \(file.lastPathComponent): \(error.localizedDescription)") }
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext`… if taken.
    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private func log(_ s: String) {
        activity.insert(s, at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
        onLog?("Watch folders: \(s)")
    }
}

extension TaskStatus {
    public var isFailure: Bool { if case .failed = self { return true }; return false }
}

extension WatchOutput {
    /// Ready-made outputs offered alongside saved presets.
    public static var builtIn: [WatchOutput] {
        func export(_ name: String, _ kind: ExporterKind, _ codec: VideoCodec? = nil, audio: AudioFormat? = nil, _ tweak: (inout ExportSettings) -> Void = { _ in }) -> WatchOutput {
            var s = ExportSettings.defaults(for: kind)
            if let codec { s.videoCodec = codec }
            if let audio { s.audioFormat = audio }
            tweak(&s)
            return WatchOutput(name: name, kind: .export(s))
        }
        return [
            export("MP4 H.264", .mpeg4, .h264, audio: .aac),
            export("MP4 HEVC (Apple hardware)", .mpeg4, .hevcHardware, audio: .aac),
            export("ProRes 422", .quickTime, .proRes, audio: .pcm) { $0.proResProfile = .standard },
            export("ProRes 422 HQ", .quickTime, .proRes, audio: .pcm) { $0.proResProfile = .hq },
            export("Hap", .quickTime, .hap, audio: .pcm),
            export("WebM / MKV AV1", .matroska, .av1, audio: .opus),
            export("Audio AAC", .audio, audio: .aac),
            export("Audio MP3", .audio, audio: .mp3),
            export("Audio WAV", .audio, audio: .wav),
            WatchOutput(name: "Lossless remux to MP4", kind: .convert(.mp4)),
            WatchOutput(name: "Lossless remux to MOV", kind: .convert(.mov)),
            WatchOutput(name: "Lossless remux to MKV", kind: .convert(.mkv)),
        ]
    }
}
