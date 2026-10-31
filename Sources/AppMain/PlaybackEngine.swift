import AppKit
import AVFoundation
import QuartzCore
import CMedia
import MediaCore

/// Thread-safe playback clock in timeline seconds, driven by the host clock.
final class PlaybackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var originTimeline = 0.0
    private var originHost = 0.0
    private var rate = 0.0

    func set(timeline: Double, host: Double, rate: Double) {
        lock.lock(); originTimeline = timeline; originHost = host; self.rate = rate; lock.unlock()
    }

    func now() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard rate != 0 else { return originTimeline }
        let elapsed = CACurrentMediaTime() - originHost
        return originTimeline + max(0, elapsed) * rate
    }

    var currentRate: Double { lock.lock(); defer { lock.unlock() }; return rate }
}

/// Monotonic counter used to abandon stale background work.
final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func isCurrent(_ v: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return v == value }
}

/// A decoder bound to one source and one stream type. Only used on its owning queue.
final class StreamDecoder {
    let handle: OpaquePointer
    let sourceID: UUID
    var lastPTS = -1.0
    var lastDuration = 0.04
    var lastImage: CGImage?
    var atEOF = false

    init?(source: SourceMedia, video: Int?, audio: Int?, outputSize: CGSize?, audioMode: AudioMixMode) {
        let input = (video == nil && source.companionAudio != nil) ? source.companionAudio!.path : source.inputSpec
        mc_set_hardware_decoding(UserDefaults.standard.bool(forKey: Pref.hardwareDecoding) ? 1 : 0)
        var err = [CChar](repeating: 0, count: 256)
        guard let h = mc_open(input, &err, Int32(err.count)) else { return nil }
        handle = h
        sourceID = source.id
        let useCompanion = video == nil && source.companionAudio != nil
        mc_select_streams(h, Int32(video ?? -1), useCompanion ? mc_selected_audio(h) : Int32(audio ?? -1))
        mc_set_decode_enabled(h, video != nil ? 1 : 0, video == nil ? 1 : 0)
        if let s = outputSize { mc_set_video_output_size(h, Int32(s.width), Int32(s.height)) }
        mc_set_audio_mode(h, MCAudioMode(UInt32(audioMode.rawValue)))
        mc_set_audio_output_rate(h, 48000)
    }

    deinit { mc_close(handle) }

    func seek(_ t: Double) {
        mc_seek(handle, max(0, t))
        lastPTS = -1
        atEOF = false
    }

    /// Next frame of the enabled type, or nil at end of stream.
    func next() -> MCFrame? {
        var f = MCFrame()
        let r = mc_decode_next(handle, &f)
        if r <= 0 { atEOF = true; return nil }
        return f
    }

