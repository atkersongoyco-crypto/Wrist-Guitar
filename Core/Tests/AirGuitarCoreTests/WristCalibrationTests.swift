import Foundation
import XCTest
@testable import AirGuitarCore

final class WristCalibrationTests: XCTestCase {
    private struct Session {
        var learner = WristMotionCalibrator()
        var time = 0.0
        var last: WristLearningUpdate?

        mutating func feed(_ duration: Double, a: Double = 0.015, r: Double = 0.04) {
            for _ in 0..<Int((duration / 0.01).rounded()) {
                last = learner.consume(MotionSample(timestamp: time, roll: 0,
                    accelerationX: a, accelerationY: 0, accelerationZ: 0,
                    rotationX: r, rotationY: 0, rotationZ: 0))
                time += 0.01
            }
        }

        mutating func swing(a: Double, r: Double) {
            feed(0.12, a: a, r: r)
            feed(0.85)
        }
    }

    private func sample(_ time: Double, a: Double = 0, r: Double = 0) -> MotionSample {
        MotionSample(timestamp: time, roll: 0.6, accelerationX: a, accelerationY: 0, accelerationZ: 0,
                     rotationX: r, rotationY: 0, rotationZ: 0)
    }

    func testLearnsExactlyThreeIndependentComfortableSwings() throws {
        var session = Session()
        session.feed(1)
        XCTAssertEqual(session.last?.stage, .collecting)
        session.swing(a: 0.20, r: 0.10)
        XCTAssertEqual(session.last?.completedSwings, 1)
        XCTAssertNil(session.last?.candidate)
        session.swing(a: 0.22, r: 0.10)
        XCTAssertEqual(session.last?.completedSwings, 2)
        session.swing(a: 0.18, r: 0.10)
        let profile = try XCTUnwrap(session.last?.candidate)
        XCTAssertTrue(profile.isValid)
        XCTAssertEqual(session.last?.stage, .completed)
        XCTAssertEqual(profile.accelerationThreshold, 0.11, accuracy: 0.002)
        XCTAssertTrue(profile.usesAcceleration)
        XCTAssertFalse(profile.usesRotation)
    }

    func testMedianRejectsOneUnusuallyLargeGesture() throws {
        var session = Session()
        session.feed(1)
        session.swing(a: 0.20, r: 0.10)
        session.swing(a: 1.50, r: 4.0)
        session.swing(a: 0.22, r: 0.10)
        let profile = try XCTUnwrap(session.last?.candidate)
        XCTAssertEqual(profile.accelerationThreshold, 0.121, accuracy: 0.003)
        XCTAssertFalse(profile.usesRotation, "One incidental wrist rotation must not train that channel")
    }

    func testTooSmallGestureCanRetryWithoutCompletingCalibration() {
        var session = Session()
        session.feed(1)
        session.swing(a: 0.04, r: 0.15)
        XCTAssertEqual(session.last?.feedback, .tooSmall)
        XCTAssertEqual(session.last?.completedSwings, 0)
        XCTAssertNil(session.last?.candidate)
        session.swing(a: 0.20, r: 0.10)
        XCTAssertEqual(session.last?.completedSwings, 1)
    }

    func testMovingBaselineAndLongContinuousMovementDoNotCount() {
        var session = Session()
        session.feed(3, a: 0.2, r: 0.5)
        XCTAssertEqual(session.last?.stage, .baseline)
        XCTAssertEqual(session.last?.completedSwings, 0)
        session.feed(1)
        session.feed(2.2, a: 0.3, r: 1)
        session.feed(0.8)
        XCTAssertEqual(session.last?.completedSwings, 0)
        XCTAssertNil(session.last?.candidate)
    }

    func testGyroOnlyCalibrationAffectsBothPerformanceModes() throws {
        var session = Session()
        session.feed(1)
        session.swing(a: 0.015, r: 1.0)
        session.swing(a: 0.015, r: 0.9)
        session.swing(a: 0.015, r: 1.1)
        let profile = try XCTUnwrap(session.last?.candidate)
        XCTAssertFalse(profile.usesAcceleration)
        XCTAssertTrue(profile.usesRotation)
        var legacyManual = MotionInterpreter(sensitivity: .high)
        XCTAssertNil(legacyManual.consume(sample(0, r: 0.65)))
        for assisted in [false, true] {
            var personal = MotionInterpreter(sensitivity: .high, assisted: assisted, calibration: profile)
            XCTAssertNotNil(personal.consume(sample(0, r: 0.65)), "Saved personal gyro gesture must work in both modes")
            personal.calibrate(roll: 0)
            XCTAssertEqual(personal.currentChord(forRoll: 0.6), .f, "Manual chord direction remains independent")
            XCTAssertNil(personal.consume(sample(1, a: 1)), "Untrained acceleration must not trigger")
            let telemetry = personal.telemetry(for: sample(2, r: 0.65))
            XCTAssertEqual(telemetry.gyroMagnitude, 0.65)
            XCTAssertEqual(telemetry.gyroStrength, 1)
        }
    }

