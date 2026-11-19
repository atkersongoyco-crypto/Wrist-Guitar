import XCTest
@testable import AirGuitarCore

final class MotionInterpreterTests: XCTestCase {
    private func sample(_ time: Double, roll: Double = 0,
                        acceleration: Double = 0, rotation: Double = 0) -> MotionSample {
        MotionSample(timestamp: time, roll: roll,
                     accelerationX: acceleration, accelerationY: 0, accelerationZ: 0,
                     rotationX: rotation, rotationY: 0, rotationZ: 0)
    }

    private func stroke(_ interpreter: inout MotionInterpreter, at time: Double,
                        acceleration: Double = 0, rotation: Double = 0) -> StrumEvent? {
        var result: StrumEvent?
        for index in 0..<3 {
            if let event = interpreter.consume(sample(time + Double(index) * 0.01,
                                                      acceleration: acceleration, rotation: rotation)) { result = event }
        }
        return result
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
        let armEvent = stroke(&arm, at: 42.123, acceleration: 0.17)
        let wristEvent = stroke(&wrist, at: 42.123, rotation: 0.76)
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
        XCTAssertNotNil(stroke(&engine, at: 3, acceleration: 0.2))
        for tick in 301...500 {
            XCTAssertNil(engine.consume(sample(Double(tick) / 100, acceleration: 0.2)))
        }
        // Changing which channel is moving is not a release.
        XCTAssertNil(engine.consume(sample(5.01, rotation: 0.9)))
        XCTAssertNil(engine.consume(sample(5.5, rotation: 0.9)))
        _ = engine.consume(sample(5.6))
        _ = engine.consume(sample(5.63))
        XCTAssertNil(engine.consume(sample(5.7, acceleration: 0.2)), "30ms quiet is too short")
        _ = engine.consume(sample(5.8))
        _ = engine.consume(sample(5.89))
        XCTAssertNotNil(stroke(&engine, at: 5.95, acceleration: 0.2))
    }

    func testAssistedCooldownConsumesAnEarlyPulseWithoutDelayedSound() {
        var engine = MotionInterpreter(sensitivity: .high, assisted: true)
        XCTAssertNotNil(stroke(&engine, at: 0, acceleration: 0.2))
        _ = engine.consume(sample(0.03)); _ = engine.consume(sample(0.08))
        XCTAssertNil(stroke(&engine, at: 0.12, acceleration: 0.2))
        XCTAssertNil(engine.consume(sample(0.4, acceleration: 0.2)))
        _ = engine.consume(sample(0.41)); _ = engine.consume(sample(0.50))
        XCTAssertNotNil(stroke(&engine, at: 0.55, acceleration: 0.2))
    }

    func testAssistedSensitivityAndModeSwitchPreserveManualCalibration() {
        var low = MotionInterpreter(sensitivity: .low, assisted: true)
        var high = MotionInterpreter(sensitivity: .high, assisted: true)
        XCTAssertNil(low.consume(sample(0, acceleration: 0.2)))
        XCTAssertNotNil(stroke(&high, at: 0, acceleration: 0.2))
        high.calibrate(roll: 0.5)
        high.assisted = false
        XCTAssertEqual(high.currentChord(forRoll: 1.1), .f)
        XCTAssertNil(high.consume(sample(1, acceleration: 0.2)))
        high.assisted = true
        _ = high.consume(sample(1.01)); _ = high.consume(sample(1.07))
        XCTAssertNotNil(stroke(&high, at: 1.1, acceleration: 0.2))
        XCTAssertEqual(high.currentChord(forRoll: 1.1), .f)
    }
    func testIdleSpikesAndLateHapticEchoDoNotBecomeStrums() {
        for profile in [MotionCalibrationProfile?.none,
                        MotionCalibrationProfile(accelerationThreshold: 0.11, rotationThreshold: 0.55,
                            quietAcceleration: 0.015, quietRotation: 0.04)] {
            var engine = MotionInterpreter(sensitivity: .high, assisted: true, calibration: profile)
            for tick in 0..<6000 {
                let impulse = tick % 100 == 50 || tick % 100 == 51
                XCTAssertNil(engine.consume(sample(Double(tick) / 100,
                    acceleration: impulse ? 0.3 : 0.015, rotation: 0.04)))
            }
        }
        var guide = MotionInterpreter(sensitivity: .high, assisted: true)
        guide.expectBeatHaptic(at: 0)
        for tick in 0..<40 {
            XCTAssertNil(guide.consume(sample(Double(tick) / 100,
                acceleration: tick == 14 ? 0.3 : 0.015))) // A single echo outside the special window.
        }
    }

