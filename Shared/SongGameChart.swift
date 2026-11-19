import Accelerate
import AirGuitarCore
import AVFoundation
import CryptoKit
import Foundation

struct SongGameChart: Codable, Sendable {
    let duration: Double
    let targets: [Double]

    static func load(url: URL, practice: Bool) async throws -> Self {
        let task = Task.detached(priority: .userInitiated) { try prepare(url: url, practice: practice) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private static func prepare(url: URL, practice: Bool) throws -> Self {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        guard (8000...384000).contains(rate), file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let duration = Double(file.length) / rate
        if practice {
            let beat = 60.0 / 96
            return Self(duration: duration, targets: Array(stride(from: beat, to: max(beat, duration - 0.18), by: beat)))
        }
        let attrs = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "g2|\(url.lastPathComponent)|\(attrs.fileSize ?? 0)|\(attrs.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WristGameCharts", isDirectory: true)
        let record = folder.appendingPathComponent(digest + ".json")
        if let data = try? Data(contentsOf: record), let chart = try? JSONDecoder().decode(Self.self, from: data),
           abs(chart.duration - duration) < 0.001 { return chart }
        let result = try scan(file: file, rate: rate, duration: duration)
        try Task.checkCancellation()
        if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil {
            try? JSONEncoder().encode(result).write(to: record, options: .atomic)
        }
        return result
    }

    /// Decode once. Energy is measured per channel so an out-of-phase stereo mix still has a chart.
    /// Sections overlap to keep a musical attack at a block boundary eligible for scoring.
    private static func scan(file: AVAudioFile, rate: Double, duration: Double) throws -> Self {
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw CocoaError(.fileReadCorruptFile) }
        let hop = max(1, Int((rate * 0.01).rounded()))
        let dt = Double(hop) / rate
        var energy: [Double] = []
        var partial = 0.0, collected = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: pcm, frameCount: AVAudioFrameCount(min(8192, file.length - file.framePosition)))
            guard pcm.frameLength > 0, let samples = pcm.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
            var offset = 0
            while offset < Int(pcm.frameLength) {
                let count = min(hop - collected, Int(pcm.frameLength) - offset)
                for c in 0..<channelCount {
                    var sum: Float = 0
                    vDSP_svesq(samples[c].advanced(by: offset), 1, &sum, vDSP_Length(count))
                    partial += Double(sum)
                }
                offset += count
                collected += count
                if collected == hop {
                    energy.append(sqrt(partial / Double(hop * channelCount)))
                    partial = 0
                    collected = 0
                }
            }
        }
        let block = Int((9.0 / dt).rounded())
        let overlap = Int((2.4 / dt).rounded())
        var targets: [Double] = []
        for first in stride(from: 0, to: energy.count, by: block) {
            try Task.checkCancellation()
            let a = max(0, first - overlap)
            let b = min(energy.count, first + block + overlap)
            var tracker = RhythmBeatTracker(windowDuration: 16)
            for i in a..<b { tracker.appendEnergy(energy[i], at: (Double(i) + 0.5) * dt) }
            let accents = tracker.recordedAccents()
            let beat = tracker.estimate()
            let lower = max(0.30, Double(first) * dt)
            let upper = min(duration - 0.16, Double(first + block) * dt)
            func add(_ t: Double) {
                if t >= lower && t < upper && t - (targets.last ?? -1) >= 0.36 { targets.append(t) }
            }
            if let beat, beat.confidence >= RhythmGame.minimumConfidence, beat.isValid {
                // Thin fast passages to a comfortable arm cadence. A grid must be supported
                // by local attacks, so held notes, silences and introductions can breathe.
                let interval = beat.period * (beat.bpm > 130 ? 2 : 1)
                var t = beat.referenceBeat + floor((lower - beat.referenceBeat) / interval) * interval
                while t < upper + 0.08 {
                    let near = accents.min { abs($0 - t) < abs($1 - t) }
                    if let near, abs(near - t) < 0.095 { add(near) }
                    else if accents.contains(where: { abs($0 - t) < 0.6 * interval }) {
                        let i = min(energy.count - 1, max(0, Int(t / dt)))
                        if energy[i] > 0.008 { add(t) }
                    }
                    t += interval
                }
            } else {
                // No defensible beat period: score the recording's actual onsets.
                for t in accents { add(t) }
            }
        }
        return Self(duration: duration, targets: targets)
    }
}

enum SongGameGrade: String, Sendable { case perfect, good, free }

struct SongGameJudge {
    let targets: [Double]
    private(set) var targetIndex = 0
    private(set) var score = 0
    private(set) var combo = 0
    private(set) var hits = 0
    private(set) var bestCombo = 0
    static let window = 0.18

    init(targets: [Double]) { self.targets = targets }

    mutating func expire(before time: Double) {
        guard time.isFinite else { return }
        // Give time-stamped watch gestures in transit a short delivery margin.
        while targetIndex < targets.count && time - targets[targetIndex] > Self.window + 0.40 {
            targetIndex += 1
            combo = 0
        }
    }

    mutating func strike(at time: Double) -> SongGameGrade {
        guard time.isFinite && time >= 0 else { return .free }
        while targetIndex < targets.count && time - targets[targetIndex] > Self.window + 1e-8 {
            targetIndex += 1
            combo = 0
        }
        guard targetIndex < targets.count else { return .free }
        let delta = abs(time - targets[targetIndex])
        guard delta <= Self.window + 1e-8 else { return .free }
        let grade: SongGameGrade = delta <= 0.08000001 ? .perfect : .good
        targetIndex += 1
        hits += 1
        combo += 1
        bestCombo = max(combo, bestCombo)
        score += grade == .perfect ? 100 : 70
        return grade
    }
}
