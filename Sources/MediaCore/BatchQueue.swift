import Foundation
import Combine

public enum TaskStatus: Equatable, Sendable {
    case waiting
    case held
    case running(Double)
    case completed
    case cancelled
    case failed(String)

    public var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .held: return "Held"
        case .running(let p): return String(format: "Running %.0f%%", p * 100)
        case .completed: return "Completed"
        case .cancelled: return "Stopped"
        case .failed(let m): return "Error: " + (m.split(separator: "\n").last.map(String.init) ?? m)
        }
    }

    public var isRunning: Bool { if case .running = self { return true }; return false }
}

public final class BatchTask: ObservableObject, Identifiable, @unchecked Sendable {
    public let id = UUID()
    @Published public var spec: JobSpec
    @Published public var status: TaskStatus = .waiting
    public var log: [String] = []
    fileprivate var process: FFmpegProcess?
    fileprivate var downloader: Downloader?

    public init(spec: JobSpec) { self.spec = spec }
    public var title: String { spec.title }
}

/// Queue of conversion tasks. Runs up to `simultaneousTasks` at once.
@MainActor
public final class BatchQueue: ObservableObject {
    @Published public private(set) var tasks: [BatchTask] = []
    @Published public var isProcessing = false
    @Published public var autoStart = false
    @Published public var simultaneousTasks = 1
    /// Script or app run when every task has finished (AppleScript `.scpt`/`.applescript`, shell script, or app).
    @Published public var completionScript: URL?

    public var onLog: ((String) -> Void)?
    public var onTaskFinished: ((BatchTask) -> Void)?

    public init() {}

    public func add(_ spec: JobSpec) {
        tasks.append(BatchTask(spec: spec))
        if autoStart { start() } else if isProcessing { pump() }
    }

    public func remove(_ ids: Set<UUID>) {
        for t in tasks where ids.contains(t.id) && t.status.isRunning { cancel(t) }
        tasks.removeAll { ids.contains($0.id) && !$0.status.isRunning }
    }

    public func clear() { remove(Set(tasks.map(\.id))) }

    public func move(_ id: UUID, by offset: Int) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard tasks.indices.contains(j) else { return }
        tasks.swapAt(i, j)
    }

    public func toggleHold(_ ids: Set<UUID>) {
        for t in tasks where ids.contains(t.id) {
            if t.status == .waiting { t.status = .held } else if t.status == .held { t.status = .waiting }
        }
        objectWillChange.send()
    }

    public func repeatTasks(_ ids: Set<UUID>) {
        for t in tasks where ids.contains(t.id) && !t.status.isRunning { t.status = .waiting }
        objectWillChange.send()
        if isProcessing { pump() }
    }

    public func redirect(_ ids: Set<UUID>, to folder: URL) {
        for t in tasks where ids.contains(t.id) && !t.status.isRunning { t.spec = t.spec.redirected(to: folder) }
        objectWillChange.send()
    }

    /// Starts processing waiting tasks.
    public func start() {
        isProcessing = true
        pump()
    }

    /// Stops starting new tasks; running tasks finish.
    public func stopAfterCurrent() { isProcessing = false }

    public func cancelAll() {
        isProcessing = false
        for t in tasks where t.status.isRunning { cancel(t) }
    }

    public func cancel(_ task: BatchTask) {
        task.process?.cancel()
        task.downloader?.cancel()
    }

    public var runningCount: Int { tasks.filter { $0.status.isRunning }.count }

    private func pump() {
        guard isProcessing else { return }
        while runningCount < max(1, simultaneousTasks), let next = tasks.first(where: { $0.status == .waiting }) {
            run(next)
        }
        if runningCount == 0 && !tasks.contains(where: { $0.status == .waiting }) {
            isProcessing = false
            runCompletionScript()
        }
    }

    private func run(_ task: BatchTask) {
        task.status = .running(0)
        task.log = []
        onLog?("Started: \(task.title)")
        if case .download(let url) = task.spec.kind {
            let d = Downloader()
            task.downloader = d
            d.onProgress = { [weak task] p in DispatchQueue.main.async { task?.status = .running(p) } }
            Task {
                do {
                    _ = try await d.download(url, to: task.spec.output)
                    self.finish(task, .completed)
                } catch {
                    self.finish(task, (error as? URLError)?.code == .cancelled ? .cancelled : .failed(error.localizedDescription))
                }
            }
            return
        }
        guard let ffmpeg = FFmpegLocator.find() else { finish(task, .failed(MediaError.ffmpegMissing.localizedDescription)); return }
        let plan: FFmpegPlan
        do {
            plan = try CommandBuilder.plan(for: task.spec)
        } catch {
            finish(task, .failed(error.localizedDescription))
            return
        }
        let proc = FFmpegProcess(plan: plan, executable: ffmpeg)
        task.process = proc
        proc.onProgress = { [weak task] p in DispatchQueue.main.async { if task?.status.isRunning == true { task?.status = .running(p) } } }
        proc.onLog = { [weak self, weak task] line in
            DispatchQueue.main.async {
                task?.log.append(line)
                self?.onLog?(line)
            }
        }
        let isCheck: Bool = { if case .checkStream = task.spec.kind { return true }; return false }()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = proc.run()
            DispatchQueue.main.async {
                switch outcome {
                case .completed:
                    if isCheck { self.onLog?(task.log.isEmpty ? "Check Stream: no errors found." : "Check Stream: \(task.log.count) problem(s) found.") }
                    self.finish(task, .completed)
                case .cancelled: self.finish(task, .cancelled)
                case .failed(let m): self.finish(task, .failed(m))
                }
            }
        }
    }

    private func finish(_ task: BatchTask, _ status: TaskStatus) {
        task.status = status
        task.process = nil
        task.downloader = nil
        onLog?("\(status.label): \(task.title)")
        onTaskFinished?(task)
        objectWillChange.send()
        pump()
    }

    private func runCompletionScript() {
        guard let script = completionScript else { return }
        let p = Process()
        switch script.pathExtension.lowercased() {
        case "scpt", "applescript", "scptd":
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = [script.path]
        case "app":
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [script.path]
        default:
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path]
        }
        try? p.run()
        onLog?("Ran completion script \(script.lastPathComponent)")
    }
}
