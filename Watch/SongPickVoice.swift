import AVFoundation
import Foundation

/// An independent, sampled nylon guitar. The song arrangement supplies
/// pitch and the wrist supplies timing and expression.
@MainActor
final class SongPickVoice {
    nonisolated static let sampleRate = NylonFingerboard.sampleRate
    nonisolated static let accentThreshold = 0.62

    nonisolated static func relativeDB(strength: Double, hasPitch: Bool) -> Double {
        let s = strength.isFinite ? min(1, max(0, strength)) : 0.5
        return hasPitch ? -3.5 + 6 * s : -8 + 4 * s
    }

    private let sampleBankURL: URL?
    private var instrument = NylonFingerboard.fallback
    private var prepared = false
    private let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    init(sampleBankURL: URL? = nil) {
        self.sampleBankURL = sampleBankURL
    }

    func prepare() {
        guard !prepared else { return }
        instrument = sampleBankURL.flatMap(NylonFingerboard.init(contentsOf:)) ?? .bundled
        prepared = true
    }

    func buffer(midiNote: Int?, strength: Double, harmonyNote: Int? = nil,
                forWatchSpeaker: Bool = false) -> AVAudioPCMBuffer {
        let count = NylonFingerboard.frameCount(muted: midiNote == nil, strength: strength)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        pcm.frameLength = pcm.frameCapacity
        let channels = pcm.floatChannelData!
        instrument.write(note: midiNote, harmonyNote: harmonyNote, strength: strength, to: channels[0], count: count)
        if forWatchSpeaker {
            Self.voiceForSmallSpeaker(channels[0], count: count)
        }
        // Keep a centre-panned take at the calibrated level in both channels.
        // The mixer's automatic mono-to-stereo connection applies a -3 dB pan law.
        channels[1].update(from: channels[0], count: count)
        return pcm
    }

    /// Project the recorded string attack into the midrange for the small
    /// speaker. The tail then retreats to leave the singer room between strokes.
    private static func voiceForSmallSpeaker(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        let rate = sampleRate
        let lowAlpha = Float(1 - exp(-2 * Double.pi * 560 / rate))
        let highAlpha = Float(1 - exp(-2 * Double.pi * 3300 / rate))
        let start = Int(0.105 * rate), end = Int(0.205 * rate)
        var low: Float = 0, high: Float = 0
        for i in 0..<count {
            let input = samples[i]
            low += lowAlpha * (input - low)
            high += highAlpha * (input - high)
            let fade = min(1, max(0, Float(i - start) / Float(end - start)))
            samples[i] = (input + 0.90 * (high - low) - 0.28 * low) * (1 - 0.42 * fade)
        }
    }

    /// Same renderer as the watch. A standalone audition tool may supply the packaged WAV directly.
    nonisolated static func render(midiNote: Int?, strength: Double, sampleBankURL: URL? = nil, harmonyNote: Int? = nil) -> [Float] {
        let bank = sampleBankURL.flatMap(NylonFingerboard.init(contentsOf:)) ?? .bundled
        let frames = NylonFingerboard.frameCount(muted: midiNote == nil, strength: strength)
        return [Float](unsafeUninitializedCapacity: frames) { storage, count in
            bank.write(note: midiNote, harmonyNote: harmonyNote, strength: strength, to: storage.baseAddress!, count: frames)
            count = frames
        }
    }
}

private struct NylonFingerboard: Sendable {
    static let sampleRate = 22_050.0
    private static let firstNote = 45
    private static let noteSpacing = 3
    private static let sampleCount = 11
    private static let framesPerSample = 44_100
    private let recordings: [Float]
    private let pickRecordings: [Float]

    private init(recordings: [Float], pickRecordings: [Float]) {
        self.recordings = recordings
        self.pickRecordings = pickRecordings
    }
    static let fallback = NylonFingerboard(recordings: [], pickRecordings: [])

    init?(contentsOf url: URL) {
        guard let finger = Self.loadBank(url) else { return nil }
        recordings = finger
        let pickURL = url.deletingLastPathComponent().appendingPathComponent("WristNylonPick.wav")
        pickRecordings = Self.loadBank(pickURL) ?? []
    }

