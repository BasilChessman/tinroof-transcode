import Foundation

/// Which exporter window the settings belong to.
public enum ExporterKind: String, Codable, CaseIterable, Sendable {
    case quickTime = "QuickTime"
    case mpeg4 = "MPEG-4"
    case avi = "AVI"
    case dv = "DV"
    case mpeg2 = "MPEG-2 (DVD)"
    case matroska = "MKV / WebM"
    case audio = "Audio"
    case frame = "Frame"

    public var fileExtension: String {
        switch self {
        case .quickTime: return "mov"
        case .mpeg4: return "mp4"
        case .avi: return "avi"
        case .dv: return "dv"
        case .mpeg2: return "mpg"
        case .matroska: return "mkv"
        case .audio, .frame: return ""
        }
    }

    public var videoCodecs: [VideoCodec] {
        switch self {
        case .quickTime:
            return [.h264, .h264Hardware, .hevc, .hevcHardware, .proRes, .proResHardware, .dnxhr, .cineform,
                    .hap, .hapAlpha, .hapQ, .animation, .v210, .mjpeg, .dv, .mpeg4Part2, .png]
        case .mpeg4: return [.h264, .h264Hardware, .hevc, .hevcHardware, .av1, .mpeg4Part2]
        case .avi: return [.mpeg4Part2, .h264, .mjpeg, .dv, .utVideo, .uncompressed]
        case .dv: return [.dv]
        case .mpeg2: return [.mpeg2]
        case .matroska: return [.av1, .vp9, .h264, .hevc, .ffv1, .proRes, .dnxhr]
        case .audio, .frame: return []
        }
    }

    public var audioFormats: [AudioFormat] {
        switch self {
        case .quickTime: return [.aac, .pcm, .pcm24, .alac, .mp3, .ac3, .passThrough, .none]
        case .mpeg4: return [.aac, .ac3, .opus, .passThrough, .none]
        case .matroska: return [.opus, .aac, .flac, .ac3, .pcm, .passThrough, .none]
        case .avi: return [.mp3, .pcm, .mp2, .ac3, .passThrough, .none]
        case .dv: return [.pcm]
        case .mpeg2: return [.mp2, .ac3, .pcm]
        case .audio: return [.aiff, .wav, .aac, .alac, .mp3, .mp2, .ac3, .flac]
        case .frame: return []
        }
    }
}

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264 = "H.264 (x264)"
    case h264Hardware = "H.264 (Apple hardware)"
    case hevc = "HEVC / H.265 (x265)"
    case hevcHardware = "HEVC (Apple hardware)"
    case proRes = "Apple ProRes"
    case proResHardware = "Apple ProRes (hardware)"
    case mjpeg = "Motion JPEG"
    case dv = "DV"
    case mpeg4Part2 = "MPEG-4 Part 2 (DivX/Xvid compatible)"
    case mpeg2 = "MPEG-2"
    case dnxhr = "Avid DNxHR"
    case cineform = "GoPro CineForm"
    case hap = "Hap"
    case hapAlpha = "Hap Alpha"
    case hapQ = "Hap Q"
    case animation = "QuickTime Animation"
    case png = "PNG (lossless)"
    case v210 = "Uncompressed 10-bit 4:2:2 (v210)"
    case av1 = "AV1 (SVT-AV1)"
    case vp9 = "VP9"
    case ffv1 = "FFV1 (lossless archival)"
    case utVideo = "Ut Video (lossless)"
    case uncompressed = "Uncompressed"

    /// ffmpeg encoder that must be present for this codec to be offered.
    public var encoderName: String {
        switch self {
        case .h264: return "libx264"
        case .h264Hardware: return "h264_videotoolbox"
        case .hevc: return "libx265"
        case .hevcHardware: return "hevc_videotoolbox"
        case .proRes: return "prores_ks"
        case .proResHardware: return "prores_videotoolbox"
        case .mjpeg: return "mjpeg"
        case .dv: return "dvvideo"
        case .mpeg4Part2: return "mpeg4"
        case .mpeg2: return "mpeg2video"
        case .dnxhr: return "dnxhd"
        case .cineform: return "cfhd"
        case .hap, .hapAlpha, .hapQ: return "hap"
        case .animation: return "qtrle"
        case .png: return "png"
        case .v210: return "v210"
        case .av1: return "libsvtav1"
        case .vp9: return "libvpx-vp9"
        case .ffv1: return "ffv1"
        case .utVideo: return "utvideo"
        case .uncompressed: return "rawvideo"
        }
    }

    public var supportsMultiPass: Bool { [.h264, .hevc, .mpeg4Part2, .mpeg2, .vp9].contains(self) }
    public var supportsBFrames: Bool { [.h264, .hevc, .h264Hardware, .hevcHardware, .mpeg4Part2, .mpeg2].contains(self) }
    public var supportsDataRate: Bool { [.h264, .hevc, .h264Hardware, .hevcHardware, .mjpeg, .mpeg4Part2, .mpeg2, .av1, .vp9].contains(self) }
    public var supportsQuality: Bool { [.h264, .hevc, .h264Hardware, .hevcHardware, .mjpeg, .mpeg4Part2, .mpeg2, .av1, .vp9, .cineform].contains(self) }
    public var hasProfiles: Bool { [.proRes, .proResHardware, .dnxhr].contains(self) }
    /// Intra-frame codecs carry an alpha channel only for these.
    public var supportsAlpha: Bool { [.hapAlpha, .animation, .png].contains(self) }
}

