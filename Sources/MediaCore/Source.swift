import Foundation

/// An opened input: one file, several files forming one MPEG stream, or a remote URL.
public struct SourceMedia: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Local files in playback order, or a single remote URL.
    public var locations: [URL]
    /// Separate audio file multiplexed with a demuxed video file (e.g. movie.m2v + movie.ac3).
    public var companionAudio: URL?
    public var info: MediaInfo
    public var companionInfo: MediaInfo?

    public init(id: UUID = UUID(), locations: [URL], companionAudio: URL? = nil, info: MediaInfo, companionInfo: MediaInfo? = nil) {
        self.id = id
        self.locations = locations
        self.companionAudio = companionAudio
        self.info = info
        self.companionInfo = companionInfo
    }

    public var isRemote: Bool { locations.first.map { !$0.isFileURL } ?? false }

    /// String handed to libavformat / ffmpeg. Multiple MPEG files are byte-joined with the concat protocol.
    public var inputSpec: String { Self.inputSpec(for: locations) }

    public static func inputSpec(for locations: [URL]) -> String {
        if locations.count > 1 {
            return "concat:" + locations.map(\.path).joined(separator: "|")
        }
        guard let first = locations.first else { return "" }
        return first.isFileURL ? first.path : first.absoluteString
    }

    public var displayName: String {
        guard let first = locations.first else { return "Untitled" }
        let name = first.isFileURL ? first.lastPathComponent : (first.lastPathComponent.isEmpty ? first.host ?? "stream" : first.lastPathComponent)
        return locations.count > 1 ? "\(name) (+\(locations.count - 1))" : name
    }

    public var baseName: String {
        guard let first = locations.first else { return "Untitled" }
        let n = first.deletingPathExtension().lastPathComponent
        return n.isEmpty ? "Untitled" : n
    }

    public var totalFileSize: Int64 {
        locations.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return sum + size
        }
    }

    /// Opens and probes `locations` (plus a companion audio file when present).
    public static func open(_ locations: [URL], companionAudio: URL? = nil) throws -> SourceMedia {
        let spec = inputSpec(for: locations)
        let info = try MediaProbe.probe(spec)
        let companionInfo = try companionAudio.map { try MediaProbe.probe($0.path) }
        return SourceMedia(locations: locations, companionAudio: companionAudio, info: info, companionInfo: companionInfo)
    }
}

/// Finds the other parts of a stream that devices split into several files,
/// and audio files that belong to a demuxed video file.
public enum SequenceDetector {
    public static let videoExtensions: Set<String> = [
        "ts", "m2t", "mts", "m2ts", "mmv", "rec", "vid", "avr", "tp", "tp0", "trp", "tod",
        "mpg", "mpeg", "ps", "vob", "vro", "dat", "m2p", "mod", "dcm", "vdr", "pvr",
        "m2v", "m1v", "mpv", "mov", "dv", "avi", "mp4", "m4v", "divx", "mkv", "webm", "wmv", "asf", "flv",
        "3gp", "ogv", "mxf", "jpeg", "jpg", "tiff", "tif", "png",
    ]
    public static let audioExtensions: Set<String> = [
        "aiff", "aif", "m1a", "m2a", "mp2", "mpa", "ac3", "aud", "mp3", "wav", "m4a", "aac", "flac", "eac3",
    ]
    static let companionAudioOrder = ["aiff", "aif", "wav", "m1a", "mp2", "mpa", "m2a", "ac3"]

    /// Returns the ordered list of files that continue `url`, including `url`, or `[url]`.
    public static func sequence(for url: URL, fileManager: FileManager = .default) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let exists = { (n: String) in fileManager.fileExists(atPath: dir.appendingPathComponent(n).path) }

