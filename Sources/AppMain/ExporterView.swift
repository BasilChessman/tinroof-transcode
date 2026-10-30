import AppKit
import SwiftUI
import MediaCore

@MainActor
final class ExporterModel: ObservableObject {
    let kind: ExporterKind
    weak var player: PlayerWindowController?
    let presets: PresetStore
    /// When set, "Make" adds one batch task per source instead of exporting the player's selection.
    var batchSources: [SourceMedia]?
    var batchFolder: URL?
    var close: (() -> Void)?

    @Published var settings: ExportSettings { didSet { if oldValue.kind == settings.kind { Self.lastSettings[kind] = settings } } }
    @Published var preview: NSImage?
    @Published var previewBusy = false
    @Published var presetList: [Preset] = []
    @Published var selectedPreset: UUID?
    @Published var customWidth = ""
    @Published var customHeight = ""
    let available = EncoderAvailability.available()

    private static var lastSettings: [ExporterKind: ExportSettings] = [:]

    init(kind: ExporterKind, player: PlayerWindowController?, presets: PresetStore) {
        self.kind = kind
        self.player = player
        self.presets = presets
        var s = Self.lastSettings[kind] ?? ExportSettings.defaults(for: kind)
        if Self.lastSettings[kind] == nil, let v = player?.doc.videoInfo {
            s.frameSize = kind == .frame ? nil : CommandBuilder.defaultFrameSize(for: s, source: v)
            if !v.fieldOrder.isInterlaced { s.interlacedScaling = false }
        }
        if !EncoderAvailability.available().contains(s.videoCodec.encoderName),
           let first = kind.videoCodecs.first(where: { EncoderAvailability.isAvailable($0) }) {
            s.videoCodec = first
        }
        settings = s
        reloadPresets()
    }

    var source: StreamInfo? { player?.doc.videoInfo ?? batchSources?.first?.info.videoStreams.first }
    var audioSource: StreamInfo? { player?.doc.audioInfo ?? batchSources?.first?.info.audioStreams.first }

    func isAvailable(_ c: VideoCodec) -> Bool { available.contains(c.encoderName) }

    func reloadPresets() { presetList = presets.presets(for: kind) }

    var frameSizeOptions: [FrameSize] {
        switch kind {
        case .dv: return [FrameSize(720, 576), FrameSize(720, 480)]
        case .mpeg2: return [FrameSize(720, 576), FrameSize(720, 480), FrameSize(704, 576), FrameSize(704, 480), FrameSize(352, 576), FrameSize(352, 480)]
        default:
            var list = FrameSize.common
            if let v = source, let d = CommandBuilder.defaultFrameSize(for: settings, source: v), !list.contains(d) { list.insert(d, at: 0) }
            return list
        }
    }

