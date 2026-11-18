import XCTest
@testable import AirGuitarCore

final class BeatPulseTests: XCTestCase {
    private let demo = BeatEstimate(bpm: 96, referenceBeat: 0, confidence: 1)

    func test96BPMWaitsForNextBeatAndEmitsOnceWithoutAdvancingPhase() throws {
        var cursor = BeatPulseCursor()
        cursor.reset(beat: demo, startingAt: 0)
        XCTAssertEqual(try XCTUnwrap(cursor.nextBeatTime), 0.625, accuracy: 1e-10)
        XCTAssertNil(cursor.consume(at: 0.624))
        XCTAssertEqual(try XCTUnwrap(cursor.consume(at: 0.64)), 0.625, accuracy: 1e-10)
        XCTAssertNil(cursor.consume(at: 0.641))
        XCTAssertEqual(try XCTUnwrap(cursor.nextBeatTime), 1.25, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(cursor.consume(at: 1.25)), 1.25, accuracy: 1e-10)
    }

    func testArbitraryPhaseAndUptimeClockRemainAligned() throws {
        let beat = BeatEstimate(bpm: 120, referenceBeat: 123_456.137, confidence: 0.8)
        var cursor = BeatPulseCursor()
        cursor.reset(beat: beat, startingAt: 123_457.2)
        XCTAssertEqual(try XCTUnwrap(cursor.nextBeatTime), 123_457.637, accuracy: 1e-8)
        XCTAssertNil(cursor.consume(at: 123_457.636))
        XCTAssertEqual(try XCTUnwrap(cursor.consume(at: 123_457.65)), 123_457.637, accuracy: 1e-8)
    }

    func testDelayedCallbackDoesNotCatchUpOrShiftFollowingBeat() throws {
        var cursor = BeatPulseCursor()
        cursor.reset(beat: demo, startingAt: 0)
        XCTAssertNil(cursor.consume(at: 3.17)) // Several beats elapsed; no burst, even near a later beat.
        XCTAssertEqual(try XCTUnwrap(cursor.nextBeatTime), 3.75, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(cursor.consume(at: 3.77)), 3.75, accuracy: 1e-10)
    }

    func testLateCueIsSkippedRatherThanFeltOffBeat() throws {
        var cursor = BeatPulseCursor()
        cursor.reset(beat: demo, startingAt: 0)
        XCTAssertNil(cursor.consume(at: 0.70))
        XCTAssertEqual(try XCTUnwrap(cursor.nextBeatTime), 1.25, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(cursor.consume(at: 1.30)), 1.25, accuracy: 1e-10)
    }

    func testSwitchOffAndSilenceRetireBeatsWithoutRecoveryPulse() throws {
        var cursor = BeatPulseCursor()
        cursor.reset(beat: demo, startingAt: 0)
        XCTAssertNil(cursor.consume(at: 0.625, enabled: false))
        XCTAssertNil(cursor.consume(at: 0.64))
        XCTAssertNil(cursor.consume(at: 1.25, isAudible: false))
        XCTAssertNil(cursor.consume(at: 1.26))
        XCTAssertEqual(try XCTUnwrap(cursor.consume(at: 1.875)), 1.875, accuracy: 1e-10)
    }

    func testPauseResumeRewindAndNewSongExplicitlyRearmFutureGrid() throws {
        var cursor = BeatPulseCursor()
        cursor.reset(beat: demo, startingAt: 0)
        _ = cursor.consume(at: 0.625)
        cursor.reset()
        XCTAssertNil(cursor.consume(at: 10))
        cursor.reset(beat: demo, startingAt: 8.75) // Resume exactly on a beat: wait, never replay it.
        XCTAssertNil(cursor.consume(at: 8.75))
        XCTAssertEqual(try XCTUnwrap(cursor.nextBeatTime), 9.375, accuracy: 1e-10)
        cursor.reset(beat: demo, startingAt: 0) // Rewind.
        XCTAssertEqual(try XCTUnwrap(cursor.consume(at: 0.625)), 0.625, accuracy: 1e-10)
        cursor.reset(beat: BeatEstimate(bpm: 100, referenceBeat: 0.1, confidence: 1), startingAt: 0)
        XCTAssertEqual(try XCTUnwrap(cursor.nextBeatTime), 0.1, accuracy: 1e-10)
    }

    func testChallengeGridUsesExactExistingTargetStride() throws {
        for (bpm, assisted) in [(96.0, true), (160.0, true), (96.0, false), (160.0, false)] {
            let stride = RhythmGame.targetBeatStride(forBPM: bpm, assisted: assisted)
            let target = BeatEstimate(bpm: bpm / Double(stride), referenceBeat: 0.13, confidence: 1)
            var cursor = BeatPulseCursor()
            cursor.reset(beat: target, startingAt: 0.14)
            let next = try XCTUnwrap(cursor.nextBeatTime)
            XCTAssertEqual(next, 0.13 + 60 / bpm * Double(stride), accuracy: 1e-10)
            XCTAssertEqual(try XCTUnwrap(cursor.consume(at: next)), next, accuracy: 1e-10)
        }
    }

    func testUntrustedInvalidAndOutOfOrderInputsNeverInventCue() throws {
        var cursor = BeatPulseCursor()
        for beat in [BeatEstimate(bpm: 96, referenceBeat: 0, confidence: 0.2),
                     BeatEstimate(bpm: .nan, referenceBeat: 0, confidence: 1),
                     BeatEstimate(bpm: 96, referenceBeat: .infinity, confidence: 1),
                     BeatEstimate(bpm: 1e100, referenceBeat: 0, confidence: 1)] {
            cursor.reset(beat: beat, startingAt: 0)
            XCTAssertNil(cursor.nextBeatTime)
            XCTAssertNil(cursor.consume(at: 1))
        }
        cursor.reset(beat: demo, startingAt: 1)
        XCTAssertNil(cursor.consume(at: .nan))
        XCTAssertNil(cursor.consume(at: 0.625))
        XCTAssertEqual(try XCTUnwrap(cursor.consume(at: 1.25)), 1.25, accuracy: 1e-10)
    }
}