    private static func loadBank(_ url: URL) -> [Float]? {
        let frames = Self.framesPerSample * Self.sampleCount
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.processingFormat.sampleRate == Self.sampleRate,
              file.processingFormat.channelCount == 1,
              file.length == frames,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              (try? file.read(into: buffer)) != nil, buffer.frameLength == frames,
              let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: frames))
    }

    static let bundled: NylonFingerboard = {
        let bundle = Bundle.main
        let name = "WristNylonFinger"
        let url = bundle.url(forResource: name, withExtension: "wav")
            ?? bundle.url(forResource: name, withExtension: "wav", subdirectory: "Guitar")
        return url.flatMap(NylonFingerboard.init(contentsOf:)) ?? .fallback
    }()

    private static func force(_ strength: Double) -> Double {
        strength.isFinite ? min(1, max(0, strength)) : 0.5
    }

    static func frameCount(muted: Bool, strength: Double) -> Int {
        let s = force(strength)
        let duration = muted ? 0.068 + 0.042 * s : 0.34 + 0.53 * s
        return Int(duration * sampleRate)
    }

    func write(note: Int?, harmonyNote: Int?, strength: Double, to output: UnsafeMutablePointer<Float>, count: Int) {
        let s = Self.force(strength)
        let accented = s >= SongPickVoice.accentThreshold
        let mainNote = note.map { !accented && $0 < 57 ? $0 + 12 : $0 }
        writeSingle(note: mainNote, strength: s, picked: true, to: output, count: count)
        guard let midi = note else { return }
        if accented && (42...66).contains(midi) {
            // All strings belong to one wrist attack. The optional fifth is
            // supplied only by a confirmed chord; a bass-only match uses octaves.
            let hasFifth = harmonyNote == midi + 7
            if hasFifth {
                addString(midi: midi + 7, strength: s, picked: false, delay: 0.010,
                          duration: 0.30, level: 0.73, to: output, count: count)
            }
            addString(midi: midi + 12, strength: s, picked: true, delay: hasFifth ? 0.023 : 0.016,
                      duration: 0.26, level: 0.70, to: output, count: count)
            let trim: Float = hasFifth ? 0.52 : 0.66
            for i in 0..<count { output[i] *= trim }
        }
        // Keep the attack distinct and ease the sustained part back under the singer.
        let start = Int(0.10 * Self.sampleRate)
        let length = 0.14 * Self.sampleRate
        for i in start..<count {
            let t = min(1, Double(i - start) / length)
            output[i] *= Float(1 - 0.54 * t * t * (3 - 2 * t))
        }
    }

    private func addString(midi: Int, strength: Double, picked: Bool, delay: Double, duration: Double,
                           level: Float, to output: UnsafeMutablePointer<Float>, count: Int) {
        let start = Int(delay * Self.sampleRate)
        let frames = min(count - start, Int(duration * Self.sampleRate))
        guard frames > 0 else { return }
        var samples = [Float](repeating: 0, count: frames)
        samples.withUnsafeMutableBufferPointer { storage in
            writeSingle(note: midi, strength: strength, picked: picked, to: storage.baseAddress!, count: frames)
        }
        for i in samples.indices { output[start + i] += level * samples[i] }
    }

    private func writeSingle(note: Int?, strength s: Double, picked: Bool, to output: UnsafeMutablePointer<Float>, count: Int) {
        let muted = note == nil
        // Keep solo notes in the useful mid register of this guitar. The muted
        // contact uses a real low string, damped before its periodic tail develops.
        let midi = min(78, max(42, note ?? 48))
        let nearest = Int((Double(midi - Self.firstNote) / Double(Self.noteSpacing)).rounded())
        let index = min(Self.sampleCount - 1, max(0, nearest))
        let anchor = Self.firstNote + Self.noteSpacing * index
        let increment = pow(2, Double(midi - anchor) / 12)
        let offset = index * Self.framesPerSample
        let fallbackFrequency = 2 * Double.pi * 440 * pow(2, Double(midi - 69) / 12)
        let volume = Float((0.61 + 0.37 * s) * (muted ? 0.65 : 1.0))
        let brightness: Float = muted ? 0.54 : Float(0.70 + 0.19 * s)
        let take = picked && !pickRecordings.isEmpty ? pickRecordings : recordings
        let releaseAt = muted ? Double(count) * 0.10 : Double(count) * 0.58
        let releaseLength = Double(count - 1) - releaseAt
        var sourceFrame = 0.0
        var previous: Float = 0
        for i in 0..<count {
            let raw: Float
            if take.isEmpty {
                // A missing resource still yields a soft pitched note. Release
                // packages verify the complete recorded bank at build time.
                let t = Double(i) / Self.sampleRate
                let phase = fallbackFrequency * t
                raw = Float((0.20 * sin(phase) + 0.065 * sin(2 * phase) * exp(-5 * t))
                            * min(1, t * 180) * exp(-2.6 * t))
            } else {
                let j = Int(sourceFrame)
                let a = take[offset + j], b = take[offset + j + 1]
                raw = a + (b - a) * Float(sourceFrame - Double(j))
            }
            previous += brightness * (raw - previous)
            let release = min(1, max(0, (Double(i) - releaseAt) / releaseLength))
            let envelope = 1 - release * release * (3 - 2 * release)
            output[i] = volume * previous * Float(envelope)
            sourceFrame += increment
        }
    }
}