    var estimatedSize: String? {
        guard let p = player else { return nil }
        let dur = p.doc.selection.upperBound - p.doc.selection.lowerBound
        var kbps = 0.0
        if settings.limitDataRate && settings.videoCodec.supportsDataRate { kbps += settings.dataRateKbps } else if kind != .audio { return nil }
        if settings.audioFormat.hasBitrate { kbps += Double(settings.audioBitrateKbps) }
        else if settings.audioFormat == .pcm || settings.audioFormat == .aiff || settings.audioFormat == .wav { kbps += 1536 }
        let bytes = kbps * 1000 / 8 * dur
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func applyCustomSize() {
        if let w = Int(customWidth), let h = Int(customHeight), (32...8192).contains(w), (32...8192).contains(h) {
            settings.frameSize = FrameSize(w & ~1, h & ~1)
        }
    }

    func resetAll() {
        var s = ExportSettings.defaults(for: kind)
        if let v = source, kind != .frame { s.frameSize = CommandBuilder.defaultFrameSize(for: s, source: v) }
        settings = s
    }

    // MARK: Presets

    func newPreset() {
        guard let name = Self.ask("New Preset", "Name for the current settings:", "Preset \(presetList.count + 1)") else { return }
        let p = Preset(name: name, settings: settings)
        presets.add(p); reloadPresets(); selectedPreset = p.id
    }
    func loadPreset() { if let p = presetList.first(where: { $0.id == selectedPreset }) { settings = p.settings } }
    func savePreset() {
        guard var p = presetList.first(where: { $0.id == selectedPreset }) else { return }
        p.settings = settings; presets.update(p); reloadPresets()
    }
    func renamePreset() {
        guard var p = presetList.first(where: { $0.id == selectedPreset }), let name = Self.ask("Rename Preset", "New name:", p.name) else { return }
        p.name = name; presets.update(p); reloadPresets()
    }
    func deletePreset() {
        guard let id = selectedPreset else { return }
        presets.delete(id); reloadPresets(); selectedPreset = nil
    }
    func movePreset(_ d: Int) { if let id = selectedPreset { presets.move(id, by: d); reloadPresets() } }

    static func ask(_ title: String, _ text: String, _ value: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let f = NSTextField(string: value)
        f.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let s = f.stringValue.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    // MARK: Rendering

    private func watermark(height: Int) -> URL? {
        let text = settings.adjustments.watermark.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return try? WatermarkRenderer.render(text, frameHeight: height)
    }

    private func outputHeight() -> Int {
        settings.frameSize?.height ?? source?.height ?? 480
    }

    /// Renders the current frame through the complete filter chain.
    func makePreview() {
        guard let p = player, let loc = p.doc.edit.locate(p.doc.position) else { return }
        var req = p.doc.renderRequest(lossless: false, allAudio: false)
        req.segments = [Segment(sourceID: loc.sourceID, start: loc.sourceTime, end: loc.sourceTime + 1)]
        req.sources = Array(p.doc.sources.values)
        req.frameTime = loc.sourceTime
        req.watermarkImage = watermark(height: outputHeight())
        var s = settings
        s.frameFormat = .png
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).png")
        let spec = JobSpec(kind: .export(s), request: req, output: out)
        previewBusy = true
        Task.detached {
            var image: NSImage?
            var failure: String?
            if let ffmpeg = FFmpegLocator.find(), let plan = try? Self.framePlan(spec) {
                let proc = FFmpegProcess(plan: plan, executable: ffmpeg)
                if case .failed(let m) = proc.run() { failure = m }
                image = NSImage(contentsOf: out)
                try? FileManager.default.removeItem(at: out)
            } else {
                failure = "ffmpeg is not available."
            }
            if let wm = req.watermarkImage { try? FileManager.default.removeItem(at: wm) }
            await MainActor.run {
                self.preview = image
                self.previewBusy = false
                if let failure { AppDelegate.shared.log("Preview failed: \(failure)") }
            }
        }
    }

    nonisolated static func framePlan(_ spec: JobSpec) throws -> FFmpegPlan {
        guard case .export(let s) = spec.kind else { throw MediaError.failed("") }
        var f = s
        if f.frameSize == nil, let v = spec.request.primary?.info.streams.first(where: { $0.index == spec.request.videoStream }) {
            f.frameSize = CommandBuilder.defaultFrameSize(for: s, source: v)
        }
        f.kind = .frame
        var fs = spec
        fs.kind = .export(f)
        return try CommandBuilder.plan(for: fs)
    }

    func make() {
        if let sources = batchSources, let folder = batchFolder {
            for src in sources {
                let video = src.info.videoStreams.first?.index
                let audio = src.info.audioStreams.first.map { [$0.index] } ?? []
                var req = RenderRequest(sources: [src], segments: [Segment(sourceID: src.id, start: 0, end: src.info.duration)], videoStream: video, audioStreams: audio)
                req.applyPreferences()
                req.watermarkImage = watermark(height: settings.frameSize?.height ?? src.info.videoStreams.first?.height ?? 480)
                let out = folder.appendingPathComponent(src.baseName).appendingPathExtension(settings.outputExtension)
                AppDelegate.shared.batch.add(JobSpec(kind: .export(settings), request: req, output: out))
            }
            BatchAddFlow.rememberExportSettings(settings)
            close?()
            return
        }
        guard let p = player else { return }
        var req = p.doc.renderRequest(lossless: false, allAudio: false)
        if kind == .frame, let loc = p.doc.edit.locate(p.doc.position) {
            req.frameTime = loc.sourceTime
            req.segments = [Segment(sourceID: loc.sourceID, start: loc.sourceTime, end: loc.sourceTime + 1)]
        }
        req.watermarkImage = watermark(height: outputHeight())
        let suffix = kind == .frame ? " " + Timecode.format(p.doc.position).replacingOccurrences(of: ":", with: "-") : ""
        AppDelegate.shared.chooseOutputAndSubmit(kind: .export(settings), request: req, suggestedName: p.doc.primary.baseName + suffix,
                                                 ext: settings.outputExtension, from: nil)
        if kind != .frame { close?() }
    }
}

struct ExporterView: View {
    @ObservedObject var model: ExporterModel

