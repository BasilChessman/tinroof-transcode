import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Renders watermark text to a transparent PNG for ffmpeg's overlay filter
/// (the Homebrew ffmpeg build has no drawtext filter).
public enum WatermarkRenderer {
    public static func render(_ text: String, frameHeight: Int, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let fontSize = CGFloat(max(12, frameHeight / 22))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 0.85)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: white]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary))
        let bounds = CTLineGetImageBounds(line, nil)
        let pad = fontSize / 4
        let width = Int(ceil(bounds.width + bounds.origin.x + pad * 2)), height = Int(ceil(fontSize * 1.3 + pad))
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw MediaError.failed("Could not render the watermark.") }
        ctx.setShadow(offset: CGSize(width: 1, height: -1), blur: fontSize / 8, color: CGColor(gray: 0, alpha: 0.8))
        ctx.textPosition = CGPoint(x: pad, y: pad + fontSize * 0.25)
        CTLineDraw(line, ctx)
        guard let image = ctx.makeImage() else { throw MediaError.failed("Could not render the watermark.") }
        let url = directory.appendingPathComponent("watermark-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MediaError.failed("Could not write the watermark.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw MediaError.failed("Could not write the watermark.") }
        return url
    }
}

/// Named export settings stored on disk.
public struct Preset: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var settings: ExportSettings
    public init(name: String, settings: ExportSettings) { self.name = name; self.settings = settings }
}

public final class PresetStore: @unchecked Sendable {
    public private(set) var presets: [Preset] = []
    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("Presets.json")
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Preset].self, from: data) { presets = list }
    }

    public func presets(for kind: ExporterKind) -> [Preset] { presets.filter { $0.settings.kind == kind } }

    public func add(_ p: Preset) { presets.append(p); save() }
    public func update(_ p: Preset) { if let i = presets.firstIndex(where: { $0.id == p.id }) { presets[i] = p; save() } }
    public func delete(_ id: UUID) { presets.removeAll { $0.id == id }; save() }

    public func move(_ id: UUID, by offset: Int) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        let kind = presets[i].settings.kind
        // Move past neighbours of the same exporter kind only.
        var j = i + offset
        while presets.indices.contains(j) && presets[j].settings.kind != kind { j += offset }
        guard presets.indices.contains(j) else { return }
        presets.swapAt(i, j)
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(presets).write(to: url, options: .atomic)
    }
}

/// HTTP(S)/FTP downloads with progress.
public final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public var onProgress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL!
    private var session: URLSession!
    private var task: URLSessionDownloadTask?

    public override init() { super.init() }

    public func download(_ url: URL, to destination: URL) async throws -> URL {
        self.destination = destination
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let t = session.downloadTask(with: url)
            task = t
            t.resume()
        }
    }

    public func cancel() { task?.cancel() }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
        session.finishTasksAndInvalidate()
    }
}

/// Resolves the direct media URL behind a web page using yt-dlp, when the user has installed it.
public enum PageResolver {
    public static func ytDLP() -> URL? { FFmpegLocator.find(named: "yt-dlp") }

    public static func looksLikeMedia(_ url: URL) -> Bool {
        let mediaExtensions: Set<String> = SequenceDetector.videoExtensions.union(SequenceDetector.audioExtensions).union(["m3u8", "mpd"])
        return mediaExtensions.contains(url.pathExtension.lowercased()) || url.scheme == "ftp"
    }

    /// Returns the direct URL of the best single-file format, or nil if yt-dlp is unavailable or fails.
    public static func resolve(_ page: URL) -> URL? {
        guard let tool = ytDLP() else { return nil }
        let p = Process()
        p.executableURL = tool
        p.arguments = ["--no-playlist", "-f", "best[vcodec!=none][acodec!=none]/best", "-g", page.absoluteString]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let first = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
        return first.flatMap(URL.init(string:))
    }
}
