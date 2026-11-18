import Foundation

/// Twelve roots, each with a major and a minor triad. Original raw values stay
/// compatible with saved C/Am/F/G data; wrist controls use only manualVoicings.
public enum Chord: String, CaseIterable, Codable, Sendable {
    case c, cSharp, d, dSharp, e, f, fSharp, g, gSharp, a, aSharp, b
    case cMinor, cSharpMinor, dMinor, dSharpMinor, eMinor, fMinor
    case fSharpMinor, gMinor, gSharpMinor, aMinor, aSharpMinor, bMinor

    public static let manualVoicings: [Chord] = [.c, .aMinor, .f, .g]
    private static let majorTriads: [Chord] = [.c, .cSharp, .d, .dSharp, .e, .f, .fSharp, .g, .gSharp, .a, .aSharp, .b]
    private static let minorTriads: [Chord] = [.cMinor, .cSharpMinor, .dMinor, .dSharpMinor, .eMinor, .fMinor,
                                              .fSharpMinor, .gMinor, .gSharpMinor, .aMinor, .aSharpMinor, .bMinor]

    public init?(pitchClass: Int, isMinor: Bool) {
        guard (0..<12).contains(pitchClass) else { return nil }
        self = (isMinor ? Self.minorTriads : Self.majorTriads)[pitchClass]
    }

    public var rootPitchClass: Int {
        switch self {
        case .c, .cMinor: return 0
        case .cSharp, .cSharpMinor: return 1
        case .d, .dMinor: return 2
        case .dSharp, .dSharpMinor: return 3
        case .e, .eMinor: return 4
        case .f, .fMinor: return 5
        case .fSharp, .fSharpMinor: return 6
        case .g, .gMinor: return 7
        case .gSharp, .gSharpMinor: return 8
        case .a, .aMinor: return 9
        case .aSharp, .aSharpMinor: return 10
        case .b, .bMinor: return 11
        }
    }

    public var isMinor: Bool {
        switch self {
        case .cMinor, .cSharpMinor, .dMinor, .dSharpMinor, .eMinor, .fMinor,
             .fSharpMinor, .gMinor, .gSharpMinor, .aMinor, .aSharpMinor, .bMinor: return true
        default: return false
        }
    }

    public var name: String {
        ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][rootPitchClass] + (isMinor ? "m" : "")
    }

    /// Guitar voicings, from lowest string to highest. The four original
    /// voicings remain sample-identical; other roots use movable E/A shapes.
    public var midiNotes: [Int] {
        switch self {
        case .c: return [48, 52, 55, 60, 64]
        case .aMinor: return [45, 52, 57, 60, 64]
        case .f: return [41, 48, 53, 57, 60, 65]
        case .g: return [43, 47, 50, 55, 59, 67]
        default:
            let root = rootPitchClass
            if (4...8).contains(root) {
                let shape = isMinor ? [40, 47, 52, 55, 59, 64] : [40, 47, 52, 56, 59, 64]
                return shape.map { $0 + root - 4 }
            }
            let shape = isMinor ? [45, 52, 57, 60, 64] : [45, 52, 57, 61, 64]
            let fret = (root - 9 + 12) % 12
            return shape.map { $0 + fret }
        }
    }

    /// A high, chord-tone answer. Preserve the original four reply timbres.
    public var replyMIDINote: Int {
        switch self {
        case .c, .g: return 67
        case .aMinor: return 69
        case .f: return 65
        default: return 64 + (rootPitchClass - 4 + 12) % 12
        }
    }
}

public enum Sensitivity: String, CaseIterable, Codable, Sendable {
    case low, medium, high

    private var thresholds: (acceleration: Double, rotation: Double) {
        switch self {
        case .low: return (0.78, 2.7)
        case .medium: return (0.46, 1.75)
        case .high: return (0.25, 1.05)
        }
    }

    fileprivate func activationThresholds(assisted: Bool, calibration: MotionCalibrationProfile?) -> (acceleration: Double, rotation: Double) {
        if let calibration, calibration.isValid {
            // A saved comfortable gesture is the authority. Do not secretly
            // scale it with a preset hidden by the personal-calibration UI.
            return (calibration.accelerationThreshold, calibration.rotationThreshold)
        }
        if assisted {
            let values: (acceleration: Double, rotation: Double)
            switch self {
            case .low: values = (0.50, 1.90)
            case .medium: values = (0.30, 1.25)
            case .high: values = (0.16, 0.75)
            }
            return values
        }
        return thresholds
    }

