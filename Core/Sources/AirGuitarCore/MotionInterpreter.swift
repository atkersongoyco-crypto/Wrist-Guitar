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

    /// Expression after an accepted edge, from a soft touch to a full accent.
    public var pickStrength: Double { min(1, max(0, (velocity - 0.45) / 0.55)) }

    public init(timestamp: TimeInterval, chord: Chord, velocity: Double) {
        self.timestamp = timestamp
        self.chord = chord
        self.velocity = velocity.isFinite ? min(1, max(0, velocity)) : 0
    }
}

/// A deterministic starting heuristic for deliberate arm strums, not a trained
/// finger/gesture recognizer. Real-watch thresholds still need user testing.
public struct MotionInterpreter: Sendable {
    public var sensitivity: Sensitivity {
        didSet {
            if sensitivity != oldValue {
                quietSince = nil; armed = false; strokeStart = nil; reversal = nil
                motionWindow.removeAll(keepingCapacity: true)
            }
        }
    }
    public var assisted: Bool {
        didSet {
            if assisted != oldValue {
                lastTimestamp = nil; lastStrumTimestamp = nil; quietSince = nil; armed = false
                strokeStart = nil; reversal = nil
                motionWindow.removeAll(keepingCapacity: true)
            }
        }
    }
    public var calibration: MotionCalibrationProfile? {
        didSet {
            if calibration != oldValue {
                lastTimestamp = nil; lastStrumTimestamp = nil; quietSince = nil; armed = false
                strokeStart = nil; reversal = nil
                motionWindow.removeAll(keepingCapacity: true)
            }
        }
    }
    /// Local play-along can recognize a deliberate wrist return without a full rest.
    public var allowsWristReversals: Bool {
        didSet {
            if allowsWristReversals != oldValue { awaitNeutral(alignWrist: needsNeutral && alignAfterNeutral) }
        }
    }
    private var referenceRoll: Double = 0
    private var lastTimestamp: TimeInterval?
    private var lastStrumTimestamp: TimeInterval?
    private var quietSince: TimeInterval?
    private var armed = true
    private var suppressedUntil = -Double.infinity
    private var beatHapticStart = -Double.infinity
    private var beatHapticEnd = -Double.infinity
    private var strokeStart: MotionSample?
    private var strokeSamples = 0
    private var protectsSessionStart = false
    private var needsNeutral = false
    private var alignAfterNeutral = false
    private var reversal: WristReversal?
    private var motionWindow = [MotionSample]()
    // Replay is used only while learning, before a pair of anchors exists.
    fileprivate var measuresCalibrationStroke = false
    fileprivate private(set) var lastStrokeTravel: Double?

    private struct WristReversal: Sendable {
        let axis: SIMD3<Double>
        let threshold: Double
        var start: MotionSample?
        var previousTime = 0.0
        var previousRate = 0.0
        var travel = 0.0

        init?(stroke: MotionSample, rotationThreshold: Double) {
            let vector = stroke.rotationVector
            let speed = hypot(hypot(vector.x, vector.y), vector.z)
            guard speed >= rotationThreshold else { return nil }
            axis = vector / speed
            threshold = max(rotationThreshold * 1.1, min(rotationThreshold * 1.55, speed * 0.35))
        }

        mutating func confirm(_ sample: MotionSample, nearHaptic: Bool) -> MotionSample? {
            let vector = sample.rotationVector
            let speed = hypot(hypot(vector.x, vector.y), vector.z)
            let returnSpeed = -(vector * axis).sum()
            guard returnSpeed >= threshold, returnSpeed >= speed * 0.75 else {
                start = nil
                return nil
            }
            defer { previousTime = sample.timestamp; previousRate = returnSpeed }
            guard let start else {
                start = sample
                travel = 0
                return nil
            }
            travel += (sample.timestamp - previousTime) * (previousRate + returnSpeed) * 0.5
            guard sample.timestamp - start.timestamp >= (nearHaptic ? 0.055 : 0.04),
                  travel >= max(0.028, threshold * 0.045) else { return nil }
            return start
        }
    }

