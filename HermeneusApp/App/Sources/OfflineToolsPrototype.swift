import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 离线录音、文件转译与说话人标签工作台。
///
/// 离线工具的控制器负责存储目录、录音与本地文件转译状态。
/// 它只验证用户选择的本地存储目录、创建一个不含内容数据的任务清单，
/// 并让用户体验未来的录音/文件转译/说话人标签工作流。
@MainActor
final class OfflineToolsPrototypeController: ObservableObject {
    enum TaskMode: String, CaseIterable, Identifiable {
        case recording = "录音后转译"
        case file = "导入文件转译"

        var id: String { rawValue }
    }

    enum SpeakerMode: String, CaseIterable, Identifiable {
        case singleSpeaker = "单人说话"
        case dualSpeaker = "双人说话"

        var id: String { rawValue }
    }

    enum StorageState: Equatable {
        case notConfigured
        case ready(path: String)
        case unavailable(message: String)

        var summary: String {
            switch self {
            case .notConfigured:
                return "尚未选择存储目录"
            case .ready(let path):
                return "已验证可写：\(path)"
            case .unavailable(let message):
                return message
            }
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    enum PreviewState: Equatable {
        case idle
        case recordingReady
        case jobCreated

        var title: String {
            switch self {
            case .idle: return "等待设置"
            case .recordingReady: return "录音体验已就绪"
            case .jobCreated: return "示例任务已写入所选目录"
            }
        }

        var detail: String {
            switch self {
            case .idle:
                return "选择存储目录后，才可体验离线工具流程。"
            case .recordingReady:
                return "这是安全体验状态：不会打开麦克风、不会捕获系统音频。"
            case .jobCreated:
                return "已仅写入不含音频/文本的任务清单；真实转写与录音将在正式功能中接入。"
            }
        }
    }

    @Published var isPresented = false
    @Published private(set) var storageState: StorageState = .notConfigured
    @Published var selectedMode: TaskMode = .file
    @Published var speakerMode: SpeakerMode = .singleSpeaker
    @Published private(set) var selectedInputName: String?
    @Published private(set) var selectedInputURL: URL?
    @Published private(set) var dualTrackLocalURL: URL?
    @Published private(set) var dualTrackRemoteURL: URL?

    var selectedDualTracks: (local: URL, remote: URL)? {
        guard let local = dualTrackLocalURL, let remote = dualTrackRemoteURL else { return nil }
        return (local, remote)
    }
    @Published private(set) var previewState: PreviewState = .idle
    @Published private(set) var lastJobLocation: String?
    @Published var message: String?

    private let defaults = UserDefaults.standard
    private let bookmarkKey = "Hermeneus.OfflineTools.StorageBookmark"
    private let displayPathKey = "Hermeneus.OfflineTools.StorageDisplayPath"
    private var storageURL: URL?

    var verifiedStorageURL: URL? {
        storageState.isReady ? storageURL : nil
    }

    func setMessage(_ value: String) { message = value }

    init() {
        restoreStorageLocation()
    }

    func chooseStorageLocation() {
        let panel = NSOpenPanel()
        panel.title = "选择 Hermeneus 数据目录（建议使用加密卷）"
        panel.message = "录音、转译检查点、字幕和导出文件都将保存在此目录。"
        panel.prompt = "使用此目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            configureStorage(url)
        }
    }

    func clearSelectedInput() {
        selectedInputURL = nil
        selectedInputName = nil
        clearDualTracks()
        speakerMode = .singleSpeaker
    }
    func useRecordedRemoteTrack(_ url: URL) {
        clearDualTracks()
        selectedInputURL = url
        selectedInputName = url.lastPathComponent
        speakerMode = .singleSpeaker
        selectedMode = .file
    }

    func useRecordedDualTracks(_ artifact: OfflineRecordingArtifact) {
        guard let local = artifact.localURL, let remote = artifact.remoteURL else {
            message = "该录音缺少我方或对方音轨，无法启动双人说话转译。"
            return
        }
        dualTrackLocalURL = local
        dualTrackRemoteURL = remote
        selectedInputURL = remote
        selectedInputName = "双方录音：对方说 + 我说"
        speakerMode = .dualSpeaker
        selectedMode = .file
        message = "已选择双方双轨录音。对方说和我说将按各自音轨识别、翻译并标注。"
    }

    private func clearDualTracks() {
        dualTrackLocalURL = nil
        dualTrackRemoteURL = nil
    }