    func testStartupRaiseSettlesBeforeLearningNeutralPose() {
        var engine = MotionInterpreter(sensitivity: .high, assisted: true)
        engine.prepareForSession()
        XCTAssertNil(engine.consume(sample(0, roll: -0.2, acceleration: 0.3, rotation: 1)))
        // Even an initial sensor warm-up gap must still learn the settled pose.
        for tick in 0..<30 {
            XCTAssertNil(engine.consume(sample(1 + Double(tick) / 100, roll: 0.5,
                                                acceleration: tick < 15 ? 0.3 : 0.015,
                                                rotation: tick < 15 ? 1 : 0.04)))
        }
        XCTAssertEqual(engine.currentChord(forRoll: 0.5), .c)
        XCTAssertEqual(engine.currentChord(forRoll: 1.1), .f)
        XCTAssertNotNil(stroke(&engine, at: 1.3, acceleration: 0.18))
    }

    func testSensorGapRequiresReleaseWithoutChangingManualNeutral() {
        var engine = MotionInterpreter(sensitivity: .high)
        engine.prepareForSession()
        for tick in 0..<15 { _ = engine.consume(sample(Double(tick) / 100, roll: 0.5)) }
        for tick in 0..<10 {
            XCTAssertNil(engine.consume(sample(1 + Double(tick) / 100, roll: 1.1, acceleration: 1, rotation: 3)))
        }
        for tick in 0..<15 { _ = engine.consume(sample(1.1 + Double(tick) / 100, roll: 1.1)) }
        XCTAssertEqual(engine.currentChord(forRoll: 1.1), .f, "A resumed stream must retain the player's neutral pose")
        XCTAssertEqual(engine.consume(sample(1.25, roll: 1.1, acceleration: 1, rotation: 3))?.chord, .f)
    }

    func test96BPMHalfBeatSmallStrokesRemainIndependentWithFeedback() {
        for mask in [0.0, 0.12, 0.30] {
            var engine = MotionInterpreter(sensitivity: .high, assisted: true)
            let first = stroke(&engine, at: 0, acceleration: 0.18)
            XCTAssertEqual(first?.timestamp, 0)
            if mask > 0 { engine.suppress(until: 0.02 + mask) } // Feedback follows the confirmation callback.
            for tick in 3..<32 { XCTAssertNil(engine.consume(sample(Double(tick) / 100))) }
            let second = stroke(&engine, at: 0.32, acceleration: -0.18) // First 100Hz sample after 312.5ms.
            XCTAssertNotNil(second, "No/classic click/success feedback, mask \(mask)")
            XCTAssertEqual(second?.timestamp, 0.32)
        }
    }

    func testHeldMotionDuringFeedbackCannotBecomeDelayedSound() {
        var engine = MotionInterpreter(sensitivity: .high, assisted: true)
        XCTAssertNotNil(stroke(&engine, at: 0, acceleration: 0.2))
        engine.suppress(until: 0.32)
        for tick in 3..<100 { XCTAssertNil(engine.consume(sample(Double(tick) / 100, acceleration: 0.3))) }
        for tick in 100..<110 { _ = engine.consume(sample(Double(tick) / 100)) }
        XCTAssertNotNil(stroke(&engine, at: 1.1, acceleration: 0.2))
    }

    func testLowAndHighDistinguishNaturalReturnFromSeparateDeliberateStrokes() {
        var counts: [Sensitivity: Int] = [:]
        for preset in [Sensitivity.low, .high] {
            var engine = MotionInterpreter(sensitivity: preset, assisted: true)
            var events: [StrumEvent] = []
            for tick in 0..<150 {
                let t = Double(tick) / 100
                let a = (0.20..<0.28).contains(t) ? 0.7 : ((0.55..<0.63).contains(t) ? -0.6 : ((1.00..<1.08).contains(t) ? 0.7 : 0.015))
                if let event = engine.consume(sample(t, acceleration: a)) { events.append(event) }
            }
            counts[preset] = events.count
        }
        XCTAssertEqual(counts[.low], 2, "Low accepts the first and the deliberately separated next stroke, not its return")
        XCTAssertEqual(counts[.high], 3, "High can intentionally play both directions; it must not be the conservative default")
    }

