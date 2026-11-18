import XCTest
@testable import AirGuitarCore

final class MotionInterpreterTests: XCTestCase {
    private func sample(_ time: Double, roll: Double = 0,
                        acceleration: Double = 0, rotation: Double = 0) -> MotionSample {
        MotionSample(timestamp: time, roll: roll,
                     accelerationX: acceleration, accelerationY: 0, accelerationZ: 0,
                     rotationX: rotation, rotationY: 0, rotationZ: 0)
    }

    func testStationaryWatchNeverStrums() {
        var interpreter = MotionInterpreter()
        for tick in 0..<500 {
            XCTAssertNil(interpreter.consume(sample(Double(tick) / 50,
                                                     roll: Double(tick) / 1000,
                                                     acceleration: 0.03, rotation: 0.06)))
        }
    }

    func testGuideClickDoesNotStrumFromAnIsolatedImpactOrOscillatingEcho() {
        var interpreter = MotionInterpreter(sensitivity: .high, assisted: true)
        for index in 0..<16 {
            let beat = Double(index) * 0.625
            interpreter.expectBeatHaptic(at: beat)
            for tick in 0..<15 {
                let alternating = tick.isMultiple(of: 2) ? 1.0 : -1.0
                let strength = tick < 8 ? alternating : 0
                XCTAssertNil(interpreter.consume(sample(beat + Double(tick) * 0.01,
                                                       acceleration: strength, rotation: strength)))
            }
        }
    }

    func testGuideClickAllowsAnOnBeatStrokeAndKeepsItsOriginalTime() throws {
        for (acceleration, rotation) in [(0.18, 0.0), (0.0, -0.9)] {
            var interpreter = MotionInterpreter(sensitivity: .high, assisted: true)
            interpreter.expectBeatHaptic(at: 2)
            var events: [StrumEvent] = []
            for tick in 0..<15 {
                if let event = interpreter.consume(sample(2 + Double(tick) * 0.010,
                                                          acceleration: acceleration, rotation: rotation)) {
                    events.append(event)
                }
            }
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(try XCTUnwrap(events.first).timestamp, 2, accuracy: 0.00001)
        }
    }

    func testOrdinaryHapticAndDebounceStillMaskAnOnBeatStroke() {
        var interpreter = MotionInterpreter(sensitivity: .high)
        interpreter.suppress(until: 1.2)
        interpreter.expectBeatHaptic(at: 1)
        for tick in 0..<30 {
            XCTAssertNil(interpreter.consume(sample(1 + Double(tick) * 0.010,
                                                   acceleration: 1, rotation: 2)))
        }
        XCTAssertNil(interpreter.consume(sample(1.34)))
        XCTAssertNil(interpreter.consume(sample(1.40)))
        XCTAssertNotNil(interpreter.consume(sample(1.42, acceleration: 1, rotation: 2)))
    }

    func testImpactWithoutRotationAndRotationWithoutImpactAreRejected() {
        var interpreter = MotionInterpreter()
        XCTAssertNil(interpreter.consume(sample(0, acceleration: 3, rotation: 0.01)))
        XCTAssertNil(interpreter.consume(sample(1, acceleration: 0.01, rotation: 5)))
        XCTAssertNotNil(interpreter.consume(sample(2, acceleration: 0.7, rotation: 2.5)))
    }

    func testSustainedMotionOnlyFiresOnceAndReleaseAllowsAnotherStrum() {
        var interpreter = MotionInterpreter()
        XCTAssertNotNil(interpreter.consume(sample(0, acceleration: 0.7, rotation: 2.5)))
        for tick in 1...30 {
            XCTAssertNil(interpreter.consume(sample(Double(tick) / 50,
                                                     acceleration: 0.7, rotation: 2.5)))
        }
        XCTAssertNil(interpreter.consume(sample(0.7)))
        XCTAssertNil(interpreter.consume(sample(0.74)))
        XCTAssertNotNil(interpreter.consume(sample(0.8, acceleration: 0.7, rotation: 2.5)))
    }

