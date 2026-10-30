import Foundation

/// Concrete ffmpeg invocations for one job.
public struct FFmpegPlan: Sendable {
    /// Argument lists (without the ffmpeg executable). Run in order; multi-pass encodes use several.
    public var commands: [[String]]
    public var outputs: [URL]
    /// Material duration, used to turn `out_time` progress into a fraction.
    public var duration: Double
    /// Scratch files to delete when the job finishes.
    public var temporaryFiles: [URL]
}

public enum CommandBuilder {
    static let commonPrefix = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
    static let protocols = "file,concat,subfile,crypto,data,http,https,tcp,tls,ftp,pipe"

    public static func plan(for job: JobSpec, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> FFmpegPlan {
        let req = job.request
        guard !req.segments.isEmpty, req.duration > 0 else { throw MediaError.failed("There is nothing to process: the selection is empty.") }
        switch job.kind {
        case .convert(let target):
            return try convert(target, req, output: job.output, tmp: temporaryDirectory)
        case .saveAs(let format):
            return try saveAs(format, req, output: job.output, tmp: temporaryDirectory)
        case .export(let settings):
            if settings.kind == .frame { return try exportFrame(settings, req, output: job.output) }
            return try export(settings, req, output: job.output, tmp: temporaryDirectory)
        case .checkStream:
            var args = commonPrefix
            args[args.firstIndex(of: "error")!] = "warning"
            let src = req.primary!
            args += ["-fflags", "+genpts", "-i", src.inputSpec]
            if let v = req.videoStream { args += ["-map", "0:\(v)"] }
            for a in req.audioStreams { args += ["-map", "0:\(a)"] }
            args += ["-f", "null", "-"]
            return FFmpegPlan(commands: [args], outputs: [], duration: src.info.duration, temporaryFiles: [])
        case .download:
            throw MediaError.unsupported("Downloads are handled by the downloader, not ffmpeg.")
        }
    }

    // MARK: - Inputs

    struct InputSet {
        var args: [String] = []
        var count = 0
        var temporaryFiles: [URL] = []
    }

    static func inputFlags(_ req: RenderRequest) -> [String] {
        req.fixDataBreaks ? ["-fflags", "+genpts+discardcorrupt+igndts", "-err_detect", "ignore_err"] : ["-fflags", "+genpts"]
    }

    /// Stream-copy input: a single trimmed input, or an ffconcat list with in/out points.
    /// Returns an input set with the main input at index 0 and, if present, companion audio at index 1.
    static func copyInputs(_ req: RenderRequest, tmp: URL) throws -> InputSet {
        var set = InputSet()
        let primary = req.primary!
        if req.segments.count == 1, let src = req.source(req.segments[0].sourceID) {
            let s = req.segments[0]
            set.args += inputFlags(req) + trimArgs(s, duration: src.info.duration) + ["-i", src.inputSpec]
            set.count = 1
            if let companion = src.companionAudio {
                set.args += trimArgs(s, duration: src.info.duration) + ["-i", companion.path]
                set.count = 2
            }
            return set
        }
        let list = try writeConcatList(req, companion: false, tmp: tmp)
        set.temporaryFiles.append(list)
        set.args += inputFlags(req) + ["-f", "concat", "-safe", "0", "-protocol_whitelist", protocols, "-i", list.path]
        set.count = 1
        if primary.companionAudio != nil {
            let alist = try writeConcatList(req, companion: true, tmp: tmp)
            set.temporaryFiles.append(alist)
            set.args += ["-f", "concat", "-safe", "0", "-protocol_whitelist", protocols, "-i", alist.path]
            set.count = 2
        }
        return set
    }

    static func trimArgs(_ s: Segment, duration: Double) -> [String] {
        var a: [String] = []
        if s.start > 0.0005 { a += ["-ss", Timecode.ffmpeg(s.start)] }
        if duration <= 0 || s.end < duration - 0.0005 { a += ["-t", Timecode.ffmpeg(s.duration)] }
        return a
    }

    static func writeConcatList(_ req: RenderRequest, companion: Bool, tmp: URL) throws -> URL {
        var text = "ffconcat version 1.0\n"
        for s in req.segments {
            guard let src = req.source(s.sourceID) else { continue }
            let spec = companion ? (src.companionAudio?.path ?? src.inputSpec) : src.inputSpec
            text += "file '\(spec.replacingOccurrences(of: "'", with: "'\\''"))'\n"
            if s.start > 0.0005 { text += "inpoint \(Timecode.ffmpeg(s.start))\n" }
            if src.info.duration <= 0 || s.end < src.info.duration - 0.0005 { text += "outpoint \(Timecode.ffmpeg(s.end))\n" }
        }
        let url = tmp.appendingPathComponent("concat-\(UUID().uuidString).ffconcat")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Lossless conversion

    static func convert(_ target: ConvertTarget, _ req: RenderRequest, output: URL, tmp: URL) throws -> FFmpegPlan {
        let src = req.primary!
        let video = req.videoStream.flatMap { v in src.info.streams.first { $0.index == v } }
        let audios = req.audioStreams.compactMap { a in src.info.streams.first { $0.index == a } }
        let companionAudio = src.companionInfo?.audioStreams.first
        let firstAudio = companionAudio ?? audios.first

        if target.requiresMPEGVideo {
            guard let v = video, v.codec == "mpeg2video" || v.codec == "mpeg1video" else {
                throw MediaError.unsupported("\(target.title) requires MPEG-1 or MPEG-2 video. Use Export or a lossless remux to MP4/MKV/MOV instead.")
            }
        }
        if [.demuxAC3, .demuxM2VAC3].contains(target), firstAudio?.codec != "ac3" {
            throw MediaError.unsupported("\(target.title) requires an AC3 audio track.")
        }
        if [.demuxAIFF, .demuxM1A, .demuxAC3, .demuxM2VAIFF, .demuxM2VM1A, .demuxM2VAC3].contains(target), firstAudio == nil {
            throw MediaError.unsupported("The stream has no audio track to demux.")
        }

        let inputs = try copyInputs(req, tmp: tmp)
        var args = commonPrefix + inputs.args
        var outputs: [URL] = []
        let audioMaps: [String] = companionAudio != nil && inputs.count > 1 ? ["1:a:0"] : audios.map { "0:\($0.index)" }
        let mp2 = ["-c:a", "mp2", "-b:a", "\(req.mp2BitrateKbps)k"] + (req.resampleTo48k ? ["-ar", "48000"] : [])
        let videoMap = video.map { ["-map", "0:\($0.index)"] } ?? []
        let base = output.deletingPathExtension()
        let isMPEG1 = video?.codec == "mpeg1video"
        let m2vURL = base.appendingPathExtension(isMPEG1 ? "m1v" : "m2v")
        let esFormat = isMPEG1 ? "mpeg1video" : "mpeg2video"

        func audioOut(_ kind: String, _ url: URL) {
            guard let map = audioMaps.first, let a = firstAudio else { return }
            args += ["-map", map]
            switch kind {
            case "aiff":
                args += audioFilterArgs(mix: req.audioMix, source: a, outputChannels: 2, extra: [])
                args += ["-c:a", "pcm_s16be", "-ac", "2"] + (req.resampleTo48k ? ["-ar", "48000"] : []) + ["-f", "aiff"]
            case "m1a":
                if a.codec == "mp2" || a.codec == "mp1" { args += ["-c:a", "copy"] }
                else { args += audioFilterArgs(mix: req.audioMix, source: a, outputChannels: 2, extra: []) + mp2 + ["-ac", "2"] }
                args += ["-f", "mp2"]
            default:
                args += ["-c:a", "copy", "-f", "ac3"]
            }
            args.append(url.path)
            outputs.append(url)
        }

        switch target {
        case .mpeg, .mpegMP2:
            args += videoMap + audioMaps.flatMap { ["-map", $0] } + ["-c:v", "copy"]
            args += target == .mpegMP2 ? mp2 : ["-c:a", "copy"]
            args += ["-f", "dvd", "-muxrate", "10080000", "-avoid_negative_ts", "make_zero", output.path]
            outputs.append(output)
        case .ts, .tsMP2:
            args += videoMap + audioMaps.flatMap { ["-map", $0] } + ["-c:v", "copy"]
            args += target == .tsMP2 ? mp2 : ["-c:a", "copy"]
            args += ["-f", "mpegts", "-avoid_negative_ts", "make_zero", output.path]
            outputs.append(output)
        case .mp4, .mov, .mkv:
            args += videoMap + audioMaps.flatMap { ["-map", $0] } + ["-c", "copy", "-avoid_negative_ts", "make_zero"]
            if target == .mp4 { args += ["-movflags", "+faststart"] }
            if target == .mp4 || target == .mov, video?.codec == "hevc" { args += ["-tag:v", "hvc1"] }
            args.append(output.path)
            outputs.append(output)
        case .demuxM2V:
            args += videoMap + ["-c:v", "copy", "-f", esFormat, m2vURL.path]
            outputs.append(m2vURL)
        case .demuxM2VAIFF, .demuxM2VM1A, .demuxM2VAC3:
            args += videoMap + ["-c:v", "copy", "-f", esFormat, m2vURL.path]
            outputs.append(m2vURL)
            let ext = target == .demuxM2VAIFF ? "aiff" : target == .demuxM2VM1A ? "m1a" : "ac3"
            audioOut(ext, base.appendingPathExtension(ext))
        case .demuxAIFF:
            audioOut("aiff", base.appendingPathExtension("aiff"))
        case .demuxM1A:
            audioOut("m1a", base.appendingPathExtension("m1a"))
        case .demuxAC3:
            audioOut("ac3", base.appendingPathExtension("ac3"))
        }
        return FFmpegPlan(commands: [args], outputs: outputs, duration: req.duration, temporaryFiles: inputs.temporaryFiles)
    }

    static func saveAs(_ format: SaveAsFormat, _ req: RenderRequest, output: URL, tmp: URL) throws -> FFmpegPlan {
        let src = req.primary!
        let inputs = try copyInputs(req, tmp: tmp)
        var args = commonPrefix + inputs.args
        let streams = src.info.streams.filter { ($0.kind == .video && !$0.isAttachedPicture) || $0.kind == .audio }
        // Every video track, and the audio tracks that were not deleted.
        for s in streams where s.kind == .video || req.audioStreams.contains(s.index) {
            args += ["-map", "0:\(s.index)"]
        }
        if inputs.count > 1 { args += ["-map", "1:a:0"] }
        args += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
        let ext = format.fileExtension(source: src)
        switch ext {
        case "mp4", "m4v": args += ["-movflags", "+faststart"]
        case "mpg", "mpeg", "vob", "m2p": args += ["-f", "dvd"]
        case "ts", "m2t", "mts", "m2ts", "trp", "tp": args += ["-f", "mpegts"]
        default: break
        }
        if ["mp4", "m4v", "mov"].contains(ext), src.info.videoStreams.first?.codec == "hevc" { args += ["-tag:v", "hvc1"] }
        args.append(output.path)
        return FFmpegPlan(commands: [args], outputs: [output], duration: req.duration, temporaryFiles: inputs.temporaryFiles)
    }

    // MARK: - Re-encoding export

    /// Output geometry computed from source stream and settings.
    public struct Geometry: Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// Output sample (pixel) aspect ratio.
        public var sampleAspect: Double
        public var interlaced: Bool
    }

    static func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }

