import Foundation

/// Deterministic Karplus–Strong plucks. Render once before playing, never on the audio thread.
public enum PluckedStringRenderer {
    /// A single finger release. A pluck partway along the string suppresses
    /// some upper partials; the remaining upper harmonics decay faster than
    /// the fundamental. Exact oscillator pitches keep chord changes in tune
    /// even in the watch's compact, lower-sample-rate bank.
    static func fingerpick(note: Int, sampleRate: Int, duration: Double) -> [Float] {
        guard (0...127).contains(note), (8_000...96_000).contains(sampleRate),
              duration.isFinite, (0.02...2).contains(duration) else { return [] }
        let fundamental = 440 * pow(2, Double(note - 69) / 12)
        let count = Int(Double(sampleRate) * duration)
        var output = [Float](repeating: 0, count: count)
        for harmonic in 1...8 {
            let order = Double(harmonic)
            let frequency = fundamental * order
            guard frequency < Double(sampleRate) * 0.45 else { break }
            let phaseStep = 2 * Double.pi * frequency / Double(sampleRate)
            let amplitude = sin(.pi * order * 0.22) / pow(order, 1.42)
            let decayPerFrame = exp(-(5.6 + 1.4 * order) / Double(sampleRate))
            var envelope = amplitude
            for frame in output.indices {
                output[frame] += Float(envelope * sin(phaseStep * Double(frame)))
                envelope *= decayPerFrame
            }
        }
        let attack = max(1, Int(0.006 * Double(sampleRate)))
        let release = max(1, Int(0.055 * Double(sampleRate)))
        var peak: Float = 0
        for frame in output.indices {
            let attackGain = min(1, Float(frame) / Float(attack))
            let releaseGain = min(1, Float(count - 1 - frame) / Float(release))
            output[frame] *= attackGain * releaseGain
            peak = max(peak, abs(output[frame]))
        }
        if peak > 0 {
            let gain: Float = 0.60 / peak
            for frame in output.indices { output[frame] *= gain }
        }
        return output
    }

    public static func render(chord: Chord, sampleRate: Int = 44_100,
                              duration: Double = 2.4) -> [Float] {
        render(notes: chord.midiNotes, sampleRate: sampleRate, duration: duration,
               emphasizeFundamental: !Chord.manualVoicings.contains(chord))
    }

    /// Shared synthesis for a whole voicing or a single answering string.
    /// Keep ordering, string offsets and seeds unchanged for manual chords.
    static func render(notes: [Int], sampleRate: Int = 44_100,
                       duration: Double = 2.4, emphasizeFundamental: Bool = false,
                       stringSpacing: Double = 0.009, attackTime: Double = 0.003) -> [Float] {
        guard (8_000...96_000).contains(sampleRate), duration.isFinite,
              duration > 0, duration <= 10 else { return [] }
        let count = Int(Double(sampleRate) * duration)
        guard count > 0 else { return [] }
        var output = [Float](repeating: 0, count: count)
        for (string, note) in notes.enumerated() {
            let frequency = 440 * pow(2, Double(note - 69) / 12)
            let length = max(2, Int(Double(sampleRate) / frequency - 0.5))
            var seed = UInt64(note * 7919 + string * 997 + 1)
            var delay = (0..<length).map { index -> Float in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let noise = Double(seed >> 40) / Double(1 << 24) * 2 - 1
                // Keep the original four excitations bit-identical. New
                // voicings add a fundamental to the noisy string attack so a
                // random overtone cannot hide a major/minor-defining third.
                return Float(emphasizeFundamental
                    ? noise * 0.45 + sin(2 * .pi * Double(index) / Double(length)) * 0.55
                    : noise)
            }
            let offset = Int(Double(sampleRate) * Double(string) * stringSpacing)
            guard offset < count else { continue }
            var index = 0
            for frame in offset..<count {
                let next = (index + 1) % length
                let value = delay[index]
                delay[index] = 0.496 * (value + delay[next])
                let attack = min(1, Float(frame - offset) / Float(sampleRate) / Float(attackTime))
                output[frame] += value * attack
                index = next
            }
        }
        let peak = output.reduce(Float(0)) { max($0, abs($1)) }
        let gain: Float = peak > 0 ? 0.70 / peak : 0
        let fadeFrames = min(count, Int(Double(sampleRate) * 0.08))
        for frame in output.indices {
            let fade = min(1, Float(count - 1 - frame) / Float(max(1, fadeFrames)))
            output[frame] *= gain * fade
        }
        return output
    }
}