    fileprivate func evidence(acceleration: Double, rotation: Double, assisted: Bool,
                              calibration: MotionCalibrationProfile?) -> Double {
        let values = activationThresholds(assisted: assisted, calibration: calibration)
        let profile = calibration.flatMap { $0.isValid ? $0 : nil }
        if assisted || profile != nil {
            return max(profile?.usesAcceleration == false ? 0 : acceleration / values.acceleration,
                       profile?.usesRotation == false ? 0 : rotation / values.rotation)
        }
        // Both acceleration and rotation must support the gesture. This helps
        // reject isolated impacts and slow changes of wrist orientation.
        return min(acceleration / values.acceleration, rotation / values.rotation)
    }
}

public struct MotionSample: Sendable {
    /// Monotonic sensor time in seconds (CMDeviceMotion.timestamp).
    public var timestamp: TimeInterval
    /// Attitude roll in radians.
    public var roll: Double
    /// Gravity-removed user acceleration in g, rather than raw acceleration.
    public var accelerationX: Double
    public var accelerationY: Double
    public var accelerationZ: Double
    /// Rotation rate in radians per second.
    public var rotationX: Double
    public var rotationY: Double
    public var rotationZ: Double

    public init(timestamp: TimeInterval, roll: Double,
                accelerationX: Double, accelerationY: Double, accelerationZ: Double,
                rotationX: Double, rotationY: Double, rotationZ: Double) {
        self.timestamp = timestamp
        self.roll = roll
        self.accelerationX = accelerationX
        self.accelerationY = accelerationY
        self.accelerationZ = accelerationZ
        self.rotationX = rotationX
        self.rotationY = rotationY
        self.rotationZ = rotationZ
    }

    fileprivate var isValid: Bool {
        [timestamp, roll, accelerationX, accelerationY, accelerationZ,
         rotationX, rotationY, rotationZ].allSatisfy(\.isFinite) && timestamp >= 0
    }

    fileprivate var accelerationVector: SIMD3<Double> { SIMD3(accelerationX, accelerationY, accelerationZ) }
    fileprivate var rotationVector: SIMD3<Double> { SIMD3(rotationX, rotationY, rotationZ) }
}

public struct StrumEvent: Sendable {
    public let timestamp: TimeInterval
    public let chord: Chord
    /// A bounded synthesis level, in 0...1.
    public let velocity: Double

    public init(timestamp: TimeInterval, chord: Chord, velocity: Double) {
        self.timestamp = timestamp
        self.chord = chord
        self.velocity = velocity.isFinite ? min(1, max(0, velocity)) : 0
    }
}

/// A deterministic starting heuristic for deliberate arm strums, not a trained
/// finger/gesture recognizer. Real-watch thresholds still need user testing.
public struct MotionInterpreter: Sendable {
    public var sensitivity: Sensitivity
    public var assisted: Bool {
        didSet {
            if assisted != oldValue {
                lastTimestamp = nil; lastStrumTimestamp = nil; quietSince = nil; armed = true
                beatStrokeStart = nil
            }
        }
    }
    public var calibration: MotionCalibrationProfile? {
        didSet {
            if calibration != oldValue {
                lastTimestamp = nil; lastStrumTimestamp = nil; quietSince = nil; armed = true
                beatStrokeStart = nil
            }
        }
    }
    private var referenceRoll: Double = 0
    private var lastTimestamp: TimeInterval?
    private var lastStrumTimestamp: TimeInterval?
    private var quietSince: TimeInterval?
    private var armed = true
    private var suppressedUntil = -Double.infinity
    private var beatHapticStart = -Double.infinity
    private var beatStrokeStart: MotionSample?
    private var beatStrokeSamples = 0

    public init(sensitivity: Sensitivity = .medium, assisted: Bool = false,
                calibration: MotionCalibrationProfile? = nil) {
        self.sensitivity = sensitivity
        self.assisted = assisted
        self.calibration = calibration?.isValid == true ? calibration : nil
    }

    public func telemetry(for sample: MotionSample) -> MotionTelemetry {
        guard sample.isValid else { return .idle }
        let limits = sensitivity.activationThresholds(assisted: assisted, calibration: calibration)
        let profile = calibration.flatMap { $0.isValid ? $0 : nil }
        return MotionTelemetry(sample: sample, accelerationThreshold: limits.acceleration,
                               rotationThreshold: limits.rotation,
                               usesAcceleration: profile?.usesAcceleration ?? true,
                               usesRotation: profile?.usesRotation ?? true)
    }

