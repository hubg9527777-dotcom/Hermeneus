import Foundation
import Combine
import AVFoundation
import AudioCore
import VADKit
import ASRKit
import TranslateKit
import TTSKit

public actor MicAudioBuffer {
    private var buffer: [Float] = []
    public init() {}
    public func append(pcm: [Float]) { buffer.append(contentsOf: pcm) }
    public func flush() -> [Float] {
        let current = buffer
        buffer.removeAll()
        return current
    }
}

public protocol VoiceActivityDetecting {
    mutating func isSpeech(pcm: [Float]) -> Bool
}

public struct AdaptiveEnergyDetector: VoiceActivityDetecting {
    private var noiseFloor: Float
    private let noiseFloorAdaptRate: Float
    private let enterMultiplier: Float
    private let holdMultiplier: Float
    private let minEnterThreshold: Float
    private let minHoldThreshold: Float
    private var wasSpeech = false
    
    public init(
        initialNoiseFloor: Float = 0.0015,
        noiseFloorAdaptRate: Float = 0.05,
        enterMultiplier: Float = 2.2,
        holdMultiplier: Float = 1.4,
        minEnterThreshold: Float = 0.0025,
        minHoldThreshold: Float = 0.0015
    ) {
        self.noiseFloor = initialNoiseFloor
        self.noiseFloorAdaptRate = noiseFloorAdaptRate
        self.enterMultiplier = enterMultiplier
        self.holdMultiplier = holdMultiplier
        self.minEnterThreshold = minEnterThreshold
        self.minHoldThreshold = minHoldThreshold
    }
    
    public mutating func isSpeech(pcm: [Float]) -> Bool {
        guard !pcm.isEmpty else { return false }
        let sumSq = pcm.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumSq / Float(pcm.count))
        let enterThreshold = max(noiseFloor * enterMultiplier, minEnterThreshold)
        let holdThreshold = max(noiseFloor * holdMultiplier, minHoldThreshold)
        let speech = wasSpeech ? (rms > holdThreshold) : (rms > enterThreshold)
        if !speech {
            noiseFloor = noiseFloor * (1 - noiseFloorAdaptRate) + rms * noiseFloorAdaptRate
        }
        wasSpeech = speech
        return speech
    }
}

public actor ContinuousStreamSegmenter {
    private var buffer: [Float] = []
    private var silenceMs: Double = 0
    private let sampleRate: Int
    private var detector: VoiceActivityDetecting
    private let maxBufferSeconds: Double
    private let minChunkSeconds: Double
    private let quickSilenceMs: Double
    private let conservativeSilenceMs: Double
    private let quickSilenceMinBufferSeconds: Double
    
    public init(
        sampleRate: Int,
        detector: VoiceActivityDetecting = AdaptiveEnergyDetector(),
        maxBufferSeconds: Double = 8.0,
        minChunkSeconds: Double = 0.8,
        quickSilenceMs: Double = 700,
        conservativeSilenceMs: Double = 1200,
        quickSilenceMinBufferSeconds: Double = 1.2
    ) {
        self.sampleRate = sampleRate
        self.detector = detector
        self.maxBufferSeconds = maxBufferSeconds
        self.minChunkSeconds = minChunkSeconds
        self.quickSilenceMs = quickSilenceMs
        self.conservativeSilenceMs = conservativeSilenceMs
        self.quickSilenceMinBufferSeconds = quickSilenceMinBufferSeconds
    }
    
    public func feed(pcm: [Float]) -> [Float]? {
        guard !pcm.isEmpty else { return nil }
        let frameMs = Double(pcm.count) / Double(sampleRate) * 1000.0
        if detector.isSpeech(pcm: pcm) {
            silenceMs = 0
            buffer.append(contentsOf: pcm)
            if buffer.count >= Int(Double(sampleRate) * maxBufferSeconds) {
                return flushBuffer()
            }
        } else {
            guard !buffer.isEmpty else { return nil }
            silenceMs += frameMs
            buffer.append(contentsOf: pcm)
            let bufferedSeconds = Double(buffer.count) / Double(sampleRate)
            let requiredSilenceMs = bufferedSeconds >= quickSilenceMinBufferSeconds
                ? quickSilenceMs
                : conservativeSilenceMs
            if silenceMs >= requiredSilenceMs {
                silenceMs = 0
                if bufferedSeconds >= minChunkSeconds {
                    return flushBuffer()
                } else {
                    buffer.removeAll()
                }
            }
        }
        return nil
    }

    /// True from the first speech frame until VAD flushes or discards the utterance.
    /// The automatic streaming controllers use this only for session lifecycle;
    /// the existing feed() result remains the authoritative VAD final boundary.
    public func hasActiveUtterance() -> Bool {
        !buffer.isEmpty
    }

    /// Discard an unfinished automatic utterance when the user explicitly
    /// takes over with push-to-talk. No mixed automatic/PTT sentence reaches ASR.
    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        silenceMs = 0
    }

    private func flushBuffer() -> [Float] {
        let chunk = buffer
        buffer.removeAll()
        silenceMs = 0
        return chunk
    }
}

public enum PipelineState: Equatable, Sendable {
    case idle
    case listening
    case previewing
    case finalizing
    case deferredForRemote
    case failed(String)

    public var label: String {
        switch self {
        case .idle: return "就绪"
        case .listening: return "监听中"
        case .previewing: return "实时预览"
        case .finalizing: return "生成最终译文"
        case .deferredForRemote: return "对方优先中 · 本方暂缓"
        case .failed(let message): return message
        }
    }