    private var s: Binding<ExportSettings> { $model.settings }
    private var kind: ExporterKind { model.kind }
    private var hasVideo: Bool { kind != .audio }
    private var hasAudio: Bool { kind != .frame && model.audioSource != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                if hasVideo && kind != .frame { compressionSection }
                if hasVideo { pictureSection }
                if hasAudio { soundSection }
                if hasVideo { adjustmentsSection }
                if kind != .frame && model.batchSources == nil { presetsSection }
            }
            .formStyle(.grouped)
            .frame(minWidth: 430)
            if hasVideo {
                VStack(spacing: 8) {
                    ZStack {
                        Rectangle().fill(Color.black)
                        if let img = model.preview { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) }
                        if model.previewBusy { ProgressView() }
                        if model.preview == nil && !model.previewBusy {
                            Text("Click Preview to render the current frame with these settings").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                        }
                    }
                    .frame(minWidth: 260, minHeight: 180)
                    Button("Preview") { model.makePreview() }.disabled(model.player == nil || model.previewBusy)
                    if let est = model.estimatedSize { Text("Estimated size: \(est)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
                .padding()
                .frame(minWidth: 280)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Reset All") { model.resetAll() }
                Spacer()
                Button("Cancel") { model.close?() }.keyboardShortcut(.cancelAction)
                Button(makeTitle) { model.make() }.keyboardShortcut(.defaultAction)
                    .disabled(hasVideo && kind != .frame && !model.isAvailable(model.settings.videoCodec))
            }
            .padding(12)
            .background(.bar)
        }
    }

    private var makeTitle: String {
        if model.batchSources != nil { return "Add to Batch" }
        switch kind {
        case .quickTime: return "Make Movie"
        case .mpeg4: return "Make MP4"
        case .avi: return "Make AVI"
        case .dv: return "Make DV Stream"
        case .mpeg2: return "Make MPEG-2"
        case .matroska: return "Make MKV"
        case .audio: return "Make Audio File"
        case .frame: return "Export Frame…"
        }
    }