    func testCooldownConsumesFastEdgeInsteadOfPlayingItLate() {
        var interpreter = MotionInterpreter()
        XCTAssertNotNil(interpreter.consume(sample(0, acceleration: 1, rotation: 3)))
        XCTAssertNil(interpreter.consume(sample(0.02)))
        XCTAssertNil(interpreter.consume(sample(0.06)))
        XCTAssertNil(interpreter.consume(sample(0.08, acceleration: 1, rotation: 3)))
        XCTAssertNil(interpreter.consume(sample(0.3, acceleration: 1, rotation: 3)))
        XCTAssertNil(interpreter.consume(sample(0.32)))
        XCTAssertNil(interpreter.consume(sample(0.36)))
        XCTAssertNotNil(interpreter.consume(sample(0.4, acceleration: 1, rotation: 3)))
    }

    func testCalibrationAndChordMappingHandlePiBoundary() {
        var interpreter = MotionInterpreter()
        interpreter.calibrate(roll: .pi - 0.1)
        XCTAssertEqual(interpreter.currentChord(forRoll: .pi - 0.1), .c)
        XCTAssertEqual(interpreter.currentChord(forRoll: .pi - 0.6), .aMinor)
        XCTAssertEqual(interpreter.currentChord(forRoll: -.pi + 0.5), .f)
        XCTAssertEqual(interpreter.currentChord(forRoll: -.pi + 1.1), .g)
    }

    func testCalibrationResetsDebounceAndInvalidCalibrationDoesNothing() {
        var interpreter = MotionInterpreter()
        XCTAssertNotNil(interpreter.consume(sample(1, acceleration: 1, rotation: 3)))
        interpreter.calibrate(roll: 1)
        XCTAssertEqual(interpreter.currentChord(forRoll: 1), .c)
        XCTAssertNotNil(interpreter.consume(sample(1.01, roll: 1, acceleration: 1, rotation: 3)))
        interpreter.calibrate(roll: .nan)
        XCTAssertEqual(interpreter.currentChord(forRoll: 1), .c)
    }

    func testBadAndOutOfOrderSamplesDoNotConsumeFutureGestures() {
        var interpreter = MotionInterpreter()
        XCTAssertNil(interpreter.consume(sample(1)))
        XCTAssertNil(interpreter.consume(sample(.nan, acceleration: 1, rotation: 3)))
        XCTAssertNil(interpreter.consume(sample(-1, acceleration: 1, rotation: 3)))
        XCTAssertNil(interpreter.consume(sample(1.1, roll: .infinity, acceleration: 1, rotation: 3)))
        XCTAssertNil(interpreter.consume(sample(0.5, acceleration: 1, rotation: 3)))
        XCTAssertNil(interpreter.consume(sample(1, acceleration: 1, rotation: 3)))
        XCTAssertNotNil(interpreter.consume(sample(1.2, acceleration: 1, rotation: 3)))
    }

    func testSensitivityAndVelocityBounds() {
        var low = MotionInterpreter(sensitivity: .low)
        var high = MotionInterpreter(sensitivity: .high)
        let gentle = sample(0, acceleration: 0.3, rotation: 1.2)
        XCTAssertNil(low.consume(gentle))
        let gentleEvent = high.consume(gentle)
        XCTAssertNotNil(gentleEvent)
        XCTAssertTrue((0...1).contains(gentleEvent?.velocity ?? -1))
        high.calibrate(roll: 0)
        let hardEvent = high.consume(sample(1, acceleration: 10, rotation: 20))
        XCTAssertEqual(hardEvent?.velocity, 1)
        XCTAssertGreaterThan(hardEvent?.velocity ?? 0, gentleEvent?.velocity ?? 1)
    }

