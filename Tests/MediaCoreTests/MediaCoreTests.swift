import XCTest
@testable import MediaCore
import CMedia

final class TimecodeTests: XCTestCase {
    func testFormatAndParse() {
        XCTAssertEqual(Timecode.format(3723.5), "1:02:03.50")
        XCTAssertEqual(Timecode.parse("1:02:03.5"), 3723.5)
        XCTAssertEqual(Timecode.parse("10203"), 3723)
        XCTAssertEqual(Timecode.parse("45"), 45)
        XCTAssertEqual(Timecode.parse("2:30"), 150)
        XCTAssertNil(Timecode.parse("abc"))
    }

    func testGoTo() {
        XCTAssertEqual(Timecode.parseGoTo("1:00-2:00"), .selection(60, 120))
        XCTAssertEqual(Timecode.parseGoTo("1:00-"), .setIn(60))
        XCTAssertEqual(Timecode.parseGoTo("-2:00"), .setOut(120))
        XCTAssertEqual(Timecode.parseGoTo("30"), .time(30))
    }
}

final class EditModelTests: XCTestCase {
    let a = UUID(), b = UUID()

    func testCutPasteTrim() {
        var e = EditState(sourceID: a, duration: 100)
        e.cut(20...30)
        XCTAssertEqual(e.duration, 90, accuracy: 1e-9)
        XCTAssertEqual(e.segments.count, 2)
        XCTAssertEqual(e.segments[1].start, 30)
        XCTAssertEqual(e.locate(25)?.sourceTime ?? -1, 35, accuracy: 1e-9)

        // Paste material from another source at 10 s.
        e.paste([Segment(sourceID: b, start: 0, end: 5)], at: 10)
        XCTAssertEqual(e.duration, 95, accuracy: 1e-9)
        XCTAssertEqual(e.segments.map(\.sourceID), [a, b, a, a])

        e.trim(to: 5...50)
        XCTAssertEqual(e.window, 5...50)
        e.cut(10...20)
        XCTAssertEqual(e.window.upperBound, 40, accuracy: 1e-9)
        e.revertTrimming()
        XCTAssertEqual(e.window.upperBound, e.duration, accuracy: 1e-9)
    }

    func testCutThenUndoRestoresMergedSegments() {
        var h = EditHistory(EditState(sourceID: a, duration: 60))
        h.apply("Cut") { $0.cut(10...20) }
        h.apply("Paste") { $0.paste([Segment(sourceID: a, start: 10, end: 20)], at: 10) }
        XCTAssertEqual(h.current.segments.count, 1, "contiguous pieces merge back together")
        h.undo(); h.undo()
        XCTAssertEqual(h.current, h.original)
        h.redo()
        XCTAssertEqual(h.current.duration, 50, accuracy: 1e-9)
    }

    func testGOPSnapping() {
        let idx = StreamIndex(keyframes: [0, 0.48, 0.96, 1.44, 1.92])
        let seg = [Segment(sourceID: a, start: 0.7, end: 1.9)]
        XCTAssertEqual(GOPSnapping.snap(seg, preserve: false) { _ in idx }.first?.start, 0.96)
        XCTAssertEqual(GOPSnapping.snap(seg, preserve: true) { _ in idx }.first?.start, 0.48)
    }
}