    /// Default frame size proposed for an exporter given the source.
    public static func defaultFrameSize(for settings: ExportSettings, source: StreamInfo) -> FrameSize? {
        if settings.broadcastGeometry { return FrameSize(720, isPAL(settings, source) ? 576 : 480) }
        switch settings.kind {
        case .frame:
            return nil
        default:
            // Square-pixel size with the source's display aspect.
            let h = source.height
            let w = even(Double(h) * source.displayAspect)
            return FrameSize(w, h)
        }
    }

    static func isPAL(_ s: ExportSettings, _ v: StreamInfo) -> Bool {
        switch s.dvStandard {
        case .pal: return true
        case .ntsc: return false
        case .automatic:
            let r = (s.frameRate ?? v.frameRate)
            return abs(r - 25) < 0.5 || abs(r - 50) < 0.5 || abs(r - 24) < 0.5 || v.height == 576 || v.height == 288
        }
    }

    /// Builds the video filter chain. `sourceLabel` and `outputLabel` are filtergraph pad names.
    public static func videoFilterChain(_ s: ExportSettings, source v: StreamInfo, watermarkInput: Int?, sourceLabel: String, outputLabel: String) -> (graph: String, geometry: Geometry) {
        var f: [String] = []
        var w = Double(v.width), h = Double(v.height)
        var dar = v.displayAspect
        var interlaced = v.fieldOrder.isInterlaced
        var fieldOrder = v.fieldOrder

        if s.deinterlace && interlaced {
            f.append("bwdif=mode=send_frame:parity=auto:deint=all")
            interlaced = false
        }
        if s.crop.isActive && s.crop.mode == .source {
            let c = s.crop
            let nw = w - Double(c.left + c.right), nh = h - Double(c.top + c.bottom)
            f.append(cropOrPad(width: w, height: h, top: c.top, bottom: c.bottom, left: c.left, right: c.right))
            dar *= (nw / w) / (nh / h)
            w = nw; h = nh
        }
        switch s.rotation {
        case .cw90: f.append("transpose=clock"); swap(&w, &h); dar = 1 / dar; interlaced = false
        case .ccw90: f.append("transpose=cclock"); swap(&w, &h); dar = 1 / dar; interlaced = false
        case .r180: f.append("hflip,vflip")
        case .none: break
        }
        if s.flipHorizontal { f.append("hflip") }

        // Target frame and its display aspect.
        let target: FrameSize
        let targetDAR: Double
        var sampleAspect = 1.0
        if s.broadcastGeometry {
            target = s.frameSize ?? defaultFrameSize(for: s, source: v)!
            let wide = s.kind == .dv ? s.dvWidescreen : dar > 1.55
            targetDAR = wide ? 16.0 / 9.0 : 4.0 / 3.0
            sampleAspect = targetDAR / (Double(target.width) / Double(target.height))
        } else if let size = s.frameSize {
            target = size
            targetDAR = Double(size.width) / Double(size.height)
        } else {
            target = FrameSize(Int(w), Int(h))
            targetDAR = dar
            sampleAspect = dar / (w / h)
        }
        let W = Double(target.width), H = Double(target.height)

        // Fit the picture's display aspect (times the X/Y stretch) inside the target, then zoom.
        let contentDAR = dar * s.zoomAspect
        var dispW: Double, dispH: Double
        if contentDAR >= targetDAR { dispW = 1; dispH = targetDAR / contentDAR } else { dispH = 1; dispW = contentDAR / targetDAR }
        let zoom = s.zoomPercent / 100
        let pw = even(dispW * zoom * W), ph = even(dispH * zoom * H)

        let flags = s.betterDownscaling ? "spline+accurate_rnd+full_chroma_int" : "lanczos+accurate_rnd"
        if pw != Int(w) || ph != Int(h) {
            if interlaced && s.interlacedScaling && H <= 288 && h > 288 {
                // Too short for interlacing: keep one field.
                f.append("field=top")
                h /= 2
                interlaced = false
            }
            let interl = interlaced && s.interlacedScaling ? ":interl=1" : ""
            f.append("scale=\(pw):\(ph):flags=\(flags)\(interl)")
            if interlaced && !s.interlacedScaling && ph != Int(h) { interlaced = false }
        }
        let tw = Int(W), th = Int(H)
        if pw != tw || ph != th || s.centerX != 0 || s.centerY != 0 {
            let padW = max(pw, tw), padH = max(ph, th)
            if padW != pw || padH != ph {
                f.append("pad=\(padW):\(padH):\((padW - pw) / 2):\((padH - ph) / 2):black")
            }
            let x = min(max(0, (padW - tw) / 2 - s.centerX), padW - tw)
            let y = min(max(0, (padH - th) / 2 - s.centerY), padH - th)
            if padW != tw || padH != th || x != 0 || y != 0 {
                // Re-centre by cropping a larger canvas; pad first so offsets never go out of range.
                if x != (padW - tw) / 2 || y != (padH - th) / 2 || padW != tw || padH != th {
                    let canvasW = padW + 2 * abs(s.centerX), canvasH = padH + 2 * abs(s.centerY)
                    if canvasW != padW || canvasH != padH {
                        f.append("pad=\(canvasW):\(canvasH):\(abs(s.centerX)):\(abs(s.centerY)):black")
                    }
                    let cx = (canvasW - tw) / 2 - s.centerX, cy = (canvasH - th) / 2 - s.centerY
                    f.append("crop=\(tw):\(th):\(cx):\(cy)")
                }
            }
        }
        var outW = tw, outH = th
        if s.crop.isActive && s.crop.mode != .source {
            let c = s.crop
            f.append(cropOrPad(width: Double(tw), height: Double(th), top: c.top, bottom: c.bottom, left: c.left, right: c.right))
            if s.crop.mode == .scale || s.broadcastGeometry {
                f.append("scale=\(tw):\(th):flags=\(flags)")
            } else {
                outW = tw - c.left - c.right
                outH = th - c.top - c.bottom
            }
        }

        if let rate = s.frameRate, rate > 0 {
            f.append(s.frameBlending ? "framerate=fps=\(rate)" : "fps=\(rate)")
        } else if s.frameBlending && v.variableFrameRate && v.frameRate > 0 {
            f.append("framerate=fps=\(v.frameRate)")
        }

        if interlaced {
            let wanted: FieldOrder
            switch s.fieldDominance {
            case .upperFirst: wanted = .topFirst
            case .lowerFirst: wanted = .bottomFirst
            case .progressive: wanted = .progressive
            case .automatic: wanted = (s.kind == .dv || s.videoCodec == .dv) ? .bottomFirst : .topFirst
            }
            if wanted == .progressive {
                f.append("bwdif=mode=send_frame:parity=auto:deint=all")
                interlaced = false
            } else {
                if fieldOrder != wanted && fieldOrder.isInterlaced { f.append(wanted == .topFirst ? "fieldorder=tff" : "fieldorder=bff") }
                f.append(wanted == .topFirst ? "setfield=tff" : "setfield=bff")
                fieldOrder = wanted
            }
        }

        let a = s.adjustments
        if a.hasVideoChanges {
            let b = a.brightness / 100 * 0.3
            let c = 1 + a.contrast / 100
            let sat = 1 + a.saturation / 100
            f.append(String(format: "eq=brightness=%.3f:contrast=%.3f:saturation=%.3f", b, c, sat))
        }
        f.append(String(format: "setsar=%.6f", sampleAspect))
        f.append("format=\(pixelFormat(for: s))")

        var graph = "[\(sourceLabel)]" + f.joined(separator: ",")
        if let wm = watermarkInput {
            let margin = max(8, outH / 30)
            graph += "[pre];[pre][\(wm):v]overlay=x=main_w-overlay_w-\(margin):y=main_h-overlay_h-\(margin):eof_action=repeat,format=\(pixelFormat(for: s))"
        }
        graph += "[\(outputLabel)]"
        return (graph, Geometry(width: outW, height: outH, sampleAspect: sampleAspect, interlaced: interlaced))
    }

