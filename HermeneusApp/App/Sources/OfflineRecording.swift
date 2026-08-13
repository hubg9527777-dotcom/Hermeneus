import Foundation
import AVFoundation
import AudioCore

struct OfflineRecordingArtifact: Sendable {
    let jobID: String
    let directoryURL: URL
    let localURL: URL?
    let remoteURL: URL?
    let startedAt: Date
    let endedAt: Date
}

enum OfflineRecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "录音已经在进行中。"
        case .notRecording: return "当前没有正在进行的录音。"
        case .storageUnavailable: return "加密卷目录不可访问或不可写。"
        }
    }
}


/// 仅用于已结束录音的本地回放优化。原始音轨始终保持不变，
/// 因此不会影响实时同传、离线转写输入或可审计性。
enum PlaybackAudioOptimizer {
    // Playback copies are created only after recording stops. Source WAV files remain untouched.
    private static let activityThreshold: Float = 0.0032 // about -50 dBFS frame RMS
    private static let targetActiveRMS: Float = 0.12 // about -18.4 dBFS for normal speech
    private static let maximumGain: Float = 16.0
    private static let limiterCeiling: Float = 0.891_250_9 // -1 dBFS

    static func outputURL(for sourceURL: URL) -> URL {
        sourceURL.deletingPathExtension()
            .appendingPathExtension("playback")
            .appendingPathExtension("wav")
    }

    /// Generates a replay-only WAV using active-speech loudness instead of a single file peak.
    /// Short spikes do not suppress normal speech gain. A soft limiter prevents clipping.
    static func createOptimizedCopy(from sourceURL: URL) throws -> URL {
        let outputURL = outputURL(for: sourceURL)
        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: temporaryURL)
        try? FileManager.default.removeItem(at: outputURL)

        let input = try AVAudioFile(forReading: sourceURL)
        let format = input.processingFormat
        guard format.commonFormat == .pcmFormatFloat32,
              format.channelCount > 0,
              let probe = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)
        else {
            throw NSError(domain: "HermeneusPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: "录音格式不支持回放优化"])
        }

        var activeFrameRMS: [Float] = []
        input.framePosition = 0
        while input.framePosition < input.length {
            probe.frameLength = 0
            try input.read(into: probe, frameCount: probe.frameCapacity)
            guard probe.frameLength > 0, let channels = probe.floatChannelData else { break }
            var sumSquares: Float = 0
            let count = Int(probe.frameLength) * Int(format.channelCount)
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<Int(probe.frameLength) {
                    sumSquares += samples[frame] * samples[frame]
                }
            }
            let rms = count > 0 ? sqrt(sumSquares / Float(count)) : 0
            if rms >= activityThreshold { activeFrameRMS.append(rms) }
        }

        // P90 of active frames is robust to silence and isolated transient peaks.
        let referenceRMS: Float
        if activeFrameRMS.count >= 3 {
            activeFrameRMS.sort()
            let index = Int(Float(activeFrameRMS.count - 1) * 0.90)
            referenceRMS = activeFrameRMS[index]
        } else {
            referenceRMS = 0
        }
        let gain: Float = referenceRMS > 0
            ? max(1, min(maximumGain, targetActiveRMS / referenceRMS))
            : 1

        input.framePosition = 0
        do {
            let output = try AVAudioFile(
                forWriting: temporaryURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
                throw NSError(domain: "HermeneusPlayback", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建录音缓冲区"])
            }
            while input.framePosition < input.length {
                buffer.frameLength = 0
                try input.read(into: buffer, frameCount: buffer.frameCapacity)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                for channel in 0..<Int(format.channelCount) {
                    let samples = channels[channel]
                    for frame in 0..<Int(buffer.frameLength) {
                        let amplified = samples[frame] * gain
                        // Smooth saturation keeps the replay comfortable while guaranteeing no hard clipping.
                        samples[frame] = limiterCeiling * Float(tanh(Double(amplified / limiterCeiling)))
                    }
                }
                try output.write(from: buffer)
            }
        }
        try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        return outputURL
    }
}
/// 将流式 Float32 音频写入 WAV。输出文件始终位于调用方传入的安全目录。
fileprivate final class PCMTrackWriter {
    private let finalURL: URL
    private let partialURL: URL
    private var audioFile: AVAudioFile?
    private var sampleRate: Double?
    private var didFail = false

    init(finalURL: URL) {
        self.finalURL = finalURL
        self.partialURL = finalURL.appendingPathExtension("partial")
    }

    func append(_ slice: AudioSlice) throws {
        guard !didFail else { return }
        guard !slice.pcmData.isEmpty else { return }
        let rate = Double(slice.sampleRate)
        if sampleRate == nil {
            sampleRate = rate
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
                throw NSError(domain: "HermeneusRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建录音格式"])
            }
            audioFile = try AVAudioFile(forWriting: partialURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        guard let file = audioFile else {
            throw NSError(domain: "HermeneusRecording", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建录音文件"])
        }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(slice.pcmData.count)),
              let destination = buffer.floatChannelData?[0] else {
            throw NSError(domain: "HermeneusRecording", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建录音缓冲区"])
        }
        buffer.frameLength = AVAudioFrameCount(slice.pcmData.count)
        slice.pcmData.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: slice.pcmData.count)
        }
        try file.write(from: buffer)
    }

    func finish() throws -> URL? {
        audioFile = nil
        guard FileManager.default.fileExists(atPath: partialURL.path) else { return nil }
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        return finalURL
    }

    func abort() {
        audioFile = nil
        didFail = true
    }
}