    /// Mask known self-generated haptics. Once the interval ends, a quiet
    /// release is still required; a held motion never becomes a delayed strum.
    public mutating func suppress(until time: TimeInterval) {
        guard time.isFinite else { return }
        suppressedUntil = max(suppressedUntil, time)
        armed = false
        quietSince = nil
        beatStrokeStart = nil
    }

    /// A guide tap can coincide with the gesture we want to hear. In its
    /// short echo window, require motion to persist in the same direction.
    public mutating func expectBeatHaptic(at time: TimeInterval) {
        guard time.isFinite else { return }
        beatHapticStart = time
        beatStrokeStart = nil
    }

    private static func projectedMagnitude(_ current: SIMD3<Double>, onto first: SIMD3<Double>) -> Double {
        let length = hypot(hypot(first.x, first.y), first.z)
        return length > 0 ? max(0, (current * first).sum() / length) : 0
    }

    private mutating func confirmedBeatStroke(_ sample: MotionSample) -> MotionSample? {
        if let first = beatStrokeStart {
            let aligned = sensitivity.evidence(
                acceleration: Self.projectedMagnitude(sample.accelerationVector, onto: first.accelerationVector),
                rotation: Self.projectedMagnitude(sample.rotationVector, onto: first.rotationVector),
                assisted: assisted, calibration: calibration)
            if aligned >= 1 {
                beatStrokeSamples += 1
                guard beatStrokeSamples >= 3, sample.timestamp - first.timestamp >= 0.025 else { return nil }
                beatStrokeStart = nil
                return first
            }
        }
        beatStrokeStart = sample
        beatStrokeSamples = 1
        return nil
    }

    /// Call while the user holds their comfortable playing pose. Resetting also
    /// clears debounce history so the next valid sweep can sound immediately.
    public mutating func calibrate(roll: Double) {
        guard roll.isFinite else { return }
        referenceRoll = Self.wrappedAngle(roll)
        lastTimestamp = nil
        lastStrumTimestamp = nil
        quietSince = nil
        armed = true
        beatStrokeStart = nil
    }

    /// Neutral pose: C. Turn inward: Am. Turn outward: F, then G.
    /// Relative boundaries are -0.35, +0.35, and +0.95 radians.
    public func currentChord(forRoll roll: Double) -> Chord {
        guard roll.isFinite else { return .c }
        let relative = Self.wrappedAngle(roll - referenceRoll)
        switch relative {
        case ..<(-0.35): return .aMinor
        case ..<0.35: return .c
        case ..<0.95: return .f
        default: return .g
        }
    }

    public mutating func consume(_ sample: MotionSample) -> StrumEvent? {
        guard sample.isValid,
              lastTimestamp.map({ sample.timestamp > $0 }) ?? true else { return nil }
        if let lastTimestamp, sample.timestamp - lastTimestamp > 0.050 { beatStrokeStart = nil }
        lastTimestamp = sample.timestamp
        if sample.timestamp < suppressedUntil {
            quietSince = nil; armed = false
            beatStrokeStart = nil
            return nil
        }

        let acceleration = hypot(hypot(sample.accelerationX, sample.accelerationY), sample.accelerationZ)
        let rotation = hypot(hypot(sample.rotationX, sample.rotationY), sample.rotationZ)
        let evidence = sensitivity.evidence(acceleration: acceleration, rotation: rotation,
                                            assisted: assisted, calibration: calibration)
        let gentleRelease = assisted || calibration?.isValid == true
        if evidence < 1 || !armed { beatStrokeStart = nil }

        // Require a short release period before accepting another sweep.
        // Manual: either channel can mark a turnaround. Assisted: both channels
        // must settle for longer; continuous movement cannot keep retriggering.
        if evidence <= 0.5 {
            if quietSince == nil { quietSince = sample.timestamp }
            if sample.timestamp - (quietSince ?? sample.timestamp) >= (gentleRelease ? 0.08 : 0.035) {
                armed = true
            }
            return nil
        }
        quietSince = nil
        guard evidence >= 1, armed else { return nil }
        let stroke: MotionSample
        if (sample.timestamp >= beatHapticStart && sample.timestamp < beatHapticStart + 0.12) || beatStrokeStart != nil {
            guard let confirmed = confirmedBeatStroke(sample) else { return nil }
            stroke = confirmed
        } else {
            stroke = sample
        }
        // Consume this edge even during cooldown, avoiding a delayed trigger
        // from a sustained gesture when the cooldown later expires.
        armed = false
        guard lastStrumTimestamp.map({ stroke.timestamp - $0 >= (gentleRelease ? 0.32 : 0.18) }) ?? true else { return nil }
        lastStrumTimestamp = stroke.timestamp
        let velocity = min(1, max(0.35, 0.45 + (evidence - 1) * 0.35))
        return StrumEvent(timestamp: stroke.timestamp,
                          chord: currentChord(forRoll: stroke.roll),
                          velocity: velocity)
    }

