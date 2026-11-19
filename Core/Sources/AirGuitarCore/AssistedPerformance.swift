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
    case upstroke(Chord)
    case picked(Int)
    case reply(Chord)
    case mutedStrum
    case mutedReply

    public var duration: TimeInterval {
        switch self {
        case .strum: return 0.36
        case .upstroke: return 0.14
        case .picked: return 0.32
        case .reply: return 0.08
        case .mutedStrum: return 0.14
        case .mutedReply: return 0.065
        }
    }

    /// A3 through C5, a shared register for the upper guitar strings.
    public static let pickedRange = 57...72

    /// Prepared before motion callbacks. Individual strings are shared by
    /// all chord voicings rather than baking a separate arpeggio per chord.
    public static var allVoices: [AssistedVoice] {
        Chord.allCases.flatMap { [.strum($0), .upstroke($0), .reply($0)] }
            + pickedRange.map(AssistedVoice.picked) + [.mutedStrum, .mutedReply]
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
    /// A quiet wrist gesture starts on a single string. A fuller gesture
    /// starts on several strings swept together.
    public var isArpeggio: Bool {
        if case .picked = hits.first?.voice { return true }
        return false
    }
    public var duration: TimeInterval {
        hits.map { $0.offset + $0.voice.duration }.max() ?? 0
    }
}

/// Each accepted gesture plays a prompt sweep, with an optional quiet reply.
/// This classifies no audio and never claims the default pulse matches a song.
public struct AssistedPerformance: Sendable {
    public private(set) var freePlayStrumCount = 0
    private var fallbackReference: TimeInterval?
    private var lastListeningTime: TimeInterval?

    public init() {}

    /// Leave room for quiet sections of the backing track without changing
    /// its volume or delaying the player's attack.
    public static func backingBlend(averagePowerDB: Double) -> Double {
        guard averagePowerDB.isFinite else { return 1 }
        let adjustmentDB = min(0, max(-6, (averagePowerDB + 18) * 0.4))
        return pow(10, adjustmentDB / 20)
    }