    static func cropOrPad(width: Double, height: Double, top: Int, bottom: Int, left: Int, right: Int) -> String {
        // Negative values add a black border.
        var parts: [String] = []
        let ct = max(0, top), cb = max(0, bottom), cl = max(0, left), cr = max(0, right)
        let cw = Int(width) - cl - cr, ch = Int(height) - ct - cb
        if ct + cb + cl + cr > 0 { parts.append("crop=\(max(2, cw)):\(max(2, ch)):\(cl):\(ct)") }
        let pt = max(0, -top), pb = max(0, -bottom), pl = max(0, -left), pr = max(0, -right)
        if pt + pb + pl + pr > 0 { parts.append("pad=iw+\(pl + pr):ih+\(pt + pb):\(pl):\(pt):black") }
        return parts.isEmpty ? "null" : parts.joined(separator: ",")
    }

    static func pixelFormat(for s: ExportSettings) -> String {
        switch s.videoCodec {
        case .proRes, .proResHardware: return s.proResProfile == .p4444 ? "yuva444p10le" : "yuv422p10le"
        case .mjpeg: return "yuvj422p"
        case .png: return "rgb24"
        case .animation: return "rgb24"
        case .uncompressed: return "bgr24"
        case .dnxhr: return s.dnxhrProfile.pixelFormat
        case .cineform: return "yuv422p10le"
        case .hap, .hapQ: return "rgb0"
        case .hapAlpha: return "rgba"
        case .v210: return "yuv422p10le"
        case .ffv1: return "yuv422p10le"
        case .utVideo: return "yuv422p"
        case .av1: return "yuv420p10le"
        case .vp9: return "yuv420p"
        case .dv:
            if s.dvVariant == .dvcpro50 { return "yuv422p" }
            return "yuv420p" // NTSC DV25 is switched to 4:1:1 in videoEncoderArgs
        default: return "yuv420p"
        }
    }