    func testPersonalThresholdAcceptsAlternatingSmallHalfBeatStrokesAcrossPresets() {
        let profile = MotionCalibrationProfile(accelerationThreshold: 0.11, rotationThreshold: 0.6,
            quietAcceleration: 0.015, quietRotation: 0.04, usesRotation: false)
        for preset in Sensitivity.allCases {
            for assisted in [false, true] {
                var engine = MotionInterpreter(sensitivity: preset, assisted: assisted, calibration: profile)
                var events: [StrumEvent] = []
                for tick in 0..<280 {
                    let t = Double(tick) / 100
                    let index = Int(max(0, t - 0.2) / 0.3125)
                    let offset = t - 0.2 - Double(index) * 0.3125
                    let active = t >= 0.2 && index < 8 && offset < 0.06
                    let a = active ? (index.isMultiple(of: 2) ? 0.13 : -0.13) : 0.015
                    if let event = engine.consume(sample(t, acceleration: a)) { events.append(event) }
                }
                XCTAssertEqual(events.count, 8, "Personal thresholds override preset \(preset), mode \(assisted)")
                for (index, event) in events.enumerated() {
                    XCTAssertEqual(event.timestamp, 0.2 + Double(index) * 0.3125, accuracy: 0.011)
                }
            }
        }
    }

    func testChangingPresetDoesNotTurnHeldMotionIntoNewStroke() {
        var engine = MotionInterpreter(sensitivity: .low, assisted: true)
        for tick in 0..<10 { XCTAssertNil(engine.consume(sample(Double(tick) / 100, acceleration: 0.3))) }
        engine.sensitivity = .high
        for tick in 10..<40 { XCTAssertNil(engine.consume(sample(Double(tick) / 100, acceleration: 0.3))) }
        for tick in 40..<50 { _ = engine.consume(sample(Double(tick) / 100)) }
        XCTAssertNotNil(stroke(&engine, at: 0.5, acceleration: 0.18))
    }

    func testContinuousWristTurnsAt96BPMAreIndependentWithAndWithoutClick() {
        // Smooth back-and-forth turns about an oblique axis. A 6 cm lever
        // contributes tangential and centripetal acceleration at the sensor.
        let halfBeat = 60.0 / 96 / 2
        let axis = SIMD3<Double>(0.60, 0.64, 0.48)
        for feedback in [false, true] {
            for enabled in [false, true] {
                var engine = MotionInterpreter(sensitivity: .low, assisted: true, allowsWristReversals: enabled)
                engine.prepareForSession()
                var events: [StrumEvent] = []
                var lastClick = -1.0
                var angle = 0.0
                for frame in 0..<295 {
                    let time = Double(frame) / 100
                    let position = (time - 0.18) / halfBeat
                    let active = (0..<8).contains(position)
                    let amplitude = Int(max(0, position)).isMultiple(of: 2) ? 4.6 : 3.7
                    let rate = active ? amplitude * sin(.pi * position) : 0
                    let tangent = active ? (0.06 / 9.81) * amplitude * (.pi / halfBeat) * cos(.pi * position) : 0
                    let radial = 0.06 / 9.81 * rate * rate
                    angle += rate * 0.01
                    let sinceClick = time - lastClick
                    let click = sinceClick < 0.08 ? exp(-sinceClick * 45) * (frame.isMultiple(of: 2) ? 1.0 : -1.0) : 0
                    let gyro = axis * rate + SIMD3(0.1, -0.3, 0.25) * click
                    let sample = MotionSample(timestamp: time, roll: angle * axis.x,
                        accelerationX: tangent + 0.35 * click, accelerationY: radial, accelerationZ: 0,
                        rotationX: gyro.x, rotationY: gyro.y, rotationZ: gyro.z)
                    if let event = engine.consume(sample) {
                        events.append(event)
                        if feedback { lastClick = time; engine.expectBeatHaptic(at: time) }
                    }
                }
                XCTAssertEqual(events.count, enabled ? 8 : 1, "Reversals \(enabled), click \(feedback)")
                for (index, event) in events.enumerated() {
                    let phase = (event.timestamp - 0.18) / halfBeat - Double(index)
                    XCTAssertTrue((0.05...0.34).contains(phase), "Each onset should land during its own stroke")
                }
            }
        }
    }

