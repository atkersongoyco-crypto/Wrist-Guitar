import Foundation

public struct BeatEstimate: Equatable, Codable, Sendable {
    public let bpm: Double
    public let referenceBeat: TimeInterval
    /// Heuristic periodicity support, not a calibrated probability or accuracy.
    public let confidence: Double
    public var period: TimeInterval { bpm > 0 ? 60 / bpm : 0 }
    public var isValid: Bool {
        bpm.isFinite && bpm > 0 && period.isFinite && period > 0 && referenceBeat.isFinite
    }

    /// All timestamps must share one clock: file seconds or monotonic uptime.
    public init(bpm: Double, referenceBeat: TimeInterval, confidence: Double) {
        self.bpm = bpm
        self.referenceBeat = referenceBeat
        self.confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
    }
}

/// A foreground beat cue cursor, independent of scoring and gestures.
/// Timestamps share the estimate's clock (file seconds or monotonic uptime).
/// Reset on playback discontinuities. Starting/resuming always waits for a
/// future beat; late observers never replay a backlog or emit off-beat cues.
public struct BeatPulseCursor: Sendable {
    public private(set) var nextBeatTime: TimeInterval?
    public let maximumLateness: TimeInterval
    private var beat: BeatEstimate?
    private var lastTime: TimeInterval?

    public init(maximumLateness: TimeInterval = 0.06) {
        self.maximumLateness = maximumLateness.isFinite ? min(0.1, max(0, maximumLateness)) : 0.06
    }

    public mutating func reset(beat: BeatEstimate? = nil, startingAt time: TimeInterval = 0) {
        self.beat = nil
        nextBeatTime = nil
        lastTime = nil
        guard let beat, beat.isValid, beat.confidence >= RhythmGame.minimumConfidence,
              beat.period >= 0.18, time.isFinite else { return }
        self.beat = beat
        lastTime = time
        nextBeatTime = futureBeat(after: time, beat: beat)
    }

    /// Return the original scheduled beat, once, only inside its lateness budget.
    /// Disabled/quiet observations still retire elapsed beats. Re-enabling must
    /// not turn a skipped cue into a pulse midway between two beats.
    public mutating func consume(at time: TimeInterval, enabled: Bool = true,
                                 isAudible: Bool = true) -> TimeInterval? {
        guard let beat, let due = nextBeatTime, time.isFinite,
              lastTime.map({ time >= $0 }) ?? true else { return nil }
        lastTime = time
        guard time >= due else { return nil }
        nextBeatTime = futureBeat(after: time, beat: beat)
        guard enabled, isAudible, time - due <= maximumLateness else { return nil }
        return due
    }

    private func futureBeat(after time: TimeInterval, beat: BeatEstimate) -> TimeInterval? {
        let cycles = floor((time - beat.referenceBeat) / beat.period + 1e-9) + 1
        let next = beat.referenceBeat + cycles * beat.period
        return next.isFinite && next > time ? next : nil
    }
}

/// A bounded, lightweight onset-periodicity heuristic. It cannot determine the
/// musical downbeat and may choose half/double tempo on ambiguous arrangements.
/// Feed normalized mono PCM, or nonnegative RMS/onset energy every 10–20 ms.
/// At least 4 seconds and 5 salient onsets are needed; 8–12 seconds is preferable.
public struct RhythmBeatTracker: Sendable {
    private struct Frame: Sendable { let time: Double; let energy: Double }
    private var frames: [Frame] = []
    private let windowDuration: TimeInterval
    private let minBPM: Double
    private let maxBPM: Double
    private var pcmRate: Double = 0
    private var pcmEnd: TimeInterval?
    private var partialStart: TimeInterval = 0
    private var partialCount = 0
    private var partialSquares: Double = 0

    public var bufferedFrameCount: Int { frames.count }
    public var observedDuration: TimeInterval {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return last.time - first.time
    }

    public init(windowDuration: TimeInterval = 16, minBPM: Double = 60, maxBPM: Double = 180) {
        self.windowDuration = windowDuration.isFinite ? min(20, max(4, windowDuration)) : 16
        self.minBPM = minBPM.isFinite ? min(240, max(30, minBPM)) : 60
        self.maxBPM = min(300, max(self.minBPM + 1, maxBPM.isFinite ? maxBPM : 180))
    }