    /// Quality slider (0…100) to encoder-specific settings.
    static func videoEncoderArgs(_ s: ExportSettings, geometry: Geometry, pass: Int?, passLog: String, pal: Bool) -> [String] {
        let q = min(100, max(0, s.quality))
        var rate = s.limitDataRate && s.videoCodec.supportsDataRate ? Int(s.dataRateKbps) : nil
        // Two-pass x264/x265/MPEG-4 need a target bit rate; derive one from quality and frame size.
        if pass != nil && rate == nil && s.videoCodec != .vp9 {
            let bitsPerPixel = 0.04 + q / 100 * 0.16
            let factor: Double = s.videoCodec == .hevc ? 0.6 : s.videoCodec == .mpeg4Part2 || s.videoCodec == .mpeg2 ? 1.6 : 1
            rate = max(300, Int(Double(geometry.width * geometry.height) * 25 * bitsPerPixel * factor / 1000))
        }
        var a: [String] = []
        switch s.videoCodec {
        case .h264:
            a += ["-c:v", "libx264", "-preset", "medium"]
            if let r = rate { a += ["-b:v", "\(r)k", "-maxrate", "\(r * 3 / 2)k", "-bufsize", "\(r * 2)k"] }
            else { a += ["-crf", String(format: "%.1f", 40 - q * 0.26)] }
            if !s.bFrames { a += ["-bf", "0"] }
            if geometry.interlaced { a += ["-flags", "+ildct+ilme", "-x264-params", "tff=\(s.fieldDominance == .lowerFirst ? 0 : 1)"] }
            if let p = pass { a += ["-pass", "\(p)", "-passlogfile", passLog] }
        case .hevc:
            a += ["-c:v", "libx265", "-preset", "medium", "-tag:v", "hvc1"]
            var params: [String] = []
            if let r = rate { a += ["-b:v", "\(r)k"] } else { a += ["-crf", String(format: "%.1f", 42 - q * 0.24)] }
            if !s.bFrames { params.append("bframes=0") }
            if let p = pass { params += ["pass=\(p)", "stats=\(passLog).x265"] }
            params.append("log-level=error")
            a += ["-x265-params", params.joined(separator: ":")]
        case .h264Hardware, .hevcHardware:
            a += ["-c:v", s.videoCodec == .h264Hardware ? "h264_videotoolbox" : "hevc_videotoolbox"]
            if s.videoCodec == .hevcHardware { a += ["-tag:v", "hvc1"] }
            if let r = rate { a += ["-b:v", "\(r)k"] } else { a += ["-q:v", "\(Int(max(1, q)))"] }
            if !s.bFrames { a += ["-bf", "0"] }
        case .proRes:
            a += ["-c:v", "prores_ks", "-profile:v", "\(s.proResProfile.rawValue)", "-vendor", "apl0"]
            if geometry.interlaced { a += ["-flags", "+ildct"] }
        case .proResHardware:
            let names = ["proxy", "lt", "standard", "hq", "4444"]
            a += ["-c:v", "prores_videotoolbox", "-profile:v", names[s.proResProfile.rawValue]]
        case .mjpeg:
            a += ["-c:v", "mjpeg", "-q:v", "\(Int(2 + (100 - q) / 100 * 29))"]
        case .mpeg4Part2:
            a += ["-c:v", "mpeg4", "-mbd", "rd", "-trellis", "2"] + (s.kind == .avi ? ["-vtag", "XVID"] : [])
            if let r = rate { a += ["-b:v", "\(r)k"] } else { a += ["-q:v", "\(Int(2 + (100 - q) / 100 * 29))"] }
            a += ["-bf", s.bFrames ? "2" : "0"]
            if let p = pass { a += ["-pass", "\(p)", "-passlogfile", passLog] }
        case .mpeg2:
            let kbps = rate ?? Int(2500 + q / 100 * 6500)
            a += ["-c:v", "mpeg2video", "-b:v", "\(kbps)k", "-maxrate", "9000k", "-bufsize", "1835k", "-g", pal ? "15" : "18"]
            a += ["-bf", s.bFrames ? "2" : "0"]
            if geometry.interlaced { a += ["-flags", "+ildct+ilme"] }
            if let p = pass { a += ["-pass", "\(p)", "-passlogfile", passLog] }
        case .dv:
            a += ["-c:v", "dvvideo"]
            if s.dvVariant == .dv25 && !pal { a += ["-pix_fmt", "yuv411p"] }
        case .png:
            a += ["-c:v", "png"]
        case .animation:
            a += ["-c:v", "qtrle"]
        case .uncompressed:
            a += ["-c:v", "rawvideo"]
        case .dnxhr:
            a += ["-c:v", "dnxhd", "-profile:v", s.dnxhrProfile.rawValue]
        case .cineform:
            // Quality 0…100 maps to CineForm's quality levels 0 (film3+) … 12 (low).
            a += ["-c:v", "cfhd", "-quality", "\(Int(12 - q / 100 * 12))"]
        case .hap:
            a += ["-c:v", "hap", "-format", "hap", "-compressor", "snappy"]
        case .hapAlpha:
            a += ["-c:v", "hap", "-format", "hap_alpha", "-compressor", "snappy"]
        case .hapQ:
            a += ["-c:v", "hap", "-format", "hap_q", "-compressor", "snappy"]
        case .v210:
            a += ["-c:v", "v210"]
        case .ffv1:
            a += ["-c:v", "ffv1", "-level", "3", "-g", "1", "-slicecrc", "1", "-slices", "16"]
        case .utVideo:
            a += ["-c:v", "utvideo"]
        case .av1:
            a += ["-c:v", "libsvtav1", "-preset", "6"]
            if let r = rate { a += ["-b:v", "\(r)k"] } else { a += ["-crf", "\(Int(55 - q * 0.35))"] }
        case .vp9:
            a += ["-c:v", "libvpx-vp9", "-row-mt", "1", "-deadline", "good", "-cpu-used", "2"]
            if let r = rate { a += ["-b:v", "\(r)k"] } else { a += ["-crf", "\(Int(50 - q * 0.32))", "-b:v", "0"] }
            if let p = pass { a += ["-pass", "\(p)", "-passlogfile", passLog] }
        }
        return a
    }

