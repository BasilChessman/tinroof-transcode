import Foundation
import CMedia

public enum StreamKind: String, Codable, Sendable { case video, audio, subtitle, other }

public enum FieldOrder: String, Codable, Sendable {
    case unknown, progressive, topFirst, bottomFirst

    public var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .progressive: return "Progressive"
        case .topFirst: return "Upper Field First"
        case .bottomFirst: return "Lower Field First"
        }
    }

    public var isInterlaced: Bool { self == .topFirst || self == .bottomFirst }
}

public struct StreamInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var kind: StreamKind
    /// PID (transport streams), start code (program streams) or container track id.
    public var streamID: Int
    public var codec: String
    public var codecLongName: String
    public var profile: String
    public var language: String
    public var width: Int
    public var height: Int
    public var sampleAspect: Double
    public var displayAspectNum: Int
    public var displayAspectDen: Int
    public var frameRate: Double
    public var variableFrameRate: Bool
    public var fieldOrder: FieldOrder
    public var pixelFormat: String
    public var sampleRate: Int
    public var channels: Int
    public var channelLayout: String
    public var bitRate: Int64
    public var duration: Double
    public var isAttachedPicture: Bool

    public var displayAspect: Double {
        if displayAspectDen > 0 && displayAspectNum > 0 { return Double(displayAspectNum) / Double(displayAspectDen) }
        return height > 0 ? Double(width) / Double(height) * sampleAspect : 16.0 / 9.0
    }

    /// Short description used in track pop-up menus, e.g. `0x1E1 mpeg2video 720x576`.
    public var menuTitle: String {
        let id = streamID > 0 ? String(format: "0x%X ", streamID) : "#\(index) "
        switch kind {
        case .video:
            return id + "\(codec) \(width)×\(height) \(String(format: "%.3g", frameRate)) fps"
        case .audio:
            var t = id + "\(codec) \(sampleRate / 1000) kHz \(channelLayout.isEmpty ? "\(channels) ch" : channelLayout)"
            if !language.isEmpty { t += " [\(language)]" }
            return t
        default:
            return id + codec
        }
    }

    public var isSurroundLayout: Bool { channels > 2 }
    /// ffmpeg pan channel names for the surround pair in this layout.
    public var surroundPairNames: (String, String) {
        channelLayout.contains("side") || channelLayout == "5.1" || channelLayout == "7.1" ? ("SL", "SR") : ("BL", "BR")
    }
}

public struct MediaInfo: Codable, Hashable, Sendable {
    public var url: String
    public var formatName: String
    public var formatLongName: String
    public var duration: Double
    public var startTime: Double
    public var bitRate: Int64
    public var fileSize: Int64
    public var streams: [StreamInfo]

    public var videoStreams: [StreamInfo] { streams.filter { $0.kind == .video && !$0.isAttachedPicture } }
    public var audioStreams: [StreamInfo] { streams.filter { $0.kind == .audio } }

    /// True for MPEG-1/2 program, transport and elementary streams, which support lossless remuxing.
    public var isMPEGFamily: Bool {
        let f = formatName
        let mpegContainer = f.contains("mpeg") || f.contains("mpegts") || f.contains("vob") || f == "mpegvideo" || f == "m2v"
        let mpegVideo = videoStreams.contains { $0.codec == "mpeg2video" || $0.codec == "mpeg1video" }
        return mpegContainer && (mpegVideo || videoStreams.isEmpty)
    }

    public var isTransportStream: Bool { formatName.contains("mpegts") }
}

public enum MediaError: LocalizedError {
    case openFailed(String)
    case unsupported(String)
    case ffmpegMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let s): return "The file could not be opened. \(s)"
        case .unsupported(let s): return s
        case .ffmpegMissing: return "The ffmpeg tool was not found. Install it with “brew install ffmpeg” or set its location in Settings."
        case .failed(let s): return s
        }
    }
}

private func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.bindMemory(to: CChar.self)
        return String(cString: bytes.baseAddress!)
    }
}

extension StreamInfo {
    init(_ s: MCStreamInfo) {
        index = Int(s.index)
        switch s.type {
        case MC_STREAM_VIDEO: kind = .video
        case MC_STREAM_AUDIO: kind = .audio
        case MC_STREAM_SUBTITLE: kind = .subtitle
        default: kind = .other
        }
        streamID = Int(s.id)
        codec = cString(s.codec)
        codecLongName = cString(s.codec_long)
        profile = cString(s.profile)
        language = cString(s.language)
        width = Int(s.width)
        height = Int(s.height)
        sampleAspect = s.sar_den > 0 ? Double(s.sar_num) / Double(s.sar_den) : 1
        displayAspectNum = Int(s.dar_num)
        displayAspectDen = Int(s.dar_den)
        frameRate = s.fps
        variableFrameRate = s.variable_fps != 0
        switch s.field_order {
        case MC_FIELD_PROGRESSIVE: fieldOrder = .progressive
        case MC_FIELD_TOP_FIRST: fieldOrder = .topFirst
        case MC_FIELD_BOTTOM_FIRST: fieldOrder = .bottomFirst
        default: fieldOrder = .unknown
        }
        pixelFormat = cString(s.pix_fmt)
        sampleRate = Int(s.sample_rate)
        channels = Int(s.channels)
        channelLayout = cString(s.channel_layout)
        bitRate = s.bit_rate
        duration = s.duration
        isAttachedPicture = s.is_attached_pic != 0
    }
}

