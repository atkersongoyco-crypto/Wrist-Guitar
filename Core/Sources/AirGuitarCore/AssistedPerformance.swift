import Foundation

/// Only explicitly known harmony produces pitched notes. Unknown accompaniment
/// uses an untuned, noise-based palm mute instead of guessing a song's key.
public enum AssistedSource: Equatable, Sendable {
    case originalDemo(playbackTime: TimeInterval)
    case freePlay
    case detected(Chord)
    case unpitched
}

public enum AssistedVoice: Hashable, Sendable {
    case strum(Chord)
    case reply(Chord)
    case mutedStrum
    case mutedReply

    public var duration: TimeInterval {
        switch self {
        case .strum: return 0.20
        case .reply: return 0.08
        case .mutedStrum: return 0.14
        case .mutedReply: return 0.065
        }
    }

    /// Fixed short-voice bank: 24 triads plus two unpitched voices, prepared
    /// before motion callbacks. Long manual tails use only manualVoicings.
    public static var allVoices: [AssistedVoice] {
        Chord.allCases.flatMap { [.strum($0), .reply($0)] } + [.mutedStrum, .mutedReply]
    }
}

public struct AssistedHit: Sendable {
    public let offset: TimeInterval
    public let voice: AssistedVoice
    public let gain: Double
}

public struct AssistedPhrase: Sendable {
    /// Monotonic performance time. Never mix file seconds with uptime here.
    public let timestamp: TimeInterval
    public let chord: Chord?
    public let hits: [AssistedHit]
    /// False when bounded response time took priority over an unsuitable grid.
    public let secondaryIsBeatAligned: Bool
    public var duration: TimeInterval {
        hits.map { $0.offset + $0.voice.duration }.max() ?? 0
    }
}

/// Two short sounds per accepted gesture: a prompt sweep, then a quiet reply.
/// This classifies no audio and never claims the default pulse matches a song.
public struct AssistedPerformance: Sendable {
    public private(set) var freePlayStrumCount = 0
    private var fallbackReference: TimeInterval?

    public init() {}

    public mutating func reset() {
        freePlayStrumCount = 0
        fallbackReference = nil
    }

    /// The bundled original demo is C / Am / F / G, 2.5 seconds per chord.
    /// Its known score is not applied to arbitrary imported songs.
    public static func guidedChord(playbackTime: TimeInterval) -> Chord {
        guard playbackTime.isFinite, playbackTime > 0 else { return .c }
        let position = playbackTime.truncatingRemainder(dividingBy: 10)
        return progression[min(3, Int(position / 2.5))]
    }

    /// `beat.referenceBeat` and `timestamp` share monotonic uptime. An optional
    /// beat determines timing only; harmony always comes from `source`.
    public mutating func phrase(at timestamp: TimeInterval, velocity: Double,
                                source: AssistedSource, beat: BeatEstimate? = nil) -> AssistedPhrase {
        let time = timestamp.isFinite ? max(0, timestamp) : 0
        if fallbackReference == nil { fallbackReference = time }
        let chord: Chord?
        switch source {
        case .originalDemo(let playbackTime):
            chord = Self.guidedChord(playbackTime: playbackTime)
        case .freePlay:
            chord = Self.progression[(freePlayStrumCount / 4) % Self.progression.count]
            // Bounded counter retains the musical cycle over long sessions.
            freePlayStrumCount = (freePlayStrumCount + 1) % 16
        case .detected(let detected): chord = detected
        case .unpitched: chord = nil
        }

        let defaultReference: TimeInterval
        if case .originalDemo(let playbackTime) = source, playbackTime.isFinite {
            defaultReference = time - max(0, playbackTime)
        } else {
            defaultReference = fallbackReference ?? time
        }
        let validBeat = beat.flatMap {
            $0.isValid && (40...240).contains($0.bpm) && (time - $0.referenceBeat).isFinite ? $0 : nil
        }
        let halfBeat = (validBeat?.period ?? (60 / 96.0)) / 2
        let reference = validBeat?.referenceBeat ?? defaultReference
        // Skip an imminent grid line rather than making the reply an accidental
        // double trigger. Never leave a tail waiting more than 400 milliseconds.
        let phase = (time - reference).truncatingRemainder(dividingBy: halfBeat)
        let positivePhase = phase < 0 ? phase + halfBeat : phase
        var delay = halfBeat - positivePhase
        if delay < 0.15 - 0.000_001 { delay += halfBeat }
        let aligned = (0.15 - 0.000_001...0.40 + 0.000_001).contains(delay)
        if !aligned { delay = min(0.40, max(0.15, halfBeat)) }
        delay = min(0.40, max(0.15, delay))

        let strength = velocity.isFinite ? min(1, max(0, velocity)) : 0
        // Gentle wrist gestures retain a clear attack; strength adds expression.
        let gain = 0.72 + 0.28 * sqrt(strength)
        let first: AssistedVoice = chord.map { .strum($0) } ?? .mutedStrum
        let second: AssistedVoice = chord.map { .reply($0) } ?? .mutedReply
        return AssistedPhrase(timestamp: time, chord: chord,
                              hits: [AssistedHit(offset: 0, voice: first, gain: gain),
                                     AssistedHit(offset: delay, voice: second, gain: gain * 0.38)],
                              secondaryIsBeatAligned: aligned)
    }