    /// Audio filter arguments (`-af …`) for mixing, volume and resampling.
    static func audioFilterArgs(mix: AudioMixMode, source: StreamInfo, outputChannels: Int, extra: [String]) -> [String] {
        var f: [String] = []
        if source.channels > 2 && outputChannels > 0 && outputChannels <= 2 {
            let (sl, sr) = source.surroundPairNames
            switch mix {
            case .stereoMix: break // ffmpeg's standard downmix via -ac
            case .frontMix: f.append("pan=stereo|FL=0.586*FL+0.414*FC|FR=0.586*FR+0.414*FC")
            case .surround: f.append("aresample=matrix_encoding=dplii")
            case .leftRight: f.append("pan=stereo|FL=FL|FR=FR")
            case .center: f.append("pan=stereo|FL=FC|FR=FC")
            case .surroundPair: f.append("pan=stereo|FL=\(sl)|FR=\(sr)")
            case .lfe: f.append("pan=stereo|FL=LFE|FR=LFE")
            }
        } else if source.channels == 2 && mix == .center {
            f.append("pan=stereo|FL=0.5*FL+0.5*FR|FR=0.5*FL+0.5*FR")
        }
        f += extra
        return f.isEmpty ? [] : ["-af", f.joined(separator: ",")]
    }