    private func detectSiblingDualTracks(for url: URL) {
        let directory = url.deletingLastPathComponent()
        let local = directory.appendingPathComponent("local.wav")
        let remote = directory.appendingPathComponent("remote.wav")
        guard FileManager.default.fileExists(atPath: local.path),
              FileManager.default.fileExists(atPath: remote.path)
        else {
            clearDualTracks()
            return
        }
        dualTrackLocalURL = local
        dualTrackRemoteURL = remote
    }

    func chooseInputFile() {
        let panel = NSOpenPanel()
        panel.title = "选择本地 MP3、M4A、WAV 或 MP4 文件"
        panel.message = "仅选择本机已有文件；不接受 URL，不会上传内容。"
        panel.prompt = "选择文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie]
        if panel.runModal() == .OK, let url = panel.url {
            _ = selectLocalInputFile(url)
        }
    }

    /// 文件选择器和拖放入口共用同一套输入边界，拒绝 URL 文本、目录与未支持的扩展名。
    @discardableResult
    func selectLocalInputFile(_ url: URL) -> Bool {
        let supportedExtensions: Set<String> = ["mp3", "m4a", "wav", "mp4"]
        let fileExtension = url.pathExtension.lowercased()
        guard url.isFileURL,
              !url.hasDirectoryPath,
              supportedExtensions.contains(fileExtension),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else {
            message = "仅支持拖入或选择本机已有的 MP3、M4A、WAV、MP4 文件；不接受链接、网页音频或文件夹。"
            return false
        }
        selectedInputURL = url
        selectedInputName = url.lastPathComponent
        detectSiblingDualTracks(for: url)
        previewState = .idle
        message = "已选择 \(url.lastPathComponent)。可在下方开始完全本地的转译。"
        return true
    }

    func prepareRecordingExperience() {
        guard storageState.isReady else {
            message = "请先选择存储目录并确认可写。"
            return
        }
        selectedMode = .recording
        previewState = .recordingReady
        message = "录音已准备就绪。"
    }

    func createPreviewJob() {
        guard let root = storageURL, storageState.isReady else {
            message = "请先选择存储目录并确认可写。"
            return
        }
        if selectedMode == .file, selectedInputName == nil {
            message = "请先选择一个本地音频或视频文件。"
            return
        }

        let jobID = UUID().uuidString.lowercased()
        let jobURL = root
            .appendingPathComponent("Hermeneus Data", isDirectory: true)
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(jobID, isDirectory: true)
        let manifestURL = jobURL.appendingPathComponent("prototype-job.json")
        let manifest: [String: Any] = [
            "schema_version": 1,
            "kind": "offline-tools-preview",
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "mode": selectedMode.rawValue,
            "speaker_strategy": speakerMode.rawValue,
            "input_file_name": selectedInputName ?? NSNull(),
            "contains_audio": false,
            "contains_transcript": false,
            "contains_translation": false,
            "network_used": false,
            "note": "仅验证存储与任务结构；不录音、不转写、不翻译。"
        ]

        do {
            try FileManager.default.createDirectory(at: jobURL, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: manifestURL, options: [.atomic])
            previewState = .jobCreated
            lastJobLocation = manifestURL.path
            message = "已在您选择的目录创建示例任务清单，不含任何音频、原文或译文。"
        } catch {
            storageState = .unavailable(message: "无法写入所选目录：\(error.localizedDescription)")
            message = "未创建任务。请检查存储目录是否仍已挂载且可写。"
        }
    }

    func clearPrototypeState() {
        selectedInputURL = nil
        selectedInputName = nil
        previewState = .idle
        lastJobLocation = nil
        message = "已清除当前选择；不会删除任何文件。"
    }

    private func restoreStorageLocation() {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else {
            storageState = .notConfigured
            return
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                storageState = .unavailable(message: "存储目录授权已失效，请重新选择目录。")
                return
            }
            configureStorage(url, persistBookmark: false)
        } catch {
            storageState = .unavailable(message: "无法恢复存储目录，请重新选择。")
        }
    }