    private static let progression: [Chord] = [.c, .aMinor, .f, .g]
}

/// The exact deterministic PCM bank used by the Watch and offline previews.
/// Rendering belongs in preparation/export code, never in a motion callback.
public enum AssistedSoundRenderer {
    public static func render(voice: AssistedVoice, sampleRate: Int = 44_100) -> [Float] {
        guard (8_000...96_000).contains(sampleRate) else { return [] }
        switch voice {
        case .strum(let chord):
            return PluckedStringRenderer.render(chord: chord, sampleRate: sampleRate, duration: voice.duration)
        case .reply(let chord):
            return PluckedStringRenderer.render(notes: [chord.replyMIDINote], sampleRate: sampleRate, duration: voice.duration)
        case .mutedStrum, .mutedReply:
            let count = Int(Double(sampleRate) * voice.duration)
            var output = [Float](repeating: 0, count: count)
            var seed: UInt64 = voice == .mutedStrum ? 0xA17_6A17 : 0xEC40_2026
            var lowPass = 0.0
            for frame in output.indices {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let noise = Double(seed >> 40) / Double(1 << 24) * 2 - 1
                lowPass = 0.42 * noise + 0.58 * lowPass
                let time = Double(frame) / Double(sampleRate)
                let attack = min(1, time / 0.002)
                let fade = min(1, Double(count - 1 - frame) / (Double(sampleRate) * 0.014))
                // Broadband, quickly damped noise: no oscillator or MIDI pitch.
                output[frame] = Float((noise - lowPass * 0.8) * attack * exp(-time * 38) * fade)
            }
            let peak = output.reduce(Float(0)) { max($0, abs($1)) }
            if peak > 0 {
                for index in output.indices { output[index] *= 0.7 / peak }
            }
            return output
        }
    }

    public static func render(phrase: AssistedPhrase, sampleRate: Int = 44_100) -> [Float] {
        render(phrases: [phrase], sampleRate: sampleRate)
    }

    /// Offline performance preview, relative to its earliest gesture. A new
    /// gesture replaces the lead and reply exactly as on the Watch's two nodes.
    /// Exports are bounded to 60 seconds; longer material should be streamed.
    public static func render(phrases: [AssistedPhrase], sampleRate: Int = 44_100) -> [Float] {
        guard (8_000...96_000).contains(sampleRate), !phrases.isEmpty else { return [] }
        let ordered = phrases.sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first, let last = ordered.last else { return [] }
        let duration = last.timestamp - first.timestamp + last.duration
        guard duration.isFinite, duration > 0, duration <= 60 else { return [] }
        var output = [Float](repeating: 0, count: Int(ceil(duration * Double(sampleRate))))
        var bank: [AssistedVoice: [Float]] = [:]
        for (index, phrase) in ordered.enumerated() {
            let nextTime = index + 1 < ordered.count ? ordered[index + 1].timestamp : .infinity
            for (hitIndex, hit) in phrase.hits.enumerated() {
                let startTime = phrase.timestamp + hit.offset
                if hitIndex > 0 && startTime >= nextTime { continue }
                if bank[hit.voice] == nil { bank[hit.voice] = render(voice: hit.voice, sampleRate: sampleRate) }
                guard let samples = bank[hit.voice] else { continue }
                let offset = max(0, Int(((startTime - first.timestamp) * Double(sampleRate)).rounded()))
                var length = min(samples.count, max(0, output.count - offset))
                if nextTime.isFinite {
                    length = min(length, max(0, Int(((nextTime - startTime) * Double(sampleRate)).rounded())))
                }
                for frame in 0..<length { output[offset + frame] += samples[frame] * Float(hit.gain) }
            }
        }
        // A deliberately fast offline gesture sequence can overlap attacks.
        // Saturation here protects exported PCM without altering normal levels.
        for index in output.indices { output[index] = min(1, max(-1, output[index])) }
        return output
    }

    /// Standard mono, little-endian 16-bit PCM WAV, playable without AVFoundation.
    public static func wavData(phrases: [AssistedPhrase], sampleRate: Int = 44_100) -> Data? {
        let samples = render(phrases: phrases, sampleRate: sampleRate)
        guard !samples.isEmpty else { return nil }
        let bytes = UInt32(samples.count * 2)
        var data = Data(capacity: Int(bytes) + 44)
        func append16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func append32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        data.append(contentsOf: "RIFF".utf8); append32(bytes + 36)
        data.append(contentsOf: "WAVEfmt ".utf8); append32(16)
        append16(1); append16(1); append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(contentsOf: "data".utf8); append32(bytes)
        for sample in samples {
            let value = Int16((Double(min(1, max(-1, sample))) * Double(Int16.max)).rounded())
            append16(UInt16(bitPattern: value))
        }
        return data
    }
}