    public mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        pcmRate = 0; pcmEnd = nil; partialCount = 0; partialSquares = 0
    }

    public mutating func appendEnergy(_ energy: Double, at time: TimeInterval) {
        guard energy.isFinite, energy >= 0, time.isFinite,
              frames.last.map({ time > $0.time }) ?? true else { return }
        frames.append(Frame(time: time, energy: energy))
        let obsolete = frames.prefix { $0.time < time - windowDuration }.count
        if obsolete > 0 { frames.removeFirst(obsolete) }
        if frames.count > 2_048 { frames.removeFirst(frames.count - 2_048) }
    }

    /// Supply contiguous chunks in increasing order. Cancellation belongs between
    /// calls, e.g. decode 1024–8192 frames, check cancellation, then append.
    /// RMS frame centers and the returned referenceBeat retain startingAt's clock.
    public mutating func appendPCM(_ samples: [Float], sampleRate: Double, startingAt: TimeInterval) {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              startingAt.isFinite, !samples.isEmpty else { return }
        if let end = pcmEnd, startingAt < end - 1 / sampleRate { return }
        if pcmRate != sampleRate || pcmEnd.map({ abs(startingAt - $0) > 1 / sampleRate }) ?? true {
            partialCount = 0; partialSquares = 0
        }
        pcmRate = sampleRate
        let frameSize = max(1, Int((sampleRate * 0.01).rounded()))
        for (index, sample) in samples.enumerated() {
            if partialCount == 0 { partialStart = startingAt + Double(index) / sampleRate }
            let value = sample.isFinite ? Double(sample) : 0
            partialSquares += value * value
            partialCount += 1
            if partialCount == frameSize {
                appendEnergy(sqrt(partialSquares / Double(partialCount)),
                             at: partialStart + Double(partialCount) / sampleRate / 2)
                partialCount = 0; partialSquares = 0
            }
        }
        pcmEnd = startingAt + Double(samples.count) / sampleRate
    }

    /// nil means insufficient, quiet or nonperiodic evidence. No fallback BPM is invented.
    public func estimate() -> BeatEstimate? {
        guard frames.count >= 200, observedDuration >= 4,
              (frames.map(\.energy).max() ?? 0) >= 0.0008 else { return nil }
        let dt = observedDuration / Double(frames.count - 1)
        guard (0.005...0.04).contains(dt) else { return nil }
        // Large missing stretches are not equally spaced observations.
        guard zip(frames, frames.dropFirst()).allSatisfy({ $1.time - $0.time < dt * 2.5 }) else { return nil }
        var flux = [Double](repeating: 0, count: frames.count)
        var smooth = frames[0].energy
        for index in 1..<frames.count {
            let next = frames[index].energy * 0.65 + smooth * 0.35
            flux[index] = max(0, next - smooth)
            smooth = next
        }
        let mean = flux.reduce(0, +) / Double(flux.count)
        let deviation = sqrt(flux.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(flux.count))
        let threshold = max(0.00005, mean + deviation * 0.5)
        var onsets: [(time: Double, weight: Double)] = []
        for index in 1..<(flux.count - 1) where flux[index] >= threshold && flux[index] >= flux[index - 1] && flux[index] > flux[index + 1] {
            let onset = (time: frames[index].time, weight: flux[index])
            if let last = onsets.last, onset.time - last.time < 0.12 {
                if onset.weight > last.weight { onsets[onsets.count - 1] = onset }
            } else { onsets.append(onset) }
        }
        guard onsets.count >= 5 else { return nil }
        let envelope = flux.map { max(0, $0 - threshold * 0.5) }
        let firstLag = max(2, Int((60 / maxBPM / dt).rounded(.down)))
        let lastLag = min(envelope.count / 2, Int((60 / minBPM / dt).rounded(.up)))
        guard lastLag > firstLag else { return nil }
        func correlation(_ lag: Int) -> Double {
            var dot = 0.0, left = 0.0, right = 0.0
            for index in lag..<envelope.count {
                let a = envelope[index], b = envelope[index - lag]
                dot += a * b; left += a * a; right += b * b
            }
            return dot / max(1e-15, sqrt(left * right))
        }
        var bestLag = firstLag, bestScore = 0.0, correlations: [Int: Double] = [:]
        for lag in firstLag...lastLag {
            let raw = correlation(lag)
            correlations[lag] = raw
            // Prefer the shortest supported repetition over a whole-number multiple.
            let supported = raw * sqrt(Double(envelope.count - lag) / Double(envelope.count))
            if supported > bestScore { bestScore = supported; bestLag = lag }
        }
        guard let peak = correlations[bestLag], peak >= 0.28 else { return nil }
        var fractionalLag = Double(bestLag)
        if let left = correlations[bestLag - 1], let right = correlations[bestLag + 1] {
            let denominator = left - 2 * peak + right
            if abs(denominator) > 1e-12 {
                fractionalLag += min(0.5, max(-0.5, 0.5 * (left - right) / denominator))
            }
        }
        let period = fractionalLag * dt
        let bpm = 60 / period
        guard bpm >= minBPM - 1, bpm <= maxBPM + 1 else { return nil }
        let tolerance = max(0.025, min(0.08, period * 0.15))
        let totalWeight = onsets.reduce(0) { $0 + $1.weight }
        var anchor = onsets[0].time, alignedWeight = 0.0
        for candidate in onsets {
            let weight = onsets.reduce(0.0) { sum, onset in
                let cycles = ((onset.time - candidate.time) / period).rounded()
                let error = abs(onset.time - candidate.time - cycles * period)
                return sum + (error <= tolerance ? onset.weight * (1 - pow(error / tolerance, 2)) : 0)
            }
            if weight > alignedWeight { alignedWeight = weight; anchor = candidate.time }
        }
        let agreement = alignedWeight / max(1e-15, totalWeight)
        guard agreement >= 0.5 else { return nil }
        var offset = 0.0, weight = 0.0
        for onset in onsets {
            let delta = onset.time - anchor - ((onset.time - anchor) / period).rounded() * period
            if abs(delta) <= tolerance { offset += delta * onset.weight; weight += onset.weight }
        }
        var reference = anchor + offset / max(weight, 1e-15)
        reference += ceil((frames[0].time - reference) / period) * period
        return BeatEstimate(bpm: bpm, referenceBeat: reference,
                            confidence: min(1, peak * agreement))
    }
}

