import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import AudioCore

/// Every launch checks real services; a saved "installed" flag is never enough.
@MainActor
final class SetupAssistant: ObservableObject {
    @Published var ready = false
    @Published var busy = false
    @Published var message = "首次使用需要联网下载模型。以后模型保存在本机。"
    @Published var problem: String?
    @Published var progress: Double?
    @Published var selectedModel = UserDefaults.standard.string(forKey: "Hermeneus.OllamaModelName") ?? "qwen2.5:3b"
    @Published var installedModels: [String] = []
    @Published var runtimeOK = false
    @Published var modelOK = false
    @Published var speechOK = false
    @Published var microphoneOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var screenOK = CGPreflightScreenCaptureAccess()
    private var work: Task<Void, Never>?
    private var children: [Process] = []
    private var automaticCheckStarted = false
    private var verifiedModel: String?
    var canBegin: Bool {
        !busy && runtimeOK && modelOK && speechOK && microphoneOK && screenOK && selectedModel == verifiedModel
    }
    func checkOnLaunch() {
        guard !automaticCheckStarted else { return }
        automaticCheckStarted = true
        run(download: false, autoEnter: true)
    }
    func shutdown() {
        work?.cancel()
        // Process objects are created here: never stop externally managed services.
        for process in children where process.isRunning { process.terminate() }
    }
    private let session = LocalServiceAccess.session
    let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Hermeneus", isDirectory: true)

    static let choices = [
        ("qwen2.5:3b", "标准 · 千问 2.5（推荐，优先响应速度）"),
        ("qwen3:4b-instruct", "千问 3 · 非思考版（可选，需更多资源）"),
        ("qwen2.5:7b", "千问 2.5 大模型（建议 16GB 以上内存）")
    ]

    private func failure(_ text: String) -> NSError {
        NSError(domain: "HermeneusSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func request(_ port: Int, _ path: String, body: [String: Any]? = nil,
                         timeout: TimeInterval = 5) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
        req.timeoutInterval = timeout
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if port == LocalServiceAccess.asrHTTPPort || port == LocalServiceAccess.ollamaPort { LocalServiceAccess.authorize(&req) }
        return req
    }