    public mutating func reset() {
        freePlayStrumCount = 0
        fallbackReference = nil
        lastListeningTime = nil
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
                                source: AssistedSource, beat: BeatEstimate? = nil,
                                includeReply: Bool = true) -> AssistedPhrase {
        let time = timestamp.isFinite ? max(0, timestamp) : 0
        if fallbackReference == nil { fallbackReference = time }
        let chord = chord(for: source)

        let strength = velocity.isFinite ? min(1, max(0, velocity)) : 0
        let gain = 0.48 + 0.48 * strength
        let first: AssistedVoice = chord.map { .strum($0) } ?? .mutedStrum
        let sweep = AssistedHit(offset: 0, voice: first, gain: gain)
        guard includeReply else {
            return AssistedPhrase(timestamp: time, chord: chord, hits: [sweep], secondaryIsBeatAligned: false)
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

        let second: AssistedVoice = chord.map { .reply($0) } ?? .mutedReply
        return AssistedPhrase(timestamp: time, chord: chord,
                              hits: [sweep, AssistedHit(offset: delay, voice: second, gain: gain * 0.38)],
                              secondaryIsBeatAligned: aligned)
    }

    private static let progression: [Chord] = [.c, .aMinor, .f, .g]

    private mutating func chord(for source: AssistedSource) -> Chord? {
        switch source {
        case .originalDemo(let time): return Self.guidedChord(playbackTime: time)
        case .freePlay:
            let result = Self.progression[freePlayStrumCount / 4]
            freePlayStrumCount = (freePlayStrumCount + 1) % 16
            return result
        case .detected(let chord): return chord
        case .unpitched: return nil
        }
    }

    /// One wrist gesture starts one bounded musical response. Times in
    /// accentOffsets are seconds *after* the gesture on the recording's clock.
    /// The callback can withhold a note when harmony changes or is uncertain.
    public mutating func listeningPhrase(at timestamp: TimeInterval, velocity: Double,
                                         source: AssistedSource, beat: BeatEstimate? = nil,
                                         accentOffsets: [TimeInterval] = [],
                                         chordAtOffset: ((TimeInterval) -> Chord?)? = nil) -> AssistedPhrase {
        let time = timestamp.isFinite ? max(0, timestamp) : 0
        let strength = velocity.isFinite ? min(1, max(0, velocity)) : 0
        let gain = 0.48 + 0.48 * strength
        let interval = lastListeningTime.map { time - $0 }
        lastListeningTime = time
        guard let chord = chord(for: source) else {
            return AssistedPhrase(timestamp: time, chord: nil,
                                  hits: [AssistedHit(offset: 0, voice: .mutedStrum, gain: gain)],
                                  secondaryIsBeatAligned: false)
        }

        let arpeggio = strength < 0.68
        let pulse = beat.flatMap {
            $0.isValid && $0.confidence >= RhythmGame.minimumConfidence && (40...240).contains($0.bpm) ? $0 : nil
        }
        let chordNotes = Self.pickedNotes(in: chord)
        let lowNote = chordNotes[0]  // The register covers every pitch class.
        // Strong strokes sweep the whole chord from the bass. A medium brush
        // between beats crosses the top strings in the opposite order.
        var lead: AssistedVoice = arpeggio ? .picked(lowNote) : .strum(chord)
        if !arpeggio, strength < 0.80, let pulse {
            let phase = (time - pulse.referenceBeat) / pulse.period
            if abs(phase - phase.rounded()) >= 0.35 { lead = .upstroke(chord) }
        }
        var hits = [AssistedHit(offset: 0, voice: lead, gain: gain)]
        let timing = Self.listeningOffsets(at: time, beat: pulse, accents: accentOffsets,
                                           previousInterval: interval, strength: strength)
        // A brushed chord has already sounded several strings. Give it one
        // closing note, leaving the fuller space to the gentler arpeggio.
        let candidates = timing.times.compactMap { offset -> (TimeInterval, Chord)? in
            if let chordAtOffset {
                guard let harmony = chordAtOffset(offset) else { return nil }
                return (offset, harmony)
            }
            return (offset, chord)
        }
        let answers = arpeggio ? candidates[...] : candidates.suffix(1)
        var lastNote = arpeggio ? lowNote : chordNotes[chordNotes.count / 2]
        for (index, answer) in answers.enumerated() {
            let (offset, harmony) = answer
            let tones = Self.pickedNotes(in: harmony)
            let nextNote: Int
            if arpeggio {
                // Minimise the jump across a chord change. A high common
                // tone at the top can resolve down to a neighbouring string.
                nextNote = tones.first(where: { $0 > lastNote })
                    ?? tones.last(where: { $0 < lastNote }) ?? lastNote
            } else {
                nextNote = tones.last(where: { $0 < lastNote })
                    ?? tones.first(where: { $0 > lastNote }) ?? lastNote
            }
            let weight = (arpeggio && index == 0 && answers.count > 1) ? 0.79 : 0.62
            hits.append(AssistedHit(offset: offset, voice: .picked(nextNote), gain: gain * weight))
            lastNote = nextNote
        }
        return AssistedPhrase(timestamp: time, chord: chord, hits: hits,
                              secondaryIsBeatAligned: hits.count > 1 && timing.usesBeat)
    }

    private static func pickedNotes(in chord: Chord) -> [Int] {
        AssistedVoice.pickedRange.filter { note in
            let interval = (note - chord.rootPitchClass) % 12
            return interval == 0 || interval == (chord.isMinor ? 3 : 4) || interval == 7
        }
    }

    private static func listeningOffsets(at time: TimeInterval, beat: BeatEstimate?,
                                         accents: [TimeInterval], previousInterval: TimeInterval?,
                                         strength: Double) -> (times: [TimeInterval], usesBeat: Bool) {
        // Closely spaced drum transients should not turn a slow wrist sweep
        // into a flurry of notes. Preserve the actual attack times we retain.
        var selected = [TimeInterval]()
        for offset in accents.filter({ $0.isFinite && (0.22...1.24).contains($0) }).sorted() {
            if let last = selected.last, offset - last < 0.25 { continue }
            selected.append(offset)
            if selected.count == 2 { break }
        }
        if !selected.isEmpty { return (selected, false) }

        if let beat {
            let step = beat.period < 0.54 ? beat.period : beat.period / 2
            let cycles = (time - beat.referenceBeat) / step
            if cycles.isFinite {
                let phase = cycles - floor(cycles)
                var first = (1 - phase) * step
                if first < 0.22 { first += step }
                selected.append(first)
                if first + step <= 1.24 { selected.append(first + step) }
                return (selected, true)
            }
        }
        // Rubato: let one quieter closing string follow the player's spacing
        // or the initial stroke's decay. This does not establish a song tempo.
        let decay = 0.36 + strength * 0.22
        let previous = previousInterval.flatMap { (0.35...3.0).contains($0) ? $0 / 2 : nil }
        return ([min(0.78, max(0.32, previous ?? decay))], false)
    }
}

/// The exact deterministic PCM bank used by the Watch and offline previews.
/// Rendering belongs in preparation/export code, never in a motion callback.
public enum AssistedSoundRenderer {
    public static let watchSampleRate = 16_000

    public static func render(voice: AssistedVoice, sampleRate: Int = 44_100) -> [Float] {
        guard (8_000...96_000).contains(sampleRate) else { return [] }
        switch voice {
        case .strum(let chord):
            return PluckedStringRenderer.render(notes: chord.midiNotes, sampleRate: sampleRate,
                                                duration: voice.duration,
                                                emphasizeFundamental: !Chord.manualVoicings.contains(chord),
                                                stringSpacing: 0.016, attackTime: 0.007)
        case .upstroke(let chord):
            return PluckedStringRenderer.render(notes: Array(chord.midiNotes.suffix(3).reversed()),
                                                sampleRate: sampleRate, duration: voice.duration,
                                                emphasizeFundamental: true, stringSpacing: 0.014, attackTime: 0.005)
        case .picked(let note):
            guard AssistedVoice.pickedRange.contains(note) else { return [] }
            return PluckedStringRenderer.fingerpick(note: note, sampleRate: sampleRate, duration: voice.duration)
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
                let attack = min(1, time / (voice == .mutedStrum ? 0.006 : 0.002))
                let fade = min(1, Double(count - 1 - frame) / (Double(sampleRate) * 0.014))
                // Broadband, quickly damped noise: no oscillator or MIDI pitch.
                let excitation = voice == .mutedStrum ? lowPass : noise - lowPass * 0.8
                output[frame] = Float(excitation * attack * exp(-time * 38) * fade)
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