public enum RhythmGrade: String, Codable, Sendable { case perfect, good, early, late, miss }

public struct RhythmJudgement: Equatable, Sendable {
    public let grade: RhythmGrade
    public let beatIndex: Int
    public let targetTime: TimeInterval
    /// Negative is early; positive is late. Misses use the observation's lateness.
    public let offset: TimeInterval
    public let points: Int
    public let combo: Int
}

public struct BeatProgress: Equatable, Sendable {
    public let beatIndex: Int
    public let previousBeat: TimeInterval
    public let nextBeat: TimeInterval
    public let fraction: Double
    public let period: TimeInterval
}

public struct RhythmTimingWindows: Equatable, Sendable {
    public let perfect: TimeInterval
    public let good: TimeInterval
    public let tolerance: TimeInterval
}

/// Judge with the same continuously advancing clock as the BeatEstimate. Pause,
/// silence and unlocked tempo skip scoring; resuming anchors to the present.
public struct RhythmGame: Sendable {
    /// A conservative product gate on heuristic support, not a probability.
    public static let minimumConfidence = 0.35
    public static func targetBeatStride(forBPM bpm: Double, assisted: Bool) -> Int {
        assisted ? (bpm >= 135 ? 4 : 2) : (bpm >= 135 ? 2 : 1)
    }
    public private(set) var beat: BeatEstimate?
    public private(set) var score = 0
    public private(set) var combo = 0
    public private(set) var bestCombo = 0
    public private(set) var lastJudgement: RhythmJudgement?
    public private(set) var isPaused = false
    /// Disable for an external song that is no longer being continuously heard.
    /// Only actual strums are judged, so a stopped external source cannot lose a combo.
    public private(set) var tracksMisses: Bool
    public private(set) var assisted: Bool
    private var nextIndex: Int?
    private var resolved: Set<Int> = []
    private var retiredThrough: Int?

    public init(beat: BeatEstimate?, tracksMisses: Bool = true, assisted: Bool = false) {
        self.beat = beat?.isValid == true && (beat?.confidence ?? 0) >= Self.minimumConfidence ? beat : nil
        self.tracksMisses = tracksMisses && !assisted
        self.assisted = assisted
    }

    public var timingWindows: RhythmTimingWindows? {
        guard let beat else { return nil }
        if assisted {
            return RhythmTimingWindows(perfect: min(0.120, beat.period * 0.18),
                                       good: min(0.220, beat.period * 0.30),
                                       tolerance: min(0.300, beat.period * 0.40))
        }
        return RhythmTimingWindows(perfect: min(0.055, beat.period * 0.12),
                                   good: min(0.110, beat.period * 0.22),
                                   tolerance: min(0.180, beat.period * 0.34))
    }