    func testSavedArmThresholdChangesManualTriggerWithoutChangingLegacyDefaults() throws {
        var session = Session()
        session.feed(1)
        for _ in 0..<3 { session.swing(a: 0.2, r: 0.10) }
        let profile = try XCTUnwrap(session.last?.candidate)
        var manual = MotionInterpreter(sensitivity: .high, calibration: profile)
        var original = MotionInterpreter(sensitivity: .high)
        XCTAssertNotNil(manual.consume(sample(0, a: 0.13)))
        XCTAssertNil(original.consume(sample(0, a: 0.13)))
        for assisted in [false, true] {
            for preset in Sensitivity.allCases {
                var personal = MotionInterpreter(sensitivity: preset, assisted: assisted, calibration: profile)
                XCTAssertNotNil(personal.consume(sample(0, a: 0.13)), "Every preset must use the saved trial threshold unchanged")
                XCTAssertEqual(personal.telemetry(for: sample(1, a: 0.08)).strength,
                               0.08 / profile.accelerationThreshold, accuracy: 0.0001)
            }
        }
        var resetToPreset = MotionInterpreter(sensitivity: .low, assisted: true, calibration: profile)
        XCTAssertNotNil(resetToPreset.consume(sample(0, a: 0.13)))
        resetToPreset.calibration = nil
        XCTAssertNil(resetToPreset.consume(sample(1, a: 0.13)), "Clearing calibration restores the old low preset")
        for tick in 1...100 { XCTAssertNil(manual.consume(sample(Double(tick) / 100, a: 0.2))) }
        _ = manual.consume(sample(1.1)); _ = manual.consume(sample(1.19))
        XCTAssertNotNil(manual.consume(sample(1.3, a: 0.13)))
    }

    func testHapticMaskRequiresQuietAfterItEnds() {
        var interpreter = MotionInterpreter(sensitivity: .high, assisted: true)
        interpreter.suppress(until: 1)
        XCTAssertNil(interpreter.consume(sample(0.5, a: 0.5, r: 2)))
        XCTAssertNil(interpreter.consume(sample(1.1, a: 0.5, r: 2)))
        XCTAssertNil(interpreter.consume(sample(1.6, a: 0.5, r: 2)))
        _ = interpreter.consume(sample(1.7)); _ = interpreter.consume(sample(1.79))
        XCTAssertNotNil(interpreter.consume(sample(1.9, a: 0.2)))
    }

    func testLearnerRejectsHapticPulseAndRequiresSettlingAfterSuppression() {
        var session = Session()
        session.feed(1)
        session.learner.suppress(until: session.time + 0.45)
        session.feed(1.0, a: 0.5, r: 2)
        XCTAssertEqual(session.last?.completedSwings, 0)
        session.feed(0.2)
        session.swing(a: 0.2, r: 0.1)
        XCTAssertEqual(session.last?.completedSwings, 1)
    }

    func testProfileSerializationValidationAndTelemetry() throws {
        let profile = MotionCalibrationProfile(accelerationThreshold: 0.12, rotationThreshold: 0.6,
                                               quietAcceleration: 0.015, quietRotation: 0.04)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(MotionCalibrationProfile.self, from: data), profile)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload["version"] = 99
        let unsupported = try JSONDecoder().decode(MotionCalibrationProfile.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertFalse(unsupported.isValid)
        let bad = MotionCalibrationProfile(accelerationThreshold: .nan, rotationThreshold: 0,
                                           quietAcceleration: 0, quietRotation: 0)
        XCTAssertFalse(bad.isValid)
        let engine = MotionInterpreter(sensitivity: .high, assisted: true, calibration: bad)
        XCTAssertNil(engine.calibration)
        XCTAssertEqual(engine.telemetry(for: sample(1, a: 0.08, r: 0.375)).strength, 0.5, accuracy: 0.0001)
    }
}