public enum MediaProbe {
    /// Opens `input` (a path, URL or `concat:` spec) and reads its container and stream descriptions.
    public static func probe(_ input: String) throws -> MediaInfo {
        var err = [CChar](repeating: 0, count: 512)
        guard let dec = mc_open(input, &err, Int32(err.count)) else {
            throw MediaError.openFailed(String(cString: err))
        }
        defer { mc_close(dec) }
        var fi = MCFileInfo()
        mc_get_file_info(dec, &fi)
        var streams: [StreamInfo] = []
        for i in 0..<Int(fi.nb_streams) {
            var si = MCStreamInfo()
            if mc_get_stream_info(dec, Int32(i), &si) == 0 { streams.append(StreamInfo(si)) }
        }
        var duration = fi.duration
        if duration <= 0 { duration = streams.map(\.duration).max() ?? 0 }
        return MediaInfo(url: input,
                         formatName: cString(fi.format_name),
                         formatLongName: cString(fi.format_long_name),
                         duration: duration,
                         startTime: fi.start_time,
                         bitRate: fi.bit_rate,
                         fileSize: fi.file_size,
                         streams: streams)
    }
}

/// Keyframe positions and timestamp discontinuities of one stream.
public struct StreamIndex: Sendable {
    public var keyframes: [Double]
    public var breaks: [Double]
    public var duration: Double
    public var packets: Int64
    public var corruptPackets: Int64

    public init(keyframes: [Double], breaks: [Double] = [], duration: Double = 0, packets: Int64 = 0, corruptPackets: Int64 = 0) {
        self.keyframes = keyframes.sorted()
        self.breaks = breaks
        self.duration = duration
        self.packets = packets
        self.corruptPackets = corruptPackets
    }

    /// Latest keyframe at or before `t`.
    public func keyframe(atOrBefore t: Double) -> Double? {
        var lo = 0, hi = keyframes.count - 1, best: Double?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if keyframes[mid] <= t + 1e-6 { best = keyframes[mid]; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    /// Earliest keyframe at or after `t`.
    public func keyframe(atOrAfter t: Double) -> Double? {
        var lo = 0, hi = keyframes.count - 1, best: Double?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if keyframes[mid] >= t - 1e-6 { best = keyframes[mid]; hi = mid - 1 } else { lo = mid + 1 }
        }
        return best
    }

    public func keyframe(after t: Double) -> Double? { keyframe(atOrAfter: t + 0.001) }
    public func keyframe(before t: Double) -> Double? { keyframe(atOrBefore: t - 0.001) }

    private final class ProgressBox {
        let handler: (Double) -> Bool
        init(_ h: @escaping (Double) -> Bool) { handler = h }
    }

    /// Scans every packet of `streamIndex`. `progress` returns false to cancel.
    public static func build(input: String, streamIndex: Int, progress: ((Double) -> Bool)? = nil) throws -> StreamIndex {
        var idx = MCIndex()
        let box = progress.map(ProgressBox.init)
        let ctx = box.map { Unmanaged.passUnretained($0).toOpaque() }
        let cb: MCProgressCallback? = box == nil ? nil : { fraction, context in
            let b = Unmanaged<ProgressBox>.fromOpaque(context!).takeUnretainedValue()
            return b.handler(fraction) ? 0 : 1
        }
        let r = withExtendedLifetime(box) { mc_build_index(input, Int32(streamIndex), &idx, cb, ctx) }
        guard r >= 0 else { throw MediaError.failed("Indexing failed (\(r)).") }
        defer { mc_free_index(&idx) }
        let k = idx.keyframes.map { Array(UnsafeBufferPointer(start: $0, count: Int(idx.keyframe_count))) } ?? []
        let b = idx.breaks.map { Array(UnsafeBufferPointer(start: $0, count: Int(idx.break_count))) } ?? []
        return StreamIndex(keyframes: k, breaks: b, duration: idx.duration, packets: idx.packets, corruptPackets: idx.corrupt_packets)
    }
}

/// Which video codecs this Mac's Media Engine can decode (asked from VideoToolbox, cached).
public enum HardwareDecoding {
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]
    private static let lock = NSLock()

    public static func isSupported(_ codec: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let known = cache[codec] { return known }
        let supported = mc_hardware_decode_supported(codec) != 0
        cache[codec] = supported
        return supported
    }
}