    public var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

public struct DialogueTurn: Identifiable, Equatable {
    public var timestamp: Date = Date()
    public let id = UUID()
    public var sourceText: String
    public var translatedText: String
    public var isTranslationFinal: Bool = false
    public var isSourcePartial: Bool = false
    public var isTranslationPreview: Bool {
        !translatedText.isEmpty && !isTranslationFinal
    }
}

@MainActor
public final class RollingTextBuffer: ObservableObject {
    @Published public private(set) var turns: [DialogueTurn] = []
    private let maxTurns: Int
    
    public init(maxTurns: Int = 3) {
        self.maxTurns = maxTurns
    }
    
    @discardableResult
    public func beginTurn(sourceText: String, isPartial: Bool = false) -> UUID? {
        if let last = turns.last, Self.isNearDuplicate(last.sourceText, sourceText) {
            return nil
        }
        let turn = DialogueTurn(sourceText: sourceText, translatedText: "", isSourcePartial: isPartial)
        turns.append(turn)
        trimIfNeeded()
        return turn.id
    }
    
    public func updateActivePartialTurn(sourceText: String) -> UUID {
        if let last = turns.last, last.isSourcePartial, !last.isTranslationFinal {
            turns[turns.count - 1].sourceText = sourceText
            return last.id
        }
        let turn = DialogueTurn(sourceText: sourceText, translatedText: "", isSourcePartial: true)
        turns.append(turn)
        trimIfNeeded()
        return turn.id
    }
    
    public func finalizeSourceText(turnId: UUID, finalText: String) {
        guard let idx = turns.firstIndex(where: { $0.id == turnId }) else { return }
        turns[idx].sourceText = finalText
        turns[idx].isSourcePartial = false
    }
    
    public func appendTranslationDelta(turnId: UUID, token: String) {
        guard let idx = turns.firstIndex(where: { $0.id == turnId }) else { return }
        turns[idx].translatedText += token
    }
    
    public func finalizeTranslation(turnId: UUID, fullText: String? = nil) {
        guard let idx = turns.firstIndex(where: { $0.id == turnId }) else { return }
        if let fullText, !fullText.isEmpty {
            turns[idx].translatedText = fullText
        }
        turns[idx].isTranslationFinal = true
    }
    
    public func updateSourceText(turnId: UUID, newText: String) {
        if let idx = turns.firstIndex(where: { $0.id == turnId }) {
            turns[idx].sourceText = newText
        }
    }
    
    public func updateTranslatedText(turnId: UUID, newText: String) {
        if let idx = turns.firstIndex(where: { $0.id == turnId }) {
            turns[idx].translatedText = newText
        }
    }
    
    public func reset() {
        turns.removeAll()
    }
    
    public var joinedSourceText: String {
        turns.map(\.sourceText).joined(separator: "，")
    }
    
    public var joinedTranslatedText: String {
        turns.map(\.translatedText).joined(separator: " ")
    }
    
    private func trimIfNeeded() {
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }
    
    private static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        guard !shorter.isEmpty else { return false }
        return longer.contains(shorter) && Double(shorter.count) / Double(longer.count) > 0.85
    }
}

private actor SegmentProcessingQueue {
    private var pending: [Segment] = []
    private var isProcessing = false
    private let maxQueueDepth: Int
    private let handler: (Segment) async -> Void
    
    init(maxQueueDepth: Int = 2, handler: @escaping (Segment) async -> Void) {
        self.maxQueueDepth = maxQueueDepth
        self.handler = handler
    }
    
    func enqueue(_ segment: Segment) {
        pending.append(segment)
        if pending.count > maxQueueDepth {
            pending.removeFirst(pending.count - maxQueueDepth)
        }
        if !isProcessing {
            Task { await drain() }
        }
    }
    
    private func drain() async {
        guard !isProcessing else { return }
        isProcessing = true
        while !pending.isEmpty {
            let seg = pending.removeFirst()
            await handler(seg)
        }
        isProcessing = false
    }
}

public enum LocalInputMode: String, Sendable {
    case automaticVAD
    case pushToTalk
}

/// The persistent user-selected mode stays separate from the short-lived
/// capture condition inside it. This makes manual override in automatic mode
/// deterministic without switching the top-level mode.
private enum LocalCaptureState {
    case automaticListening
    case manualPressed
    case manualFinalizing
    case pushToTalkIdle
}

@MainActor
private final class PushToTalkController {
    private let asrEngine: WebSocketASREngine
    private var activeSession: WebSocketStreamingSession?
    private var consumeTask: Task<Void, Never>?
    private var isPressedState = false
    private var finishWhenReady = false
    private var pendingFrames: [(pcm: [Float], sampleRate: Int)] = []
    
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    
    init(asrEngine: WebSocketASREngine) {
        self.asrEngine = asrEngine
    }
    
    var isPressed: Bool { isPressedState }
    
    /// In automatic mode the previous streaming session needs a brief window
    /// to release the local ASR slot. Capture frames during that window so the
    /// first syllables of an explicit PTT utterance are never lost.
    func press(language: String, sessionStartDelayNs: UInt64 = 0) {
        guard !isPressedState else { return }
        isPressedState = true
        finishWhenReady = false
        pendingFrames.removeAll(keepingCapacity: true)
        consumeTask = Task {
            if sessionStartDelayNs > 0 {
                try? await Task.sleep(nanoseconds: sessionStartDelayNs)
            }
            guard !Task.isCancelled, self.isPressedState || self.finishWhenReady else { return }
            do {
                let session = try await asrEngine.startStreamingSession(language: language)
                self.activeSession = session
                let bufferedFrames = self.pendingFrames
                self.pendingFrames.removeAll(keepingCapacity: true)
                for frame in bufferedFrames {
                    await session.feed(pcm: frame.pcm, sampleRate: frame.sampleRate)
                }
                if self.finishWhenReady {
                    await session.finish()
                }
                for try await update in session.updates {
                    switch update {
                    case .partial(let text, _):
                        self.onPartial?(text)
                    case .final(let text, _):
                        self.onFinal?(text)
                    }
                }
            } catch is CancellationError {
                // A canceled PTT turn is intentionally silent.
            } catch {
                print("⚠️ [PTT] 流式会话异常: \(error)")
            }
            self.activeSession = nil
            self.pendingFrames.removeAll(keepingCapacity: true)
            self.finishWhenReady = false
            self.isPressedState = false
        }
    }
    