        // DVD: VTS_01_1.VOB, VTS_01_2.VOB, … (VTS_xx_0 is the menu and is skipped)
        if let m = name.wholeMatch(of: #/(?i)(VTS_\d\d_)(\d)\.(VOB)/#) {
            let prefix = String(m.1), ext = String(m.3)
            var n = Int(m.2) ?? 1
            if n == 0 { return [url] }
            while n > 1, exists("\(prefix)\(n - 1).\(ext)") { n -= 1 }
            var out: [URL] = []
            while exists("\(prefix)\(n).\(ext)") { out.append(dir.appendingPathComponent("\(prefix)\(n).\(ext)")); n += 1 }
            return out.isEmpty ? [url] : out
        }
        // DreamBox style: Recording.ts, Recording.ts.001, Recording.ts.002, …
        if let m = name.wholeMatch(of: #/(.+\.ts)(?:\.(\d{3}))?/#) {
            let base = String(m.1)
            var out = [dir.appendingPathComponent(base)].filter { fileManager.fileExists(atPath: $0.path) }
            var i = 1
            while exists(String(format: "%@.%03d", base, i)) { out.append(dir.appendingPathComponent(String(format: "%@.%03d", base, i))); i += 1 }
            if out.count > 1 { return out }
        }
        // Humax style: Movie~0.vid, Movie~1.vid, …
        if let m = name.wholeMatch(of: #/(.+~)(\d+)\.(vid)/#.ignoresCase()) {
            return numbered(dir: dir, prefix: String(m.1), suffix: "." + String(m.3), from: 0, exists: exists) ?? [url]
        }
        // Homecast style: 000&&Channel.tp0, .tp1, …
        if let m = name.wholeMatch(of: #/(.+\.tp)(\d)/#.ignoresCase()) {
            return numbered(dir: dir, prefix: String(m.1), suffix: "", from: 0, exists: exists) ?? [url]
        }
        return [url]
    }

    private static func numbered(dir: URL, prefix: String, suffix: String, from: Int, exists: (String) -> Bool) -> [URL]? {
        var out: [URL] = []
        var i = from
        while exists("\(prefix)\(i)\(suffix)") { out.append(dir.appendingPathComponent("\(prefix)\(i)\(suffix)")); i += 1 }
        return out.count > 1 ? out : nil
    }

    /// For .m2v / .m1v / .mpv files, the same-named audio file to multiplex with it.
    public static func companionAudio(for url: URL, fileManager: FileManager = .default) -> URL? {
        guard ["m2v", "m1v", "mpv"].contains(url.pathExtension.lowercased()) else { return nil }
        let base = url.deletingPathExtension()
        for ext in companionAudioOrder {
            for candidate in [base.appendingPathExtension(ext), base.appendingPathExtension(ext.uppercased())] where fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// A title on a DVD-Video disc or VIDEO_TS folder.
public struct DVDTitle: Identifiable, Hashable, Sendable {
    public var id: Int { titleSet }
    public var titleSet: Int
    public var files: [URL]
    public var totalSize: Int64

    public var label: String {
        let gb = Double(totalSize) / 1_000_000_000
        return String(format: "Title set %d — %d file%@, %.2f GB", titleSet, files.count, files.count == 1 ? "" : "s", gb)
    }
}

public enum DVDScanner {
    /// Accepts a disc root, a VIDEO_TS folder, or any folder containing VTS_xx_y.VOB files.
    public static func titles(at folder: URL, fileManager: FileManager = .default) -> [DVDTitle] {
        var dir = folder
        let videoTS = folder.appendingPathComponent("VIDEO_TS")
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: videoTS.path, isDirectory: &isDir), isDir.boolValue { dir = videoTS }
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return [] }
        var sets: [Int: [(Int, URL)]] = [:]
        for name in names {
            guard let m = name.wholeMatch(of: #/(?i)VTS_(\d\d)_(\d)\.VOB/#), let ts = Int(m.1), let part = Int(m.2), part > 0 else { continue }
            sets[ts, default: []].append((part, dir.appendingPathComponent(name)))
        }
        return sets.keys.sorted().map { ts in
            let files = sets[ts]!.sorted { $0.0 < $1.0 }.map(\.1)
            let size = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return DVDTitle(titleSet: ts, files: files, totalSize: size)
        }
    }
}
