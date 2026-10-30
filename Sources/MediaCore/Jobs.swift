import Foundation

/// Lossless conversions (no video re-encoding).
public enum ConvertTarget: String, Codable, CaseIterable, Sendable {
    case mpeg = "Convert to MPEG…"
    case mpegMP2 = "Convert to MPEG with MP2 Audio…"
    case ts = "Convert to TS…"
    case tsMP2 = "Convert to TS with MP2 Audio…"
    case mp4 = "Convert to MP4 (Lossless Remux)…"
    case mov = "Convert to MOV (Lossless Remux)…"
    case mkv = "Convert to MKV (Lossless Remux)…"
    case demuxM2VAIFF = "Demux to M2V and AIFF…"
    case demuxM2VM1A = "Demux to M2V and M1A…"
    case demuxM2VAC3 = "Demux to M2V and AC3…"
    case demuxM2V = "Demux to M2V…"
    case demuxAIFF = "Demux to AIFF…"
    case demuxM1A = "Demux to M1A…"
    case demuxAC3 = "Demux to AC3…"

    public var title: String { rawValue.replacingOccurrences(of: "…", with: "") }

    public var isDemux: Bool { rawValue.hasPrefix("Demux") }
    /// True when the target only accepts MPEG-1/2 video.
    public var requiresMPEGVideo: Bool { [.mpeg, .mpegMP2, .demuxM2V, .demuxM2VAIFF, .demuxM2VM1A, .demuxM2VAC3].contains(self) }

    /// Extension of the file the user names in the save panel.
    public var primaryExtension: String {
        switch self {
        case .mpeg, .mpegMP2: return "mpg"
        case .ts, .tsMP2: return "ts"
        case .mp4: return "mp4"
        case .mov: return "mov"
        case .mkv: return "mkv"
        case .demuxM2V, .demuxM2VAIFF, .demuxM2VM1A, .demuxM2VAC3: return "m2v"
        case .demuxAIFF: return "aiff"
        case .demuxM1A: return "m1a"
        case .demuxAC3: return "ac3"
        }
    }
}

/// Lossless "Save As" containers.
public enum SaveAsFormat: String, Codable, CaseIterable, Sendable {
    case original = "Same as Source"
    case mov = "QuickTime Movie (MOV)"
    case mp4 = "MPEG-4 (MP4)"
    case mkv = "Matroska (MKV)"
    case avi = "AVI"
    case ts = "MPEG Transport Stream (TS)"
    case mpg = "MPEG Program Stream (MPG)"

    public func fileExtension(source: SourceMedia) -> String {
        switch self {
        case .original:
            let ext = source.locations.first?.pathExtension.lowercased() ?? ""
            return ext.isEmpty ? "mkv" : ext
        case .mov: return "mov"
        case .mp4: return "mp4"
        case .mkv: return "mkv"
        case .avi: return "avi"
        case .ts: return "ts"
        case .mpg: return "mpg"
        }
    }
}

public enum JobKind: Codable, Hashable, Sendable {
    case convert(ConvertTarget)
    case saveAs(SaveAsFormat)
    case export(ExportSettings)
    case checkStream
    case download(URL)

    public var title: String {
        switch self {
        case .convert(let t): return t.title
        case .saveAs: return "Save As"
        case .export(let s): return s.kind == .frame ? "Export Frame" : s.kind == .audio ? "Export Audio" : "Export to \(s.kind.rawValue)"
        case .checkStream: return "Check Stream"
        case .download: return "Download"
        }
    }
}

/// The tracks to use from one clip.
public struct StreamSelection: Codable, Hashable, Sendable {
    public var video: Int?
    public var audio: [Int]
    public init(video: Int?, audio: [Int]) { self.video = video; self.audio = audio }
}

/// Everything ffmpeg needs to know about the material to process.
public struct RenderRequest: Codable, Hashable, Sendable {
    public var sources: [SourceMedia]
    /// Timeline material in order. For lossless jobs these should already be GOP-snapped.
    public var segments: [Segment]
    public var videoStream: Int?
    public var audioStreams: [Int]
    /// Two-channel rendering of multichannel audio for conversions that decode audio.
    public var audioMix: AudioMixMode = .stereoMix
    public var fixDataBreaks = false
    public var resampleTo48k = false
    public var mp2BitrateKbps = 224
    /// PNG produced by `WatermarkRenderer`, overlaid in the lower-right corner.
    public var watermarkImage: URL?
    /// Time of the frame to export (frame exporter only).
    public var frameTime: Double?
    /// Streams to use for clips other than the primary one (appended clips may number streams differently).
    public var selections: [UUID: StreamSelection] = [:]

    public func videoStream(for id: UUID) -> Int? { selections[id].map(\.video) ?? videoStream }
    public func audioStreams(for id: UUID) -> [Int] { selections[id]?.audio ?? audioStreams }

    public init(sources: [SourceMedia], segments: [Segment], videoStream: Int?, audioStreams: [Int]) {
        self.sources = sources
        self.segments = segments
        self.videoStream = videoStream
        self.audioStreams = audioStreams
    }

    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    public func source(_ id: UUID) -> SourceMedia? { sources.first { $0.id == id } }
    public var primary: SourceMedia? { segments.first.flatMap { source($0.sourceID) } ?? sources.first }
}

public struct JobSpec: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var kind: JobKind
    public var request: RenderRequest
    /// Output file (or the first output file of a demux). Ignored by `checkStream`.
    public var output: URL

    public init(kind: JobKind, request: RenderRequest, output: URL) {
        self.kind = kind
        self.request = request
        self.output = output
    }

    public var title: String {
        let name = request.primary?.displayName ?? output.lastPathComponent
        return "\(kind.title): \(name)"
    }

    /// Same job with outputs moved to `folder` (batch "Redirect").
    public func redirected(to folder: URL) -> JobSpec {
        var copy = self
        copy.output = folder.appendingPathComponent(output.lastPathComponent)
        return copy
    }
}
