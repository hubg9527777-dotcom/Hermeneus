import Foundation

@MainActor
final class OfflineBatchRunner: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case completed
        case failed(String)
        case cancelled

        var description: String {
            switch self {
            case .idle: return "未开始"
            case .running: return "正在本地转写与翻译"
            case .completed: return "已完成"
            case .failed(let reason): return "失败：\(reason)"
            case .cancelled: return "已取消"
            }
        }
    }

    private struct WorkerLaunch {
        let executableURL: URL
        let baseArguments: [String]
        let diarizerArguments: [String]
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var completedSegments = 0
    @Published private(set) var statusMessage = "等待开始"
    @Published private(set) var exportDirectory: URL?
    private var process: Process?
    private var progressTimer: Timer?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func start(
        inputURL: URL,
        secureRoot: URL,
        modelName: String,
        diarization: Bool,
        dualTracks: (local: URL, remote: URL)? = nil
    ) throws {
        guard !isRunning else { return }
        let launch = try resolveWorkerLaunch(needsDiarization: diarization)
        let jobID = UUID().uuidString.lowercased()
        let process = Process()
        process.executableURL = launch.executableURL
        var arguments = launch.baseArguments + ["--secure-root", secureRoot.path, "--job-id", jobID, "--model", modelName]
        if let dualTracks {
            arguments += ["--local-input", dualTracks.local.path, "--remote-input", dualTracks.remote.path]
        } else {
            arguments += ["--input", inputURL.path]
        }
        if diarization { arguments += ["--diarization"] + launch.diarizerArguments }
        process.arguments = arguments
        // pyannote 4 uses torchcodec, whose packaged macOS bridge loads the
        // local FFmpeg dylibs. Homebrew uses one of these standard prefixes.
        var environment = ProcessInfo.processInfo.environment
        let ffmpegLibraryDirectories = ["/opt/homebrew/opt/ffmpeg/lib", "/usr/local/opt/ffmpeg/lib"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        if !ffmpegLibraryDirectories.isEmpty {
            let inherited = environment["DYLD_FALLBACK_LIBRARY_PATH"].map { ":\($0)" } ?? ""
            environment["DYLD_FALLBACK_LIBRARY_PATH"] = ffmpegLibraryDirectories.joined(separator: ":") + inherited
        }
        process.environment = environment

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        process.terminationHandler = { [weak self] task in
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                self?.finish(task: task, errorText: errorText, root: secureRoot, jobID: jobID)
            }
        }
        try process.run()
        self.process = process
        state = .running
        completedSegments = 0
        statusMessage = "正在加载本地 Whisper 模型。"
        startProgressPolling(root: secureRoot, jobID: jobID)
    }

    private func resolveWorkerLaunch(needsDiarization: Bool) throws -> WorkerLaunch {
        // Full DMG path: one self-contained ASR binary dispatches to the offline worker.
        if let serverURL = Bundle.main.url(forResource: "asr_server", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: serverURL.path) {
            var diarizerArguments: [String] = []
            if needsDiarization {
                guard let diarizerURL = Bundle.main.url(forResource: "offline_diarizer", withExtension: nil),
                      FileManager.default.isExecutableFile(atPath: diarizerURL.path) else {
                    throw NSError(domain: "HermeneusBatch", code: 2, userInfo: [NSLocalizedDescriptionKey: "完整离线说话人分离组件未安装。请使用 Full DMG。"])
                }
                diarizerArguments = ["--diarization-executable", diarizerURL.path]
            }
            return WorkerLaunch(executableURL: serverURL, baseArguments: ["--offline-batch"], diarizerArguments: diarizerArguments)
        }

        // Development fallback has no machine-specific literal. It only resolves while source files exist.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("asr_server/offline_batch_worker.py")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NSError(domain: "HermeneusBatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到离线批量组件。请使用包含离线功能的 Full DMG。"])
        }
        let python = URL(fileURLWithPath: "/usr/bin/env")
        var diarizerArguments: [String] = []
        if needsDiarization {
            let diarizer = sourceURL.deletingLastPathComponent().appendingPathComponent("offline_diarization_worker.py")
            diarizerArguments = ["--diarization-worker", diarizer.path]
        }
        return WorkerLaunch(executableURL: python, baseArguments: ["python3", sourceURL.path], diarizerArguments: diarizerArguments)
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
        progressTimer?.invalidate()
        progressTimer = nil
        state = .cancelled
        statusMessage = "已请求取消；已完成检查点保留在加密卷。"
    }

    private func startProgressPolling(root: URL, jobID: String) {
        progressTimer?.invalidate()
        let url = root.appendingPathComponent("Hermeneus Data/jobs/\(jobID)/progress.json")
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readProgress(url) }
        }
    }

    private func readProgress(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        completedSegments = payload["completed_segments"] as? Int ?? completedSegments
        statusMessage = payload["message"] as? String ?? statusMessage
    }

    private func finish(task: Process, errorText: String, root: URL, jobID: String) {
        progressTimer?.invalidate()
        progressTimer = nil
        process = nil
        if state == .cancelled { return }
        if task.terminationStatus == 0 {
            state = .completed
            statusMessage = "已完成本地转写、翻译与双语记录导出。"
            exportDirectory = root.appendingPathComponent("Hermeneus Data/exports/\(jobID)")
        } else {
            state = .failed(errorText.isEmpty ? "本地工作器退出码 \(task.terminationStatus)" : errorText)
            statusMessage = "工作器失败；检查加密卷中的 jobs 目录以获取检查点。"
        }
    }
}