/// 双轨录音会分别保存麦克风（我方）与 ScreenCaptureKit 系统音频（对方）轨道。
/// 不调用 ASR/Ollama，不和实时同传共享采集器，调用方必须保证模式互斥。
@MainActor
final class OfflineDualTrackRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var statusMessage = "未录音"

    private let microphone = MicrophoneCapturer()
    private let systemAudio = SCKAudioCapturer()
    private var localWriter: PCMTrackWriter?
    private var remoteWriter: PCMTrackWriter?
    private var jobID: String?
    private var jobDirectory: URL?
    private var startedAt: Date?
    private var timer: Timer?
    private var accessURL: URL?
    private var hasSecurityAccess = false

    func start(in rootURL: URL) async throws {
        guard !isRecording else { throw OfflineRecordingError.alreadyRecording }
        guard rootURL.startAccessingSecurityScopedResource() || FileManager.default.isWritableFile(atPath: rootURL.path) else {
            throw OfflineRecordingError.storageUnavailable
        }
        accessURL = rootURL
        hasSecurityAccess = true

        let id = UUID().uuidString.lowercased()
        let directory = rootURL
            .appendingPathComponent("Hermeneus Data", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent("\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))_\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let local = PCMTrackWriter(finalURL: directory.appendingPathComponent("local.wav"))
            let remote = PCMTrackWriter(finalURL: directory.appendingPathComponent("remote.wav"))
            localWriter = local
            remoteWriter = remote
            jobID = id
            jobDirectory = directory
            startedAt = Date()

            microphone.onAudioChunk = { [weak local] slice in
                do { try local?.append(slice) } catch { print("录音麦克风写入失败：\(error.localizedDescription)") }
            }
            systemAudio.onAudioChunk = { [weak remote] slice in
                do { try remote?.append(slice) } catch { print("录音系统音频写入失败：\(error.localizedDescription)") }
            }
            try microphone.startCapture()
            try await systemAudio.startCapture()
            isRecording = true
            elapsedSeconds = 0
            statusMessage = "正在录制双轨：麦克风 + 对方系统音频"
            startTimer()
        } catch {
            await stopAndDiscard()
            throw error
        }
    }

    func stop() async throws -> OfflineRecordingArtifact {
        guard isRecording, let id = jobID, let directory = jobDirectory, let startedAt else {
            throw OfflineRecordingError.notRecording
        }
        timer?.invalidate()
        timer = nil
        microphone.stopCapture()
        try? await systemAudio.stopCapture()
        microphone.onAudioChunk = nil
        systemAudio.onAudioChunk = nil

        let local = try localWriter?.finish()
        let remote = try remoteWriter?.finish()
        let endedAt = Date()
        let manifest: [String: Any] = [
            "schema_version": 1,
            "kind": "dual-track-recording",
            "job_id": id,
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "ended_at": ISO8601DateFormatter().string(from: endedAt),
            "local_track": local?.lastPathComponent as Any,
            "remote_track": remote?.lastPathComponent as Any,
            "network_used": false
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
        cleanup()
        statusMessage = "录音已安全保存"
        return OfflineRecordingArtifact(jobID: id, directoryURL: directory, localURL: local, remoteURL: remote, startedAt: startedAt, endedAt: endedAt)
    }

    func stopAndDiscard() async {
        timer?.invalidate()
        timer = nil
        microphone.stopCapture()
        try? await systemAudio.stopCapture()
        microphone.onAudioChunk = nil
        systemAudio.onAudioChunk = nil
        localWriter?.abort()
        remoteWriter?.abort()
        cleanup()
        statusMessage = "录音已停止；未完成轨道保留为 .partial，供人工检查"
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func cleanup() {
        isRecording = false
        localWriter = nil
        remoteWriter = nil
        jobID = nil
        jobDirectory = nil
        startedAt = nil
        if hasSecurityAccess, let accessURL {
            accessURL.stopAccessingSecurityScopedResource()
        }
        accessURL = nil
        hasSecurityAccess = false
    }
}


/// Bounded asynchronous sink. Audio callbacks only enqueue pre-copied slices;
/// disk I/O runs off the live capture callback. When saturated, recording drops
/// its own oldest pending chunk rather than delaying real-time interpretation.
private final class BoundedPCMTrackWriter: @unchecked Sendable {
    private let writer: PCMTrackWriter
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [AudioSlice] = []
    private var draining = false
    private var closed = false
    private let capacity: Int
    private(set) var droppedChunks: UInt64 = 0

    init(finalURL: URL, label: String, capacity: Int = 64) {
        self.writer = PCMTrackWriter(finalURL: finalURL)
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.capacity = capacity
    }

    func enqueue(_ slice: AudioSlice) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if pending.count >= capacity {
            pending.removeFirst()
            droppedChunks += 1
        }
        pending.append(slice)
        let shouldSchedule = !draining
        if shouldSchedule { draining = true }
        lock.unlock()
        if shouldSchedule {
            queue.async { [weak self] in self?.drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                draining = false
                lock.unlock()
                return
            }
            let slice = pending.removeFirst()
            lock.unlock()
            do { try writer.append(slice) }
            catch { print("会议录音写入失败：\(error.localizedDescription)") }
        }
    }

    func finish() throws -> (URL?, UInt64) {
        lock.lock()
        closed = true
        lock.unlock()
        var result: URL?
        queue.sync {
            self.drain()
            result = try? self.writer.finish()
        }
        lock.lock()
        let dropped = droppedChunks
        lock.unlock()
        return (result, dropped)
    }

    func abort() {
        lock.lock()
        closed = true
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
        queue.sync { writer.abort() }
    }
}

/// Records a meeting while the existing real-time session remains the primary
/// consumer. It attaches mirror observers instead of opening second capture
/// engines, so it never replaces ASR callbacks or capture ownership.
@MainActor
final class LiveMeetingDualTrackRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var statusMessage = "未录制会议"

    private var localWriter: BoundedPCMTrackWriter?
    private var remoteWriter: BoundedPCMTrackWriter?
    private var micObserverID: UUID?
    private var systemObserverID: UUID?
    private var jobID: String?
    private var jobDirectory: URL?
    private var startedAt: Date?
    private var timer: Timer?
    private weak var microphone: MicrophoneCapturer?
    private weak var systemAudio: SCKAudioCapturer?
    private var accessURL: URL?
    private var hasSecurityAccess = false

    func start(in rootURL: URL, microphone: MicrophoneCapturer, systemAudio: SCKAudioCapturer) throws {
        guard !isRecording else { throw OfflineRecordingError.alreadyRecording }
        guard rootURL.startAccessingSecurityScopedResource() || FileManager.default.isWritableFile(atPath: rootURL.path) else {
            throw OfflineRecordingError.storageUnavailable
        }
        accessURL = rootURL
        hasSecurityAccess = true
        let id = UUID().uuidString.lowercased()
        let directory = rootURL
            .appendingPathComponent("Hermeneus Data", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent("meeting_\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))_\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let local = BoundedPCMTrackWriter(finalURL: directory.appendingPathComponent("local.wav"), label: "Hermeneus.meeting.local")
            let remote = BoundedPCMTrackWriter(finalURL: directory.appendingPathComponent("remote.wav"), label: "Hermeneus.meeting.remote")
            self.microphone = microphone
            self.systemAudio = systemAudio
            localWriter = local
            remoteWriter = remote
            micObserverID = microphone.addAudioObserver { [weak local] slice in local?.enqueue(slice) }
            systemObserverID = systemAudio.addAudioObserver { [weak remote] slice in remote?.enqueue(slice) }
            jobID = id
            jobDirectory = directory
            startedAt = Date()
            isRecording = true
            elapsedSeconds = 0
            statusMessage = "正在镜像录制会议双轨；实时识别优先"
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.elapsedSeconds += 1 }
            }
        } catch {
            cleanup(abort: true)
            throw error
        }
    }

    func stop() throws -> OfflineRecordingArtifact {
        guard isRecording, let id = jobID, let directory = jobDirectory, let startedAt else {
            throw OfflineRecordingError.notRecording
        }
        removeObservers()
        timer?.invalidate()
        timer = nil
        let (local, localDrops) = try localWriter?.finish() ?? (nil, 0)
        let (remote, remoteDrops) = try remoteWriter?.finish() ?? (nil, 0)
        let endedAt = Date()
        let manifest: [String: Any] = [
            "schema_version": 1,
            "kind": "live-meeting-dual-track-recording",
            "job_id": id,
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "ended_at": ISO8601DateFormatter().string(from: endedAt),
            "local_track": local?.lastPathComponent as Any,
            "remote_track": remote?.lastPathComponent as Any,
            "recording_dropped_chunks": ["local": localDrops, "remote": remoteDrops],
            "real_time_interpretation_priority": true,
            "network_used": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
        cleanup(abort: false)
        statusMessage = localDrops + remoteDrops > 0
            ? "会议录音已保存；为保护实时同传，丢弃了 \(localDrops + remoteDrops) 个滞后块"
            : "会议录音已安全保存"
        return OfflineRecordingArtifact(jobID: id, directoryURL: directory, localURL: local, remoteURL: remote, startedAt: startedAt, endedAt: endedAt)
    }

    func stopAndDiscard() {
        removeObservers()
        cleanup(abort: true)
        statusMessage = "会议录音已停止；未完成轨道保留为 .partial，供人工检查"
    }

    private func removeObservers() {
        if let id = micObserverID { microphone?.removeAudioObserver(id) }
        if let id = systemObserverID { systemAudio?.removeAudioObserver(id) }
        micObserverID = nil
        systemObserverID = nil
    }

    private func cleanup(abort: Bool) {
        removeObservers()
        timer?.invalidate()
        timer = nil
        if abort {
            localWriter?.abort()
            remoteWriter?.abort()
        }
        isRecording = false
        localWriter = nil
        remoteWriter = nil
        jobID = nil
        jobDirectory = nil
        startedAt = nil
        microphone = nil
        systemAudio = nil
        if hasSecurityAccess, let accessURL { accessURL.stopAccessingSecurityScopedResource() }
        accessURL = nil
        hasSecurityAccess = false
    }
}
