import XCTest
@testable import AirGuitarCore

final class RecordedAccentTests: XCTestCase {
    func testRecordsIrregularAttacksInFileTimeWithoutAClock() {
        let attacks = [32, 107, 163, 269, 311, 428]
        var tracker = RhythmBeatTracker()
        for frame in 0..<500 {
            let duringAttack = attacks.contains { (0..<6).contains(frame - $0) }
            tracker.appendEnergy(duringAttack ? 0.16 : 0.018, at: 48 + Double(frame) * 0.01)
        }
        let observed = tracker.recordedAccents()
        XCTAssertEqual(observed.count, attacks.count)
        for (time, frame) in zip(observed, attacks) {
            XCTAssertEqual(time, 48 + Double(frame) * 0.01, accuracy: 0.011)
        }
    }

    func testSilenceSustainedSoundAndIsolatedSpikesProvideNoCue() {
        for floor in [0.0, 0.09] {
            var tracker = RhythmBeatTracker()
            for i in 0..<600 {
                tracker.appendEnergy(i.isMultiple(of: 59) ? 0.45 : floor, at: Double(i) * 0.01)
            }
            XCTAssertTrue(tracker.recordedAccents().isEmpty)
        }
    }

    func testSearchReturnsOnlyAnObservedLaterAttackWithinTheRequestedWindow() {
        let guide = FileRhythmGuide(startTime: 10, endTime: 12, beat: nil,
                                    accents: [11.25, 10.8, 10.23, 12.2, .nan])
        XCTAssertEqual(guide.accentOffsets(after: 10.1, within: 0.1), [])
        XCTAssertEqual(guide.accentOffsets(after: 10.1, within: 0.8), [10.23 - 10.1, 10.8 - 10.1])
        XCTAssertEqual(guide.accentOffsets(after: 10.23, within: 0.8), [10.8 - 10.23])
        XCTAssertEqual(guide.accentOffsets(after: 11.4, within: 1.2), [])
        XCTAssertEqual(guide.accentOffsets(after: 9, within: 2), [])
        XCTAssertEqual(guide.accentOffsets(after: .nan, within: 1), [])
    }

    func testSustainedLowBassCyclesAreNotRepeatedGuitarCues() {
        var tracker = RhythmBeatTracker()
        let rate = 16_000.0
        let pcm: [Float] = (0..<48_000).map { frame in
            Float(0.2 * sin(2 * Double.pi * 41.2 * Double(frame) / rate))
        }
        tracker.appendPCM(pcm, sampleRate: rate, startingAt: 8)
        XCTAssertTrue(tracker.recordedAccents().isEmpty)
    }
}