    func testWristReturnRejectsBounceImpactsShakeAndHapticTail() {
        var engine = MotionInterpreter(sensitivity: .high, assisted: true, allowsWristReversals: true)
        engine.prepareForSession()
        var events: [StrumEvent] = []
        for frame in 0..<280 {
            let t = Double(frame) / 100
            let sign = frame.isMultiple(of: 2) ? 1.0 : -1.0
            var rotation = 0.02, acceleration = 0.01
            switch frame {
            case 0..<20: rotation = 3             // Lifting the wrist to start.
            case 45..<85: rotation = 2.0          // A held outward sweep.
            case 85..<100: rotation = -0.80       // Weak mechanical return.
            case 100..<112: rotation = 1.7
            case 112..<114: rotation = -2.6; acceleration = -1.5  // Impact.
            case 114..<135: rotation = 1.7
            case 135..<158: rotation = sign * 1.6; acceleration = sign * 0.7
            case 180..<205:                       // Oscillating guide click at rest.
                rotation = sign * 1.3; acceleration = sign * 0.6
            case 230..<270:                       // A second isolated gentle sweep.
                rotation = -1.2
            default: break
            }
            if frame == 180 { engine.expectBeatHaptic(at: t) }
            if let event = engine.consume(sample(t, acceleration: acceleration, rotation: rotation)) {
                events.append(event)
                engine.expectBeatHaptic(at: t)
            }
        }
        XCTAssertEqual(events.map(\.timestamp), [0.45, 2.30])
        XCTAssertGreaterThan(events.first?.velocity ?? 0, events.last?.velocity ?? 1)
    }

    func testEarlyHeldReturnAndHardHapticMaskCannotTriggerLate() {
        for mask in [false, true] {
            var engine = MotionInterpreter(sensitivity: .high, assisted: true, allowsWristReversals: true)
            var events: [StrumEvent] = []
            for frame in 0..<180 {
                let t = Double(frame) / 100
                let rate: Double
                switch frame {
                case 0..<16: rate = 2
                case 16..<88: rate = -2
                case 110..<121: rate = 2
                case 121..<170: rate = mask ? -2 : 2
                default: rate = 0
                }
                if frame == 119, mask { engine.suppress(until: 1.48) }
                if let event = engine.consume(sample(t, rotation: rate)) { events.append(event) }
            }
            XCTAssertEqual(events.map(\.timestamp), [0, 1.10])
        }
    }

    func testAccentFeedbackRejectsItsEchoButPermitsTheNextReturnWithoutComingToRest() {
        for returns in [false, true] {
            var engine = MotionInterpreter(sensitivity: .high, assisted: true, allowsWristReversals: true)
            var events = [StrumEvent]()
            for frame in 0..<75 {
                let t = Double(frame) / 100
                var rate = 2.0
                if (7..<18).contains(frame) { rate = frame.isMultiple(of: 2) ? -3 : 2 }
                if frame == 23 { rate = -3.0 }
                if returns, frame >= 26 { rate = -1.9 }
                if let event = engine.consume(sample(t, rotation: rate)) {
                    events.append(event)
                    engine.expectBeatHaptic(at: t, window: 0.25)
                }
            }
            XCTAssertEqual(events.map(\.timestamp), returns ? [0, 0.26] : [0])
        }
    }

    func testAccelerationOnlyPersonalStrokeKeepsItsReleaseRule() {
        let profile = MotionCalibrationProfile(accelerationThreshold: 0.11, rotationThreshold: 0.4,
            quietAcceleration: 0.015, quietRotation: 0.04, usesRotation: false)
        var engine = MotionInterpreter(sensitivity: .low, assisted: true, calibration: profile, allowsWristReversals: true)
        var events: [StrumEvent] = []
        for frame in 0..<150 {
            let strength = frame < 40 ? 0.14 : (frame < 85 ? -0.14 : (frame < 105 ? 0 : -0.14))
            if let event = engine.consume(sample(Double(frame) / 100, acceleration: strength,
                                                 rotation: frame < 40 ? 2 : -2)) { events.append(event) }
        }
        XCTAssertEqual(events.map(\.timestamp), [0, 1.05])
    }

    func testCalibratedSmallWristReturnUsesTrainedAxisAndScale() {
        let profile = MotionCalibrationProfile(accelerationThreshold: 0.3, rotationThreshold: 0.42,
            quietAcceleration: 0.02, quietRotation: 0.04, usesAcceleration: false)
        for preset in Sensitivity.allCases {
            var engine = MotionInterpreter(sensitivity: preset, assisted: true, calibration: profile, allowsWristReversals: true)
            var events: [StrumEvent] = []
            for frame in 0..<140 {
                let t = Double(frame) / 100
                let x = frame < 30 ? 0.56 : (frame < 76 ? 0 : -0.59)
                let y = (30..<76).contains(frame) ? 0.65 : 0
                if frame == 76 { engine.expectBeatHaptic(at: t) }
                let s = MotionSample(timestamp: t, roll: 0.3,
                    accelerationX: frame.isMultiple(of: 2) ? 0.65 : -0.65, accelerationY: 0, accelerationZ: 0,
                    rotationX: x, rotationY: y, rotationZ: 0)
                if let event = engine.consume(s) { events.append(event) }
            }
            XCTAssertEqual(events.map(\.timestamp), [0, 0.76], "Orthogonal motion must not count as a reversal")
        }
    }