    public func progress(at time: TimeInterval) -> BeatProgress? {
        guard let beat, time.isFinite else { return nil }
        let cycles = (time - beat.referenceBeat) / beat.period
        guard cycles.isFinite, abs(cycles) < 1e12 else { return nil }
        let index = Int(floor(cycles))
        let previous = beat.referenceBeat + Double(index) * beat.period
        return BeatProgress(beatIndex: index, previousBeat: previous,
                            nextBeat: previous + beat.period,
                            fraction: min(1, max(0, cycles - floor(cycles))), period: beat.period)
    }

    public mutating func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        nextIndex = nil
    }

    public mutating func reset(beat: BeatEstimate? = nil, tracksMisses: Bool = true, assisted: Bool = false) {
        self = RhythmGame(beat: beat, tracksMisses: tracksMisses, assisted: assisted)
    }

    /// Advances overdue beats, then returns at most one hit. Repeated strums on
    /// the same target return nil. An out-of-window strum does not consume it.
    public mutating func strum(at time: TimeInterval, isAudible: Bool = true) -> RhythmJudgement? {
        guard let beat, let windows = timingWindows, time.isFinite, !isPaused, isAudible else {
            if !isAudible { nextIndex = nil }
            return nil
        }
        _ = advance(to: time, isAudible: isAudible)
        let cycles = (time - beat.referenceBeat) / beat.period
        guard cycles.isFinite, abs(cycles) < 1e12 else { return nil }
        let index = Int(cycles.rounded())
        let target = beat.referenceBeat + Double(index) * beat.period
        let offset = time - target
        guard abs(offset) <= windows.tolerance, !wasResolved(index),
              assisted || (nextIndex.map({ index >= $0 }) ?? true) else { return nil }
        let grade: RhythmGrade
        if abs(offset) <= windows.perfect { grade = .perfect }
        else if abs(offset) <= windows.good { grade = .good }
        else { grade = offset < 0 ? .early : .late }
        return resolve(index: index, target: target, offset: offset, grade: grade)
    }

    /// First entry never backfills the song. Call during audible foreground play;
    /// use isAudible=false throughout silence, and setPaused for suspensions.
    /// Catch-up output is bounded to 64 misses per call for a large clock jump.
    public mutating func advance(to time: TimeInterval, isAudible: Bool = true) -> [RhythmJudgement] {
        guard let beat, let windows = timingWindows, time.isFinite, !isPaused, isAudible else {
            if !isAudible { nextIndex = nil }
            return []
        }
        let cycles = (time - beat.referenceBeat - windows.tolerance) / beat.period
        guard cycles.isFinite, abs(cycles) < 1e12 else { return [] }
        if !tracksMisses {
            let current = Int(ceil(cycles))
            nextIndex = max(nextIndex ?? current, current)
            return []
        }
        if nextIndex == nil { nextIndex = Int(ceil(cycles)) }
        var misses: [RhythmJudgement] = []
        var inspected = 0
        while let index = nextIndex, inspected < 64 {
            let target = beat.referenceBeat + Double(index) * beat.period
            guard target + windows.tolerance < time else { break }
            if !wasResolved(index) {
                misses.append(resolve(index: index, target: target, offset: time - target, grade: .miss))
            }
            nextIndex = index + 1
            inspected += 1
        }
        if inspected == 64 { nextIndex = Int(ceil(cycles)) }
        return misses
    }

    private func wasResolved(_ index: Int) -> Bool {
        resolved.contains(index) || (retiredThrough.map { index <= $0 } ?? false)
    }

    private mutating func resolve(index: Int, target: Double, offset: Double,
                                  grade: RhythmGrade) -> RhythmJudgement {
        resolved.insert(index)
        if resolved.count > 256 {
            let keep = resolved.sorted().suffix(128)
            if let first = keep.first { retiredThrough = max(retiredThrough ?? first - 1, first - 1) }
            resolved = Set(keep)
        }
        let points: Int
        switch grade {
        case .perfect: points = 100
        case .good: points = 70
        case .early, .late: points = 30
        case .miss: points = 0
        }
        combo = grade == .miss ? 0 : combo + 1
        let awarded = assisted && grade != .miss ? 100 : points
        score += awarded
        bestCombo = max(bestCombo, combo)
        let result = RhythmJudgement(grade: grade, beatIndex: index, targetTime: target,
                                     offset: offset, points: awarded, combo: combo)
        lastJudgement = result
        return result
    }
}