    static func makeImage(_ f: MCFrame) -> CGImage? {
        guard let px = f.pixels else { return nil }
        let size = Int(f.linesize) * Int(f.height)
        let data = Data(bytes: px, count: size) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: Int(f.width), height: Int(f.height), bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Int(f.linesize), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Snapshot of what to play, taken on the main thread.
struct PlaybackSnapshot: @unchecked Sendable {
    var edit: EditState
    var sources: [UUID: SourceMedia]
    /// Video and audio stream per clip (appended clips may number their streams differently).
    var videoStreams: [UUID: Int]
    var audioStreams: [UUID: Int]
    var hasAudio: Bool { !audioStreams.isEmpty || sources.values.contains { $0.companionAudio != nil } }
    var audioMode: AudioMixMode
    var displaySize: CGSize?
}

@MainActor
final class PlaybackEngine {
    var onFrame: ((CGImage, Double) -> Void)?
    var onStop: (() -> Void)?

    private(set) var isPlaying = false
    private(set) var rate = 0.0
    let clock = PlaybackClock()

    private let generation = Generation()
    private let videoQueue = DispatchQueue(label: "player.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "player.audio", qos: .userInteractive)
    // Owned by videoQueue / audioQueue respectively.
    nonisolated(unsafe) private var videoDecoders: [UUID: StreamDecoder] = [:]
    nonisolated(unsafe) private var audioDecoders: [UUID: StreamDecoder] = [:]
    nonisolated(unsafe) private var decoderKey = ""

    private let engine = AVAudioEngine()
    nonisolated(unsafe) private let player = AVAudioPlayerNode()
    nonisolated(unsafe) private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var shuttleTimer: Timer?

    // Coalesced still-frame requests.
    private let requestLock = NSLock()
    nonisolated(unsafe) private var pendingRequest: (Double, PlaybackSnapshot, Int)?
    nonisolated(unsafe) private var requestRunning = false

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Discards cached decoders, e.g. after the selected tracks change.
    func invalidateDecoders() {
        stop()
        let g = generation.next()
        _ = g
        videoQueue.async { self.videoDecoders.removeAll() }
        audioQueue.async { self.audioDecoders.removeAll() }
    }

    // MARK: Still frames

    /// Shows the frame at timeline time `t` (coalesces rapid requests).
    func showFrame(at t: Double, _ snap: PlaybackSnapshot) {
        let g = isPlaying ? generation.next() : currentGeneration()
        requestLock.lock()
        pendingRequest = (t, snap, g)
        let start = !requestRunning
        requestRunning = true
        requestLock.unlock()
        if start { videoQueue.async { self.drainRequests() } }
    }

    private var lastGeneration = 0
    private func currentGeneration() -> Int {
        if lastGeneration == 0 { lastGeneration = generation.next() }
        return lastGeneration
    }

    nonisolated private func drainRequests() {
        while true {
            requestLock.lock()
            guard let (t, snap, _) = pendingRequest else { requestRunning = false; requestLock.unlock(); return }
            pendingRequest = nil
            requestLock.unlock()
            if let (image, time) = decodeStill(at: t, snap) {
                DispatchQueue.main.async { self.onFrame?(image, time) }
            }
        }
    }

    nonisolated private func videoDecoder(for source: SourceMedia, _ snap: PlaybackSnapshot) -> StreamDecoder? {
        let key = "\(snap.videoStreams.sorted { $0.key.uuidString < $1.key.uuidString }.map { "\($0.value)" }.joined(separator: ","))-\(Int(snap.displaySize?.width ?? 0))x\(Int(snap.displaySize?.height ?? 0))"
        if key != decoderKey { videoDecoders.removeAll(); decoderKey = key }
        if let d = videoDecoders[source.id] { return d }
        guard let v = snap.videoStreams[source.id] else { return nil }
        let d = StreamDecoder(source: source, video: v, audio: nil, outputSize: snap.displaySize, audioMode: snap.audioMode)
        videoDecoders[source.id] = d
        return d
    }

    nonisolated private func decodeStill(at t: Double, _ snap: PlaybackSnapshot) -> (CGImage, Double)? {
        guard let loc = snap.edit.locate(t), let src = snap.sources[loc.sourceID],
              let dec = videoDecoder(for: src, snap) else { return nil }
        let target = loc.sourceTime
        if let img = dec.lastImage, dec.lastPTS >= 0, target >= dec.lastPTS - 0.001, target < dec.lastPTS + dec.lastDuration - 0.001 {
            return (img, t)
        }
        if dec.lastPTS < 0 || target < dec.lastPTS || target > dec.lastPTS + 3 || dec.atEOF {
            dec.seek(target)
        }
        var best: CGImage? = dec.lastImage
        var guardCount = 0
        while let f = dec.next() {
            guardCount += 1
            dec.lastPTS = f.pts
            dec.lastDuration = max(0.001, f.duration)
            if f.pts + f.duration * 0.5 > target || guardCount > 2000 {
                best = StreamDecoder.makeImage(f)
                dec.lastImage = best
                break
            }
        }
        return best.map { ($0, t) }
    }

    // MARK: Playback

    /// Plays from `t` at `rate`. Normal speed plays sound; other rates shuttle silently.
    func play(from t: Double, rate: Double, _ snap: PlaybackSnapshot) {
        stop(notify: false)
        let g = generation.next()
        lastGeneration = g
        isPlaying = true
        self.rate = rate
        if rate == 1 {
            let startHost = CACurrentMediaTime() + 0.25
            clock.set(timeline: t, host: startHost, rate: 1)
            if snap.hasAudio {
                if !engine.isRunning { try? engine.start() }
                player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: startHost)))
                audioQueue.async { self.audioLoop(from: t, snap, generation: g) }
            }
            videoQueue.async { self.videoLoop(from: t, snap, generation: g) }
        } else {
            clock.set(timeline: t, host: CACurrentMediaTime(), rate: rate)
            shuttleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = self.clock.now()
                    let w = snap.edit.window
                    if now <= w.lowerBound || now >= w.upperBound {
                        self.clock.set(timeline: min(max(now, w.lowerBound), w.upperBound), host: CACurrentMediaTime(), rate: 0)
                        self.stop()
                        return
                    }
                    self.showFrame(at: now, snap)
                }
            }
        }
    }

    func stop(notify: Bool = true) {
        let wasPlaying = isPlaying
        let t = clock.now()
        _ = generation.next()
        lastGeneration = 0
        shuttleTimer?.invalidate()
        shuttleTimer = nil
        player.stop()
        clock.set(timeline: t, host: CACurrentMediaTime(), rate: 0)
        isPlaying = false
        rate = 0
        if wasPlaying && notify { onStop?() }
    }

    func setPosition(_ t: Double) {
        clock.set(timeline: t, host: CACurrentMediaTime(), rate: 0)
    }

    nonisolated private func videoLoop(from start: Double, _ snap: PlaybackSnapshot, generation g: Int) {
        let edit = snap.edit
        guard var loc = edit.locate(start) else { return }
        let end = edit.window.upperBound
        var segStart = loc.segmentTimelineStart
        guard var dec = snap.sources[loc.sourceID].flatMap({ videoDecoder(for: $0, snap) }) else { return }
        dec.seek(loc.sourceTime)
        var target = loc.sourceTime
        while generation.isCurrent(g) {
            let seg = edit.segments[loc.segmentIndex]
            guard let f = dec.next(), f.pts < seg.end - 0.0005 else {
                // Next segment of the edit list.
                let nextIndex = loc.segmentIndex + 1
                guard nextIndex < edit.segments.count, segStart + seg.duration < end else { break }
                segStart += seg.duration
                let ns = edit.segments[nextIndex]
                guard let src = snap.sources[ns.sourceID], let nd = videoDecoder(for: src, snap) else { break }
                dec = nd
                dec.seek(ns.start)
                target = ns.start
                loc = TimelineLocation(segmentIndex: nextIndex, sourceID: ns.sourceID, sourceTime: ns.start, segmentTimelineStart: segStart)
                continue
            }
            dec.lastPTS = f.pts
            dec.lastDuration = max(0.001, f.duration)
            if f.pts + f.duration * 0.5 < target { continue } // pre-roll after keyframe seek
            let tl = segStart + (f.pts - seg.start)
            if tl >= end { break }
            let now = clock.now()
            if tl + f.duration < now - 0.05 { continue } // late: drop
            guard let image = StreamDecoder.makeImage(f) else { continue }
            dec.lastImage = image
            while generation.isCurrent(g) {
                let wait = tl - clock.now()
                if wait <= 0.002 { break }
                Thread.sleep(forTimeInterval: min(wait, 0.02))
            }
            guard generation.isCurrent(g) else { return }
            DispatchQueue.main.async { if self.generation.isCurrent(g) { self.onFrame?(image, tl) } }
        }
        // Reached the end of the window.
        let finalTime = min(end, clock.now())
        DispatchQueue.main.async {
            guard self.generation.isCurrent(g) else { return }
            while self.clock.now() < finalTime - 0.05 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            self.clock.set(timeline: finalTime, host: CACurrentMediaTime(), rate: 0)
            self.stop()
        }
    }

    nonisolated private func audioDecoder(for source: SourceMedia, _ snap: PlaybackSnapshot) -> StreamDecoder? {
        if let d = audioDecoders[source.id] { return d }
        let d = StreamDecoder(source: source, video: nil, audio: snap.audioStreams[source.id], outputSize: nil, audioMode: snap.audioMode)
        audioDecoders[source.id] = d
        return d
    }

    nonisolated private func audioLoop(from start: Double, _ snap: PlaybackSnapshot, generation g: Int) {
        let edit = snap.edit
        guard var loc = edit.locate(start) else { return }
        let end = edit.window.upperBound
        var segStart = loc.segmentTimelineStart
        // Audio decoders are recreated per play so the downmix mode is current.
        audioDecoders.removeAll()
        guard var dec = snap.sources[loc.sourceID].flatMap({ audioDecoder(for: $0, snap) }) else { return }
        dec.seek(loc.sourceTime)
        var scheduledUntil = start // timeline time covered by scheduled audio
        var target = loc.sourceTime
        while generation.isCurrent(g) {
            let seg = edit.segments[loc.segmentIndex]
            guard let f = dec.next(), f.pts < seg.end - 0.0005 else {
                let nextIndex = loc.segmentIndex + 1
                guard nextIndex < edit.segments.count, segStart + seg.duration < end else { break }
                segStart += seg.duration
                let ns = edit.segments[nextIndex]
                guard let src = snap.sources[ns.sourceID], let nd = audioDecoder(for: src, snap) else { break }
                dec = nd
                dec.seek(ns.start)
                target = ns.start
                loc = TimelineLocation(segmentIndex: nextIndex, sourceID: ns.sourceID, sourceTime: ns.start, segmentTimelineStart: segStart)
                continue
            }
            let rateHz = Double(f.sample_rate)
            var first = 0
            var count = Int(f.nb_samples)
            // Trim samples before the target (after seeking) and after the segment end.
            if f.pts < target { first = min(count, Int(((target - f.pts) * rateHz).rounded())) }
            let segEndSample = Int(((seg.end - f.pts) * rateHz).rounded())
            if segEndSample < count { count = max(first, segEndSample) }
            let frames = count - first
            if frames <= 0 { continue }
            let tl = segStart + (f.pts + Double(first) / rateHz - seg.start)
            if tl >= end { break }
            // Fill any gap with silence so the audio stays aligned to the timeline.
            if tl > scheduledUntil + 0.02 {
                let gap = AVAudioFrameCount((tl - scheduledUntil) * rateHz)
                if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: gap) {
                    silence.frameLength = gap
                    player.scheduleBuffer(silence, completionHandler: nil)
                    scheduledUntil = tl
                }
            }
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let src = f.samples else { continue }
            buf.frameLength = AVAudioFrameCount(frames)
            let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
            for i in 0..<frames {
                l[i] = src[(first + i) * 2]
                r[i] = src[(first + i) * 2 + 1]
            }
            guard generation.isCurrent(g) else { return }
            player.scheduleBuffer(buf, completionHandler: nil)
            scheduledUntil = tl + Double(frames) / rateHz
            // Stay about a second ahead of the clock.
            while generation.isCurrent(g) && scheduledUntil - clock.now() > 1.0 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