    private func json(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("组件响应无法读取，请重试或打开诊断日志。")
        }
        if let detail = object["error"] as? String {
            throw failure("组件报告：\(detail.prefix(600))。请重试；内存不足时请选择较小模型。")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw failure("组件未通过检查，请重试或打开诊断日志。")
        }
        return object
    }

    private func tags() async throws -> [String] {
        let version = try await json(request(LocalServiceAccess.ollamaPort, "api/version"))
        guard version["version"] as? String == LocalServiceAccess.ollamaSecurityRevision else {
            throw failure("翻译运行包版本未通过安全检查，请重新安装当前 Full 完整版。")
        }
        let object = try await json(request(LocalServiceAccess.ollamaPort, "api/tags"))
        guard let models = object["models"] as? [[String: Any]] else {
            throw failure("翻译服务响应不正确，请重试；如重复失败，请打开诊断日志。")
        }
        return models.compactMap { item in
            guard item["remote_host"] == nil, let name = item["name"] as? String,
                  !name.hasSuffix(":cloud"), !name.hasSuffix("-cloud") else { return nil }
            return name
        }
    }

    private func executable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func launch(_ path: String, arguments: [String], log: String) throws {
        let file = try PrivateLogFile.open(in: logDirectory, name: log)
        defer { try? file.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = file
        process.standardError = file
        var environment = ProcessInfo.processInfo.environment
        if let ffmpeg = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg", isDirectory: true),
           FileManager.default.isExecutableFile(atPath: ffmpeg.appendingPathComponent("ffmpeg").path) {
            environment["PATH"] = ffmpeg.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            environment["DYLD_FALLBACK_LIBRARY_PATH"] = ffmpeg.appendingPathComponent("lib").path
        }
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HERMENEUS_ASR_TOKEN"] = LocalServiceAccess.token
        environment["HERMENEUS_OLLAMA_TOKEN"] = LocalServiceAccess.token
        environment["OLLAMA_HOST"] = "127.0.0.1:\(LocalServiceAccess.ollamaPort)"
        environment["OLLAMA_NO_CLOUD"] = "1"
        environment["OLLAMA_MAX_QUEUE"] = "8"
        environment["OLLAMA_NUM_PARALLEL"] = "1"
        environment["OLLAMA_MAX_LOADED_MODELS"] = "1"
        environment["ASR_WS_HOST"] = "127.0.0.1"
        environment["ASR_HTTP_PORT"] = String(LocalServiceAccess.asrHTTPPort)
        environment["ASR_WS_PORT"] = String(LocalServiceAccess.asrWSPort)
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["PYANNOTE_METRICS_ENABLED"] = "0"
        if URL(fileURLWithPath: path).lastPathComponent == "asr_server" {
            // Both listeners remain owned by this app, including while models load.
            process.standardInput = LocalServiceAccess.asrHTTPListener.handle
            process.standardOutput = LocalServiceAccess.asrWSListener.handle
            environment["HERMENEUS_ASR_HTTP_FD"] = "0"
            environment["HERMENEUS_ASR_WS_FD"] = "1"
        } else {
            process.standardInput = LocalServiceAccess.ollamaListener.handle
            environment["HERMENEUS_OLLAMA_LISTENER_FD"] = "0"
        }
        process.environment = environment
        try process.run()
        children.append(process)
    }

    func run(download: Bool, autoEnter: Bool = false) {
        guard !busy else { return }
        busy = true
        problem = nil
        progress = nil
        ready = false
        work = Task {
            defer { busy = false; progress = nil }
            do {
                try await prepare(download: download, autoEnter: autoEnter)
            } catch is CancellationError {
                message = "已暂停检查。再次点击即可继续；已下载模型会保留。"
            } catch {
                if Task.isCancelled {
                    message = "已暂停等待。再次点击即可继续；已下载模型会保留。"
                } else {
                    problem = error.localizedDescription
                    message = "尚未准备完成。请按提示处理后重试。"
                }
            }
        }
    }

    func cancel() { work?.cancel() }

    private func prepare(download: Bool, autoEnter: Bool) async throws {
        runtimeOK = false; modelOK = false; speechOK = false; verifiedModel = nil
        message = "正在检查翻译组件…"
        do {
            installedModels = try await tags()
        } catch {
            try Task.checkCancellation()
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("ollama-runtime/ollama").path ?? ""
            guard let cli = executable([bundled, "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]) else {
                throw failure("安装包缺少内置翻译组件。请重新安装 Hermeneus Full 完整版；无需安装 Ollama 图形界面或 Homebrew。")
            }
            if !children.contains(where: { $0.isRunning && $0.executableURL?.path == cli }) {
                try launch(cli, arguments: ["serve"], log: "ollama.log")
            }
            var connected = false
            for _ in 0..<30 {
                try Task.checkCancellation()
                if let models = try? await tags() {
                    installedModels = models; connected = true; break
                }
                try await Task.sleep(for: .seconds(1))
            }
            guard connected else { throw failure("内置翻译服务未能启动或版本未通过安全检查。请重试或重新安装当前 Full 完整版。") }
        }
        runtimeOK = true
        if !installedModels.contains(selectedModel) {
            guard download else {
                message = "请选择翻译模型，然后点击“下载并准备”。已有模型可直接选择，不会重复下载。"
                return
            }
            guard Self.choices.contains(where: { $0.0 == selectedModel }) else {
                throw failure("上次选择的本地模型已不可用，请选择列表中的推荐模型。云端模型不用于本地同传。")
            }
            let capacity = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = capacity?.volumeAvailableCapacityForImportantUsage, available < 10_000_000_000 {
                throw failure("磁盘可用空间不足 10GB，请先清理空间后重试。")
            }
            message = "正在下载 \(selectedModel)，请保持联网。下载时间取决于网速。"
            let req = try request(LocalServiceAccess.ollamaPort, "api/pull", body: ["model": selectedModel, "stream": true], timeout: 300)
            let (bytes, response) = try await session.bytes(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw failure("模型下载未开始，请检查网络和 Ollama 是否为最新版本后重试。")
            }
            var success = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8),
                      let item = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let error = item["error"] as? String { throw failure("模型下载失败：\(error)。请重试。") }
                if let total = item["total"] as? Double, total > 0 {
                    let completed = item["completed"] as? Double ?? 0
                    progress = min(1, completed / total)
                    message = "正在下载模型：\(Int(progress! * 100))%（当前文件）"
                } else { progress = nil }
                if item["status"] as? String == "success" { success = true }
            }
            guard success else { throw failure("下载中断，请检查网络后重试。Ollama 会复用已下载的数据。") }
            installedModels = try await tags()
            guard installedModels.contains(selectedModel) else { throw failure("下载后未找到所选模型，请重试。") }
        }
        progress = nil
        message = "正在测试翻译模型，首次加载可能需要几分钟…"
        let test = try await json(request(LocalServiceAccess.ollamaPort, "api/generate", body: [
            "model": selectedModel, "prompt": "Translate to Spanish. Output only the translation: 你好",
            "stream": false, "keep_alive": "30m", "options": ["num_predict": 48]
        ], timeout: 300))
        guard let result = test["response"] as? String,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("模型没有返回翻译，请选择推荐模型重试。")
        }
        try Task.checkCancellation()
        verifiedModel = selectedModel
        modelOK = true
        // Save only a model that has actually responded. The pipeline reads this same key.
        UserDefaults.standard.set(selectedModel, forKey: "Hermeneus.OllamaModelName")
        message = "正在准备中文和西语语音模型。首次下载可能需要较长时间，请保持联网…"
        try Task.checkCancellation()
        if let health = try? await json(request(LocalServiceAccess.asrHTTPPort, "health")), health["service"] as? String == "hermeneus-asr" {
            if download && health["setup_error"] is String {
                _ = try await json(request(LocalServiceAccess.asrHTTPPort, "setup/retry", body: [:]))
                try await Task.sleep(for: .seconds(1))
            }
            try await waitForSpeech()
        } else {
            try Task.checkCancellation()
            let binary = Bundle.main.resourceURL?.appendingPathComponent("asr_server").path ?? ""
            guard FileManager.default.isExecutableFile(atPath: binary) else {
                throw failure("此版本缺少内置语音引擎。请安装 Hermeneus Full 完整版，再双击打开；无需自行安装 Python 或语音引擎。")
            }
            // Never terminate an unknown process occupying a port.
            if !children.contains(where: { $0.isRunning && $0.executableURL?.path == binary }) {
                try launch(binary, arguments: [], log: "speech.log")
            }
            try await waitForSpeech()
        }
        speechOK = true
        microphoneOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenOK = CGPreflightScreenCaptureAccess()
        message = "模型和引擎已准备好。请完成以下两项系统授权，然后开始翻译。"
        if autoEnter && microphoneOK && screenOK && UserDefaults.standard.bool(forKey: "Hermeneus.SetupCompleted") {
            ready = true
        }
    }

    private func waitForSpeech() async throws {
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            try Task.checkCancellation()
            if let health = try? await json(request(LocalServiceAccess.asrHTTPPort, "health")),
               health["service"] as? String == "hermeneus-asr" {
                if let error = health["setup_error"] as? String, !error.isEmpty {
                    throw failure("语音模型准备失败：\(error)。请检查网络后重试；如重复失败，请重新打开应用并查看诊断日志。")
                }
                if health["ready"] as? Bool == true { return }
            }
            if let child = children.last(where: { $0.executableURL?.lastPathComponent == "asr_server" }), !child.isRunning {
                throw failure("语音引擎启动失败或端口被占用。请打开诊断日志，或关闭旧版 Hermeneus 后重试。")
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw failure("语音模型下载或启动超时。请检查网络后重试；详细原因见诊断日志。")
    }

    func authorizeMicrophone() async {
        microphoneOK = await AVCaptureDevice.requestAccess(for: .audio)
        if !microphoneOK { openPrivacy("Microphone") }
    }
    func authorizeScreen() {
        screenOK = CGPreflightScreenCaptureAccess()
        if !screenOK { _ = CGRequestScreenCaptureAccess(); openPrivacy("ScreenCapture") }
    }
    func refreshPermissions() {
        microphoneOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenOK = CGPreflightScreenCaptureAccess()
    }
    private func openPrivacy(_ name: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(name)")!)
    }
    func showLogs() {
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logDirectory)
    }
}

