import Foundation
@main
struct AudioResamplerSecurity {
    static func main() {
        precondition(AudioResampler.resample(samples: [0, 1], inputSampleRate: 0, targetSampleRate: 16000).isEmpty)
        precondition(AudioResampler.resample(samples: [0, 1], inputSampleRate: -1, targetSampleRate: 16000).isEmpty)
        precondition(AudioResampler.resample(samples: [0, 1], inputSampleRate: 16000, targetSampleRate: 0).isEmpty)
        let data = AudioResampler.floatToPCM16Data([.nan, .infinity, -.infinity, 0, 1, -1])
        precondition(Array(data.prefix(8)) == [UInt8](repeating: 0, count: 8))
        precondition(data.count == 12)
        let valid = AudioResampler.resample(samples: [0, 0.5, 1, 0.5], inputSampleRate: 32000, targetSampleRate: 16000)
        precondition(valid == [0, 1])
        print("PASS: malformed sample rates/nonfinite samples cannot trap; valid resampling unchanged")
    }
}