    private func configureStorage(_ url: URL, persistBookmark: Bool = true) {
        let gainedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if gainedAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw NSError(domain: "HermeneusStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "所选位置不是可用文件夹"])
            }
            let testURL = standardized.appendingPathComponent(".hermeneus-write-test-\(UUID().uuidString)")
            try Data("Hermeneus storage check".utf8).write(to: testURL, options: [.atomic])
            try FileManager.default.removeItem(at: testURL)

            if persistBookmark {
                let bookmark = try standardized.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                defaults.set(bookmark, forKey: bookmarkKey)
                defaults.set(standardized.path, forKey: displayPathKey)
            }
            storageURL = standardized
            storageState = .ready(path: standardized.path)
            message = "存储目录可写。应用未验证磁盘加密，请确认敏感录音保存在已加密的卷上。"
        } catch {
            storageURL = nil
            storageState = .unavailable(message: "目录不可用：\(error.localizedDescription)")
            message = "未保存该目录，也不会写入任何回退位置。"
        }
    }
}

private final class RecordingResultState: ObservableObject {
    @Published var latestRecording: OfflineRecordingArtifact?
    @Published var isPreparingPlayback = false
}

struct OfflineToolsPrototypeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var orchestrator: PipelineOrchestrator
    @ObservedObject var controller: OfflineToolsPrototypeController
    @ObservedObject var meetingRecorder: LiveMeetingDualTrackRecorder
    @StateObject private var recorder = OfflineDualTrackRecorder()
    @StateObject private var batchRunner = OfflineBatchRunner()
    @StateObject private var recordingResult = RecordingResultState()

    /// 同传会话可以保持打开，但只有任一实时采集逻辑开启时，批量转译才会竞争资源。
    private var realtimeCaptureIsActive: Bool {
        orchestrator.isListeningRemote || orchestrator.isSpeakingLocal
    }

    /// 会议录音仍需要依附已启动的实时会话，不能与独立录音器并存。
    private var realtimeSessionIsOpen: Bool {
        orchestrator.isRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) { Divider().opacity(0.22) }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    storageCard
                    workflowCard
                    footer
                }
                .padding(20)
                .frame(minWidth: 640, idealWidth: 740, maxWidth: 860, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: realtimeCaptureIsActive) { _, isActive in
            guard isActive else { return }
            if batchRunner.isRunning { batchRunner.cancel() }
            if recorder.isRecording {
                Task { _ = try? await recorder.stop() }
            }
        }
        .alert("离线工具提示", isPresented: Binding(
            get: { controller.message != nil },
            set: { if !$0 { controller.message = nil } }
        )) {
            Button("好", role: .cancel) { controller.message = nil }
        } message: {
            Text(controller.message ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.cyan)
            Text("离线工具")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: controller.storageState.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(controller.storageState.isReady ? .green : .orange)
                Text(controller.storageState.isReady ? "存储目录可写" : "请选择存储目录")
                    .foregroundStyle(.primary)
            }
            .font(.system(size: 11, weight: .medium))
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("关闭离线工具")
        }
        .padding(.bottom, 2)
    }

    private var storageCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(controller.storageState.isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("存储位置（建议选择加密卷）")
                    .font(.system(size: 12, weight: .semibold))
                Text(controller.storageState.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("更改位置…") { controller.chooseStorageLocation() }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("录音")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            if realtimeSessionIsOpen {
                liveMeetingRecordingControls
            } else {
                recordingControls
            }

            if recordingResult.latestRecording != nil {
                recordingResultCard
            }

            Divider().opacity(0.35)
            importedFileTranslationCard
        }
    }

    @ViewBuilder
    private var recordingResultCard: some View {
        if let artifact = recordingResult.latestRecording {
            VStack(alignment: .leading, spacing: 8) {
                Label("最近一次双轨录音", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([artifact.directoryURL])
                    }
                    if recordingResult.isPreparingPlayback {
                        ProgressView().controlSize(.small)
                        Text("正在准备优化回放版…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        if let local = artifact.localURL {
                            Button("播放我方音轨") { openPlayback(for: local) }
                        }
                        if let remote = artifact.remoteURL {
                            Button("播放对方音轨") { openPlayback(for: remote) }
                            Button("转译对方说") {
                                controller.useRecordedRemoteTrack(remote)
                            }
                            .disabled(realtimeCaptureIsActive)
                        }
                        if artifact.localURL != nil, artifact.remoteURL != nil {
                            Button("转译双方录音") {
                                controller.useRecordedDualTracks(artifact)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(realtimeCaptureIsActive)
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(11)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var importedFileTranslationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("导入本地文件转译", systemImage: "doc.badge.gearshape")
                .font(.headline)
            Text("支持本机已有的 MP3、M4A、WAV 与 MP4。链接或网页音频不作为输入；文件不会上传。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.selectedInputName ?? "将 MP3、M4A、WAV 或 MP4 拖到这里")
                            .font(.system(size: 12, weight: controller.selectedInputURL == nil ? .regular : .medium))
                            .lineLimit(1)
                        Text(controller.selectedInputURL == nil ? "仅接收本机文件；拖入只选中文件，需由您确认开始转译。" : "已选择；转写、译文和字幕只写入所选目录。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "tray.and.arrow.down.fill")
                        .foregroundStyle(.blue)
                }
                HStack {
                    Button("选择本地文件…") { controller.chooseInputFile() }
                    if controller.selectedInputURL != nil {
                        Button("清除") { controller.clearSelectedInput() }
                    }
                    Spacer()
                    Text("或直接拖入文件")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.blue.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleFileDrop)
            Picker("说话模式", selection: $controller.speakerMode) {
                ForEach(OfflineToolsPrototypeController.SpeakerMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            if controller.speakerMode == .dualSpeaker {
                VStack(alignment: .leading, spacing: 5) {
                    if controller.selectedDualTracks != nil {
                        HStack(spacing: 14) {
                            Label("对方说 (系统音源)", systemImage: "headphones")
                                .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 1.0))
                            Label("我说 (麦克风 → BlackHole)", systemImage: "mic.fill")
                                .foregroundStyle(.yellow)
                        }
                        .font(.system(size: 11, weight: .semibold))
                    } else {
                        Label("离线分离说话人 A / B · 无需账号", systemImage: "person.2.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
            }

            if realtimeCaptureIsActive {
                Label("请先关闭实时采集", systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            } else if realtimeSessionIsOpen {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("实时采集已暂停")
                        .foregroundStyle(.primary)
                }
                .font(.system(size: 11, weight: .medium))
            }
            batchControls
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func preparePlayback(for artifact: OfflineRecordingArtifact) {
        recordingResult.latestRecording = artifact
        recordingResult.isPreparingPlayback = true
        let resultState = recordingResult
        let tracks = [artifact.localURL, artifact.remoteURL].compactMap { $0 }
        Task.detached(priority: .utility) {
            let succeeded = tracks.map { track in
                (try? PlaybackAudioOptimizer.createOptimizedCopy(from: track)) != nil
            }.allSatisfy { $0 }
            await MainActor.run {
                resultState.isPreparingPlayback = false
                if !succeeded {
                    controller.setMessage("录音已保存，但未能生成全部增强回放副本；仍可在访达中打开原始音轨。")
                }
            }
        }
    }

    private func openPlayback(for originalURL: URL) {
        let optimizedURL = PlaybackAudioOptimizer.outputURL(for: originalURL)
        let target = FileManager.default.fileExists(atPath: optimizedURL.path) ? optimizedURL : originalURL
        NSWorkspace.shared.open(target)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else {
            controller.setMessage("没有检测到可导入的本地文件。")
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            let url: URL?
            if let directURL = item as? URL {
                url = directURL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            Task { @MainActor in
                guard error == nil, let url else {
                    controller.setMessage("无法读取拖入的文件。请拖入本机 MP3、M4A、WAV 或 MP4 文件。")
                    return
                }
                _ = controller.selectLocalInputFile(url)
            }
        }
        return true
    }

    private var batchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(batchRunner.state.description)
                .font(.system(size: 12, weight: .medium))
            Text(batchRunner.statusMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if batchRunner.isRunning {
                ProgressView(value: Double(batchRunner.completedSegments)) {
                    Text("已完成 \(batchRunner.completedSegments) 个字幕片段")
                        .font(.system(size: 10))
                }
            }
            HStack {
                Button(batchRunner.isRunning ? "取消并保留检查点" : "开始本地转译") {
                    if batchRunner.isRunning { batchRunner.cancel() } else { startBatchTranslation() }
                }
                .buttonStyle(.borderedProminent)
                .tint(batchRunner.isRunning ? .orange : .blue)
                .disabled(realtimeCaptureIsActive || !controller.storageState.isReady || (!batchRunner.isRunning && controller.selectedInputURL == nil))
                if let exports = batchRunner.exportDirectory {
                    Button("在 Finder 中显示导出") { NSWorkspace.shared.open(exports) }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
    }

    private func startBatchTranslation() {
        guard !realtimeCaptureIsActive else {
            controller.setMessage("实时采集仍开启。请先关闭“听对方”和“我的麦克风”，以保护对方说话优先。")
            return
        }
        guard let input = controller.selectedInputURL, let root = controller.verifiedStorageURL else {
            controller.setMessage("请先选择文件与存储目录（建议使用加密卷）。")
            return
        }
        do {
            let dualTracks = controller.speakerMode == .dualSpeaker ? controller.selectedDualTracks : nil
            let useAnonymousDiarization = controller.speakerMode == .dualSpeaker && dualTracks == nil
            if useAnonymousDiarization {
                let confirmation = NSAlert()
                confirmation.messageText = "启用离线说话人分离？"
                confirmation.informativeText = "首次使用会从官方公开来源下载约 47 MB 模型，随后可断网使用。无需注册账号，录音不会上传。模型采用 MIT / Apache 2.0 许可，详情见应用随附说明。"
                confirmation.addButton(withTitle: "确认并开始")
                confirmation.addButton(withTitle: "取消")
                guard confirmation.runModal() == .alertFirstButtonReturn else { return }
            }
            try batchRunner.start(
                inputURL: input,
                secureRoot: root,
                modelName: UserDefaults.standard.string(forKey: "Hermeneus.OllamaModelName") ?? "qwen2.5:3b",
                diarization: useAnonymousDiarization,
                dualTracks: dualTracks
            )
        } catch {
            controller.setMessage("无法启动本地转译：\(error.localizedDescription)")
        }
    }

    private var liveMeetingRecordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meetingRecorder.isRecording ? "正在录音  \(format(meetingRecorder.elapsedSeconds))" : "会议录音")
                .font(.system(size: 12, weight: .medium))
            Text(meetingRecorder.statusMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack {
                Button(meetingRecorder.isRecording ? "停止并安全保存会议录音" : "开始会议双轨录音") {
                    Task { await toggleLiveMeetingRecording() }
                }
                .buttonStyle(.borderedProminent)
                .tint(meetingRecorder.isRecording ? .red : .teal)
                .disabled(!controller.storageState.isReady)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
    }

    private func toggleLiveMeetingRecording() async {
        do {
            if meetingRecorder.isRecording {
                let artifact = try orchestrator.stopMeetingRecording()
                preparePlayback(for: artifact)
                controller.setMessage("会议录音已保存。可在“最近一次双轨录音”中直接打开文件夹或播放音轨。")
            } else if let root = controller.verifiedStorageURL {
                try orchestrator.startMeetingRecording(in: root)
                controller.setMessage("已开始会议双轨录音；同传与对方优先策略保持运行。")
            } else {
                controller.setMessage("请先选择存储目录并确认可写。")
            }
        } catch {
            controller.setMessage("会议录音未能开始或保存：\(error.localizedDescription)")
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recorder.isRecording ? "正在录音  \(format(recorder.elapsedSeconds))" : "双轨录音")
                .font(.system(size: 12, weight: .medium))
            Text(recorder.statusMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack {
                Button(recorder.isRecording ? "停止并安全保存" : "开始双轨录音") {
                    Task { await toggleRecording() }
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .teal)
                .disabled(realtimeSessionIsOpen || !controller.storageState.isReady)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
    }

    private func toggleRecording() async {
        do {
            if recorder.isRecording {
                let artifact = try await recorder.stop()
                preparePlayback(for: artifact)
                controller.setMessage("双轨录音已保存。可在“最近一次双轨录音”中打开文件夹、播放音轨或选择对方音轨转译。")
            } else if let root = controller.verifiedStorageURL {
                try await recorder.start(in: root)
                controller.setMessage("已开始双轨录音。请在状态栏确认麦克风和系统音频权限。")
            } else {
                controller.setMessage("请先选择存储目录并确认可写。")
            }
        } catch {
            controller.setMessage("录音未能开始或保存：\(error.localizedDescription)")
        }
    }

    private func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("安全与功能边界", systemImage: "checkmark.shield")
                .font(.headline)
            Text("已实现：目录选择、书签保存、可写性测试、会议同传期间的旁路双轨录音、独立离线双轨录音、MP3/MP4 批量转写、Ollama 翻译与字幕导出。批量转译仍与同传互斥；失败任务在所选目录保留检查点；应用未验证磁盘加密。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        Label("仅保存在所选目录；应用未验证磁盘加密", systemImage: "lock.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}