struct SetupAssistantView: View {
    @ObservedObject var setup: SetupAssistant
    let begin: () -> Void
    let configureAudio: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    private func row(_ name: String, _ done: Bool) -> some View {
        Label(name, systemImage: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? Color.green : Color.secondary)
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("让 Hermeneus 准备好翻译").font(.title2.bold())
            Text("只需完成一次准备。无需终端命令；以后双击应用即可自动检查并启动。")
                .foregroundStyle(.secondary)
            row("内置翻译组件 Ollama（后台运行）", setup.runtimeOK)
            row("千问翻译模型", setup.modelOK)
            row("中文 / 西语语音引擎", setup.speechOK)
            Picker("翻译模型", selection: $setup.selectedModel) {
                ForEach(SetupAssistant.choices, id: \.0) { item in Text(item.1).tag(item.0) }
                if !SetupAssistant.choices.contains(where: { $0.0 == setup.selectedModel }) && !setup.installedModels.contains(setup.selectedModel) {
                    Text("上次选择 · \(setup.selectedModel)（不可用，请选择其他模型）").tag(setup.selectedModel)
                }
                ForEach(setup.installedModels.filter { name in !SetupAssistant.choices.contains { $0.0 == name } }, id: \.self) {
                    Text("已安装 · \($0)").tag($0)
                }
            }
            .disabled(setup.busy)
            Text("首次会下载数 GB 文件，请预留至少 10GB 可用空间。模型下载和更新需要联网；翻译音频在本机处理。")
                .font(.caption).foregroundStyle(.secondary)
            if setup.busy {
                if let progress = setup.progress { ProgressView(value: progress) }
                else { ProgressView().controlSize(.small) }
            }
            Text(setup.message).fixedSize(horizontal: false, vertical: true)
            if let problem = setup.problem {
                Text(problem).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(setup.microphoneOK ? "麦克风已授权 ✓" : "允许麦克风") {
                    Task { await setup.authorizeMicrophone() }
                }
                Button(setup.screenOK ? "系统音频权限已授权 ✓" : "允许系统音频 / 屏幕录制") { setup.authorizeScreen() }
                Button("刷新授权") { setup.refreshPermissions() }
            }
            Button("设置语音回传设备 / 发送测试语音", action: configureAudio)
            Text("系统音频权限用于识别对方的声音。若系统提示退出并重新打开，请按提示操作。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("打开诊断日志") { setup.showLogs() }
                Spacer()
                if setup.busy { Button("暂停等待") { setup.cancel() } }
                else {
                    Button(setup.problem == nil ? "下载并准备 / 重新检查" : "重试") { setup.run(download: true) }
                    Button("开始翻译", action: begin)
                        .buttonStyle(.borderedProminent)
                        .disabled(!setup.canBegin)
                }
            }
        }
        .padding(28)
        }
        .frame(width: 700, height: 680)
        .onChange(of: setup.selectedModel) { _, _ in setup.modelOK = false }
        .onChange(of: scenePhase) { _, phase in if phase == .active { setup.refreshPermissions() } }
    }
}
