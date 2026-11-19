import AirGuitarCore
import AVFoundation
import Foundation

struct LocalSongFrame {
    let chord: Chord?
    let bass: Int?
    // Stereo programme RMS measured over 120 ms, at 20 ms intervals.
    let levels: [Float]

    func level(at offset: Double) -> Float {
        guard !levels.isEmpty else { return 0 }
        let index = min(levels.count - 1, max(0, Int(offset / LocalHarmonyReader.levelStep)))
        return levels[index]
    }
}

struct SongPickContext {
    var midiNote: Int?
    var sourceRMS: Float?
    var harmonyNote: Int?

    // Keep the picked voice in a small, playable register around A3. Accents
    // establish the root; light offbeats can answer with its open fifth.
    mutating func use(chord: Chord, strength: Double) {
        let accent = strength >= SongPickVoice.accentThreshold
        let note = Self.note(forPitchClass: (chord.rootPitchClass + (accent ? 0 : 7)) % 12)
        midiNote = note
        harmonyNote = accent ? note + 7 : nil
    }

    static func note(forPitchClass pitch: Int) -> Int { 51 + (pitch - 3 + 12) % 12 }
}

enum LocalHarmonyReader {
    static let step = 0.5
    static let levelStep = 0.02
    static let blockSize = 12

    static func read(url: URL, first: Int) -> [Int: Chord] {
        readFrames(url: url, first: first).compactMapValues(\.chord)
    }

    /// Small, overlapping blocks keep chord boundaries and mix levels available
    /// across cache hand-offs. Analysis and file decoding never run on a gesture.
    static func readFrames(url: URL, first: Int) -> [Int: LocalSongFrame] {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else { return [:] }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard (8000...192000).contains(rate), (1...32).contains(format.channelCount) else { return [:] }
        let stride = max(1, Int((rate / 5500).rounded()))
        let capacity = AVAudioFrameCount(ceil(rate * (step + 0.12)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [:] }
        var result = [Int: LocalSongFrame]()
        for slot in max(0, first - 1)..<(first + blockSize + 1) {
            guard !Task.isCancelled else { return [:] }
            let start = AVAudioFramePosition(Double(slot) * step * rate)
            guard start < file.length else { break }
            file.framePosition = start
            let available = AVAudioFrameCount(min(file.length - start, AVAudioFramePosition(capacity)))
            guard (try? file.read(into: buffer, frameCount: available)) != nil,
                  let channels = buffer.floatChannelData else { break }
            let length = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)
            let analysisEnd = min(length, Int(rate * 0.445))
            var mono = [Float]()
            for base in Swift.stride(from: Int(rate * 0.055), to: analysisEnd - stride + 1, by: stride) {
                var sum: Float = 0
                for c in 0..<channelCount {
                    for frame in base..<(base + stride) { sum += channels[c][frame] }
                }
                mono.append(sum / Float(stride * channelCount))
            }
            let match = LocalChordMatcher.analyze(mono: mono, sampleRate: rate / Double(stride))
            // Integrate each channel's energy separately so stereo phase
            // cancellation cannot make an audible backing appear silent.
            var energy = [Double](repeating: 0, count: (length + 3) / 4 + 1)
            for i in 1..<energy.count {
                var power = 0.0
                for c in 0..<channelCount {
                    let value = Double(channels[c][(i - 1) * 4])
                    power += value * value
                }
                energy[i] = energy[i - 1] + power / Double(channelCount)
            }
            let levels = (0..<25).map { index -> Float in
                let a = min(energy.count - 1, Int(Double(index) * levelStep * rate / 4))
                let b = min(energy.count - 1, a + Int(0.12 * rate / 4))
                guard b > a else { return 0 }
                return Float(sqrt(max(0, energy[b] - energy[a]) / Double(b - a)))
            }
            result[slot] = LocalSongFrame(chord: match.chord, bass: match.bass, levels: levels)
        }
        return result
    }

    static func pick(at time: Double, strength: Double, frames: [Int: LocalSongFrame]) -> SongPickContext {
        let slot = Int(time / step)
        guard let now = frames[slot] else { return SongPickContext() }
        let rms = now.level(at: time - Double(slot) * step)
        var result = SongPickContext(midiNote: nil, sourceRMS: rms)
        guard rms > 0.003 else { return result }
        let before = frames[slot - 1], after = frames[slot + 1]
        // Fill only a short gap between two matching neighbours. An isolated
        // bass can anchor a picked note if another frame independently supports it.
        if let chord = now.chord ?? (before?.chord == after?.chord ? before?.chord : nil) {
            result.use(chord: chord, strength: strength)
        } else if let bass = now.bass, [before, after].contains(where: { frame in
            if frame?.bass == bass { return true }
            guard let chord = frame?.chord else { return false }
            let interval = (bass - chord.rootPitchClass + 12) % 12
            return interval == 0 || interval == 7 || interval == (chord.isMinor ? 3 : 4)
        }) {
            result.midiNote = SongPickContext.note(forPitchClass: bass)
        }
        return result
    }
}

@MainActor
final class LocalHarmonyGuide {
    private var url: URL?
    private var blocks = [Int: [Int: LocalSongFrame]]()
    private var pending = [Int: Task<Void, Never>]()
    private var generation = UUID()

    func configure(url: URL?) {
        guard self.url != url else { return }
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        generation = UUID()
        blocks.removeAll()
        self.url = url
    }

    private func frames(at time: Double) -> [Int: LocalSongFrame] {
        guard let url, time.isFinite, time >= 0, time < 1_000_000_000 else { return [:] }
        let slot = Int(time / LocalHarmonyReader.step)
        let size = LocalHarmonyReader.blockSize
        let first = slot / size * size
        let wanted = [first, first + size]
        for key in Array(pending.keys) where !wanted.contains(key) { pending.removeValue(forKey: key)?.cancel() }
        for key in Array(blocks.keys) where !wanted.contains(key) { blocks.removeValue(forKey: key) }
        let id = generation
        for key in wanted where blocks[key] == nil && pending[key] == nil {
            pending[key] = Task.detached(priority: .utility) { [weak self] in
                let data = LocalHarmonyReader.readFrames(url: url, first: key)
                guard !Task.isCancelled else { return }
                await self?.store(data, first: key, id: id)
            }
        }
        return blocks[first] ?? [:]
    }

    private func store(_ data: [Int: LocalSongFrame], first: Int, id: UUID) {
        guard id == generation, pending[first] != nil else { return }
        blocks[first] = data
        pending.removeValue(forKey: first)
    }

    func warm(at time: Double) { _ = frames(at: time) }

    func chord(at time: Double) -> Chord? {
        let block = frames(at: time)
        guard !block.isEmpty else { return nil }
        return block[Int(time / LocalHarmonyReader.step)]?.chord
    }

    func pick(at time: Double, strength: Double) -> SongPickContext {
        let block = frames(at: time)
        guard !block.isEmpty else { return SongPickContext() }
        return LocalHarmonyReader.pick(at: time, strength: strength, frames: block)
    }
}
