import Foundation

/// A piece of a source file, in that source's own time base (seconds from its start).
public struct Segment: Codable, Hashable, Sendable {
    public var sourceID: UUID
    public var start: Double
    public var end: Double

    public init(sourceID: UUID, start: Double, end: Double) {
        self.sourceID = sourceID
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
}

/// Position in the edited timeline resolved to a segment and source time.
public struct TimelineLocation: Equatable, Sendable {
    public var segmentIndex: Int
    public var sourceID: UUID
    public var sourceTime: Double
    /// Timeline time at which this segment begins.
    public var segmentTimelineStart: Double

    public init(segmentIndex: Int, sourceID: UUID, sourceTime: Double, segmentTimelineStart: Double) {
        self.segmentIndex = segmentIndex
        self.sourceID = sourceID
        self.sourceTime = sourceTime
        self.segmentTimelineStart = segmentTimelineStart
    }
}

/// Non-destructive edit decision list.
///
/// The *timeline* is the concatenation of `segments`. Cut/copy/paste operate on
/// timeline ranges. `window` is the trimmed range shown in the player; trimming
/// never removes material, so "Revert Trimming" restores the full timeline.
public struct EditState: Codable, Equatable, Sendable {
    public var segments: [Segment]
    public var window: ClosedRange<Double>
    public var deletedAudioStreams: Set<Int>

    public init(sourceID: UUID, duration: Double) {
        segments = [Segment(sourceID: sourceID, start: 0, end: max(0, duration))]
        window = 0...max(0, duration)
        deletedAudioStreams = []
    }

    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// Timeline positions where one segment ends and the next begins.
    public var cutPoints: [Double] {
        var t = 0.0
        var points: [Double] = []
        for s in segments.dropLast() { t += s.duration; points.append(t) }
        return points
    }

    /// Start time of every segment in the timeline.
    public var segmentStarts: [Double] {
        var t = 0.0
        return segments.map { s in defer { t += s.duration }; return t }
    }

    public func locate(_ timelineTime: Double) -> TimelineLocation? {
        guard !segments.isEmpty else { return nil }
        var t = 0.0
        for (i, s) in segments.enumerated() {
            let isLast = i == segments.count - 1
            if timelineTime < t + s.duration || isLast {
                let offset = min(max(0, timelineTime - t), s.duration)
                return TimelineLocation(segmentIndex: i, sourceID: s.sourceID, sourceTime: s.start + offset, segmentTimelineStart: t)
            }
            t += s.duration
        }
        return nil
    }

    /// Timeline time for a source time inside segment `index`.
    public func timelineTime(segment index: Int, sourceTime: Double) -> Double {
        let starts = segmentStarts
        guard segments.indices.contains(index) else { return 0 }
        return starts[index] + (sourceTime - segments[index].start)
    }

    /// Segments that make up timeline range `range`.
    public func segments(in range: ClosedRange<Double>) -> [Segment] {
        var out: [Segment] = []
        var t = 0.0
        for s in segments {
            let a = t, b = t + s.duration
            t = b
            let lo = max(a, range.lowerBound), hi = min(b, range.upperBound)
            if hi - lo > 1e-6 {
                out.append(Segment(sourceID: s.sourceID, start: s.start + (lo - a), end: s.start + (hi - a)))
            }
        }
        return out
    }

    /// Removes `range` from the timeline. The trim window shrinks accordingly.
    public mutating func cut(_ range: ClosedRange<Double>) {
        let total = duration
        let lo = max(0, range.lowerBound), hi = min(total, range.upperBound)
        guard hi > lo else { return }
        let before = segments(in: 0...lo)
        let after = segments(in: hi...total)
        segments = Self.merge(before + after)
        let removed = hi - lo
        let wLo = window.lowerBound > hi ? window.lowerBound - removed : min(window.lowerBound, lo)
        var wHi = window.upperBound > hi ? window.upperBound - removed : min(window.upperBound, lo)
        wHi = max(wLo, wHi)
        window = wLo...wHi
    }

    /// Inserts `pasted` at timeline time `at`. The trim window grows to include it.
    public mutating func paste(_ pasted: [Segment], at: Double) {
        let total = duration
        let at = min(max(0, at), total)
        let added = pasted.reduce(0) { $0 + $1.duration }
        segments = Self.merge(segments(in: 0...at) + pasted + segments(in: at...total))
        let wLo = window.lowerBound > at ? window.lowerBound + added : window.lowerBound
        let wHi = window.upperBound >= at ? window.upperBound + added : window.upperBound
        window = wLo...wHi
    }

    public mutating func trim(to range: ClosedRange<Double>) {
        let lo = max(window.lowerBound, range.lowerBound), hi = min(window.upperBound, range.upperBound)
        guard hi > lo else { return }
        window = lo...hi
    }

    public mutating func revertTrimming() { window = 0...duration }

    /// Joins adjacent segments that are contiguous in the same source.
    static func merge(_ list: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for s in list where s.duration > 1e-6 {
            if var last = out.last, last.sourceID == s.sourceID, abs(last.end - s.start) < 1e-6 {
                last.end = s.end
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }
}

/// Linear undo/redo history of edit states.
public struct EditHistory: Sendable {
    public private(set) var current: EditState
    private var undoStack: [(EditState, String)] = []
    private var redoStack: [(EditState, String)] = []
    public let original: EditState

    public init(_ initial: EditState) {
        current = initial
        original = initial
    }

    public var undoName: String? { undoStack.last?.1 }
    public var redoName: String? { redoStack.last?.1 }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isModified: Bool { current != original }

    public mutating func apply(_ name: String, _ change: (inout EditState) -> Void) {
        var next = current
        change(&next)
        guard next != current else { return }
        undoStack.append((current, name))
        redoStack.removeAll()
        current = next
    }

    public mutating func undo() {
        guard let (state, name) = undoStack.popLast() else { return }
        redoStack.append((current, name))
        current = state
    }

    public mutating func redo() {
        guard let (state, name) = redoStack.popLast() else { return }
        undoStack.append((current, name))
        current = state
    }

    public mutating func revertAll() {
        let target = original
        apply("Revert All Changes") { $0 = target }
    }
}

/// GOP-level rendering helpers for lossless (stream-copy) outputs.
public enum GOPSnapping {
    /// Adjusts segments to keyframe boundaries.
    ///
    /// With `preserve == false` (the default), partial GOPs at a segment's start
    /// are discarded, so output starts on the first keyframe inside the segment.
    /// With `preserve == true`, the GOP containing the start is kept.
    public static func snap(_ segments: [Segment], preserve: Bool, index: (UUID) -> StreamIndex?) -> [Segment] {
        segments.compactMap { s in
            guard let idx = index(s.sourceID), !idx.keyframes.isEmpty else { return s }
            var out = s
            if s.start > 0.001 {
                let k = preserve ? idx.keyframe(atOrBefore: s.start) : idx.keyframe(atOrAfter: s.start)
                out.start = k ?? s.start
            }
            if out.end - out.start <= 0.001 { return nil }
            return out
        }
    }
}