    public init(sensitivity: Sensitivity = .medium, assisted: Bool = false,
                calibration: MotionCalibrationProfile? = nil, allowsWristReversals: Bool = false) {
        self.sensitivity = sensitivity
        self.assisted = assisted
        self.calibration = calibration?.isValid == true ? calibration : nil
        self.allowsWristReversals = allowsWristReversals
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

    /// Sensor adapters call this when capture starts or the user explicitly
    /// recalibrates. Ignore raising/filter-settling motion, then take the pose
    /// after 80ms of quiet. Ordinary wrist-down/up must not call it again.
    public mutating func prepareForSession() {
        protectsSessionStart = true
        lastTimestamp = nil
        lastStrumTimestamp = nil
        awaitNeutral(alignWrist: true)
    }

    private mutating func awaitNeutral(alignWrist: Bool) {
        needsNeutral = true
        alignAfterNeutral = alignWrist
        armed = false
        quietSince = nil
        strokeStart = nil
        reversal = nil
        motionWindow.removeAll(keepingCapacity: true)
    }

    /// Mask known self-generated haptics. A real quiet release is required,
    /// including a settled tail inside the mask; do not add another full wait
    /// after a long notification has already finished. Held motion stays blocked.
    public mutating func suppress(until time: TimeInterval) {
        guard time.isFinite else { return }
        suppressedUntil = max(suppressedUntil, time)
        armed = false
        quietSince = nil
        strokeStart = nil
        reversal = nil
        motionWindow.removeAll(keepingCapacity: true)
    }

    /// A guide tap can coincide with the gesture we want to hear. In its
    /// short echo window, require motion to persist in the same direction.
    public mutating func expectBeatHaptic(at time: TimeInterval, window: TimeInterval = 0.12) {
        guard time.isFinite, window.isFinite else { return }
        // A short beat tap can overlap a longer accent already in progress.
        if time >= beatHapticEnd { beatHapticStart = time }
        beatHapticEnd = max(beatHapticEnd, time + min(0.30, max(0.12, window)))
        strokeStart = nil
        reversal?.start = nil
    }

    private static func projectedMagnitude(_ current: SIMD3<Double>, onto first: SIMD3<Double>) -> Double {
        let length = hypot(hypot(first.x, first.y), first.z)
        return length > 0 ? max(0, (current * first).sum() / length) : 0
    }

    private mutating func confirmedStroke(_ sample: MotionSample, minimumDuration: Double) -> MotionSample? {
        if let first = strokeStart {
            let aligned = sensitivity.evidence(
                acceleration: Self.projectedMagnitude(sample.accelerationVector, onto: first.accelerationVector),
                rotation: Self.projectedMagnitude(sample.rotationVector, onto: first.rotationVector),
                assisted: assisted, calibration: calibration)
            if aligned >= 0.65 {
                strokeSamples += 1
                guard strokeSamples >= 3, sample.timestamp - first.timestamp >= minimumDuration else { return nil }
                strokeStart = nil
                return first
            }
        }
        let evidence = sensitivity.evidence(
            acceleration: hypot(hypot(sample.accelerationX, sample.accelerationY), sample.accelerationZ),
            rotation: hypot(hypot(sample.rotationX, sample.rotationY), sample.rotationZ),
            assisted: assisted, calibration: calibration)
        strokeStart = evidence >= 1 ? sample : nil
        strokeSamples = 1
        return nil
    }

    /// Call while the user holds their comfortable playing pose. Resetting also
    /// clears debounce history so the next valid sweep does not inherit a cooldown.
    public mutating func calibrate(roll: Double) {
        guard roll.isFinite else { return }
        referenceRoll = Self.wrappedAngle(roll)
        lastTimestamp = nil
        lastStrumTimestamp = nil
        quietSince = nil
        armed = true
        needsNeutral = false
        strokeStart = nil
        reversal = nil
        motionWindow.removeAll(keepingCapacity: true)
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

    private var responseTiming: (release: Double, cooldown: Double) {
        // During guided local play, a released stroke or a proven reverse turn
        // can be an eighth note at 150 BPM. The release/direction checks still
        // decide whether there was a new edge at all.
        if allowsWristReversals && assisted && (sensitivity == .high || calibration?.isValid == true) {
            return (0.04, 0.18)
        }
        if calibration?.isValid == true { return (0.04, 0.24) }
        if !assisted { return (0.035, 0.18) }
        switch sensitivity {
        case .low: return (0.12, 0.36) // A casual return is not another deliberate stroke.
        case .medium: return (0.08, 0.32)
        case .high: return (0.04, 0.24)
        }
    }

    public mutating func consume(_ sample: MotionSample) -> StrumEvent? {
        guard sample.isValid,
              lastTimestamp.map({ sample.timestamp > $0 }) ?? true else { return nil }
        if let lastTimestamp, sample.timestamp - lastTimestamp > 0.050 {
            strokeStart = nil
            reversal = nil
            motionWindow.removeAll(keepingCapacity: true)
        }
        if protectsSessionStart, let lastTimestamp, sample.timestamp - lastTimestamp > 0.1 {
            // Resuming a discontinuous stream must settle, but must not move
            // the manual player's neutral wrist angle to a different pose.
            awaitNeutral(alignWrist: needsNeutral && alignAfterNeutral)
        }
        lastTimestamp = sample.timestamp
        let acceleration = hypot(hypot(sample.accelerationX, sample.accelerationY), sample.accelerationZ)
        let rotation = hypot(hypot(sample.rotationX, sample.rotationY), sample.rotationZ)
        let evidence = sensitivity.evidence(acceleration: acceleration, rotation: rotation,
                                            assisted: assisted, calibration: calibration)
        let personal = calibration?.isValid == true
        let gentleRelease = assisted || personal
        let timing = responseTiming
        let releaseDuration = timing.release
        let cooldown = timing.cooldown
        if sample.timestamp < suppressedUntil {
            strokeStart = nil
            if evidence <= 0.5 {
                if quietSince == nil { quietSince = sample.timestamp }
                if sample.timestamp - (quietSince ?? sample.timestamp) >= releaseDuration { armed = true }
            } else { quietSince = nil; armed = false }
            return nil
        }
        if needsNeutral {
            if evidence <= 0.5, acceleration <= 0.08, rotation <= 0.28 {
                if quietSince == nil { quietSince = sample.timestamp }
                if sample.timestamp - (quietSince ?? sample.timestamp) >= 0.08 {
                    if alignAfterNeutral { referenceRoll = Self.wrappedAngle(sample.roll) }
                    needsNeutral = false
                    armed = true
                }
            } else { quietSince = nil }
            return nil
        }
        let measuresTravel = measuresCalibrationStroke || (personal && calibration?.hasPersonalDynamics == true)
        let guidedLightStrokes = assisted && allowsWristReversals && (personal || sensitivity == .high)
        if measuresTravel || guidedLightStrokes {
            // Include the approach to the trigger: a broad, unhurried stroke
            // has already travelled before the rate crosses the attack gate.
            motionWindow.removeAll { $0.timestamp < sample.timestamp - 0.16 }
            if motionWindow.count >= 48 { motionWindow.removeFirst() }
            motionWindow.append(sample)
        }
        if evidence < 0.65 || !armed { strokeStart = nil }
        let nearGuide = sample.timestamp >= beatHapticStart && sample.timestamp < beatHapticEnd
        let beganNearGuide = strokeStart.map { $0.timestamp >= beatHapticStart && $0.timestamp < beatHapticEnd } ?? false
        let returnBeganNearGuide = reversal?.start.map { $0.timestamp >= beatHapticStart && $0.timestamp < beatHapticEnd } ?? false
        let returnStroke = reversal?.confirm(sample, nearHaptic: nearGuide || returnBeganNearGuide)

        // A short actual release plus cooldown allows natural back-and-forth
        // half-beat strokes. A constant hold never earns another edge.
        if evidence <= 0.5 {
            if quietSince == nil { quietSince = sample.timestamp }
            if sample.timestamp - (quietSince ?? sample.timestamp) >= releaseDuration {
                armed = true
                reversal = nil
            }
            return nil
        }
        quietSince = nil
        let limits = sensitivity.activationThresholds(assisted: assisted, calibration: calibration)
        let armOnly = personal && calibration?.usesRotation == false
        let threshold = armOnly ? limits.acceleration : limits.rotation
        let lightStroke = guidedLightStrokes && armed && evidence < 1 && strokeStart == nil
            ? sustainedLightStroke(threshold: threshold, armOnly: armOnly) : nil
        let stroke: MotionSample
        if let returnStroke {
            stroke = returnStroke
        } else if let lightStroke {
            stroke = lightStroke
        } else {
            guard evidence >= 1 || strokeStart != nil, armed else { return nil }
            if allowsWristReversals || gentleRelease || nearGuide || strokeStart != nil {
                let nearHaptic = nearGuide || beganNearGuide
                let clearWristAttack = guidedLightStrokes && !measuresTravel && !nearHaptic
                    && rotation >= limits.rotation * 1.3 && acceleration >= limits.acceleration
                let minimumDuration = clearWristAttack ? 0.025 :
                    (nearHaptic ? 0.025 : 0.015) + (allowsWristReversals || measuresTravel ? 0.020 : 0)
                guard let confirmed = confirmedStroke(sample, minimumDuration: minimumDuration) else { return nil }
                stroke = confirmed
            } else { stroke = sample }
        }
        // Consume this edge even during cooldown, avoiding a delayed trigger
        // from a sustained gesture when the cooldown later expires.
        armed = false
        reversal = nil
        let strokeCooldown = returnStroke == nil ? cooldown : min(cooldown, 0.22)
        guard lastStrumTimestamp.map({ stroke.timestamp - $0 >= strokeCooldown }) ?? true else { return nil }
        lastStrumTimestamp = stroke.timestamp
        if allowsWristReversals, calibration?.isValid != true || calibration?.usesRotation == true {
            reversal = WristReversal(stroke: sample, rotationThreshold: lightStroke == nil ? limits.rotation : rotation * 0.82)
        }
        let onsetEvidence = sensitivity.evidence(
            acceleration: hypot(hypot(stroke.accelerationX, stroke.accelerationY), stroke.accelerationZ),
            rotation: hypot(hypot(stroke.rotationX, stroke.rotationY), stroke.rotationZ),
            assisted: assisted, calibration: calibration)
        var velocity = min(1, max(0.35, 0.45 + (max(evidence, onsetEvidence) - 1) * 0.35))
        if lightStroke != nil {
            let proportion = min(1, max(0, ((armOnly ? acceleration : rotation) / threshold - 0.60) / 0.40))
            velocity = 0.45 + 0.55 * (0.14 + 0.16 * proportion)
        }
        if measuresTravel, let profile = calibration {
            let travel = strokeTravel(along: stroke, profile: profile)
            lastStrokeTravel = travel
            motionWindow.removeAll(keepingCapacity: true)
            if lightStroke == nil, let light = profile.lightTravel, let accent = profile.accentTravel, profile.hasPersonalDynamics {
                let expression = min(1, max(0.08, 0.30 + 0.56 * (travel - light) / (accent - light)))
                velocity = 0.45 + 0.55 * expression
            }
        }
        return StrumEvent(timestamp: stroke.timestamp,
                          chord: currentChord(forRoll: stroke.roll),
                          velocity: velocity)
    }

    /// A light turn below the usual peak can still travel several degrees.
    /// Require a recent rise out of rest and a sustained, aligned trace. Use
    /// acceleration impulse only for a player who calibrated arm-only strokes.
    private func sustainedLightStroke(threshold: Double, armOnly: Bool) -> MotionSample? {
        guard let end = motionWindow.last else { return nil }
        let channel: KeyPath<MotionSample, SIMD3<Double>> = armOnly ? \.accelerationVector : \.rotationVector
        let axis = end[keyPath: channel]
        let magnitude = hypot(hypot(axis.x, axis.y), axis.z)
        let noise = armOnly ? (calibration?.quietAcceleration ?? 0.012) : (calibration?.quietRotation ?? 0.04)
        let floor = max(armOnly ? 0.045 : 0.26, threshold * 0.60, noise * 3)
        guard magnitude >= floor else { return nil }
        let unit = axis / magnitude
        var first = end
        var integral = 0.0, previousProjection = magnitude
        var start = motionWindow.count - 1
        while start > 0 {
            let sample = motionWindow[start - 1]
            let vector = sample[keyPath: channel]
            let projected = (vector * unit).sum()
            guard projected >= floor, projected >= 0.85 * hypot(hypot(vector.x, vector.y), vector.z),
                  projected < threshold, first.timestamp - sample.timestamp <= 0.03 else { break }
            integral += min(previousProjection, projected) * (first.timestamp - sample.timestamp)
            previousProjection = projected
            first = sample
            start -= 1
        }
        let overlapsHaptic = end.timestamp >= beatHapticStart && first.timestamp < beatHapticEnd
        let confirmation = armOnly ? 0.075 : 0.055
        guard end.timestamp - first.timestamp >= confirmation + (overlapsHaptic ? 0.030 : 0),
              integral >= max(armOnly ? 0.005 : 0.028, floor * confirmation) else { return nil }
        for sample in motionWindow[..<start].reversed() {
            guard first.timestamp - sample.timestamp <= 0.075 else { break }
            let vector = sample[keyPath: channel]
            if hypot(hypot(vector.x, vector.y), vector.z) <= floor * 0.65 { return first }
        }
        return nil
    }

    /// Integrate only movement along the accepted stroke. Rotation contributes
    /// angular travel; arm-led strokes contribute the integral of acceleration.
    /// Normalising in each trained channel makes the anchors comparable on either wrist.
    private func strokeTravel(along onset: MotionSample, profile: MotionCalibrationProfile) -> Double {
        func projection(_ v: SIMD3<Double>, along direction: SIMD3<Double>) -> Double {
            let length = hypot(hypot(direction.x, direction.y), direction.z)
            return length > 0 ? max(0, (v * direction).sum() / length) : 0
        }
        var arm = 0.0, wrist = 0.0
        // A guide tap needs a slightly longer confirmation. Measure the same
        // slice as an ordinary attack, so the guide cannot make a stroke louder.
        var crossing = onset.timestamp
        if let previous = motionWindow.last(where: { $0.timestamp < onset.timestamp }) {
            let before = telemetry(for: previous)
            let at = telemetry(for: onset)
            let low = sensitivity.evidence(acceleration: before.accelerationMagnitude, rotation: before.gyroMagnitude,
                                           assisted: assisted, calibration: profile)
            let high = sensitivity.evidence(acceleration: at.accelerationMagnitude, rotation: at.gyroMagnitude,
                                            assisted: assisted, calibration: profile)
            if low < 1, high >= 1 {
                crossing = previous.timestamp + (onset.timestamp - previous.timestamp) * (1 - low) / (high - low)
            }
        }
        let end = crossing + 0.035
        for (previous, current) in zip(motionWindow, motionWindow.dropFirst()) {
            guard previous.timestamp < end else { break }
            let intervalEnd = min(end, current.timestamp)
            var elapsed = intervalEnd - previous.timestamp
            // Fast strokes cross the very same activation gate earlier. Add a
            // short continuation at the mean speed of the last 20 ms, so they
            // can sound accented before the wrist reaches the end of its arc.
            let recent = max(0, intervalEnd - max(previous.timestamp, end - 0.020))
            elapsed += 3 * recent
            // Minimum of adjacent samples keeps a single impact from boosting
            // expression. The gate already required a sustained, aligned onset.
            if profile.usesRotation {
                let rate = min(projection(previous.rotationVector, along: onset.rotationVector),
                               projection(current.rotationVector, along: onset.rotationVector))
                wrist += elapsed * max(0, rate - profile.quietRotation) / profile.rotationThreshold
            }
            if profile.usesAcceleration {
                let acceleration = min(projection(previous.accelerationVector, along: onset.accelerationVector),
                                       projection(current.accelerationVector, along: onset.accelerationVector))
                arm += elapsed * max(0, acceleration - profile.quietAcceleration) / profile.accelerationThreshold
            }
        }
        return max(arm, wrist)
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
    /// Median motion integrated up to sound onset, in threshold-normalised seconds.
    public let lightTravel: Double?
    public let accentTravel: Double?

    public init(accelerationThreshold: Double, rotationThreshold: Double,
                quietAcceleration: Double, quietRotation: Double,
                usesAcceleration: Bool = true, usesRotation: Bool = true,
                learnedAt: Date = Date(), lightTravel: Double? = nil, accentTravel: Double? = nil) {
        version = lightTravel == nil && accentTravel == nil ? 1 : 2
        self.accelerationThreshold = accelerationThreshold
        self.rotationThreshold = rotationThreshold
        self.quietAcceleration = quietAcceleration
        self.quietRotation = quietRotation
        self.usesAcceleration = usesAcceleration
        self.usesRotation = usesRotation
        self.learnedAt = learnedAt
        self.lightTravel = lightTravel
        self.accentTravel = accentTravel
    }

    public var hasPersonalDynamics: Bool {
        guard version == 2, let lightTravel, let accentTravel else { return false }
        return (0.001...20).contains(lightTravel) && (0.001...20).contains(accentTravel)
            && accentTravel >= max(lightTravel * 1.35, lightTravel + 0.018)
    }

    public var isValid: Bool {
        ((version == 1 && lightTravel == nil && accentTravel == nil) || hasPersonalDynamics)
            && (usesAcceleration || usesRotation)
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

public enum WristLearningStage: Equatable, Sendable { case baseline, collecting, collectingAccents, completed }
public enum WristLearningFeedback: Equatable, Sendable {
    case holdStill, moveComfortably, relaxBetween, tooSmall, recorded, needsMoreContrast, complete
}

public struct WristLearningUpdate: Sendable {
    public let stage: WristLearningStage
    public let completedSwings: Int
    public let feedback: WristLearningFeedback
    public let candidate: MotionCalibrationProfile?
    public let telemetry: MotionTelemetry
}

/// Three independent gestures establish activation thresholds after a quiet baseline.
/// When expression is requested, three more teach the player's accented range.
public struct WristMotionCalibrator: Sendable {
    private let learnsDynamics: Bool
    private var stage: WristLearningStage = .baseline
    private var feedback: WristLearningFeedback = .holdStill
    private var lastTime: Double?
    private var previousSample: MotionSample?
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
    private var lightProfile: MotionCalibrationProfile?
    private var lightTravel: Double?
    private var swingTrace = [MotionSample]()
    private var traces = [[MotionSample]]()

    public init(learnsDynamics: Bool = false) { self.learnsDynamics = learnsDynamics }

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
        defer { previousSample = sample }
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
        case .collecting, .collectingAccents:
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
                    swingTrace.removeAll(keepingCapacity: true)
                    if learnsDynamics, let previousSample, sample.timestamp - previousSample.timestamp <= 0.05 {
                        swingTrace.append(previousSample)
                    }
                    releasedAt = nil; feedback = .relaxBetween
                }
                if let start = swingStart {
                    if learnsDynamics && swingTrace.count < 256 { swingTrace.append(sample) }
                    peakA = max(peakA, a); peakR = max(peakR, r)
                    let settled = a <= max(0.025, quietA * 1.4) && r <= max(0.10, quietR * 1.4)
                    if settled {
                        if releasedAt == nil { releasedAt = sample.timestamp }
                        if sample.timestamp - (releasedAt ?? sample.timestamp) >= 0.16 {
                            let useful = peakA >= max(0.08, quietA * 3) || peakR >= max(0.35, quietR * 3)
                            let sustained = !learnsDynamics || (releasedAt ?? sample.timestamp) - start >= 0.035
                            if useful && sustained && sample.timestamp - start <= 1.8 {
                                peaks.append((peakA, peakR)); feedback = .recorded
                                if learnsDynamics { traces.append(swingTrace) }
                            } else { feedback = useful && sustained ? .relaxBetween : .tooSmall }
                            swingStart = nil; releasedAt = nil; cooldownUntil = sample.timestamp + 0.45
                            if peaks.count == 3 { finishSet() }
                        }
                    } else { releasedAt = nil }
                }
            }
        case .completed: break
        }
        let completed = peaks.count + (lightProfile == nil ? 0 : 3)
        return WristLearningUpdate(stage: stage, completedSwings: completed, feedback: feedback,
                                   candidate: candidate, telemetry: MotionTelemetry(sample: sample))
    }

    private func thresholdProfile() -> MotionCalibrationProfile {
        let acceleration = quantile(peaks.map(\.a), fraction: 0.5)
        let rotation = quantile(peaks.map(\.r), fraction: 0.5)
        return MotionCalibrationProfile(
            accelerationThreshold: min(0.65, max(0.06, quietA * 2.2, acceleration * 0.55)),
            rotationThreshold: min(2.8, max(0.25, quietR * 2.2, rotation * 0.55)),
            quietAcceleration: quietA, quietRotation: quietR,
            usesAcceleration: peaks.filter { $0.a >= max(0.08, quietA * 3) }.count >= 2,
            usesRotation: peaks.filter { $0.r >= max(0.35, quietR * 3) }.count >= 2)
    }

    private mutating func finishSet() {
        let thresholds = lightProfile ?? thresholdProfile()
        guard thresholds.isValid else {
            peaks.removeAll(); traces.removeAll(); feedback = .tooSmall
            return
        }
        guard learnsDynamics else {
            candidate = thresholds; stage = .completed; feedback = .complete
            return
        }
        // Compare the part of the motion available at the moment of a real
        // note, instead of training on the peak of a gesture after it ends.
        let measured = traces.map { trace -> Double? in
            var engine = MotionInterpreter(sensitivity: .high, assisted: true, calibration: thresholds)
            engine.measuresCalibrationStroke = true
            for sample in trace where engine.consume(sample) != nil { return engine.lastStrokeTravel }
            return nil
        }
        let travels = measured.compactMap { $0 }
        if travels.count < 3 {
            let accepted = measured.indices.filter { measured[$0] != nil }
            traces = accepted.map { traces[$0] }
            peaks = accepted.map { peaks[$0] }
            feedback = .tooSmall
            return
        }
        traces.removeAll()
        let travel = quantile(travels, fraction: 0.5)
        if let lightTravel {
            let profile = MotionCalibrationProfile(accelerationThreshold: thresholds.accelerationThreshold,
                rotationThreshold: thresholds.rotationThreshold, quietAcceleration: quietA, quietRotation: quietR,
                usesAcceleration: thresholds.usesAcceleration, usesRotation: thresholds.usesRotation,
                lightTravel: lightTravel, accentTravel: travel)
            guard profile.isValid else {
                peaks.removeAll(); feedback = .needsMoreContrast
                return
            }
            candidate = profile; stage = .completed; feedback = .complete
        } else {
            lightProfile = thresholds; lightTravel = travel
            peaks.removeAll(); stage = .collectingAccents; feedback = .moveComfortably
        }
    }

    private func quantile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
}
