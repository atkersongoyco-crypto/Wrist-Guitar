import AirGuitarCore
import CoreMotion
import Foundation

/// One process-wide manager and serial lane. Calibration and playing can own
/// different MotionDriver objects, but never own two sensor streams.
private final class MotionCaptureSource: @unchecked Sendable {
    static let shared = MotionCaptureSource()
    let manager = CMMotionManager()
    let control = DispatchQueue(label: "AirGuitar.Motion", qos: .userInteractive)
    let callbacks: OperationQueue
    var owner: UUID?
    var generation = 0

    private init() {
        callbacks = OperationQueue()
        callbacks.name = "AirGuitar.Motion.Callbacks"
        callbacks.maxConcurrentOperationCount = 1
        callbacks.qualityOfService = .userInteractive
        callbacks.underlyingQueue = control
    }
}

final class MotionDriver {
    private let id = UUID()
    private var interpreter = MotionInterpreter()
    private var learner = WristMotionCalibrator()
    private var needsCalibration = true
    private var lastUpdate = -Double.infinity
    private var lastLearning: WristLearningUpdate?

    var isAvailable: Bool { MotionCaptureSource.shared.manager.isDeviceMotionAvailable }

    func start(sensitivity: Sensitivity,
               assisted: Bool = false,
               calibration: MotionCalibrationProfile? = nil,
               allowsWristReversals: Bool = false,
               state: @escaping (Chord, Double) -> Void,
               strum: @escaping (StrumEvent) -> Void,
               failure: @escaping (String) -> Void,
               telemetry: ((MotionTelemetry) -> Void)? = nil) {
        startUpdates(prepare: { [weak self] in
            guard let self else { return }
            self.interpreter = MotionInterpreter(sensitivity: sensitivity, assisted: assisted, calibration: calibration,
                                                allowsWristReversals: allowsWristReversals)
            self.needsCalibration = true
            self.lastUpdate = -.infinity
        }, consume: { [weak self] sample in
            guard let self else { return }
            if self.needsCalibration {
                self.interpreter.prepareForSession()
                self.needsCalibration = false
            }
            if let event = self.interpreter.consume(sample) { DispatchQueue.main.async { strum(event) } }
            if sample.timestamp - self.lastUpdate >= 0.05 {
                self.lastUpdate = sample.timestamp
                let chord = self.interpreter.currentChord(forRoll: sample.roll)
                let value = self.interpreter.telemetry(for: sample)
                DispatchQueue.main.async { state(chord, value.strength); telemetry?(value) }
            }
        }, failure: failure)
    }

    func startCalibration(update: @escaping (WristLearningUpdate) -> Void,
                          failure: @escaping (String) -> Void) {
        startUpdates(prepare: { [weak self] in
            self?.learner = WristMotionCalibrator(learnsDynamics: true)
            self?.lastLearning = nil
            self?.lastUpdate = -.infinity
        }, consume: { [weak self] sample in
            guard let self, let value = self.learner.consume(sample) else { return }
            let changed = self.lastLearning?.completedSwings != value.completedSwings
                || self.lastLearning?.stage != value.stage || self.lastLearning?.feedback != value.feedback
            if changed || sample.timestamp - self.lastUpdate >= 0.05 {
                self.lastLearning = value
                self.lastUpdate = sample.timestamp
                DispatchQueue.main.async { update(value) }
            }
        }, failure: failure)
    }

    private func startUpdates(prepare: @escaping () -> Void,
                              consume: @escaping (MotionSample) -> Void,
                              failure: @escaping (String) -> Void) {
        let source = MotionCaptureSource.shared
        source.control.async { [weak self] in
            guard let self else { return }
            source.manager.stopDeviceMotionUpdates()
            source.generation += 1
            let generation = source.generation
            source.owner = self.id
            prepare()
            guard source.manager.isDeviceMotionAvailable else {
                source.owner = nil
                DispatchQueue.main.async { failure("当前没有可用的动作传感器，请在手表真机上重试。") }
                return
            }
            source.manager.deviceMotionUpdateInterval = 0.01
            source.manager.startDeviceMotionUpdates(to: source.callbacks) { [weak self] motion, error in
                guard let self, source.owner == self.id, source.generation == generation else { return }
                if let error {
                    source.generation += 1
                    source.manager.stopDeviceMotionUpdates()
                    source.owner = nil
                    DispatchQueue.main.async { failure(error.localizedDescription) }
                    return
                }
                guard let motion else { return }
                let a = motion.userAcceleration, r = motion.rotationRate
                consume(MotionSample(timestamp: motion.timestamp, roll: motion.attitude.roll,
                                     accelerationX: a.x, accelerationY: a.y, accelerationZ: a.z,
                                     rotationX: r.x, rotationY: r.y, rotationZ: r.z))
            }
        }
    }

    func calibrate() { MotionCaptureSource.shared.control.async { self.needsCalibration = true } }
    func setSensitivity(_ sensitivity: Sensitivity) {
        MotionCaptureSource.shared.control.async { self.interpreter.sensitivity = sensitivity }
    }
    func setAssisted(_ assisted: Bool) {
        MotionCaptureSource.shared.control.async { self.interpreter.assisted = assisted }
    }
    func setWristReversals(_ enabled: Bool) {
        MotionCaptureSource.shared.control.async { self.interpreter.allowsWristReversals = enabled }
    }
    func setCalibration(_ profile: MotionCalibrationProfile?) {
        MotionCaptureSource.shared.control.async { self.interpreter.calibration = profile?.isValid == true ? profile : nil }
    }
    func prepareForBeatHaptic(window: TimeInterval = 0.12) {
        let time = ProcessInfo.processInfo.systemUptime
        MotionCaptureSource.shared.control.async { self.interpreter.expectBeatHaptic(at: time, window: window) }
    }
    func suppressGestures(for duration: TimeInterval) {
        guard duration.isFinite else { return }
        let until = ProcessInfo.processInfo.systemUptime + min(2, max(0, duration))
        MotionCaptureSource.shared.control.async {
            self.interpreter.suppress(until: until)
            self.learner.suppress(until: until)
        }
    }
    func stop() {
        let source = MotionCaptureSource.shared
        source.control.async { [self] in
            // A disappearing calibration sheet must not stop a newer performer.
            guard source.owner == id else { return }
            source.generation += 1
            source.manager.stopDeviceMotionUpdates()
            source.owner = nil
        }
    }
}
