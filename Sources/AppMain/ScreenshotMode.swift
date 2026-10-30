import AppKit
import MediaCore
import WebKit

/// Renders the app's main windows to PNG files for documentation.
///
///   TRT_SCREENSHOTS=/path/to/dir TRT_SAMPLE=/path/to/movie.mpg "TinRoof Transcode.app/Contents/MacOS/TinRoof Transcode"
///
/// Windows render themselves (no screen-recording permission needed), then the app quits.
@MainActor
enum ScreenshotMode {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["TRT_SCREENSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(in dir: URL) {
        NSApp.appearance = NSAppearance(named: .aqua)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let sample = ProcessInfo.processInfo.environment["TRT_SAMPLE"] else {
            print("TRT_SAMPLE not set"); NSApp.terminate(nil); return
        }
        let app = AppDelegate.shared
        app.showEmptyPlayer()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            capture(window(titled: "\(AppInfo.name) \(AppInfo.version)"), to: dir.appendingPathComponent("empty-player.png"))
            app.openSource([URL(fileURLWithPath: sample)])
            // Wait for the player and its first frame.
            var player: PlayerWindowController?
            for _ in 0..<100 {
                player = app.players.first
                if player != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let p = player else { print("player did not open"); NSApp.terminate(nil); return }
            p.window?.setContentSize(NSSize(width: 960, height: 632))
            p.window?.center()
            try? await Task.sleep(for: .seconds(2))

            // Player with a selection.
            p.move(to: 6.2, extend: false)
            p.doc.inPoint = 4.0
            p.doc.outPoint = 9.0
            try? await Task.sleep(for: .seconds(1))
            capture(p.window, to: dir.appendingPathComponent("player.png"), video: p)

            // Self-check: Trim, then Undo through the real menu routing.
            p.window?.makeKeyAndOrderFront(nil)
            p.trimSelection(nil)
            // Walk the window's responder chain as AppKit does for a nil-targeted menu action.
            var responder: NSResponder? = p.window?.firstResponder
            while let r = responder, !r.responds(to: #selector(PlayerWindowController.undo(_:))) { responder = r.nextResponder }
            let undoTarget: Any? = responder
            let undoItem = NSMenuItem(title: "Undo", action: #selector(PlayerWindowController.undo(_:)), keyEquivalent: "z")
            let enabled = (undoTarget as? NSMenuItemValidation)?.validateMenuItem(undoItem) ?? false
            print("check: undo routed to \(undoTarget.map { String(describing: type(of: $0)) } ?? "nothing"), enabled=\(enabled), title=\"\(undoItem.title)\"")
            (responder as? PlayerContentView)?.undo(undoItem)
            print("check: after undo, window = \(p.doc.window), duration = \(p.doc.edit.duration)")
            p.doc.inPoint = 4.0; p.doc.outPoint = 9.0

            // Edit: cut a piece so the edit list has segments, then show the edit list.
            p.doc.inPoint = 12; p.doc.outPoint = 14
            p.cut(nil)
            p.move(to: 4.5, extend: false)
            try? await Task.sleep(for: .seconds(1))
            capture(p.window, to: dir.appendingPathComponent("player-edited.png"), video: p)
            app.showEditList(nil)
            try? await Task.sleep(for: .milliseconds(800))
            capture(window(titled: "Edit List"), to: dir.appendingPathComponent("edit-list.png"))

            // Stream info.
            p.window?.makeKeyAndOrderFront(nil)
            app.showStreamInfo(nil)
            try? await Task.sleep(for: .milliseconds(800))
            if let w = window(titled: "Stream Info") { w.setContentSize(NSSize(width: 520, height: 760)) }
            try? await Task.sleep(for: .milliseconds(400))
            capture(window(titled: "Stream Info"), to: dir.appendingPathComponent("stream-info.png"))

            // Exporter with a rendered preview.
            let model = app.showExporter(kind: .quickTime, player: p)
            model?.settings.adjustments.watermark = "TinRoof Transcode"
            try? await Task.sleep(for: .milliseconds(800))
            window(containing: "Exporter")?.setContentSize(NSSize(width: 1040, height: 760))
            model?.makePreview()
            try? await Task.sleep(for: .milliseconds(700))   // let the debounced re-render start too
            for _ in 0..<150 where model?.previewBusy == true || model?.preview == nil { try? await Task.sleep(for: .milliseconds(100)) }
            print(model?.preview == nil ? "preview: none" : "preview: rendered")
            try? await Task.sleep(for: .milliseconds(600))
            capture(window(containing: "Exporter"), to: dir.appendingPathComponent("exporter.png"))
            window(containing: "Exporter")?.close()

            // Batch list with queued tasks.
            app.showBatch(nil)
            var req = p.doc.renderRequest(lossless: true, allAudio: true)
            req.applyPreferences()
            let base = FileManager.default.temporaryDirectory
            app.batch.add(JobSpec(kind: .convert(.ts), request: req, output: base.appendingPathComponent("sample.ts")))
            app.batch.add(JobSpec(kind: .convert(.demuxM2VAC3), request: req, output: base.appendingPathComponent("sample.m2v")))
            var mp4 = ExportSettings(kind: .mpeg4)
            mp4.frameSize = FrameSize(1280, 720)
            app.batch.add(JobSpec(kind: .export(mp4), request: p.doc.renderRequest(lossless: false, allAudio: false),
                                  output: base.appendingPathComponent("sample.mp4")))
            app.batch.toggleHold([app.batch.tasks[2].id])
            try? await Task.sleep(for: .milliseconds(800))
            capture(window(titled: "Batch List"), to: dir.appendingPathComponent("batch.png"))

            // Settings.
            app.showPreferences(nil)
            try? await Task.sleep(for: .milliseconds(800))
            window(titled: "Settings")?.setContentSize(NSSize(width: 520, height: 860))
            try? await Task.sleep(for: .milliseconds(400))
            capture(window(titled: "Settings"), to: dir.appendingPathComponent("settings.png"))

            // Log after a stream check.
            p.window?.makeKeyAndOrderFront(nil)
            app.checkStream(nil)
            try? await Task.sleep(for: .seconds(3))
            app.showLog(nil)
            try? await Task.sleep(for: .milliseconds(800))
            capture(window(titled: "Log"), to: dir.appendingPathComponent("log.png"))

            // Self-check: append a clip in a different format by the same path as a drop.
            p.window?.makeKeyAndOrderFront(nil)
            let before = p.doc.edit.duration
            p.appendClips([URL(fileURLWithPath: sample).deletingLastPathComponent().appendingPathComponent("sample_h264.ts")])
            for _ in 0..<80 where p.doc.edit.duration == before { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(1.5))
            print("check: append \(before) -> \(p.doc.edit.duration) s, segments \(p.doc.edit.segments.count), mixed formats \(p.doc.hasMixedSources), undo title \(p.doc.history.undoName ?? "-")")
            capture(p.window, to: dir.appendingPathComponent("player-appended.png"), video: p)

            // Drop dialog: capture it, then cancel.
            let h264 = URL(fileURLWithPath: sample).deletingLastPathComponent().appendingPathComponent("sample_h264.ts")
            p.handleDrop([h264])
            try? await Task.sleep(for: .milliseconds(900))
            if let sheet = p.window?.attachedSheet {
                capture(sheet, to: dir.appendingPathComponent("drop-dialog.png"), titleBar: false)
                p.window?.endSheet(sheet, returnCode: .alertThirdButtonReturn)
                print("check: drop dialog shown and cancelled; segments still \(p.doc.edit.segments.count)")
            } else {
                print("check: drop dialog NOT shown")
            }
            try? await Task.sleep(for: .milliseconds(400))
            // Replace: the new clip takes this player's place.
            let oldFrame = p.window?.frame ?? .zero
            app.open([h264], replacing: p)
            for _ in 0..<80 where app.players.first === p { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(500))
            let np = app.players.first
            print("check: replace -> players \(app.players.count), title \(np?.window?.title ?? "-"), old closed \(p.window?.isVisible == false), placed at old position (kept on screen) \(np.map { abs($0.window!.frame.minX - oldFrame.minX) < 1 || $0.window!.frame.maxX >= (NSScreen.main?.visibleFrame.maxX ?? 0) - 1 || $0.window!.frame.minY <= 1 } ?? false)")
            // Render the guide (for review; not part of the guide's own images).
            if let check = ProcessInfo.processInfo.environment["TRT_GUIDE_SNAPSHOT"] {
                app.showGuide(nil)
                try? await Task.sleep(for: .seconds(2.5))
                if let web = window(containing: "Guide")?.contentView as? WKWebView {
                    web.window?.setContentSize(NSSize(width: 900, height: 1400))
                    try? await Task.sleep(for: .seconds(1))
                    for anchor in ["start", "join", "export", "edit"] {
                        _ = try? await web.evaluateJavaScript("document.getElementById(\"\(anchor)\").scrollIntoView()")
                        try? await Task.sleep(for: .milliseconds(600))
                        if let img = try? await web.takeSnapshot(configuration: nil), let tiff = img.tiffRepresentation,
                           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: check.replacingOccurrences(of: ".png", with: "-\(anchor).png")))
                        }
                    }
                    print("guide snapshots written")
                }
            }
            print("Screenshots written to \(dir.path)")
            NSApp.terminate(nil)
        }
    }

    static func window(titled title: String) -> NSWindow? { NSApp.windows.first { $0.title == title && $0.isVisible } }
    static func window(containing text: String) -> NSWindow? { NSApp.windows.first { $0.title.contains(text) && $0.isVisible } }

    static func findPreviewButton(in view: NSView) -> NSButton? {
        if let b = view as? NSButton, b.title == "Preview" { return b }
        for v in view.subviews { if let b = findPreviewButton(in: v) { return b } }
        return nil
    }

    /// Draws a window's content view, plus the current video frame, with a title bar strip.
    static func capture(_ window: NSWindow?, to url: URL, video: PlayerWindowController? = nil, titleBar: Bool = true) {
        guard let window, let content = window.contentView else { print("no window for \(url.lastPathComponent)"); return }
        content.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let titleHeight: CGFloat = titleBar ? 28 : 0
        let size = NSSize(width: content.bounds.width, height: content.bounds.height + titleHeight)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)

        let image = NSImage(size: size)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height))
        // Layer-backed video is not part of cacheDisplay: draw the current frame into the video area.
        if let video, let frame = video.currentFrameImage, let vv = video.videoArea {
            let r = vv.convert(vv.bounds, to: content)
            NSColor.black.setFill(); r.fill()
            let iw = CGFloat(frame.width), ih = CGFloat(frame.height)
            let f = min(r.width / iw, r.height / ih)
            let dw = iw * f, dh = ih * f
            let dest = NSRect(x: r.midX - dw / 2, y: r.midY - dh / 2, width: dw, height: dh)
            NSGraphicsContext.current?.cgContext.draw(frame, in: dest)
        }
        if titleBar {
        // Simple title bar.
        let bar = NSRect(x: 0, y: content.bounds.height, width: size.width, height: titleHeight)
        NSColor(white: 0.93, alpha: 1).setFill(); bar.fill()
        NSColor(white: 0.8, alpha: 1).setFill(); NSRect(x: 0, y: bar.minY, width: size.width, height: 1).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: 12 + CGFloat(i) * 20, y: bar.midY - 6, width: 12, height: 12)).fill()
        }
        let title = NSAttributedString(string: window.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let ts = title.size()
        title.draw(at: NSPoint(x: (size.width - ts.width) / 2, y: bar.midY - ts.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(out)
        if let data = out.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("wrote \(url.lastPathComponent)")
        }
    }
}