    private static func wrappedAngle(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }
}

/// Versioned, bounded personal thresholds. A channel is enabled only when at
/// least two of the three learned gestures provide useful evidence for it.
public struct MotionCalibrationProfile: Codable, Equatable, Sendable {
    public let version: Int
    public let accelerationThreshold: Double
    public let rotationThreshold: Double
    public let quietAcceleration: Double
    public let quietRotation: Double
    public let usesAcceleration: Bool
    public let usesRotation: Bool
    public let learnedAt: Date

    public init(accelerationThreshold: Double, rotationThreshold: Double,
                quietAcceleration: Double, quietRotation: Double,
                usesAcceleration: Bool = true, usesRotation: Bool = true,
                learnedAt: Date = Date()) {
        version = 1
        self.accelerationThreshold = accelerationThreshold
        self.rotationThreshold = rotationThreshold
        self.quietAcceleration = quietAcceleration
        self.quietRotation = quietRotation
        self.usesAcceleration = usesAcceleration
        self.usesRotation = usesRotation
        self.learnedAt = learnedAt
    }

    public var isValid: Bool {
        version == 1 && (usesAcceleration || usesRotation)
            && accelerationThreshold.isFinite && (0.04...2).contains(accelerationThreshold)
            && rotationThreshold.isFinite && (0.15...10).contains(rotationThreshold)
            && quietAcceleration.isFinite && (0...0.08).contains(quietAcceleration)
            && quietRotation.isFinite && (0...0.28).contains(quietRotation)
            && (!usesAcceleration || quietAcceleration < accelerationThreshold)
            && (!usesRotation || quietRotation < rotationThreshold)
            && learnedAt.timeIntervalSinceReferenceDate.isFinite
    }
}

public struct MotionTelemetry: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let accelerationMagnitude: Double
    public let gyroMagnitude: Double
    public let gyroX: Double
    public let gyroY: Double
    public let gyroZ: Double
    public let gyroStrength: Double
    public let strength: Double

    public init(sample: MotionSample, accelerationThreshold: Double = 0.16,
                rotationThreshold: Double = 0.75,
                usesAcceleration: Bool = true, usesRotation: Bool = true) {
        timestamp = sample.timestamp
        accelerationMagnitude = hypot(hypot(sample.accelerationX, sample.accelerationY), sample.accelerationZ)
        gyroMagnitude = hypot(hypot(sample.rotationX, sample.rotationY), sample.rotationZ)
        gyroX = sample.rotationX; gyroY = sample.rotationY; gyroZ = sample.rotationZ
        gyroStrength = min(1, max(0, gyroMagnitude / max(0.01, rotationThreshold)))
        strength = min(1, max(usesAcceleration ? accelerationMagnitude / max(0.01, accelerationThreshold) : 0,
                              usesRotation ? gyroMagnitude / max(0.01, rotationThreshold) : 0))
    }

    public static var idle: MotionTelemetry {
        MotionTelemetry(sample: MotionSample(timestamp: 0, roll: 0,
                                             accelerationX: 0, accelerationY: 0, accelerationZ: 0,
                                             rotationX: 0, rotationY: 0, rotationZ: 0))
    }
}

public enum WristLearningStage: Equatable, Sendable { case baseline, collecting, completed }
public enum WristLearningFeedback: Equatable, Sendable {
    case holdStill, moveComfortably, relaxBetween, tooSmall, recorded, complete
}

public struct WristLearningUpdate: Sendable {
    public let stage: WristLearningStage
    public let completedSwings: Int
    public let feedback: WristLearningFeedback
    public let candidate: MotionCalibrationProfile?
    public let telemetry: MotionTelemetry
}

/// Three independent, comfortable gestures after an 0.8-second quiet baseline.
/// Medians resist one unusually large gesture. No position or finger tracking.
public struct WristMotionCalibrator: Sendable {
    private var stage: WristLearningStage = .baseline
    private var feedback: WristLearningFeedback = .holdStill
    private var lastTime: Double?
    private var baselineStart: Double?
    private var baselineA: [Double] = [], baselineR: [Double] = []
    private var quietA = 0.012, quietR = 0.04
    private var peaks: [(a: Double, r: Double)] = []
    private var swingStart: Double?
    private var peakA = 0.0, peakR = 0.0
    private var releasedAt: Double?
    private var cooldownUntil = -Double.infinity
    private var needsQuietAfterSuppression = false
    private var suppressionQuietStart: Double?
    private var candidate: MotionCalibrationProfile?

