import Foundation
import CoreAudio

@main
struct AudioRouteSmoke {
    @MainActor static func main() throws {
        let device = AudioOutputDevice(id: "stable-uid", name: "BlackHole 2ch", deviceID: 101)
        assert(device.isLoopback)
        let resolved = try AudioOutputDevice.resolve("stable-uid", devices: [device])
        assert(resolved == 101)
        let reconnected = AudioOutputDevice(id: "stable-uid", name: "BlackHole 2ch", deviceID: 202)
        let newID = try AudioOutputDevice.resolve("stable-uid", devices: [reconnected])
        assert(newID == 202)
        let local = try AudioOutputDevice.resolve(AudioOutputDevice.systemDefault, devices: [])
        assert(local == nil)
        do {
            _ = try AudioOutputDevice.resolve("missing-device", devices: [device])
            fatalError("A disconnected device must never silently fall back to a speaker")
        } catch { }
        let actual = AudioOutputDevice.available()
        for device in actual.filter(\.isLoopback) {
            try BlackHoleTTSEngine.validateConnection(to: device.id)
        }
        print("Audio route checks passed: persistent UID, reconnect, explicit local playback, missing-device rejection. Output devices enumerated: \(actual.count); loopback devices: \(actual.filter(\.isLoopback).count). Loopback output bindings were set and read back without playing audio.")
    }
}