    func feed(pcm: [Float], sampleRate: Int) {
        guard isPressedState, !pcm.isEmpty else { return }
        if let session = activeSession {
            Task { await session.feed(pcm: pcm, sampleRate: sampleRate) }
            return
        }
        pendingFrames.append((pcm: pcm, sampleRate: sampleRate))
        if pendingFrames.count > 48 {
            pendingFrames.removeFirst(pendingFrames.count - 48)
        }
    }
    
    func release() {
        guard isPressedState else { return }
        isPressedState = false
        finishWhenReady = true
        guard let session = activeSession else { return }
        Task { await session.finish() }
    }
    
    func cancelActive() {
        isPressedState = false
        finishWhenReady = false
        pendingFrames.removeAll(keepingCapacity: true)
        consumeTask?.cancel()
        guard let session = activeSession else { return }
        Task { await session.cancel() }
        activeSession = nil
    }
}

@MainActor
private final class AutomaticStreamingController {
    private let asrEngine: WebSocketASREngine
    private var activeSession: WebSocketStreamingSession?
    private var consumeTask: Task<Void, Never>?
    private var pendingFrames: [(pcm: [Float], sampleRate: Int)] = []
    private var isActive = false
    private var finishRequested = false

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    init(asrEngine: WebSocketASREngine) {
        self.asrEngine = asrEngine
    }

    func begin(language: String) {
        guard !isActive else { return }
        isActive = true
        finishRequested = false
        consumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.asrEngine.startStreamingSession(language: language)
                guard self.isActive else {
                    await session.cancel()
                    return
                }
                self.activeSession = session
                let bufferedFrames = self.pendingFrames
                self.pendingFrames.removeAll(keepingCapacity: true)
                for frame in bufferedFrames {
                    await session.feed(pcm: frame.pcm, sampleRate: frame.sampleRate)
                }
                if self.finishRequested {
                    await session.finish()
                }
                for try await update in session.updates {
                    guard !Task.isCancelled else { break }
                    switch update {
                    case .partial(let text, _):
                        self.onPartial?(text)
                    case .final(let text, _):
                        self.onFinal?(text)
                    }
                }
            } catch is CancellationError {
                // Cancellation is the normal response to stop/reset.
            } catch {
                print("⚠️ [AutoStream] 会话异常: \(error)")
            }
            self.activeSession = nil
            self.pendingFrames.removeAll(keepingCapacity: true)
            self.isActive = false
            self.finishRequested = false
        }
    }

    func feed(pcm: [Float], sampleRate: Int) {
        guard isActive, !finishRequested, !pcm.isEmpty else { return }
        if let activeSession {
            Task { await activeSession.feed(pcm: pcm, sampleRate: sampleRate) }
            return
        }
        // Preserve only the short connection-start gap. This caps the extra
        // memory while retaining the beginning of a short utterance.
        pendingFrames.append((pcm: pcm, sampleRate: sampleRate))
        if pendingFrames.count > 12 {
            pendingFrames.removeFirst(pendingFrames.count - 12)
        }
    }

    func finish() {
        guard isActive else { return }
        finishRequested = true
        guard let activeSession else { return }
        Task { await activeSession.finish() }
    }

    func cancelActive() {
        isActive = false
        finishRequested = false
        pendingFrames.removeAll(keepingCapacity: true)
        consumeTask?.cancel()
        guard let activeSession else { return }
        Task { await activeSession.cancel() }
        self.activeSession = nil
    }
}

@MainActor
public final class PipelineOrchestrator: ObservableObject {
    @Published public var isListeningRemote: Bool = true
    @Published public var isSpeakingLocal: Bool = true
    public let remoteBuffer = RollingTextBuffer(maxTurns: 9999)
    public let localBuffer = RollingTextBuffer(maxTurns: 9999)
    @Published public var isRunning: Bool = false
    @Published public private(set) var startupError: String?
    private var systemAudioLoop: Task<Void, Never>?
    private var microphoneLoop: Task<Void, Never>?
    private var sessionGeneration = UUID()
    @Published public var latencyMs: Int = 0
    @Published public var isTTSPlaying: Bool = false
    @Published public private(set) var remotePipelineState: PipelineState = .idle
    @Published public private(set) var localPipelineState: PipelineState = .idle
    private var cancellables = Set<AnyCancellable>()
    @Published public var editingTurnId: UUID? = nil
    @Published public var editingSourceText: String = ""
    @Published public var editingTransText: String = ""
    @Published public var localInputMode: LocalInputMode = .automaticVAD
    @Published public var isPTTPressed: Bool = false
    