    public init() {}

    public mutating func suppress(until time: TimeInterval) {
        guard time.isFinite else { return }
        cooldownUntil = max(cooldownUntil, time)
        swingStart = nil; releasedAt = nil
        needsQuietAfterSuppression = true; suppressionQuietStart = nil
        if stage == .baseline {
            baselineStart = nil; baselineA.removeAll(keepingCapacity: true); baselineR.removeAll(keepingCapacity: true)
        }
    }

    public mutating func consume(_ sample: MotionSample) -> WristLearningUpdate? {
        guard sample.isValid, lastTime.map({ sample.timestamp > $0 }) ?? true else { return nil }
        lastTime = sample.timestamp
        let a = hypot(hypot(sample.accelerationX, sample.accelerationY), sample.accelerationZ)
        let r = hypot(hypot(sample.rotationX, sample.rotationY), sample.rotationZ)
        switch stage {
        case .baseline:
            if sample.timestamp < cooldownUntil || a > 0.08 || r > 0.28 {
                baselineStart = nil; baselineA.removeAll(keepingCapacity: true); baselineR.removeAll(keepingCapacity: true)
            } else {
                if baselineStart == nil { baselineStart = sample.timestamp }
                baselineA.append(a); baselineR.append(r)
                if baselineA.count > 128 { baselineA.removeFirst(); baselineR.removeFirst() }
                if sample.timestamp - (baselineStart ?? sample.timestamp) >= 0.8 && baselineA.count >= 20 {
                    quietA = max(0.012, quantile(baselineA, fraction: 0.95))
                    quietR = max(0.04, quantile(baselineR, fraction: 0.95))
                    stage = .collecting; feedback = .moveComfortably
                }
            }
        case .collecting:
            if sample.timestamp >= cooldownUntil {
                if needsQuietAfterSuppression {
                    if a <= max(0.025, quietA * 1.4) && r <= max(0.10, quietR * 1.4) {
                        if suppressionQuietStart == nil { suppressionQuietStart = sample.timestamp }
                        if sample.timestamp - (suppressionQuietStart ?? sample.timestamp) >= 0.16 {
                            needsQuietAfterSuppression = false
                        }
                    } else { suppressionQuietStart = nil }
                    break
                }
                if swingStart == nil && (a > max(0.025, quietA * 1.6) || r > max(0.10, quietR * 1.6)) {
                    swingStart = sample.timestamp; peakA = a; peakR = r
                    releasedAt = nil; feedback = .relaxBetween
                }
                if let start = swingStart {
                    peakA = max(peakA, a); peakR = max(peakR, r)
                    let settled = a <= max(0.025, quietA * 1.4) && r <= max(0.10, quietR * 1.4)
                    if settled {
                        if releasedAt == nil { releasedAt = sample.timestamp }
                        if sample.timestamp - (releasedAt ?? sample.timestamp) >= 0.16 {
                            let useful = peakA >= max(0.08, quietA * 3) || peakR >= max(0.35, quietR * 3)
                            if useful && sample.timestamp - start <= 1.8 {
                                peaks.append((peakA, peakR)); feedback = .recorded
                            } else { feedback = useful ? .relaxBetween : .tooSmall }
                            swingStart = nil; releasedAt = nil; cooldownUntil = sample.timestamp + 0.45
                            if peaks.count == 3 { complete() }
                        }
                    } else { releasedAt = nil }
                }
            }
        case .completed: break
        }
        return WristLearningUpdate(stage: stage, completedSwings: peaks.count, feedback: feedback,
                                   candidate: candidate, telemetry: MotionTelemetry(sample: sample))
    }

    private mutating func complete() {
        let acceleration = quantile(peaks.map(\.a), fraction: 0.5)
        let rotation = quantile(peaks.map(\.r), fraction: 0.5)
        candidate = MotionCalibrationProfile(
            accelerationThreshold: min(0.65, max(0.06, quietA * 2.2, acceleration * 0.55)),
            rotationThreshold: min(2.8, max(0.25, quietR * 2.2, rotation * 0.55)),
            quietAcceleration: quietA, quietRotation: quietR,
            usesAcceleration: peaks.filter { $0.a >= max(0.08, quietA * 3) }.count >= 2,
            usesRotation: peaks.filter { $0.r >= max(0.35, quietR * 3) }.count >= 2)
        if candidate?.isValid == true { stage = .completed; feedback = .complete }
        else { candidate = nil; peaks.removeAll(); feedback = .tooSmall }
    }

    private func quantile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
}