public enum DNxHRProfile: String, Codable, CaseIterable, Sendable {
    case lb = "dnxhr_lb", sq = "dnxhr_sq", hq = "dnxhr_hq", hqx = "dnxhr_hqx", p444 = "dnxhr_444"
    public var label: String {
        switch self {
        case .lb: return "LB (Low Bandwidth)"
        case .sq: return "SQ (Standard)"
        case .hq: return "HQ (High Quality)"
        case .hqx: return "HQX (10-bit)"
        case .p444: return "444 (10-bit 4:4:4)"
        }
    }
    public var pixelFormat: String {
        switch self {
        case .lb, .sq, .hq: return "yuv422p"
        case .hqx: return "yuv422p10le"
        case .p444: return "yuv444p10le"
        }
    }
}

/// Which encoders the installed ffmpeg provides (queried once with `ffmpeg -encoders`).
public enum EncoderAvailability {
    nonisolated(unsafe) private static var cache: Set<String>?
    private static let lock = NSLock()

    public static func available() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        var names = Set<String>()
        if let ffmpeg = FFmpegLocator.find() {
            let p = Process()
            p.executableURL = ffmpeg
            p.arguments = ["-hide_banner", "-encoders"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                for line in text.split(separator: "\n") {
                    let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                    if cols.count >= 2, cols[0].count == 6 { names.insert(String(cols[1])) }
                }
            }
        }
        cache = names
        return names
    }

    public static func isAvailable(_ codec: VideoCodec) -> Bool { available().contains(codec.encoderName) }

    public static func reset() { lock.lock(); cache = nil; lock.unlock() }
}

public enum ProResProfile: Int, Codable, CaseIterable, Sendable {
    case proxy = 0, lt = 1, standard = 2, hq = 3, p4444 = 4
    public var label: String { ["Proxy", "LT", "422", "422 HQ", "4444"][rawValue] }
}

public enum AudioFormat: String, Codable, CaseIterable, Sendable {
    case passThrough = "Pass Through"
    case none = "No Sound"
    case aac = "AAC"
    case pcm = "Uncompressed (PCM)"
    case pcm24 = "Uncompressed 24-bit"
    case opus = "Opus"
    case alac = "Apple Lossless"
    case mp3 = "MP3"
    case mp2 = "MPEG Layer 2"
    case ac3 = "AC3 (Dolby Digital)"
    case aiff = "AIFF"
    case wav = "WAV"
    case flac = "FLAC"

    public var hasBitrate: Bool { [.aac, .mp3, .mp2, .ac3, .opus].contains(self) }

    public var audioFileExtension: String {
        switch self {
        case .aac, .alac: return "m4a"
        case .opus: return "opus"
        case .pcm24: return "aiff"
        case .mp3: return "mp3"
        case .mp2: return "mp2"
        case .ac3: return "ac3"
        case .aiff, .pcm: return "aiff"
        case .wav: return "wav"
        case .flac: return "flac"
        case .passThrough, .none: return "mka"
        }
    }
}

/// Two-channel rendering of multichannel audio (mirrors `MCAudioMode`).
public enum AudioMixMode: Int, Codable, CaseIterable, Sendable {
    case stereoMix = 0, frontMix, surround, leftRight, center, surroundPair, lfe

    public var label: String {
        ["Stereo Mix", "Front Mix", "Surround (Pro Logic)", "L/R Ch.", "Center Ch.", "LS/RS Ch.", "LFE Ch."][rawValue]
    }
}

public enum FieldDominance: String, Codable, CaseIterable, Sendable {
    case automatic = "Automatic"
    case upperFirst = "Upper Field First"
    case lowerFirst = "Lower Field First"
    case progressive = "Progressive"
}

public enum CropMode: String, Codable, CaseIterable, Sendable {
    /// Crop pixels from the output; output frame shrinks.
    case destination = "Destination"
    /// Crop pixels from the source before scaling; output frame size is kept.
    case source = "Source"
    /// Crop output pixels and stretch back to the output frame size.
    case scale = "Scale"
}