    private func guidedStrokes(peak: Double, spacing: Double, duration: Double,
                               preset: Sensitivity = .high, profile: MotionCalibrationProfile? = nil,
                               armOnly: Bool = false) -> [StrumEvent] {
        var engine = MotionInterpreter(sensitivity: preset, assisted: true, calibration: profile, allowsWristReversals: true)
        engine.prepareForSession()
        var events = [StrumEvent]()
        for frame in 0..<380 {
            let time = Double(frame) / 100
            let index = Int(floor((time - 0.30) / spacing + 0.000_001))
            let phase = (time - 0.30 - Double(index) * spacing) / duration
            let active = (0..<8).contains(index) && (0..<1).contains(phase)
            let rate = active ? (index.isMultiple(of: 2) ? peak : -peak) * sin(.pi * phase) : 0
            if let event = engine.consume(sample(time, acceleration: armOnly ? rate : rate * 0.125,
                                                 rotation: armOnly ? 0.01 : rate)) {
                events.append(event)
                engine.expectBeatHaptic(at: time, window: event.pickStrength >= 0.62 ? 0.18 : 0.12)
            }
        }
        return events
    }

    func testSmallSmoothStrokesAndReleasedEighthNotesUseExistingProfiles() {
        let legacy = MotionCalibrationProfile(accelerationThreshold: 0.16, rotationThreshold: 0.70,
                                              quietAcceleration: 0.012, quietRotation: 0.04)
        let paired = MotionCalibrationProfile(accelerationThreshold: 0.16, rotationThreshold: 0.70,
            quietAcceleration: 0.012, quietRotation: 0.04, lightTravel: 0.15, accentTravel: 0.34)
        for profile: MotionCalibrationProfile? in [nil, legacy, paired] {
            let quiet = guidedStrokes(peak: 0.67, spacing: 0.32, duration: 0.23, profile: profile)
            XCTAssertEqual(quiet.count, 8)
            XCTAssertTrue(quiet.allSatisfy { (0.05..<0.62).contains($0.pickStrength) })
            let quick = guidedStrokes(peak: 1.65, spacing: 0.20, duration: 0.125, profile: profile)
            XCTAssertEqual(quick.count, 8)
        }
        XCTAssertTrue(guidedStrokes(peak: 0.67, spacing: 0.32, duration: 0.23, preset: .low).isEmpty)
        let arm = MotionCalibrationProfile(accelerationThreshold: 0.15, rotationThreshold: 0.75,
            quietAcceleration: 0.012, quietRotation: 0.04, usesRotation: false)
        XCTAssertEqual(guidedStrokes(peak: 0.135, spacing: 0.34, duration: 0.24, profile: arm, armOnly: true).count, 8)
    }

    func testGentleRecognitionRejectsSlowDriftImpactsAlternatingVibrationAndHeldMotion() {
        for armOnly in [false, true] {
            let arm = MotionCalibrationProfile(accelerationThreshold: 0.15, rotationThreshold: 0.75,
                quietAcceleration: 0.012, quietRotation: 0.04, usesRotation: false)
            var engine = MotionInterpreter(sensitivity: .high, assisted: true, calibration: armOnly ? arm : nil,
                                           allowsWristReversals: true)
            engine.prepareForSession()
            var events = [StrumEvent]()
            for tick in 0..<560 {
                let t = Double(tick) / 100
                let x: Double
                switch tick {
                case 50..<160: x = 0.64 * Double(tick - 50) / 110 // Slowly raising the wrist.
                case 160..<180: x = 0.64
                case 215, 216, 276: x = 3.0 // Short impulses.
                case 280..<300: x = tick.isMultiple(of: 2) ? 0.67 : -0.67
                case 333..<340: x = 0.61  // Short coherent echo right after a guide beat.
                case 410..<505: x = 0.67 // Deliberate onset then hold, exactly one event.
                default: x = 0.02
                }
                if tick == 275 || tick == 332 { engine.expectBeatHaptic(at: t, window: 0.18) }
                if let event = engine.consume(sample(t, acceleration: armOnly ? x * 0.20 : 0.01,
                                                     rotation: armOnly ? 0.03 : x)) { events.append(event) }
            }
            XCTAssertEqual(events.map(\.timestamp), [4.10])
        }
    }

}
