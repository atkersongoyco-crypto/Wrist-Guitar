import Foundation

/// A conservative short-window matcher over all 24 major/minor triads.
/// Unknown, quiet or competing harmony returns nil rather than inventing a key.
public enum LocalChordMatcher {
    public static func match(mono: [Float], sampleRate: Double) -> Chord? {
        analyze(mono: mono, sampleRate: sampleRate).chord
    }

    /// A passage may have a clear pitched bass even when its full triad is ambiguous.
    public static func analyze(mono: [Float], sampleRate: Double) -> (chord: Chord?, bass: Int?) {
        guard mono.count >= 512, mono.count <= 8192, (3000...12000).contains(sampleRate) else { return (nil, nil) }
        var energy = 0.0
        let window = mono.enumerated().map { index, sample in
            let value = Double(sample)
            energy += value * value
            return value * (0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(mono.count - 1)))
        }
        guard energy.isFinite, energy / Double(mono.count) > 0.000008 else { return (nil, nil) }

        let notes = 36...83
        func amplitude(at midi: Int) -> Double {
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            let coefficient = 2 * cos(2 * .pi * frequency / sampleRate)
            var a = 0.0
            var b = 0.0
            for value in window {
                let next = value + coefficient * a - b
                b = a
                a = next
            }
            return sqrt(max(0, a * a + b * b - coefficient * a * b))
        }
        let amplitudes = notes.map { amplitude(at: $0) }
        var chroma = Array(repeating: 0.0, count: 12)
        var salience = [Double](repeating: 0, count: amplitudes.count)
        for index in amplitudes.indices {
            // Suppress spectral leakage and upper harmonics from a strong bass.
            let neighbor = max(index > 0 ? amplitudes[index - 1] : 0,
                               index + 1 < amplitudes.count ? amplitudes[index + 1] : 0)
            var magnitude = amplitudes[index] - neighbor * 0.65
            if index >= 12 { magnitude -= amplitudes[index - 12] * 0.28 }
            if index >= 19 { magnitude -= amplitudes[index - 19] * 0.15 }
            // A bass note's fifth harmonic lies near a major third two
            // octaves up. It must not turn minor accompaniment into major.
            if index >= 28 { magnitude -= amplitudes[index - 28] * 0.13 }
            salience[index] = max(0, magnitude)
            chroma[(notes.lowerBound + index) % 12] += salience[index]
        }
        let total = chroma.reduce(0, +)
        guard total > 0 else { return (nil, nil) }
        chroma = chroma.map { $0 / total }
        var best = 0.0, second = 0.0
        var selected: Chord?
        for root in 0..<12 {
            for third in [3, 4] {
                let tones = [chroma[root], chroma[(root + third) % 12], chroma[(root + 7) % 12]]
                let coverage = tones.reduce(0, +)
                let weakest = tones.min() ?? 0
                let score = coverage + weakest * 0.35
                if score > best {
                    second = best
                    best = score
                    let thirdClass = (root + third) % 12
                    let rootPeak = amplitudes.enumerated().filter { (notes.lowerBound + $0.offset) % 12 == root }.map(\.element).max() ?? 0
                    let lowestRoot = amplitudes.indices.first {
                        (notes.lowerBound + $0) % 12 == root && amplitudes[$0] >= rootPeak * 0.15
                    }.map { notes.lowerBound + $0 } ?? notes.lowerBound
                    var thirdTotal = 0.0, independentThird = 0.0
                    for index in salience.indices where (notes.lowerBound + index) % 12 == thirdClass {
                        thirdTotal += salience[index]
                        if notes.lowerBound + index <= lowestRoot + 24 { independentThird += salience[index] }
                    }
                    // A high fifth harmonic alone is not evidence for a major
                    // third. Require substantial third support within two
                    // octaves of the bass root; otherwise leave it unpitched.
                    let supportedThird = independentThird >= thirdTotal * 0.35
                    selected = coverage >= 0.70 && weakest >= 0.075 && supportedThird
                        ? Chord(pitchClass: root, isMinor: third == 3) : nil
                } else {
                    second = max(second, score)
                }
            }
        }
        // A standard bass guitar reaches E1. Ignoring the octave below the
        // triad matcher often selects a vocal partial instead of the bass.
        let lowest = 27
        let bassSpectrum = (lowest..<notes.lowerBound).map { amplitude(at: $0) } + amplitudes
        var lowChroma = Array(repeating: 0.0, count: 12)
        for midi in 28...53 {
            let i = midi - lowest
            let neighbour = max(bassSpectrum[i - 1], bassSpectrum[i + 1])
            var peak = max(0, bassSpectrum[i] - 0.78 * neighbour)
            if i >= 12 { peak = max(0, peak - 0.40 * bassSpectrum[i - 12]) }
            let overtone = max(bassSpectrum[i + 12], bassSpectrum[i + 19])
            let support = min(1, overtone / max(peak, 1e-9))
            lowChroma[midi % 12] += peak * (0.65 + 0.35 * support)
        }
        let ordered = lowChroma.indices.sorted { lowChroma[$0] > lowChroma[$1] }
        let bass = ordered[0]
        let isClearBass = lowChroma[bass] > 1.6 * lowChroma[ordered[1]]
            && lowChroma[bass] > 0.31 * lowChroma.reduce(0, +)
            && lowChroma[bass] > 0.055 * total
        return (best - second >= 0.085 ? selected : nil, isClearBass ? bass : nil)
    }

}