    private let systemCapturer = SCKAudioCapturer()
    private let micCapturer = MicrophoneCapturer()
    /// Optional meeting recorder mirrors existing capture streams. It never owns or replaces ASR capture.
    let meetingRecorder = LiveMeetingDualTrackRecorder()
    private let asr = WebSocketASREngine()
    private let contextEngine = ConversationContextEngine()
    private lazy var translator = OllamaTranslationEngine(
        onTermCorrectionExtracted: { [contextEngine] original, corrected in
            Task {
                await contextEngine.registerTermCorrection(original: original, corrected: corrected)
            }
        },
        contextPromptProvider: { [contextEngine] text in
            await contextEngine.generateContextPrompt(for: text)
        }
    )
    let tts = BlackHoleTTSEngine()
    var speechOutputLabel: String {
        let uid = tts.selectedDeviceUID
        if uid == AudioOutputDevice.systemDefault { return "本机播放" }
        return AudioOutputDevice.available().first(where: { $0.id == uid })?.name ?? "设备已断开"
    }
    private var scheduler: ClauseSpeechScheduler?
    private let micBufferActor = MicAudioBuffer()
    private let remoteSegmenter = ContinuousStreamSegmenter(sampleRate: 48000)
    // Local speech may be repeated, so use a faster final boundary without
    // changing the protected remote Spanish channel's conservative timing.
    private let localSegmenter = ContinuousStreamSegmenter(
        sampleRate: 48000,
        minChunkSeconds: 0.55,
        quickSilenceMs: 450,
        conservativeSilenceMs: 650,
        quickSilenceMinBufferSeconds: 0.9
    )
    
    private lazy var remoteQueue = SegmentProcessingQueue(maxQueueDepth: 2) { [weak self] seg in
        await self?.processRemoteSegment(seg)
    }
    private lazy var localQueue = SegmentProcessingQueue(maxQueueDepth: 2) { [weak self] seg in
        await self?.processLocalSegmentAutoVAD(seg)
    }
    