    static func audioEncoderArgs(_ s: ExportSettings, container: String) -> [String] {
        var a: [String] = []
        switch s.audioFormat {
        case .passThrough: return ["-c:a", "copy"]
        case .none: return ["-an"]
        case .aac: a += ["-c:a", "aac_at", "-b:a", "\(s.audioBitrateKbps)k"]
        case .pcm: a += ["-c:a", container == "aiff" ? "pcm_s16be" : "pcm_s16le"]
        case .pcm24: a += ["-c:a", container == "aiff" ? "pcm_s24be" : "pcm_s24le"]
        case .opus: a += ["-c:a", "libopus", "-b:a", "\(s.audioBitrateKbps)k"]
        case .aiff: a += ["-c:a", "pcm_s16be"]
        case .wav: a += ["-c:a", "pcm_s16le"]
        case .alac: a += ["-c:a", "alac"]
        case .mp3: a += ["-c:a", "libmp3lame", "-b:a", "\(s.audioBitrateKbps)k"]
        case .mp2: a += ["-c:a", "mp2", "-b:a", "\(s.audioBitrateKbps)k"]
        case .ac3: a += ["-c:a", "ac3", "-b:a", "\(s.audioBitrateKbps)k"]
        case .flac: a += ["-c:a", "flac"]
        }
        if s.audioChannels > 0 { a += ["-ac", "\(s.audioChannels)"] }
        if s.audioSampleRate > 0 { a += ["-ar", "\(s.audioSampleRate)"] }
        return a
    }

