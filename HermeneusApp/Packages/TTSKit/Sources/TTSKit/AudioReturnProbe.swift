import Foundation
import AVFoundation
import AudioToolbox

/// Measures only the selected virtual input. No audio samples leave the tap or are saved.
@MainActor
public enum AudioReturnProbe {
    public struct Result: Sendable {
        public let baselineRMS: Double
        public let speechRMS: Double
        public let activeSeconds: Double
        public let frames: Int
        public let sampleRate: Double
    }

    public static func test(engine: BlackHoleTTSEngine, deviceUID: String) async throws -> Result {
        guard let device = AudioOutputDevice.available().first(where: { $0.id == deviceUID }), device.isLoopback else {
            throw failure("请选择 BlackHole 虚拟回传设备。")
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw failure("回传检测需要音频输入权限。请在系统设置 → 隐私与安全性 → 麦克风中允许 Hermeneus，然后重试。")
        }
        try Task.checkCancellation()
        let recorder = AVAudioEngine()
        let input = recorder.inputNode
        guard let unit = input.audioUnit else { throw failure("无法创建虚拟输入检测。") }
        var selected = device.deviceID
        var actual: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                0, &selected, size) == noErr,
              AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                0, &actual, &size) == noErr, actual == selected else {
            throw failure("无法检测所选 BlackHole 输入，请刷新设备或重新安装 BlackHole 2ch。")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw failure("虚拟设备没有可用输入通道。") }
        let measurement = Measurement()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in measurement.consume(buffer) }
        defer { recorder.stop(); input.removeTap(onBus: 0) }
        try recorder.start()
        try await Task.sleep(for: .seconds(1))
        let before = measurement.snapshot()
        let baseline = sqrt(before.power / Double(max(before.frames, 1)))
        guard before.frames > 0 else { throw failure("未收到虚拟设备输入，请检查音频权限与设备连接。") }
        guard baseline < 0.001 else { throw failure("BlackHole 当前已有音频，未发送测试语音。请暂停其他发送到此设备的声音后重试。") }
        try await engine.testOutput(to: deviceUID)
        try await Task.sleep(for: .milliseconds(400))
        let after = measurement.snapshot()
        let frames = after.frames - before.frames
        let rms = sqrt(max(0, after.power - before.power) / Double(max(frames, 1)))
        let active = Double(after.activeFrames - before.activeFrames) / format.sampleRate
        guard rms > 0.002, active > 0.5 else {
            throw failure("测试语音已发送，但 BlackHole 输入未收到足够信号。请确认安装的是 BlackHole 2ch，并刷新后重试。")
        }
        return Result(baselineRMS: baseline, speechRMS: rms, activeSeconds: active, frames: frames, sampleRate: format.sampleRate)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "HermeneusReturnProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class Measurement: @unchecked Sendable {
    struct Snapshot { var power: Double = 0; var frames = 0; var activeFrames = 0 }
    private let lock = NSLock()
    private var values = Snapshot()
    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        var power: Double = 0
        for index in 0..<Int(buffer.frameLength) {
            let value = Double(channels[0][index])
            if value.isFinite { power += value * value }
        }
        lock.lock(); defer { lock.unlock() }
        values.power += power
        values.frames += Int(buffer.frameLength)
        if power > Double(buffer.frameLength) * 0.000001 { values.activeFrames += Int(buffer.frameLength) }
    }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return values }
}
