import Foundation
import AVFoundation
import AudioToolbox

/// Synthesize PCM in memory and bind this engine's output to the selected device.
/// Never changes the system default input/output and never writes speech to disk.
@MainActor
public final class BlackHoleTTSEngine: NSObject, @unchecked Sendable, TTSEngine {
    private let synthesizer = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var consumeTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var operationID = UUID()
    private var routeObserver: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?

    public var selectedDeviceUID: String {
        UserDefaults.standard.string(forKey: AudioOutputDevice.preferenceKey) ?? AudioOutputDevice.systemDefault
    }

    public func selectDevice(_ uid: String) async throws {
        try Self.validateConnection(to: uid)
        await stopPlayout()
        UserDefaults.standard.set(uid, forKey: AudioOutputDevice.preferenceKey)
    }

    public func speak(text: String, language: String = "es-ES") async throws {
        try await render(text: text, language: language, deviceUID: selectedDeviceUID)
    }

    public func testOutput(to uid: String) async throws {
        try await render(text: "Hola. Esta es una prueba de traducción de Hermeneus.", language: "es-ES", deviceUID: uid)
    }

    private func render(text: String, language: String, deviceUID: String) async throws {
        await stopPlayout()
        try Task.checkCancellation()
        let device = try AudioOutputDevice.resolve(deviceUID, devices: AudioOutputDevice.available())
        guard text.count <= 4000 else { throw Self.failure("单次播报内容过长，请分段播放。") }
        guard let voice = AVSpeechSynthesisVoice(language: language) else {
            throw Self.failure("系统尚未安装对应语言的声音，请在 macOS 辅助功能的朗读设置中下载西班牙语声音。")
        }
        let id = UUID()
        operationID = id
        var streamContinuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation!
        let stream = AsyncThrowingStream<AVAudioPCMBuffer, Error>(bufferingPolicy: .unbounded) {
            streamContinuation = $0
        }
        let producer = streamContinuation!
        let writeBudget = PCMWriteBudget()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { completion in
                continuation = completion
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.finish(id, error: Self.failure("语音播放超时，请检查输出设备后重试。"))
                }
                consumeTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        var renderedBytes = 0
                        for try await buffer in stream {
                            try Task.checkCancellation()
                            guard self.operationID == id else { throw CancellationError() }
                            renderedBytes += UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                                .reduce(0) { $0 + Int($1.mDataByteSize) }
                            guard renderedBytes <= 32 * 1024 * 1024 else { throw Self.failure("语音数据超出长度限制。") }
                            if self.engine == nil { try self.prepareOutput(format: buffer.format, device: device) }
                            self.player?.scheduleBuffer(buffer, completionHandler: nil)
                            if self.player?.isPlaying == false { self.player?.play() }
                        }
                        guard self.operationID == id else { return }
                        guard let player = self.player, let format = self.engine?.mainMixerNode.inputFormat(forBus: 0),
                              let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
                            throw Self.failure("系统没有生成可播放的语音。")
                        }
                        tail.frameLength = 1
                        for audio in UnsafeMutableAudioBufferListPointer(tail.mutableAudioBufferList) {
                            if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
                        }
                        player.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                            Task { @MainActor in self?.finish(id, error: nil) }
                        }
                    } catch { self.finish(id, error: error) }
                }
                synthesizer.write(utterance) { buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else {
                        producer.finish(throwing: Self.failure("系统返回了不支持的语音格式。")); return
                    }
                    if pcm.frameLength == 0 { producer.finish(); return }
                    let bytes = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                        .reduce(0) { $0 + Int($1.mDataByteSize) }
                    guard writeBudget.claim(bytes) else {
                        producer.finish(throwing: Self.failure("语音数据超出长度限制，请分段播放。")); return
                    }
                    guard let copy = Self.copyPCM(pcm) else {
                        producer.finish(throwing: Self.failure("无法准备语音缓冲区。")); return
                    }
                    // AVSpeech may deliver many tiny buffers before the actor can
                    // consume them. Bound bytes and object count before enqueueing,
                    // rather than dropping an otherwise valid short utterance.
                    producer.yield(copy)
                }
            }
        }, onCancel: { [weak self] in
            producer.finish(throwing: CancellationError())
            Task { @MainActor in self?.finish(id, error: CancellationError()) }
        })
    }

    private func prepareOutput(format: AVAudioFormat, device: AudioDeviceID?) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let output = engine.outputNode
        try Self.bindOutput(output, to: device)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.player = player
        let id = operationID
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finish(id, error: Self.failure("音频设备发生变化，已停止播报。请刷新设备后重试。")) }
        }
    }

    public static func validateConnection(to uid: String) throws {
        let device = try AudioOutputDevice.resolve(uid, devices: AudioOutputDevice.available())
        let probe = AVAudioEngine()
        try bindOutput(probe.outputNode, to: device)
        // No engine start, scheduled buffers, recording, or system-default changes.
    }

    private static func bindOutput(_ output: AVAudioOutputNode, to device: AudioDeviceID?) throws {
        if var device {
            guard let unit = output.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw Self.failure("无法使用所选设备，请刷新设备列表并确认设备已连接。")
            }
            var actual: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard let unit = output.audioUnit,
                  AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &actual, &size) == noErr, actual == device else {
                throw Self.failure("输出设备确认失败，已停止播报。")
            }
        }
    }

    public func stopPlayout() async { finish(operationID, error: CancellationError()) }

    private func finish(_ id: UUID, error: Error?) {
        guard id == operationID else { return }
        operationID = UUID()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        consumeTask?.cancel()
        consumeTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        let completion = continuation
        continuation = nil
        if let error { completion?.resume(throwing: error) } else { completion?.resume() }
    }

    nonisolated private static func failure(_ message: String) -> NSError {
        NSError(domain: "HermeneusAudioRoute", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    nonisolated private static func copyPCM(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard input.count == output.count else { return nil }
        for index in input.indices {
            guard let from = input[index].mData, let to = output[index].mData,
                  input[index].mDataByteSize <= output[index].mDataByteSize else { return nil }
            memcpy(to, from, Int(input[index].mDataByteSize))
        }
        return copy
    }
}

private final class PCMWriteBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var buffers = 0
    func claim(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count > 0, count <= 32 * 1024 * 1024 - bytes, buffers < 32768 else { return false }
        bytes += count
        buffers += 1
        return true
    }
}
