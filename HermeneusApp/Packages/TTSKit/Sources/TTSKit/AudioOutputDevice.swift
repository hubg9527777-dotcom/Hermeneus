import Foundation
import CoreAudio

public struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    public let id: String // Persistent CoreAudio UID; numeric device IDs change on reconnect.
    public let name: String
    public let deviceID: AudioDeviceID
    public var isLoopback: Bool { name.localizedCaseInsensitiveContains("BlackHole") }

    public static let preferenceKey = "Hermeneus.SpeechOutputDeviceUID"
    public static let systemDefault = "system-default"

    public static func available() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = stringProperty(device, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(device, kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(id: uid, name: name, deviceID: device)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        // CoreAudio transfers ownership of these CFString properties to the caller.
        return value.takeRetainedValue() as String
    }

    public static func resolve(_ uid: String, devices: [AudioOutputDevice]) throws -> AudioDeviceID? {
        if uid == systemDefault { return nil }
        guard let device = devices.first(where: { $0.id == uid }) else {
            throw NSError(domain: "HermeneusAudioRoute", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "所选语音设备已断开。请重新连接，或在“语音回传设备”中重新选择。为避免误播，不会切换到扬声器。"])
        }
        return device.deviceID
    }
}
