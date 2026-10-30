import Foundation
import Combine
import MediaCore

/// Global cut/copy clipboard: survives closing a file, so streams can be joined by copy and paste.
@MainActor
enum EditClipboard {
    static var segments: [Segment] = []
    static var sources: [UUID: SourceMedia] = [:]
    static var isEmpty: Bool { segments.isEmpty }
}

/// Model of one open stream: sources, edit history, selection and chosen tracks.
@MainActor
final class PlayerDocument: ObservableObject {
    @Published private(set) var history: EditHistory
    @Published var sources: [UUID: SourceMedia]
    let primary: SourceMedia

    @Published var position: Double = 0
    @Published var inPoint: Double?
    @Published var outPoint: Double?
    @Published var videoStream: Int?
    @Published var audioStream: Int?
    @Published var audioMode: AudioMixMode
    @Published var fixTimecodeBreaks = false
    @Published private(set) var indexes: [UUID: StreamIndex] = [:]
    @Published var indexingProgress: Double?

    var edit: EditState { history.current }

    init(source: SourceMedia) {
        primary = source
        sources = [source.id: source]
        history = EditHistory(EditState(sourceID: source.id, duration: source.info.duration))
        videoStream = source.info.videoStreams.first?.index
        audioStream = source.info.audioStreams.first?.index
        audioMode = AudioMixMode(rawValue: Pref.d.integer(forKey: Pref.defaultAudioMode)) ?? .stereoMix
        if source.companionAudio != nil { audioStream = nil }
    }

    var title: String { primary.displayName }
    var window: ClosedRange<Double> { edit.window }

    var videoInfo: StreamInfo? { videoStream.flatMap { v in primary.info.streams.first { $0.index == v } } }
    var audioInfo: StreamInfo? {
        if primary.companionAudio != nil { return primary.companionInfo?.audioStreams.first }
        return audioStream.flatMap { a in primary.info.streams.first { $0.index == a } }
    }
    var availableAudio: [StreamInfo] { primary.info.audioStreams.filter { !edit.deletedAudioStreams.contains($0.index) } }

    var frameDuration: Double {
        let fps = videoInfo?.frameRate ?? 25
        return fps > 0 ? 1 / fps : 0.04
    }

    /// Selection between In and Out, defaulting to the trimmed window.
    var selection: ClosedRange<Double> {
        let lo = max(window.lowerBound, inPoint ?? window.lowerBound)
        let hi = min(window.upperBound, outPoint ?? window.upperBound)
        return lo <= hi ? lo...hi : hi...lo
    }
    var hasSelection: Bool { inPoint != nil || outPoint != nil }

    func clampToWindow(_ t: Double) -> Double { min(max(t, window.lowerBound), window.upperBound) }

    // MARK: Editing

    func perform(_ name: String, _ change: (inout EditState) -> Void) {
        history.apply(name, change)
        position = clampToWindow(position)
        cancelSelection()
    }

    func cancelSelection() { inPoint = nil; outPoint = nil }

    func cut() {
        let sel = selection
        EditClipboard.segments = edit.segments(in: sel)
        EditClipboard.sources = sources
        perform("Cut") { $0.cut(sel) }
        position = clampToWindow(sel.lowerBound)
    }

    func copy() {
        EditClipboard.segments = edit.segments(in: selection)
        EditClipboard.sources = sources
    }

    func paste() {
        guard !EditClipboard.isEmpty else { return }
        for (id, s) in EditClipboard.sources where sources[id] == nil { sources[id] = s }
        let at = position
        let length = EditClipboard.segments.reduce(0) { $0 + $1.duration }
        perform("Paste") { $0.paste(EditClipboard.segments, at: at) }
        inPoint = at
        outPoint = at + length
    }

    func trim() {
        let sel = selection
        perform("Trim") { $0.trim(to: sel) }
        position = clampToWindow(position)
    }

    func revertTrimming() { perform("Revert Trimming") { $0.revertTrimming() } }

    func deleteAudioTrack() {
        guard let a = audioStream else { return }
        perform("Delete Audio Track") { $0.deletedAudioStreams.insert(a) }
        audioStream = availableAudio.first?.index
    }

    func undo() { history.undo(); position = clampToWindow(position) }
    func redo() { history.redo(); position = clampToWindow(position) }
    func revertAll() { history.revertAll(); position = clampToWindow(position); cancelSelection() }

    // MARK: Keyframes

    var primaryIndex: StreamIndex? { indexes[primary.id] }

    /// Builds the keyframe index of the selected video stream in the background.
    func buildIndex() {
        guard indexes[primary.id] == nil, let v = videoStream ?? primary.info.audioStreams.first?.index, !primary.isRemote else { return }
        let spec = primary.inputSpec
        let id = primary.id
        indexingProgress = 0
        Task.detached(priority: .utility) {
            let idx = try? StreamIndex.build(input: spec, streamIndex: v) { p in
                Task { @MainActor in self.indexingProgress = p }
                return true
            }
            await MainActor.run {
                if let idx { self.indexes[id] = idx }
                self.indexingProgress = nil
            }
        }
    }

    /// Keyframe position (in timeline time) next to `t` in `direction` (+1 / -1).
    func keyframe(from t: Double, direction: Int) -> Double? {
        guard let loc = edit.locate(t), let idx = indexes[loc.sourceID] else { return nil }
        let seg = edit.segments[loc.segmentIndex]
        let k = direction > 0 ? idx.keyframe(after: loc.sourceTime) : idx.keyframe(before: loc.sourceTime)
        guard let k else { return direction > 0 ? window.upperBound : window.lowerBound }
        if k < seg.start || k >= seg.end {
            // Outside the segment: jump to the segment boundary.
            let start = loc.segmentTimelineStart
            return direction > 0 ? min(start + seg.duration, window.upperBound) : max(start, window.lowerBound)
        }
        return edit.timelineTime(segment: loc.segmentIndex, sourceTime: k)
    }

    // MARK: Render requests

    /// Material between In and Out as a render request.
    func renderRequest(lossless: Bool, allAudio: Bool) -> RenderRequest {
        var segs = edit.segments(in: selection)
        if lossless {
            let preserve = Pref.d.bool(forKey: Pref.preserveGOPs)
            let idx = indexes
            segs = GOPSnapping.snap(segs, preserve: preserve) { idx[$0] }
        }
        let audio: [Int]
        if primary.companionAudio != nil { audio = [] }
        else if allAudio { audio = availableAudio.map(\.index) }
        else { audio = audioStream.map { [$0] } ?? [] }
        var req = RenderRequest(sources: Array(sources.values), segments: segs, videoStream: videoStream, audioStreams: audio)
        req.audioMix = audioMode
        req.fixDataBreaks = fixTimecodeBreaks
        req.applyPreferences()
        return req
    }
}