    static func export(_ s: ExportSettings, _ req: RenderRequest, output: URL, tmp: URL) throws -> FFmpegPlan {
        let src = req.primary!
        let videoInfo = req.videoStream.flatMap { v in src.info.streams.first { $0.index == v } }
        let audioIndex = req.audioStreams.first
        let usesCompanion = src.companionAudio != nil
        let audioInfo = usesCompanion ? src.companionInfo?.audioStreams.first : audioIndex.flatMap { a in src.info.streams.first { $0.index == a } }
        let wantsVideo = s.kind != .audio
        if wantsVideo && videoInfo == nil { throw MediaError.unsupported("The stream has no video track to export.") }
        let wantsAudio = audioInfo != nil && s.audioFormat != .none
        if s.kind == .audio && !wantsAudio { throw MediaError.unsupported("The stream has no audio track to export.") }

        // One trimmed input per segment (accurate seeking), plus companion audio inputs.
        var inputArgs: [String] = []
        var videoPads: [String] = [], audioPads: [String] = []
        var inputIndex = 0
        for seg in req.segments {
            guard let ss = req.source(seg.sourceID) else { continue }
            inputArgs += inputFlags(req) + trimArgs(seg, duration: ss.info.duration) + ["-i", ss.inputSpec]
            let main = inputIndex
            inputIndex += 1
            if wantsVideo, let v = req.videoStream { videoPads.append("\(main):\(v)") }
            if wantsAudio {
                if let companion = ss.companionAudio {
                    inputArgs += trimArgs(seg, duration: ss.info.duration) + ["-i", companion.path]
                    audioPads.append("\(inputIndex):a:0")
                    inputIndex += 1
                } else if let a = audioIndex {
                    audioPads.append("\(main):\(a)")
                }
            }
        }
        var watermarkInput: Int?
        if let wm = req.watermarkImage, wantsVideo {
            inputArgs += ["-i", wm.path]
            watermarkInput = inputIndex
            inputIndex += 1
        }

        var graph: [String] = []
        var vLabel = videoPads.first, aLabel = audioPads.first
        let n = req.segments.count
        if n > 1 {
            var concatIn = ""
            for i in 0..<n {
                if wantsVideo { concatIn += "[\(videoPads[i])]" }
                if wantsAudio { concatIn += "[\(audioPads[i])]" }
            }
            var outs = ""
            if wantsVideo { outs += "[vcat]"; vLabel = "vcat" }
            if wantsAudio { outs += "[acat]"; aLabel = "acat" }
            graph.append("\(concatIn)concat=n=\(n):v=\(wantsVideo ? 1 : 0):a=\(wantsAudio ? 1 : 0)\(outs)")
        }

        var geometry = Geometry(width: 0, height: 0, sampleAspect: 1, interlaced: false)
        var pal = true
        if wantsVideo, let v = videoInfo, let label = vLabel {
            var settings = s
            if s.broadcastGeometry && (settings.frameSize == nil || s.videoCodec == .dv) { settings.frameSize = defaultFrameSize(for: s, source: v) }
            pal = isPAL(settings, v)
            if s.broadcastGeometry { settings.frameRate = pal ? 25 : 30000.0 / 1001.0 }
            let chain = videoFilterChain(settings, source: v, watermarkInput: watermarkInput, sourceLabel: label, outputLabel: "vout")
            graph.append(chain.graph)
            geometry = chain.geometry
        }
        var audioFilter: [String] = []
        if wantsAudio, let a = audioInfo, let label = aLabel, s.audioFormat != .passThrough {
            let channels = s.kind == .dv ? 2 : s.audioChannels
            var f: [String] = []
            let mixArgs = audioFilterArgs(mix: s.audioMix, source: a, outputChannels: channels == 0 ? a.channels : channels, extra: [])
            if mixArgs.count == 2 { f.append(mixArgs[1]) }
            if s.adjustments.volumeDB != 0 { f.append(String(format: "volume=%.2fdB", s.adjustments.volumeDB)) }
            if s.adjustments.automaticVolume { f.append("dynaudnorm") }
            graph.append("[\(label)]" + (f.isEmpty ? "anull" : f.joined(separator: ",")) + "[aout]")
            audioFilter = ["-map", "[aout]"]
        } else if wantsAudio, let label = aLabel {
            // Pass-through: copy the stream directly (single segment), or the concatenated audio.
            audioFilter = n > 1 ? ["-map", "[\(label)]"] : ["-map", label]
        }

        var outArgs: [String] = []
        if wantsVideo { outArgs += ["-map", "[vout]"] }
        outArgs += audioFilter
        let container: String
        switch s.kind {
        case .quickTime: container = "mov"
        case .mpeg4: container = "mp4"
        case .avi: container = "avi"
        case .dv: container = "dv"
        case .mpeg2: container = "dvd"
        case .matroska: container = output.pathExtension.lowercased() == "webm" ? "webm" : "matroska"
        case .audio:
            switch s.audioFormat {
            case .aiff, .pcm, .pcm24: container = "aiff"
            case .opus: container = "opus"
            case .wav: container = "wav"
            case .aac, .alac: container = "ipod"
            case .mp3: container = "mp3"
            case .mp2: container = "mp2"
            case .ac3: container = "ac3"
            case .flac: container = "flac"
            default: container = "matroska"
            }
        case .frame: container = "image2"
        }
        var audioArgs: [String] = []
        if wantsAudio {
            var a = s
            if s.kind == .dv { a.audioFormat = .pcm; a.audioSampleRate = 48000; a.audioChannels = 2 }
            if s.audioFormat == .passThrough && n > 1 { a.audioFormat = .pcm }
            audioArgs = audioEncoderArgs(a, container: container)
        } else if wantsVideo {
            audioArgs = ["-an"]
        }
        var tail: [String] = []
        if s.broadcastGeometry {
            let shownAspect = geometry.height > 0 ? Double(geometry.width) / Double(geometry.height) * geometry.sampleAspect : 4.0 / 3.0
            tail += ["-r", pal ? "25" : "30000/1001", "-aspect", shownAspect > 1.5 ? "16:9" : "4:3"]
        }
        if s.kind == .mpeg2 { tail += ["-muxrate", "10080000"] }
        if (s.kind == .quickTime || s.kind == .mpeg4) && s.fastStart { tail += ["-movflags", "+faststart"] }
        if s.kind == .audio && container == "ipod" { tail += ["-movflags", "+faststart"] }
        tail += ["-max_muxing_queue_size", "4096", "-f", container, output.path]

        let filterArgs = graph.isEmpty ? [] : ["-filter_complex", graph.joined(separator: ";")]
        var commands: [[String]] = []
        var temps: [URL] = []
        let passLog = tmp.appendingPathComponent("pass-\(UUID().uuidString)").path
        if wantsVideo && s.multiPass && s.videoCodec.supportsMultiPass {
            let first = commonPrefix + inputArgs + filterArgs + ["-map", "[vout]"]
                + videoEncoderArgs(s, geometry: geometry, pass: 1, passLog: passLog, pal: pal)
                + (audioFilter.isEmpty ? ["-an"] : audioFilter + ["-c:a", "pcm_s16le"]) + ["-f", "null", "-"]
            let second = commonPrefix + inputArgs + filterArgs + outArgs
                + videoEncoderArgs(s, geometry: geometry, pass: 2, passLog: passLog, pal: pal) + audioArgs + tail
            commands = [first, second]
            for suffix in ["-0.log", "-0.log.mbtree", ".x265", ".x265.cutree", "-0.log.temp"] {
                temps.append(URL(fileURLWithPath: passLog + suffix))
            }
        } else {
            let video = wantsVideo ? videoEncoderArgs(s, geometry: geometry, pass: nil, passLog: passLog, pal: pal) : ["-vn"]
            commands = [commonPrefix + inputArgs + filterArgs + outArgs + video + audioArgs + tail]
        }
        return FFmpegPlan(commands: commands, outputs: [output], duration: req.duration, temporaryFiles: temps)
    }