public enum Rotation: Int, Codable, CaseIterable, Sendable {
    case none = 0, cw90 = 90, r180 = 180, ccw90 = 270
    public var label: String {
        switch self {
        case .none: return "No Rotation"
        case .cw90: return "90° Clockwise"
        case .r180: return "180°"
        case .ccw90: return "90° Counter-clockwise"
        }
    }
}

public enum FrameFormat: String, Codable, CaseIterable, Sendable {
    case png = "PNG", jpeg = "JPEG", tiff = "TIFF"
    public var fileExtension: String { ["PNG": "png", "JPEG": "jpg", "TIFF": "tiff"][rawValue]! }
}

public enum DVStandard: String, Codable, CaseIterable, Sendable {
    case automatic = "Automatic", pal = "PAL", ntsc = "NTSC"
}

public enum DVVariant: String, Codable, CaseIterable, Sendable {
    case dv25 = "DV (DV25)", dvcpro50 = "DVCPRO50"
}

public struct FrameSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(_ w: Int, _ h: Int) { width = w; height = h }
    public var label: String { "\(width) × \(height)" }

    public static let common: [FrameSize] = [
        FrameSize(3840, 2160), FrameSize(2560, 1440), FrameSize(1920, 1080), FrameSize(1280, 720),
        FrameSize(1024, 576), FrameSize(960, 540), FrameSize(854, 480), FrameSize(720, 576), FrameSize(720, 480),
        FrameSize(768, 576), FrameSize(640, 480), FrameSize(640, 360), FrameSize(480, 270), FrameSize(320, 240),
    ]
}

public struct Crop: Codable, Hashable, Sendable {
    public var enabled = false
    public var top = 0, bottom = 0, left = 0, right = 0
    public var mode: CropMode = .destination
    public init() {}
    public var isActive: Bool { enabled && (top != 0 || bottom != 0 || left != 0 || right != 0) }
}

public struct Adjustments: Codable, Hashable, Sendable {
    /// -100…100
    public var brightness = 0.0
    /// -100…100
    public var contrast = 0.0
    /// -100…100
    public var saturation = 0.0
    /// Gain in dB.
    public var volumeDB = 0.0
    public var automaticVolume = false
    public var watermark = ""
    public init() {}
    public var hasVideoChanges: Bool { brightness != 0 || contrast != 0 || saturation != 0 }
}

/// Every option of the exporter windows. Codable so it can be stored as a preset.
public struct ExportSettings: Codable, Hashable, Sendable {
    public var kind: ExporterKind

    // Video
    public var videoCodec: VideoCodec
    public var quality = 75.0                      // 0…100
    public var limitDataRate = false
    public var dataRateKbps = 5000.0
    public var multiPass = false
    public var bFrames = true
    public var proResProfile: ProResProfile = .standard
    public var dnxhrProfile: DNxHRProfile = .hq
    public var frameSize: FrameSize?               // nil = unscaled
    public var frameRate: Double?                  // nil = same as source
    public var frameBlending = false
    public var fieldDominance: FieldDominance = .automatic
    public var interlacedScaling = true
    public var betterDownscaling = false
    public var deinterlace = false
    public var rotation: Rotation = .none
    public var flipHorizontal = false
    public var zoomPercent = 100.0
    public var zoomAspect = 1.0                    // X/Y stretch
    public var centerX = 0                         // pixels
    public var centerY = 0
    public var crop = Crop()
    public var adjustments = Adjustments()
    public var fastStart = true
    public var hardwareDecoding = false

    // DV
    public var dvStandard: DVStandard = .automatic
    public var dvVariant: DVVariant = .dv25
    public var dvWidescreen = false

    // Audio
    public var audioFormat: AudioFormat
    public var audioChannels = 2                   // 1 or 2 (0 = keep source channels)
    public var audioSampleRate = 48000             // 0 = keep source rate
    public var audioBitrateKbps = 192
    public var audioMix: AudioMixMode = .stereoMix

    // Frame export
    public var frameFormat: FrameFormat = .png

    public init(kind: ExporterKind) {
        self.kind = kind
        videoCodec = kind.videoCodecs.first ?? .h264
        audioFormat = kind.audioFormats.first ?? .aac
        switch kind {
        case .avi: audioBitrateKbps = 160
        case .mpeg2: audioBitrateKbps = 224; quality = 85
        case .dv: audioSampleRate = 48000
        case .audio: audioFormat = .aiff
        default: break
        }
    }

    public static func defaults(for kind: ExporterKind) -> ExportSettings { ExportSettings(kind: kind) }

    /// DV and DVD outputs use fixed 720-pixel frames, broadcast frame rates and non-square pixels.
    public var broadcastGeometry: Bool { kind == .dv || kind == .mpeg2 || (videoCodec == .dv && kind != .frame) }

    public var outputExtension: String {
        switch kind {
        case .audio: return audioFormat.audioFileExtension
        case .frame: return frameFormat.fileExtension
        default: return kind.fileExtension
        }
    }
}