    @ViewBuilder private var compressionSection: some View {
        Section("Compression") {
            Picker("Codec", selection: s.videoCodec) {
                ForEach(kind.videoCodecs, id: \.self) { c in
                    Text(model.isAvailable(c) ? c.rawValue : "\(c.rawValue) — not in this ffmpeg").tag(c)
                }
            }
            if !model.isAvailable(model.settings.videoCodec) {
                Text("The installed ffmpeg has no “\(model.settings.videoCodec.encoderName)” encoder. See README for building ffmpeg with Hap (libsnappy) support.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.settings.videoCodec == .proRes || model.settings.videoCodec == .proResHardware {
                Picker("Profile", selection: s.proResProfile) { ForEach(ProResProfile.allCases, id: \.self) { Text($0.label).tag($0) } }
            }
            if model.settings.videoCodec == .dnxhr {
                Picker("Profile", selection: s.dnxhrProfile) { ForEach(DNxHRProfile.allCases, id: \.self) { Text($0.label).tag($0) } }
            }
            if kind == .dv {
                Picker("Format", selection: s.dvVariant) { ForEach(DVVariant.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Standard", selection: s.dvStandard) { ForEach(DVStandard.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Toggle("16:9 widescreen", isOn: s.dvWidescreen)
            }
            if kind == .mpeg2 {
                Picker("Standard", selection: s.dvStandard) { ForEach(DVStandard.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            }
            if model.settings.videoCodec.supportsQuality && !(model.settings.limitDataRate && model.settings.videoCodec.supportsDataRate) {
                HStack {
                    Text("Quality")
                    Slider(value: s.quality, in: 0...100, step: 1)
                    Text("\(Int(model.settings.quality))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            if model.settings.videoCodec.supportsDataRate {
                HStack {
                    Toggle("Limit data rate", isOn: s.limitDataRate)
                    TextField("", value: s.dataRateKbps, format: .number).frame(width: 80).disabled(!model.settings.limitDataRate)
                    Text("Kbps")
                }
            }
            if model.settings.videoCodec.supportsMultiPass { Toggle("Multipass encoding", isOn: s.multiPass) }
            if model.settings.videoCodec.supportsBFrames { Toggle("B-frames", isOn: s.bFrames) }
            if kind == .quickTime || kind == .mpeg4 { Toggle("Fast start (streaming-ready)", isOn: s.fastStart) }
        }
    }

    @ViewBuilder private var pictureSection: some View {
        Section("Picture") {
            if kind == .frame {
                Picker("Format", selection: s.frameFormat) { ForEach(FrameFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            }
            Picker("Frame size", selection: s.frameSize) {
                if kind != .dv && kind != .mpeg2 { Text("Unscaled").tag(FrameSize?.none) }
                ForEach(model.frameSizeOptions, id: \.self) { Text($0.label).tag(FrameSize?.some($0)) }
                if let fs = model.settings.frameSize, !model.frameSizeOptions.contains(fs) { Text("\(fs.label) (custom)").tag(FrameSize?.some(fs)) }
            }
            if kind != .dv && kind != .mpeg2 {
                LabeledContent("Custom size") {
                    HStack {
                        TextField("", text: $model.customWidth, prompt: Text("width")).labelsHidden().frame(width: 64)
                        Text("×")
                        TextField("", text: $model.customHeight, prompt: Text("height")).labelsHidden().frame(width: 64)
                        Button("Set") { model.applyCustomSize() }
                    }
                }
            }
            if kind != .frame && kind != .dv && kind != .mpeg2 {
                LabeledContent("Frame rate") {
                    HStack {
                        TextField("", value: s.frameRate, format: .number, prompt: Text("same as source"))
                            .labelsHidden().frame(width: 120)
                        Text("fps")
                    }
                }
                Toggle("Frame blending", isOn: s.frameBlending)
            }
            if kind != .frame {
                Picker("Field dominance", selection: s.fieldDominance) { ForEach(FieldDominance.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            }
            Toggle("Interlaced scaling", isOn: s.interlacedScaling)
            Toggle("Better downscaling", isOn: s.betterDownscaling)
            Toggle("Deinterlace video (motion adaptive)", isOn: s.deinterlace)
            if let v = model.source {
                Text("Source: \(v.width)×\(v.height), \(String(format: "%.3g", v.frameRate)) fps, \(v.fieldOrder.label), DAR \(String(format: "%.3f", v.displayAspect))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Rotation", selection: s.rotation) { ForEach(Rotation.allCases, id: \.self) { Text($0.label).tag($0) } }
            Toggle("Flip horizontally", isOn: s.flipHorizontal)
            LabeledContent("Zoom") {
                HStack {
                    TextField("", value: s.zoomPercent, format: .number).labelsHidden().frame(width: 60)
                    Text("%   X/Y stretch")
                    TextField("", value: s.zoomAspect, format: .number).labelsHidden().frame(width: 60)
                }
            }
            LabeledContent("Center offset") {
                HStack {
                    Text("X")
                    TextField("", value: s.centerX, format: .number).labelsHidden().frame(width: 50)
                    Text("Y")
                    TextField("", value: s.centerY, format: .number).labelsHidden().frame(width: 50)
                    Text("pixels")
                }
            }
            Toggle("Cropping", isOn: s.crop.enabled)
            if model.settings.crop.enabled {
                HStack {
                    Text("T"); TextField("", value: s.crop.top, format: .number).frame(width: 45)
                    Text("B"); TextField("", value: s.crop.bottom, format: .number).frame(width: 45)
                    Text("L"); TextField("", value: s.crop.left, format: .number).frame(width: 45)
                    Text("R"); TextField("", value: s.crop.right, format: .number).frame(width: 45)
                }
                Picker("Crop relative to", selection: s.crop.mode) { ForEach(CropMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
            }
        }
    }

    @ViewBuilder private var soundSection: some View {
        Section("Sound") {
            Picker("Format", selection: s.audioFormat) { ForEach(kind.audioFormats, id: \.self) { Text($0.rawValue).tag($0) } }
            if model.settings.audioFormat != .none && model.settings.audioFormat != .passThrough && kind != .dv {
                Picker("Channels", selection: s.audioChannels) {
                    Text("Mono").tag(1); Text("Stereo").tag(2); Text("Same as source").tag(0)
                }
                Picker("Sample rate", selection: s.audioSampleRate) {
                    ForEach([0, 22050, 32000, 44100, 48000, 96000], id: \.self) { r in Text(r == 0 ? "Same as source" : "\(r) Hz").tag(r) }
                }
                if model.settings.audioFormat.hasBitrate {
                    Picker("Bit rate", selection: s.audioBitrateKbps) {
                        ForEach([64, 96, 128, 160, 192, 224, 256, 320, 384, 448, 640], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                }
            }
            if (model.audioSource?.channels ?? 0) > 2 {
                Picker("Surround downmix", selection: s.audioMix) { ForEach(AudioMixMode.allCases, id: \.self) { Text($0.label).tag($0) } }
            }
        }
    }

    @ViewBuilder private var adjustmentsSection: some View {
        Section("Adjustments") {
            LabeledSlider(label: "Brightness", value: s.adjustments.brightness, range: -100...100)
            LabeledSlider(label: "Contrast", value: s.adjustments.contrast, range: -100...100)
            LabeledSlider(label: "Saturation", value: s.adjustments.saturation, range: -100...100)
            if hasAudio {
                LabeledSlider(label: "Volume (dB)", value: s.adjustments.volumeDB, range: -24...24)
                Toggle("Automatic volume control", isOn: s.adjustments.automaticVolume)
            }
            TextField("Watermark", text: s.adjustments.watermark, prompt: Text("Text shown in the lower-right corner"))
        }
    }

    @ViewBuilder private var presetsSection: some View {
        Section("Presets") {
            Picker("Preset", selection: $model.selectedPreset) {
                Text("—").tag(UUID?.none)
                ForEach(model.presetList) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            HStack {
                Button("New…") { model.newPreset() }
                Button("Load") { model.loadPreset() }.disabled(model.selectedPreset == nil)
                Button("Save") { model.savePreset() }.disabled(model.selectedPreset == nil)
                Button("Rename…") { model.renamePreset() }.disabled(model.selectedPreset == nil)
                Button("Delete") { model.deletePreset() }.disabled(model.selectedPreset == nil)
                Button { model.movePreset(-1) } label: { Image(systemName: "arrow.up") }.disabled(model.selectedPreset == nil)
                Button { model.movePreset(1) } label: { Image(systemName: "arrow.down") }.disabled(model.selectedPreset == nil)
            }
        }
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: "%+.0f", value)).monospacedDigit().frame(width: 36, alignment: .trailing)
            Button { value = 0 } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless)
        }
    }
}
