import AirGuitarCore
import AVFoundation
import Foundation

enum LocalHarmonyReader {
    static let step = 0.5
    static let blockSize = 12

    /// Read a few seconds ahead, off the main and audio threads. Memory and work
    /// per request stay bounded even if an imported song is several hours long.
    static func read(url: URL, first: Int) -> [Int: Chord] {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else { return [:] }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard (8000...192000).contains(rate), (1...32).contains(format.channelCount) else { return [:] }
        let stride = max(1, Int((rate / 5500).rounded()))
        let capacity = AVAudioFrameCount(rate * 0.39)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [:] }
        var result = [Int: Chord]()
        for slot in first..<(first + blockSize) {
            guard !Task.isCancelled else { return [:] }
            let start = AVAudioFramePosition((Double(slot) * step + 0.055) * rate)
            guard start < file.length else { break }
            file.framePosition = start
            let available = AVAudioFrameCount(min(file.length - start, AVAudioFramePosition(capacity)))
            guard (try? file.read(into: buffer, frameCount: available)) != nil,
                  let channels = buffer.floatChannelData else { break }
            let length = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)
            var mono = [Float]()
            for base in Swift.stride(from: 0, to: length - stride + 1, by: stride) {
                var sum: Float = 0
                for c in 0..<channelCount {
                    for frame in base..<(base + stride) { sum += channels[c][frame] }
                }
                mono.append(sum / Float(stride * channelCount))
            }
            result[slot] = LocalChordMatcher.match(mono: mono, sampleRate: rate / Double(stride))
        }
        return result
    }
}

@MainActor
final class LocalHarmonyGuide {
    private var url: URL?
    private var blocks = [Int: [Int: Chord]]()
    private var pending: Task<[Int: Chord], Never>?
    private var generation = UUID()

    func configure(url: URL?) {
        pending?.cancel()
        pending = nil
        generation = UUID()
        blocks.removeAll()
        self.url = url
    }

    func chord(at time: Double) -> Chord? {
        guard let url, time.isFinite, time >= 0 else { return nil }
        let slot = Int(time / LocalHarmonyReader.step)
        let size = LocalHarmonyReader.blockSize
        let first = slot / size * size
        let next = blocks[first] == nil ? first : first + size
        if pending == nil, blocks[next] == nil, next == first || slot >= next - 3 {
            let id = generation
            let worker = Task.detached(priority: .utility) {
                LocalHarmonyReader.read(url: url, first: next)
            }
            pending = worker
            Task { [weak self] in
                let matches = await worker.value
                guard let self, id == self.generation else { return }
                self.blocks = self.blocks.filter { $0.key >= first }
                self.blocks[next] = matches
                self.pending = nil
            }
        }
        return blocks[first]?[slot]
    }
}