/// Runs real ffmpeg jobs against generated media in TestMedia/.
final class IntegrationTests: XCTestCase {
    static let media = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestMedia")
    var out: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(FFmpegLocator.find() == nil, "ffmpeg not installed")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.media.appendingPathComponent("sample_pal_ac3.mpg").path), "run scripts/make_test_media.sh")
        out = FileManager.default.temporaryDirectory.appendingPathComponent("mctests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() { if let out { try? FileManager.default.removeItem(at: out) } }

    func source(_ name: String) throws -> SourceMedia { try SourceMedia.open([Self.media.appendingPathComponent(name)]) }

    func run(_ spec: JobSpec, file: StaticString = #filePath, line: UInt = #line) -> [MediaInfo] {
        guard let plan = try? CommandBuilder.plan(for: spec, temporaryDirectory: out) else { XCTFail("plan failed", file: file, line: line); return [] }
        let proc = FFmpegProcess(plan: plan, executable: FFmpegLocator.find()!)
        let outcome = proc.run()
        if case .failed(let m) = outcome {
            XCTFail("\(spec.title) failed: \(m)\n\(plan.commands.map { $0.joined(separator: " ") }.joined(separator: "\n"))", file: file, line: line)
            return []
        }
        return plan.outputs.compactMap { try? MediaProbe.probe($0.path) }
    }

    func request(_ src: SourceMedia, _ segs: [Segment]? = nil, allAudio: Bool = true) -> RenderRequest {
        RenderRequest(sources: [src], segments: segs ?? [Segment(sourceID: src.id, start: 0, end: src.info.duration)],
                      videoStream: src.info.videoStreams.first?.index,
                      audioStreams: allAudio ? src.info.audioStreams.map(\.index) : Array(src.info.audioStreams.prefix(1).map(\.index)))
    }

    func testProbeAndIndex() throws {
        let src = try source("sample_pal_ac3.mpg")
        let v = try XCTUnwrap(src.info.videoStreams.first)
        XCTAssertEqual(v.codec, "mpeg2video")
        XCTAssertEqual(v.fieldOrder, .topFirst)
        XCTAssertEqual(v.displayAspect, 16.0 / 9.0, accuracy: 0.01)
        XCTAssertEqual(src.info.audioStreams.first?.channels, 6)
        XCTAssertTrue(src.info.isMPEGFamily)
        let idx = try StreamIndex.build(input: src.inputSpec, streamIndex: v.index)
        XCTAssertGreaterThan(idx.keyframes.count, 30) // GOP 12 at 25 fps over 20 s
        XCTAssertEqual(idx.keyframes[1] - idx.keyframes[0], 0.48, accuracy: 0.05)
    }

    func testSequenceDetectionAndJoin() throws {
        let seq = SequenceDetector.sequence(for: Self.media.appendingPathComponent("VTS_01_2.VOB"))
        XCTAssertEqual(seq.map(\.lastPathComponent), ["VTS_01_1.VOB", "VTS_01_2.VOB"])
        let src = try SourceMedia.open(seq)
        XCTAssertEqual(src.info.duration, 20, accuracy: 1.0)
        let dvd = DVDScanner.titles(at: Self.media)
        XCTAssertEqual(dvd.first?.files.count, 2)
    }

    func testAllLosslessConversions() throws {
        let src = try source("sample_pal_ac3.mpg")
        for target in ConvertTarget.allCases {
            let spec = JobSpec(kind: .convert(target), request: request(src, allAudio: !target.isDemux),
                               output: out.appendingPathComponent("conv-\(target.hashValue).\(target.primaryExtension)"))
            let infos = run(spec)
            XCTAssertFalse(infos.isEmpty, "\(target) produced no output")
            for info in infos {
                // Raw elementary video carries no duration; check it has a stream instead.
                if info.formatName.contains("video") { XCTAssertEqual(info.videoStreams.count, 1, "\(target)") }
                else { XCTAssertGreaterThan(info.duration, 18, "\(target) output too short") }
            }
        }
    }

    func testEditedLosslessJoinsSegments() throws {
        let src = try source("sample_pal_ac3.mpg")
        var e = EditState(sourceID: src.id, duration: src.info.duration)
        e.cut(4.8...9.6)
        let req = request(src, e.segments)
        let infos = run(JobSpec(kind: .convert(.ts), request: req, output: out.appendingPathComponent("edited.ts")))
        XCTAssertEqual(infos.first?.duration ?? 0, 15.2, accuracy: 0.7)
    }

    func testH264RejectedForMPEGOnlyTargets() throws {
        let src = try source("sample_h264.ts")
        XCTAssertThrowsError(try CommandBuilder.plan(for: JobSpec(kind: .convert(.demuxM2V), request: request(src), output: out.appendingPathComponent("x.m2v"))))
        let infos = run(JobSpec(kind: .convert(.mp4), request: request(src), output: out.appendingPathComponent("remux.mp4")))
        XCTAssertEqual(infos.first?.videoStreams.first?.codec, "h264")
    }

    func testExportersAndCodecs() throws {
        let src = try source("sample_pal_ac3.mpg")
        let seg = [Segment(sourceID: src.id, start: 2, end: 4)]
        let available = EncoderAvailability.available()
        for kind in [ExporterKind.quickTime, .mpeg4, .avi, .matroska, .dv, .mpeg2] {
            for codec in kind.videoCodecs where available.contains(codec.encoderName) {
                var s = ExportSettings(kind: kind)
                s.videoCodec = codec
                s.frameSize = kind == .dv || kind == .mpeg2 ? nil : FrameSize(640, 360)
                if codec == .dnxhr { s.frameSize = FrameSize(1280, 720) }
                if codec == .hap || codec == .hapAlpha || codec == .hapQ { s.frameSize = FrameSize(640, 360) }
                s.audioFormat = kind.audioFormats.first { $0 != .passThrough } ?? .none
                let url = out.appendingPathComponent("exp-\(kind.fileExtension)-\(codec.encoderName)-\(codec.hashValue).\(s.outputExtension)")
                let infos = run(JobSpec(kind: .export(s), request: request(src, seg, allAudio: false), output: url))
                guard let info = infos.first, let v = info.videoStreams.first else { XCTFail("\(kind) \(codec): no output"); continue }
                XCTAssertEqual(info.duration, 2, accuracy: 0.3, "\(kind) \(codec)")
                if kind == .dv || kind == .mpeg2 || codec == .dv { XCTAssertEqual(v.width, 720) } else { XCTAssertEqual(v.width, codec == .dnxhr ? 1280 : 640, "\(kind) \(codec)") }
                if s.audioFormat != .none { XCTAssertEqual(info.audioStreams.count, 1, "\(kind) \(codec) audio") }
            }
        }
    }

    func testFilterOptionsAndMultiSegmentExport() throws {
        let src = try source("sample_pal_ac3.mpg")
        var s = ExportSettings(kind: .mpeg4)
        s.frameSize = FrameSize(1280, 720)
        s.deinterlace = true
        s.rotation = .r180
        s.flipHorizontal = true
        s.zoomPercent = 120
        s.centerX = 20
        s.crop.enabled = true; s.crop.left = 8; s.crop.right = 8; s.crop.mode = .scale
        s.adjustments.brightness = 10; s.adjustments.saturation = -20; s.adjustments.volumeDB = 3; s.adjustments.automaticVolume = true
        s.frameRate = 30; s.frameBlending = true
        s.audioMix = .frontMix
        s.multiPass = true
        var req = request(src, [Segment(sourceID: src.id, start: 1, end: 2.5), Segment(sourceID: src.id, start: 10, end: 11)], allAudio: false)
        req.watermarkImage = try WatermarkRenderer.render("Sample", frameHeight: 720, directory: out)
        let infos = run(JobSpec(kind: .export(s), request: req, output: out.appendingPathComponent("complex.mp4")))
        let info = try XCTUnwrap(infos.first)
        XCTAssertEqual(info.duration, 2.5, accuracy: 0.2)
        XCTAssertEqual(info.videoStreams.first?.width, 1280)
        XCTAssertEqual(info.videoStreams.first?.frameRate ?? 0, 30, accuracy: 0.1)
        XCTAssertEqual(info.audioStreams.first?.channels, 2)
    }

    func testDownmixModesAndAudioExport() throws {
        let src = try source("sample_pal_ac3.mpg")
        let seg = [Segment(sourceID: src.id, start: 0, end: 3)]
        for mode in AudioMixMode.allCases {
            var s = ExportSettings(kind: .audio)
            s.audioFormat = .aiff
            s.audioMix = mode
            let infos = run(JobSpec(kind: .export(s), request: request(src, seg, allAudio: false), output: out.appendingPathComponent("mix-\(mode.rawValue).aiff")))
            XCTAssertEqual(infos.first?.audioStreams.first?.channels, 2, "\(mode)")
        }
        // 5.1 kept as surround in Opus.
        var surround = ExportSettings(kind: .audio)
        surround.audioFormat = .opus
        surround.audioChannels = 0
        let sInfo = run(JobSpec(kind: .export(surround), request: request(src, seg, allAudio: false), output: out.appendingPathComponent("surround.opus")))
        XCTAssertEqual(sInfo.first?.audioStreams.first?.channels, 6)
        for f in [AudioFormat.aac, .mp3, .flac, .wav, .alac, .opus, .ac3, .mp2] {
            var s = ExportSettings(kind: .audio)
            s.audioFormat = f
            let infos = run(JobSpec(kind: .export(s), request: request(src, seg, allAudio: false), output: out.appendingPathComponent("audio.\(s.outputExtension)")))
            XCTAssertEqual(infos.first?.duration ?? 0, 3, accuracy: 0.2, "\(f)")
        }
    }

    func testExportJoinsClipsInDifferentFormats() throws {
        // MPEG-2 720x576 25 fps with 5.1 AC3, then H.264 1080p 29.97 fps with stereo AAC, then a clip with no sound.
        let a = try source("sample_pal_ac3.mpg"), b = try source("sample_h264.ts"), c = try source("sample_silent.mp4")
        var req = RenderRequest(sources: [a, b, c], segments: [Segment(sourceID: a.id, start: 1, end: 3), Segment(sourceID: b.id, start: 2, end: 4),
                                                            Segment(sourceID: c.id, start: 0, end: 1.5)],
                                videoStream: a.info.videoStreams.first?.index, audioStreams: [a.info.audioStreams.first!.index])
        req.selections[b.id] = StreamSelection(video: b.info.videoStreams.first?.index, audio: [b.info.audioStreams.first!.index])
        req.selections[c.id] = StreamSelection(video: c.info.videoStreams.first?.index, audio: [])
        var s = ExportSettings(kind: .mpeg4)
        s.frameSize = FrameSize(1024, 576)
        let infos = run(JobSpec(kind: .export(s), request: req, output: out.appendingPathComponent("joined.mp4")))
        let info = try XCTUnwrap(infos.first)
        XCTAssertEqual(info.duration, 5.5, accuracy: 0.3)
        XCTAssertEqual(info.videoStreams.first?.width, 1024)
        XCTAssertEqual(info.audioStreams.count, 1)
    }

    func testFrameExportAndSaveAs() throws {
        let src = try source("sample_pal_ac3.mpg")
        var s = ExportSettings(kind: .frame)
        s.frameFormat = .png
        var req = request(src, [Segment(sourceID: src.id, start: 5, end: 6)], allAudio: false)
        req.frameTime = 5
        let infos = run(JobSpec(kind: .export(s), request: req, output: out.appendingPathComponent("frame.png")))
        XCTAssertEqual(infos.first?.videoStreams.first?.width, 720)
        for f in SaveAsFormat.allCases where f != .avi {
            let url = out.appendingPathComponent("saveas-\(f.hashValue).\(f.fileExtension(source: src))")
            let r = run(JobSpec(kind: .saveAs(f), request: request(src), output: url))
            XCTAssertEqual(r.first?.duration ?? 0, 20, accuracy: 1, "\(f)")
        }
    }

    func testDecoderProducesFramesAndDownmixedAudio() throws {
        let src = try source("sample_pal_ac3.mpg")
        var err = [CChar](repeating: 0, count: 256)
        let dec = try XCTUnwrap(mc_open(src.inputSpec, &err, 256))
        defer { mc_close(dec) }
        mc_set_audio_mode(dec, MC_AUDIO_SURROUND)
        var video = 0, audio = 0
        var f = MCFrame()
        for _ in 0..<200 {
            guard mc_decode_next(dec, &f) == 1 else { break }
            if f.type == MC_FRAME_VIDEO { video += 1; XCTAssertEqual(f.width, 720) } else { audio += 1; XCTAssertEqual(f.sample_rate, 48000) }
        }
        XCTAssertEqual(mc_seek(dec, 10), 0)
        XCTAssertEqual(mc_decode_next(dec, &f), 1)
        XCTAssertEqual(f.pts, 10, accuracy: 1.0)
        XCTAssertGreaterThan(video, 10)
        XCTAssertGreaterThan(audio, 10)
    }
}
