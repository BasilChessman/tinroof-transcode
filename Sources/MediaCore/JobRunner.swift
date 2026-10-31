import Foundation

/// Locates the ffmpeg executable: a user override, one bundled in the app, or Homebrew/MacPorts.
public enum FFmpegLocator {
    public static let overrideKey = "ffmpegPath"

    public static func find(named tool: String = "ffmpeg") -> URL? {
        var candidates: [String] = []
        if tool == "ffmpeg", let env = ProcessInfo.processInfo.environment["FFMPEG_PATH"], !env.isEmpty { candidates.append(env) }
        if tool == "ffmpeg", let custom = UserDefaults.standard.string(forKey: overrideKey), !custom.isEmpty { candidates.append(custom) }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: tool)?.path { candidates.append(bundled) }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("bin/\(tool)").path { candidates.append(res) }
        candidates += ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)", "/opt/local/bin/\(tool)"]
        for path in ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? [] {
            candidates.append("\(path)/\(tool)")
        }
        return candidates.lazy.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Runs the commands of an `FFmpegPlan`, reporting progress and collecting diagnostics.
public final class FFmpegProcess: @unchecked Sendable {
    public enum Outcome: Sendable {
        case completed
        case cancelled
        case failed(String)
    }

    public let plan: FFmpegPlan
    private let executable: URL
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Fraction 0…1 across all passes.
    public var onProgress: (@Sendable (Double) -> Void)?
    /// Diagnostic lines from ffmpeg's stderr.
    public var onLog: (@Sendable (String) -> Void)?

    public init(plan: FFmpegPlan, executable: URL) {
        self.plan = plan
        self.executable = executable
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning {
            p.interrupt() // lets ffmpeg finalize the container
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        }
    }

    /// Runs synchronously; call from a background thread.
    public func run() -> Outcome {
        defer { for url in plan.temporaryFiles { try? FileManager.default.removeItem(at: url) } }
        let passes = plan.commands.count
        var errors: [String] = []
        for (i, args) in plan.commands.enumerated() {
            lock.lock()
            if cancelled { lock.unlock(); return .cancelled }
            let p = Process()
            p.executableURL = executable
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            p.qualityOfService = .userInitiated   // keep encodes on the performance cores
            process = p
            lock.unlock()

            let duration = max(plan.duration, 0.001)
            let progress = onProgress
            let log = onLog
            let errLock = NSLock()
            var outBuffer = Data(), errBuffer = Data()
            out.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty else { return }
                outBuffer.append(chunk)
                while let nl = outBuffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: outBuffer[..<nl], as: UTF8.self)
                    outBuffer.removeSubrange(...nl)
                    if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                        let frac = min(1, max(0, us / 1_000_000 / duration))
                        progress?((Double(i) + frac) / Double(passes))
                    }
                }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty else { return }
                errLock.lock()
                errBuffer.append(chunk)
                while let nl = errBuffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: errBuffer[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                    errBuffer.removeSubrange(...nl)
                    if !line.isEmpty { errors.append(line); log?(line) }
                }
                errLock.unlock()
            }
            do {
                try p.run()
            } catch {
                return .failed("Could not start ffmpeg: \(error.localizedDescription)")
            }
            p.waitUntilExit()
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let rest = err.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty {
                errLock.lock()
                let text = String(decoding: errBuffer + rest, as: UTF8.self)
                for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    errors.append(String(line)); log?(String(line))
                }
                errLock.unlock()
            }
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { return .cancelled }
            if p.terminationStatus != 0 {
                let tail = errors.suffix(6).joined(separator: "\n")
                return .failed(tail.isEmpty ? "ffmpeg exited with status \(p.terminationStatus)." : tail)
            }
        }
        onProgress?(1)
        return .completed
    }
}
