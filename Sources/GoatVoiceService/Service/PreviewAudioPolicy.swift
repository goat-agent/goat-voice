import Foundation

enum PreviewAudioPolicy {
    static func containsSignal(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        let energy = samples.reduce(0.0) { total, sample in
            let value = Double(sample)
            return total + value * value
        }
        return energy.isFinite && energy / Double(samples.count) > 0.000001
    }
}