    static func exportFrame(_ s: ExportSettings, _ req: RenderRequest, output: URL) throws -> FFmpegPlan {
        guard let src = req.primary, let v = req.videoStream, let info = src.info.streams.first(where: { $0.index == v }) else {
            throw MediaError.unsupported("The stream has no video track.")
        }
        let t = req.frameTime ?? req.segments.first?.start ?? 0
        var args = commonPrefix + ["-ss", Timecode.ffmpeg(t), "-i", src.inputSpec]
        var wmIndex: Int?
        if let wm = req.watermarkImage { args += ["-i", wm.path]; wmIndex = 1 }
        var settings = s
        settings.videoCodec = .png // rgb24 output
        let chain = videoFilterChain(settings, source: info, watermarkInput: wmIndex, sourceLabel: "0:\(v)", outputLabel: "vout")
        args += ["-filter_complex", chain.graph, "-map", "[vout]", "-frames:v", "1", "-update", "1"]
        switch s.frameFormat {
        case .jpeg: args += ["-c:v", "mjpeg", "-q:v", "2", "-pix_fmt", "yuvj444p"]
        case .png: args += ["-c:v", "png"]
        case .tiff: args += ["-c:v", "tiff"]
        }
        args.append(output.path)
        return FFmpegPlan(commands: [args], outputs: [output], duration: 1, temporaryFiles: [])
    }
}
