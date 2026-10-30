import AppKit
import MediaCore

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
        app.openSource([URL(fileURLWithPath: sample)])
        Task { @MainActor in
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
            window(containing: "Exporter")?.setContentSize(NSSize(width: 860, height: 900))
            model?.makePreview()
            for _ in 0..<100 where model?.preview == nil { try? await Task.sleep(for: .milliseconds(100)) }
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
    static func capture(_ window: NSWindow?, to url: URL, video: PlayerWindowController? = nil) {
        guard let window, let content = window.contentView else { print("no window for \(url.lastPathComponent)"); return }
        content.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let titleHeight: CGFloat = 28
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
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(out)
        if let data = out.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("wrote \(url.lastPathComponent)")
        }
    }
}