    // One local streaming controller owns every Chinese turn. The top-level
    // mode decides how a turn begins; it never creates a competing ASR session.
    private lazy var localStreamController: AutomaticStreamingController = {
        let controller = AutomaticStreamingController(asrEngine: asr)
        controller.onPartial = { [weak self] text in
            guard let self else { return }
            if self.localCaptureState == .manualPressed || self.localCaptureState == .manualFinalizing {
                self.handlePTTPartial(text)
            } else {
                self.handleLocalAutoPartial(text)
            }
        }
        controller.onFinal = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                if self.localCaptureState == .manualPressed || self.localCaptureState == .manualFinalizing {
                    await self.handlePTTFinal(text)
                    self.completeManualTurn()
                } else {
                    await self.handleLocalAutoFinal(text)
                }
            }
        }
        return controller
    }()
    private var localCaptureState: LocalCaptureState = .automaticListening
    private var pttActiveTurnId: UUID?
    private var localAutoTurnId: UUID?
    private var localPreviewTask: Task<Void, Never>?
    private var localPreviewGeneration: UInt = 0
    private var localPreviewSource = ""

    private lazy var remoteAutoController: AutomaticStreamingController = {
        let controller = AutomaticStreamingController(asrEngine: asr)
        controller.onPartial = { [weak self] text in
            self?.handleRemoteAutoPartial(text)
        }
        controller.onFinal = { [weak self] text in
            Task { @MainActor in
                await self?.handleRemoteAutoFinal(text)
            }
        }
        return controller
    }()
    private var remoteAutoTurnId: UUID?
    private var remotePreviewTask: Task<Void, Never>?
    private var remotePreviewGeneration: UInt = 0
    private var remotePreviewSource = ""

    // Final translations must never compete with low-value preview work. A
    // single counter covers both directions because they share one local Ollama.
    private var finalTranslationInFlightCount = 0

    // Product policy: protect the other speaker first. While a Spanish remote
    // utterance is active or its final translation is pending, local work may
    // be safely repeated and is therefore deferred rather than competing.
    private var isRemotePriorityActive = false

    // Rendering every model token can saturate SwiftUI animations during long
    // responses. Coalesce non-final updates to approximately 30 FPS.
    private var uiRefreshPending = false
    private let uiRefreshIntervalNs: UInt64 = 33_000_000
    
    public init() {
        let ttsEngine = self.tts
        self.scheduler = ClauseSpeechScheduler(ttsEngine: ttsEngine)
    }
    
    func startMeetingRecording(in rootURL: URL) throws {
        guard isRunning else {
            throw NSError(domain: "HermeneusMeetingRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先启动同传，再开始会议录音。"])
        }
        try meetingRecorder.start(in: rootURL, microphone: micCapturer, systemAudio: systemCapturer)
    }

    func stopMeetingRecording() throws -> OfflineRecordingArtifact {
        try meetingRecorder.stop()
    }

    public func selectTranslationModel(_ name: String) async {
        await translator.updateModel(to: name)
    }

    public func startSession() async {
        guard !isRunning else { return }
        isRunning = true
        localCaptureState = localInputMode == .automaticVAD ? .automaticListening : .pushToTalkIdle
        remotePipelineState = .listening
        localPipelineState = .listening
        // Begin loading the selected local model before the first user turn.
        // This has no visible output and does not enter conversation context.
        Task.detached(priority: .userInitiated) { [translator] in
            let warmed = await translator.warmUp()
            print(warmed ? "✅ 本地翻译模型预热完成" : "⚠️ 本地翻译模型预热未完成；首句仍会自动重试")
        }
        startupError = nil
        let generation = UUID()
        sessionGeneration = generation
        let microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == sessionGeneration, isRunning else { return }
        guard microphoneGranted else {
            await stopSession()
            startupError = "麦克风未获授权，请在系统设置中允许 Hermeneus 使用麦克风。"
            return
        }
        do {
            setupMicCallback()
            try micCapturer.startCapture()
            try await systemCapturer.startCapture()
            guard generation == sessionGeneration, isRunning else { return }
            startSystemAudioLoop()
            startMicAudioLoop()
            print("🚀 V3.0 WebSocket 流式同传系统已就绪！")
        } catch {
            guard generation == sessionGeneration else { return }
            await stopSession()
            startupError = "音频启动失败：\(error.localizedDescription)。请检查麦克风及系统音频权限后重试。"
        }
    }
    
    public func stopSession() async {
        guard isRunning else { return }
        isRunning = false
        sessionGeneration = UUID()
        let oldSystemLoop = systemAudioLoop
        let oldMicrophoneLoop = microphoneLoop
        oldSystemLoop?.cancel()
        oldMicrophoneLoop?.cancel()
        systemAudioLoop = nil
        microphoneLoop = nil
        await oldSystemLoop?.value
        await oldMicrophoneLoop?.value
        await remoteSegmenter.reset()
        await localSegmenter.reset()
        _ = await micBufferActor.flush()
        await tts.stopPlayout()
        // Finalize the mirror before capture engines stop, preserving the last received audio.
        if meetingRecorder.isRecording { _ = try? meetingRecorder.stop() }
        micCapturer.stopCapture()
        try? await systemCapturer.stopCapture()
        localStreamController.cancelActive()
        remoteAutoController.cancelActive()
        localCaptureState = localInputMode == .automaticVAD ? .automaticListening : .pushToTalkIdle
        isPTTPressed = false
        invalidateLocalPreview()
        invalidateRemotePreview()
        remoteBuffer.reset()
        localBuffer.reset()
        await contextEngine.reset()
        isTTSPlaying = false
        remotePipelineState = .idle
        localPipelineState = .idle
        isRemotePriorityActive = false
        print("🛑 会话已结束，全部上下文已清空（纯内存，无残留）")
    }
    
    private func setupMicCallback() {
        let bufferActor = self.micBufferActor
        micCapturer.onAudioChunk = { [weak self] slice in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning else { return }
                switch self.localInputMode {
                case .automaticVAD:
                    if self.localCaptureState == .manualPressed {
                        // Option is an explicit low-latency override in automatic mode.
                        self.localStreamController.feed(pcm: slice.pcmData, sampleRate: slice.sampleRate)
                    } else {
                        await bufferActor.append(pcm: slice.pcmData)
                    }
                case .pushToTalk:
                    if self.localCaptureState == .manualPressed {
                        self.localStreamController.feed(pcm: slice.pcmData, sampleRate: slice.sampleRate)
                    }
                }
            }
        }
    }
    
    private func startSystemAudioLoop() {
        let segmenter = self.remoteSegmenter
        systemAudioLoop?.cancel()
        let generation = sessionGeneration
        systemAudioLoop = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard await self?.isRunning == true else { break }
                do { try await Task.sleep(nanoseconds: 80_000_000) } catch { break }
                guard let self = self else { break }
                let listening = await self.isListeningRemote
                let ttsPlaying = await self.isTTSPlaying
                if !listening || ttsPlaying {
                    _ = await self.systemCapturer.ringBuffer.readLatest(count: 9600)
                    Task { @MainActor in
                        guard self.isRunning, self.sessionGeneration == generation else { return }
                        self.remoteAutoController.cancelActive()
                        self.invalidateRemotePreview()
                        self.releaseRemotePriority()
                    }
                    continue
                }
                let samples = await self.systemCapturer.ringBuffer.readLatest(count: 4800)
                guard !samples.isEmpty else { continue }

                let wasActive = await segmenter.hasActiveUtterance()
                let completedSegment = await segmenter.feed(pcm: samples)
                let isActive = await segmenter.hasActiveUtterance()
                let shouldFinish = completedSegment != nil || (wasActive && !isActive)

                if wasActive || isActive {
                    Task { @MainActor in
                        guard self.isRunning, self.sessionGeneration == generation else { return }
                        self.activateRemotePriority()
                        self.remoteAutoController.begin(language: "es")
                        self.remoteAutoController.feed(pcm: samples, sampleRate: 48000)
                        if shouldFinish {
                            self.remoteAutoController.finish()
                        }
                    }
                }
            }
        }
    }
    
    private func startMicAudioLoop() {
        let bufferActor = self.micBufferActor
        let segmenter = self.localSegmenter
        microphoneLoop?.cancel()
        let generation = sessionGeneration
        microphoneLoop = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard await self?.isRunning == true else { break }
                do { try await Task.sleep(nanoseconds: 80_000_000) } catch { break }
                guard let self = self else { break }
                let mode = await self.localInputMode
                guard mode == .automaticVAD else {
                    _ = await bufferActor.flush()
                    continue
                }
                let speaking = await self.isSpeakingLocal
                let ttsPlaying = await self.isTTSPlaying
                let remotePriority = await self.isRemotePriorityActive
                let captureState = await self.localCaptureState
                let manualOverrideActive = captureState == .manualPressed || captureState == .manualFinalizing
                if !speaking || ttsPlaying || remotePriority || manualOverrideActive {
                    _ = await self.micBufferActor.flush()
                    continue
                }
                let pcmChunk = await bufferActor.flush()
                guard !pcmChunk.isEmpty else { continue }

                let wasActive = await segmenter.hasActiveUtterance()
                let completedSegment = await segmenter.feed(pcm: pcmChunk)
                let isActive = await segmenter.hasActiveUtterance()
                let shouldFinish = completedSegment != nil || (wasActive && !isActive)

                if wasActive || isActive {
                    Task { @MainActor in
                        guard self.isRunning, self.sessionGeneration == generation else { return }
                        self.localStreamController.begin(language: "zh")
                        self.localStreamController.feed(pcm: pcmChunk, sampleRate: 48000)
                        if shouldFinish {
                            self.localStreamController.finish()
                        }
                    }
                }
            }
        }
    }
    
    private func activateRemotePriority() {
        guard !isRemotePriorityActive else { return }
        isRemotePriorityActive = true
        invalidateLocalPreview()
        localStreamController.cancelActive()
        if localCaptureState == .manualPressed || localCaptureState == .manualFinalizing {
            isPTTPressed = false
        }
        localCaptureState = localInputMode == .automaticVAD ? .automaticListening : .pushToTalkIdle
        if !localPipelineState.isError {
            localPipelineState = .deferredForRemote
        }
    }

    private func releaseRemotePriority() {
        guard isRemotePriorityActive else { return }
        isRemotePriorityActive = false
        if !localPipelineState.isError && !isTTSPlaying {
            localPipelineState = .listening
        }
    }

    private func invalidateRemotePreview() {
        remotePreviewGeneration &+= 1
        remotePreviewTask?.cancel()
        remotePreviewTask = nil
        remotePreviewSource = ""
    }

    private func startRemotePreviewTranslation(sourceText: String, turnId: UUID) {
        guard finalTranslationInFlightCount == 0 else { return }
        guard let candidate = previewCandidate(from: sourceText, previous: remotePreviewSource) else { return }
        remotePreviewSource = candidate
        remotePreviewGeneration &+= 1
        let generation = remotePreviewGeneration
        remotePreviewTask?.cancel()
        remoteBuffer.updateTranslatedText(turnId: turnId, newText: "")
        let context = recentContext(from: remoteBuffer)

        remotePreviewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.translator.translate(
                    text: candidate,
                    contextHistory: context,
                    targetLanguage: "中文"
                )
                for try await update in stream {
                    guard !Task.isCancelled,
                          self.remotePreviewGeneration == generation,
                          self.remoteAutoTurnId == turnId else { return }
                    if case .delta(let token) = update {
                        self.remoteBuffer.appendTranslationDelta(turnId: turnId, token: token)
                        self.scheduleUIRefresh()
                    }
                }
            } catch is CancellationError {
                // Superseded by a newer Spanish stable prefix or final text.
            } catch {
                if self.remotePreviewGeneration == generation {
                    print("⚠️ [AutoStream] 西语预翻译异常: \(error)")
                }
            }
        }
    }

    private func handleRemoteAutoPartial(_ text: String) {
        guard !text.isEmpty else { return }
        activateRemotePriority()
        remotePipelineState = .previewing
        let turnId = remoteBuffer.updateActivePartialTurn(sourceText: text)
        remoteAutoTurnId = turnId
        scheduleUIRefresh()
        startRemotePreviewTranslation(sourceText: text, turnId: turnId)
    }

    private func handleRemoteAutoFinal(_ text: String) async {
        guard !text.isEmpty else {
            remoteAutoTurnId = nil
            invalidateRemotePreview()
            releaseRemotePriority()
            return
        }
        await commitRemoteFinalText(text, existingTurnId: remoteAutoTurnId)
        remoteAutoTurnId = nil
    }

    private func commitRemoteFinalText(_ text: String, existingTurnId: UUID?) async {
        // Stop preview traffic in both directions before requesting an
        // authoritative result. Ollama may still finish a canceled HTTP stream,
        // but no stale token is allowed to reach the subtitle buffer.
        activateRemotePriority()
        invalidateRemotePreview()
        invalidateLocalPreview()
        finalTranslationInFlightCount += 1
        remotePipelineState = .finalizing
        defer {
            finalTranslationInFlightCount = max(0, finalTranslationInFlightCount - 1)
            if !remotePipelineState.isError { remotePipelineState = .listening }
            releaseRemotePriority()
        }
        let turnId: UUID
        if let existingTurnId {
            remoteBuffer.finalizeSourceText(turnId: existingTurnId, finalText: text)
            turnId = existingTurnId
        } else {
            guard let newTurnId = remoteBuffer.beginTurn(sourceText: text) else { return }
            turnId = newTurnId
        }
        remoteBuffer.updateTranslatedText(turnId: turnId, newText: "")
        scheduleUIRefresh()
        await contextEngine.observeSource(text)
        let context = recentContext(from: remoteBuffer)
        do {
            let transStream = try await translator.translate(text: text, contextHistory: context, targetLanguage: "中文")
            for try await transUpdate in transStream {
                switch transUpdate {
                case .delta(let token):
                    remoteBuffer.appendTranslationDelta(turnId: turnId, token: token)
                    scheduleUIRefresh()
                case .final(let fullTrans):
                    var finalText = fullTrans
                    if !finalText.isEmpty && !finalText.hasSuffix(" ") && !finalText.hasSuffix("。") {
                        finalText += "。"
                    }
                    remoteBuffer.finalizeTranslation(turnId: turnId, fullText: finalText)
                    remotePipelineState = .listening
                    Task { [contextEngine] in
                        await contextEngine.observeTranslation(finalText)
                    }
                default:
                    break
                }
            }
        } catch {
            remotePipelineState = .failed("对方翻译失败，请继续说话重试")
            print("远端翻译异常: \(error)")
        }
    }

    // Backward-compatible segment entry point retained for callers outside the
    // automatic loop. The automatic path now uses remoteAutoController instead.
    private func processRemoteSegment(_ seg: Segment) async {
        do {
            let stream = try await asr.transcribe(segment: seg, language: "es")
            for try await update in stream {
                guard case .final(let text, _) = update, !text.isEmpty else { continue }
                await commitRemoteFinalText(text, existingTurnId: nil)
            }
        } catch {
            remotePipelineState = .failed("对方识别连接中断")
            print("远端处理异常: \(error)")
        }
    }
    
    private func handleLocalAutoPartial(_ text: String) {
        guard !text.isEmpty, !isRemotePriorityActive else { return }
        localPipelineState = .previewing
        let turnId = localBuffer.updateActivePartialTurn(sourceText: text)
        localAutoTurnId = turnId
        scheduleUIRefresh()
        // A partial is for immediate Chinese visibility only. Starting and
        // canceling Ollama requests for every growing prefix competed with the
        // authoritative final request and caused the observed 1–3s jitter.
    }

    private func handleLocalAutoFinal(_ text: String) async {
        guard !text.isEmpty else {
            localAutoTurnId = nil
            invalidateLocalPreview()
            return
        }
        await commitLocalFinalText(text, existingTurnId: localAutoTurnId)
        localAutoTurnId = nil
    }

    private func previewCandidate(from sourceText: String, previous: String, minimumCharacters: Int = 10) -> String? {
        let candidate = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= minimumCharacters, candidate != previous else { return nil }
        let growth = candidate.count - previous.count
        let isSentenceBoundary = candidate.last.map { "，。！？；,.?!;".contains($0) } ?? false
        guard previous.isEmpty || growth >= 8 || isSentenceBoundary else { return nil }
        return candidate
    }

    private func invalidateLocalPreview() {
        localPreviewGeneration &+= 1
        localPreviewTask?.cancel()
        localPreviewTask = nil
        localPreviewSource = ""
    }

    private func startLocalPreviewTranslation(sourceText: String, turnId: UUID) {
        guard finalTranslationInFlightCount == 0, !isRemotePriorityActive else { return }
        guard let candidate = previewCandidate(from: sourceText, previous: localPreviewSource) else { return }
        localPreviewSource = candidate
        localPreviewGeneration &+= 1
        let generation = localPreviewGeneration
        localPreviewTask?.cancel()
        localBuffer.updateTranslatedText(turnId: turnId, newText: "")
        let context = recentContext(from: localBuffer)

        localPreviewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.translator.translate(
                    text: candidate,
                    contextHistory: context,
                    targetLanguage: "西班牙语"
                )
                for try await update in stream {
                    guard !Task.isCancelled,
                          self.localPreviewGeneration == generation,
                          self.localAutoTurnId == turnId else { return }
                    if case .delta(let token) = update {
                        self.localBuffer.appendTranslationDelta(turnId: turnId, token: token)
                        self.scheduleUIRefresh()
                    }
                }
            } catch is CancellationError {
                // A newer stable prefix or final text superseded this preview.
            } catch {
                if self.localPreviewGeneration == generation {
                    print("⚠️ [AutoStream] 中文预翻译异常: \(error)")
                }
            }
        }
    }

    private func processLocalSegmentAutoVAD(_ seg: Segment) async {
        do {
            let stream = try await asr.transcribe(segment: seg, language: "zh")
            var activeTurnId: UUID?
            for try await update in stream {
                switch update {
                case .partial(let text, _):
                    guard !text.isEmpty else { continue }
                    let turnId = localBuffer.updateActivePartialTurn(sourceText: text)
                    activeTurnId = turnId
                    DispatchQueue.main.async { self.objectWillChange.send() }
                case .final(let text, _):
                    guard !text.isEmpty else { continue }
                    await self.commitLocalFinalText(text, existingTurnId: activeTurnId)
                }
            }
        } catch {
            localPipelineState = .failed("我的识别连接中断")
            print("麦克风同传异常(自动模式): \(error)")
            self.isTTSPlaying = false
        }
    }
    
    private func handlePTTPartial(_ text: String) {
        guard !text.isEmpty else { return }
        let turnId = localBuffer.updateActivePartialTurn(sourceText: text)
        pttActiveTurnId = turnId
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
    
    private func handlePTTFinal(_ text: String) async {
        guard !text.isEmpty else {
            pttActiveTurnId = nil
            return
        }
        await commitLocalFinalText(text, existingTurnId: pttActiveTurnId)
        pttActiveTurnId = nil
    }
    
    private func commitLocalFinalText(_ text: String, existingTurnId: UUID?) async {
        guard !isRemotePriorityActive else {
            localPipelineState = .deferredForRemote
            return
        }
        invalidateLocalPreview()
        invalidateRemotePreview()
        finalTranslationInFlightCount += 1
        localPipelineState = .finalizing
        defer {
            finalTranslationInFlightCount = max(0, finalTranslationInFlightCount - 1)
            if !localPipelineState.isError { localPipelineState = .listening }
        }
        let turnId: UUID
        if let existingTurnId {
            localBuffer.finalizeSourceText(turnId: existingTurnId, finalText: text)
            turnId = existingTurnId
        } else {
            guard let newTurnId = localBuffer.beginTurn(sourceText: text) else { return }
            turnId = newTurnId
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
        localBuffer.updateTranslatedText(turnId: turnId, newText: "")
        await contextEngine.observeSource(text)
        let context = recentContext(from: localBuffer)
        do {
            let transStream = try await translator.translate(text: text, contextHistory: context, targetLanguage: "西班牙语")
            for try await transUpdate in transStream {
                switch transUpdate {
                case .delta(let token):
                    localBuffer.appendTranslationDelta(turnId: turnId, token: token)
                    scheduleUIRefresh()
                case .clauseCommitted(_):
                    break
                case .final(let fullTrans):
                    localBuffer.finalizeTranslation(turnId: turnId, fullText: fullTrans)
                    localPipelineState = .listening
                    Task { [contextEngine] in
                        await contextEngine.observeTranslation(fullTrans)
                    }
                    self.isTTSPlaying = true
                    await speakOnSelectedDevice(fullTrans)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.isTTSPlaying = false
                }
            }
        } catch {
            localPipelineState = .failed("我的翻译失败，请继续说话重试")
            print("本地翻译异常: \(error)")
            self.isTTSPlaying = false
        }
    }
    
    private func speakOnSelectedDevice(_ text: String) async {
        do { try await tts.speak(text: text, language: "es-ES") }
        catch is CancellationError { }
        catch { localPipelineState = .failed("语音回传失败：\(error.localizedDescription)") }
    }

    public func pressToTalkStart() {
        guard isRunning, !isRemotePriorityActive else {
            if isRemotePriorityActive { localPipelineState = .deferredForRemote }
            return
        }
        guard localCaptureState == .automaticListening || localCaptureState == .pushToTalkIdle else { return }

        // This is a sub-state transition only. localInputMode remains unchanged,
        // so release has an unambiguous target: automatic listening or PTT idle.
        if localInputMode == .automaticVAD {
            localAutoTurnId = nil
            invalidateLocalPreview()
            Task { [localSegmenter, micBufferActor] in
                await localSegmenter.reset()
                _ = await micBufferActor.flush()
            }
        }
        localCaptureState = .manualPressed
        isPTTPressed = true
        localPipelineState = .listening
        localStreamController.begin(language: "zh")
    }
    
    public func pressToTalkEnd() {
        guard localCaptureState == .manualPressed else { return }
        isPTTPressed = false
        localCaptureState = .manualFinalizing
        // The same local ASR stream is finalized; its callback restores the
        // correct persistent mode only after the final text is handled.
        localStreamController.finish()
    }

    private func completeManualTurn() {
        localCaptureState = localInputMode == .automaticVAD ? .automaticListening : .pushToTalkIdle
        if !localPipelineState.isError && !isRemotePriorityActive {
            localPipelineState = .listening
        }
    }
    
    public func setLocalInputMode(_ mode: LocalInputMode) {
        guard mode != localInputMode else { return }
        localStreamController.cancelActive()
        isPTTPressed = false
        localInputMode = mode
        localCaptureState = mode == .automaticVAD ? .automaticListening : .pushToTalkIdle
    }
    
    public func retranslateAndSpeak(turnId: UUID, newChineseText: String) async {
        guard !isRemotePriorityActive else {
            localPipelineState = .deferredForRemote
            return
        }
        localBuffer.updateSourceText(turnId: turnId, newText: newChineseText)
        DispatchQueue.main.async { self.objectWillChange.send() }
        localBuffer.updateTranslatedText(turnId: turnId, newText: "重新翻译中...")
        DispatchQueue.main.async { self.objectWillChange.send() }
        let context = recentContext(from: localBuffer)
        do {
            let transStream = try await translator.translate(text: newChineseText, contextHistory: context, targetLanguage: "西班牙语")
            var fullTrans = ""
            for try await transUpdate in transStream {
                switch transUpdate {
                case .delta(let token):
                    fullTrans += token
                case .final(let text):
                    fullTrans = text
                default: break
                }
            }
            let trimmed = fullTrans.trimmingCharacters(in: .whitespacesAndNewlines)
            localBuffer.finalizeTranslation(turnId: turnId, fullText: trimmed)
            await speakSpanishText(trimmed)
        } catch {
            print("编辑重译异常: \(error)")
        }
    }
    
    public func updateSpanishAndSpeak(turnId: UUID, newSpanishText: String) async {
        localBuffer.updateTranslatedText(turnId: turnId, newText: newSpanishText)
        DispatchQueue.main.async { self.objectWillChange.send() }
        await speakSpanishText(newSpanishText)
    }
    
    public func speakSpanishText(_ text: String) async {
        guard !text.isEmpty else { return }
        self.isTTSPlaying = true
        await speakOnSelectedDevice(text)
        try? await Task.sleep(nanoseconds: 300_000_000)
        self.isTTSPlaying = false
    }
    
    public func replayLastLocalTranslation() async {
        guard let lastTurn = localBuffer.turns.last, !lastTurn.translatedText.isEmpty else { return }
        DispatchQueue.main.async { self.objectWillChange.send() }
        self.isTTSPlaying = true
        await speakOnSelectedDevice(lastTurn.translatedText)
        try? await Task.sleep(nanoseconds: 300_000_000)
        self.isTTSPlaying = false
    }
    
    private func recentContext(from buffer: RollingTextBuffer) -> [TranslationContext] {
        let fifteenSecondsAgo = Date().addingTimeInterval(-15)
        let inWindowTurns = buffer.turns.filter { turn in
            turn.isTranslationFinal && !turn.translatedText.isEmpty && turn.timestamp >= fifteenSecondsAgo
        }
        let selectedTurns = inWindowTurns.isEmpty ? buffer.turns.filter({ $0.isTranslationFinal && !$0.translatedText.isEmpty }).suffix(4) : inWindowTurns.suffix(6)
        return selectedTurns.map { turn in
            TranslationContext(sourceText: turn.sourceText, translatedText: turn.translatedText)
        }
    }
    
    private func scheduleUIRefresh() {
        guard !uiRefreshPending else { return }
        uiRefreshPending = true
        let interval = uiRefreshIntervalNs
        Task { @MainActor [weak self, interval] in
            try? await Task.sleep(nanoseconds: interval)
            guard let self else { return }
            self.uiRefreshPending = false
            self.objectWillChange.send()
        }
    }

    public func triggerUIRefresh() {
        self.objectWillChange.send()
    }
}