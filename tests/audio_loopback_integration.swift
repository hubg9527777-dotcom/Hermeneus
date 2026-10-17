import Foundation
import TTSKit

@main struct AudioLoopbackIntegration {
    @MainActor static func main() async {
        guard CommandLine.arguments.contains("--confirm-no-meeting") else {
            fputs("Run only after confirming that no meeting will receive the fixed test speech.\n", stderr)
            exit(2)
        }
        do {
            guard let device = AudioOutputDevice.available().first(where: { $0.isLoopback && $0.name.contains("2ch") }) else {
                throw NSError(domain: "AudioLoopbackTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "BlackHole 2ch unavailable"])
            }
            let result = try await AudioReturnProbe.test(engine: BlackHoleTTSEngine(), deviceUID: device.id)
            let details: [String: Any] = ["device": device.name, "uid": device.id,
                "baseline_rms": result.baselineRMS, "speech_rms": result.speechRMS,
                "active_seconds": result.activeSeconds, "captured_frames": result.frames,
                "sample_rate": result.sampleRate, "audio_saved": false, "loopback_passed": true]
            print(String(data: try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