/// Exercises every exporter's Preview on real clips and reports whether a non-black image came back.
///   TRT_PREVIEW_TEST=1 TRT_SAMPLE=/path/a.mpg[:/path/b.ts] "TinRoof Transcode.app/Contents/MacOS/TinRoof Transcode"
@MainActor
enum PreviewTest {
    static func run(samples: [String]) {
        let app = AppDelegate.shared
        Task { @MainActor in
            for sample in samples {
                app.openSource([URL(fileURLWithPath: sample)])
                var player: PlayerWindowController?
                for _ in 0..<100 { player = app.players.last; if player?.doc.primary.locations.first?.path == sample { break }; player = nil; try? await Task.sleep(for: .milliseconds(100)) }
                guard let p = player else { print("preview-test: could not open \(sample)"); continue }
                try? await Task.sleep(for: .seconds(1))
                p.move(to: 5, extend: false)
                try? await Task.sleep(for: .milliseconds(600))
                for kind in [ExporterKind.frame, .quickTime, .mpeg4, .avi, .matroska, .dv, .mpeg2] {
                    guard let m = app.showExporter(kind: kind, player: p) else { print("preview-test: \(kind.rawValue): exporter did not open"); continue }
                    // No click: the preview should render by itself when the exporter opens.
                    for _ in 0..<150 where m.preview == nil && m.previewError == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    let shown = m.preview.map { meanBrightness($0) }
                    print("preview-test: \((sample as NSString).lastPathComponent) \(kind.rawValue): " +
                          (shown.map { String(format: "image, mean brightness %.2f", $0) } ?? "NO IMAGE"))
                    if let shots = ProcessInfo.processInfo.environment["TRT_PREVIEW_SHOTS"], [ExporterKind.frame, .quickTime, .dv].contains(kind) {
                        try? await Task.sleep(for: .milliseconds(400))
                        ScreenshotMode.capture(ScreenshotMode.window(containing: "Export"), to: URL(fileURLWithPath: shots)
                            .appendingPathComponent("\((sample as NSString).lastPathComponent)-\(kind.rawValue.replacingOccurrences(of: " ", with: "")).png"))
                    }
                    m.close?()
                }
                // A settings change re-renders by itself.
                if let m = app.showExporter(kind: .quickTime, player: p) {
                    for _ in 0..<150 where m.preview == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    let before = m.preview.map(meanBrightness) ?? -1
                    m.settings.adjustments.brightness = 90
                    try? await Task.sleep(for: .milliseconds(300))
                    for _ in 0..<150 where m.previewBusy || (m.preview.map(meanBrightness) ?? -1) == before { try? await Task.sleep(for: .milliseconds(100)) }
                    print(String(format: "preview-test: settings change re-rendered: brightness %.2f -> %.2f", before, m.preview.map(meanBrightness) ?? -1))
                    m.close?()
                }
                // Playhead at the very end of the clip.
                p.move(to: p.doc.window.upperBound, extend: false)
                try? await Task.sleep(for: .milliseconds(500))
                if let m = app.showExporter(kind: .frame, player: p) {
                    for _ in 0..<150 where m.preview == nil && m.previewError == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    print("preview-test: at end of clip, Frame: " + (m.preview.map { String(format: "image, mean brightness %.2f", meanBrightness($0)) } ?? "NO IMAGE (\(m.previewError ?? "-"))"))
                    m.close?()
                }
            }
            // Playhead inside a clip appended to the first one (different stream numbering).
            if samples.count > 1, let p = app.players.first(where: { $0.doc.primary.locations.first?.path == samples[0] }) {
                p.appendClips([URL(fileURLWithPath: samples[1])])
                for _ in 0..<80 where p.doc.edit.segments.count < 2 { try? await Task.sleep(for: .milliseconds(100)) }
                p.move(to: p.doc.edit.segmentStarts.last! + 3, extend: false)
                try? await Task.sleep(for: .milliseconds(500))
                for kind in [ExporterKind.frame, .quickTime] {
                    guard let m = app.showExporter(kind: kind, player: p) else { continue }
                    for _ in 0..<150 where m.preview == nil && m.previewError == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    print("preview-test: inside appended clip, \(kind.rawValue): " + (m.preview.map { String(format: "image, mean brightness %.2f", meanBrightness($0)) } ?? "NO IMAGE (\(m.previewError ?? "-"))"))
                    m.close?()
                }
            }
            for line in app.logStore.lines where line.contains("Preview failed") { print("preview-test log: \(line)") }
            NSApp.terminate(nil)
        }
    }

    /// Average luminance 0…1 of the image as it would be drawn.
    static func meanBrightness(_ image: NSImage) -> Double {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return -1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let data = ctx.data else { return -1 }
        let px = data.bindMemory(to: UInt8.self, capacity: 32 * 32 * 4)
        var sum = 0.0
        for i in 0..<(32 * 32) { sum += (Double(px[i * 4]) + Double(px[i * 4 + 1]) + Double(px[i * 4 + 2])) / 3 }
        return sum / Double(32 * 32) / 255
    }
}