    func testEventCarriesChordAndGuitarVoicingsStayInPlayableRange() {
        var interpreter = MotionInterpreter()
        let event = interpreter.consume(sample(0, roll: 0.6, acceleration: 1, rotation: 3))
        XCTAssertEqual(event?.chord, .f)
        for chord in Chord.allCases {
            XCTAssertTrue((5...6).contains(chord.midiNotes.count))
            XCTAssertTrue(chord.midiNotes.allSatisfy { (40...88).contains($0) })
        }
    }

    func testAssistedSingleChannelGestureDoesNotRequireWristTurn() {
        var arm = MotionInterpreter(sensitivity: .high, assisted: true)
        var wrist = MotionInterpreter(sensitivity: .high, assisted: true)
        let armEvent = arm.consume(sample(42.123, acceleration: 0.17, rotation: 0))
        let wristEvent = wrist.consume(sample(42.123, acceleration: 0, rotation: 0.76))
        XCTAssertNotNil(armEvent)
        XCTAssertNotNil(wristEvent)
        XCTAssertEqual(armEvent?.timestamp, 42.123)
        XCTAssertEqual(armEvent?.chord, .c)
        var manual = MotionInterpreter(sensitivity: .high)
        XCTAssertNil(manual.consume(sample(42.123, acceleration: 0.17)))
        XCTAssertNil(manual.consume(sample(42.223, rotation: 0.76)))
    }

    func testAssistedIdleAndContinuousMovementDoNotRepeat() {
        var engine = MotionInterpreter(sensitivity: .high, assisted: true)
        for tick in 0..<300 {
            XCTAssertNil(engine.consume(sample(Double(tick) / 100, acceleration: 0.025, rotation: 0.05)))
        }
        XCTAssertNotNil(engine.consume(sample(3, acceleration: 0.2)))
        for tick in 301...500 {
            XCTAssertNil(engine.consume(sample(Double(tick) / 100, acceleration: 0.2)))
        }
        // Changing which channel is moving is not a release.
        XCTAssertNil(engine.consume(sample(5.01, rotation: 0.9)))
        XCTAssertNil(engine.consume(sample(5.5, rotation: 0.9)))
        _ = engine.consume(sample(5.6))
        _ = engine.consume(sample(5.65))
        XCTAssertNil(engine.consume(sample(5.7, acceleration: 0.2)), "50ms quiet is too short")
        _ = engine.consume(sample(5.8))
        _ = engine.consume(sample(5.89))
        XCTAssertNotNil(engine.consume(sample(5.95, acceleration: 0.2)))
    }

    func testAssistedCooldownConsumesAnEarlyPulseWithoutDelayedSound() {
        var engine = MotionInterpreter(sensitivity: .high, assisted: true)
        XCTAssertNotNil(engine.consume(sample(0, acceleration: 0.2)))
        _ = engine.consume(sample(0.01)); _ = engine.consume(sample(0.10))
        XCTAssertNil(engine.consume(sample(0.12, acceleration: 0.2)))
        XCTAssertNil(engine.consume(sample(0.4, acceleration: 0.2)))
        _ = engine.consume(sample(0.41)); _ = engine.consume(sample(0.50))
        XCTAssertNotNil(engine.consume(sample(0.55, acceleration: 0.2)))
    }

    func testAssistedSensitivityAndModeSwitchPreserveManualCalibration() {
        var low = MotionInterpreter(sensitivity: .low, assisted: true)
        var high = MotionInterpreter(sensitivity: .high, assisted: true)
        XCTAssertNil(low.consume(sample(0, acceleration: 0.2)))
        XCTAssertNotNil(high.consume(sample(0, acceleration: 0.2)))
        high.calibrate(roll: 0.5)
        high.assisted = false
        XCTAssertEqual(high.currentChord(forRoll: 1.1), .f)
        XCTAssertNil(high.consume(sample(1, acceleration: 0.2)))
        high.assisted = true
        XCTAssertNotNil(high.consume(sample(1.01, acceleration: 0.2)))
        XCTAssertEqual(high.currentChord(forRoll: 1.1), .f)
    }
}
