import Foundation
import XCTest
@testable import AirGuitarCore

final class RhythmGameplayTests: XCTestCase {
    private func syntheticTempo(_ bpm: Double, start: Double = 0,
                                duration: Double = 12) -> RhythmBeatTracker {
        var tracker = RhythmBeatTracker()
        let period = 60 / bpm
        for index in 0...Int(duration / 0.01) {
            let time = Double(index) * 0.01
            let nearest = ((time - 0.15) / period).rounded()
            let distance = time - 0.15 - nearest * period
            let pulse = exp(-pow(distance / 0.025, 2)) * 0.6
            tracker.appendEnergy(0.002 + pulse, at: start + time)
        }
        return tracker
    }

    private func phaseDistance(_ time: Double, reference: Double, period: Double) -> Double {
        let cycles = ((time - reference) / period).rounded()
        return abs(time - reference - cycles * period)
    }

    func testTwoTemposAndMonotonicReference() throws {
        for bpm in [80.0, 140.0] {
            let tracker = syntheticTempo(bpm, start: 123_456)
            let result = try XCTUnwrap(tracker.estimate(), "Expected periodic evidence at \(bpm) BPM")
            XCTAssertEqual(result.bpm, bpm, accuracy: 2)
            XCTAssertEqual(result.period, 60 / bpm, accuracy: 0.015)
            XCTAssertLessThan(phaseDistance(result.referenceBeat, reference: 123_456.15,
                                            period: 60 / bpm), 0.05)
            XCTAssertGreaterThanOrEqual(result.confidence, RhythmGame.minimumConfidence)
        }
    }

    func testSilenceSteadyEnergyAndInsufficientEvidenceDoNotInventTempo() {
        for energy in [0.0, 0.0001, 0.2] {
            var tracker = RhythmBeatTracker()
            for index in 0..<1200 { tracker.appendEnergy(energy, at: Double(index) * 0.01) }
            XCTAssertNil(tracker.estimate())
        }
        XCTAssertNil(syntheticTempo(96, duration: 2).estimate())
    }

    func testUnstructuredNoiseDoesNotLock() {
        var tracker = RhythmBeatTracker()
        var seed: UInt64 = 17
        for index in 0..<1200 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let energy = 0.01 + Double(seed >> 40) / Double(1 << 24) * 0.15
            tracker.appendEnergy(energy, at: Double(index) * 0.01)
        }
        XCTAssertNil(tracker.estimate())
    }

    func testEnergyHistoryBoundAndReset() {
        var tracker = RhythmBeatTracker(windowDuration: 20)
        for index in 0..<10_000 { tracker.appendEnergy(Double(index % 60 == 0 ? 1 : 0), at: Double(index) * 0.01) }
        XCTAssertLessThanOrEqual(tracker.bufferedFrameCount, 2048)
        XCTAssertLessThanOrEqual(tracker.observedDuration, 20.001)
        let count = tracker.bufferedFrameCount
        tracker.appendEnergy(.nan, at: 101)
        tracker.appendEnergy(1, at: 1)
        XCTAssertEqual(tracker.bufferedFrameCount, count)
        tracker.reset()
        XCTAssertEqual(tracker.bufferedFrameCount, 0)
        XCTAssertNil(tracker.estimate())
    }

    func testActual96BPMPracticePCMInChunks() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/Demo-C-Am-F-G-96bpm.wav")
        let data = try Data(contentsOf: fixture)
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func dword(_ offset: Int) -> Int { word(offset) | word(offset + 2) << 16 }
        XCTAssertEqual(String(bytes: bytes[0..<4], encoding: .ascii), "RIFF")
        var offset = 12, sampleRate = 0, pcm: [Float] = []
        while offset + 8 <= bytes.count {
            let kind = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
            let size = dword(offset + 4), content = offset + 8
            guard content + size <= bytes.count else { break }
            if kind == "fmt " {
                XCTAssertEqual(word(content), 1)
                XCTAssertEqual(word(content + 2), 1)
                sampleRate = dword(content + 4)
                XCTAssertEqual(word(content + 14), 16)
            }
            if kind == "data" {
                pcm = stride(from: content, to: content + size - 1, by: 2).map {
                    Float(Int16(bitPattern: UInt16(word($0)))) / 32768
                }
            }
            offset = content + size + (size % 2)
        }
        XCTAssertGreaterThan(sampleRate, 0)
        for duration in [8, 10, 20] {
            var tracker = RhythmBeatTracker()
            let limit = min(pcm.count, duration * sampleRate)
            for start in stride(from: 0, to: limit, by: 8192) {
                let chunk = Array(pcm[start..<min(limit, start + 8192)])
                tracker.appendPCM(chunk, sampleRate: Double(sampleRate), startingAt: Double(start) / Double(sampleRate))
            }
            let estimate = try XCTUnwrap(tracker.estimate(), "\(duration)-second fixture")
            XCTAssertEqual(estimate.bpm, 96, accuracy: 2)
            XCTAssertLessThan(phaseDistance(estimate.referenceBeat, reference: 0, period: 60 / 96), 0.07)
            XCTAssertGreaterThanOrEqual(estimate.confidence, RhythmGame.minimumConfidence)
            XCTAssertLessThanOrEqual(tracker.bufferedFrameCount, 2048)
        }
    }

    func testPCMChunkingPreservesClockAndPartialFrames() throws {
        let rate = 8_000.0
        let samples: [Float] = (0..<96_000).map { index in
            let time = Double(index) / rate
            let phase = (time - 0.15).truncatingRemainder(dividingBy: 0.625)
            let envelope = phase >= 0 && phase < 0.08 ? exp(-phase * 35) : 0
            return Float(sin(2 * .pi * 200 * time) * envelope * 0.7)
        }
        var whole = RhythmBeatTracker(), chunked = RhythmBeatTracker()
        whole.appendPCM(samples, sampleRate: rate, startingAt: 500)
        for start in stride(from: 0, to: samples.count, by: 777) {
            chunked.appendPCM(Array(samples[start..<min(samples.count, start + 777)]),
                              sampleRate: rate, startingAt: 500 + Double(start) / rate)
        }
        let a = try XCTUnwrap(whole.estimate()), b = try XCTUnwrap(chunked.estimate())
        XCTAssertEqual(a.bpm, b.bpm, accuracy: 0.001)
        XCTAssertEqual(a.referenceBeat, b.referenceBeat, accuracy: 0.001)
        XCTAssertEqual(a.bpm, 96, accuracy: 2)
    }

    func testJudgementGradesScoreAndCombo() {
        var game = RhythmGame(beat: BeatEstimate(bpm: 96, referenceBeat: 10, confidence: 1))
        XCTAssertEqual(game.strum(at: 10)?.grade, .perfect)
        XCTAssertEqual(game.strum(at: 10.625 + 0.08)?.grade, .good)
        XCTAssertEqual(game.strum(at: 11.25 - 0.14)?.grade, .early)
        XCTAssertEqual(game.strum(at: 11.875 + 0.14)?.grade, .late)
        XCTAssertEqual(game.score, 230)
        XCTAssertEqual(game.combo, 4)
        XCTAssertEqual(game.bestCombo, 4)
        let missed = game.advance(to: 12.5 + 0.181)
        XCTAssertEqual(missed.map(\.grade), [.miss])
        XCTAssertEqual(game.combo, 0)
        XCTAssertEqual(game.score, 230)
    }

    func testSameBeatOnlyJudgedOnceIncludingAfterPause() {
        var game = RhythmGame(beat: BeatEstimate(bpm: 96, referenceBeat: 1000, confidence: 1))
        XCTAssertEqual(game.strum(at: 1000)?.grade, .perfect)
        XCTAssertNil(game.strum(at: 1000.01))
        XCTAssertTrue(game.advance(to: 1000.2).isEmpty)
        game.setPaused(true); game.setPaused(false)
        XCTAssertNil(game.strum(at: 1000.03))
        XCTAssertEqual(game.score, 100)
        XCTAssertEqual(game.strum(at: 1000.625)?.grade, .perfect)
        XCTAssertEqual(game.combo, 2)
    }

    func testFirstLateEntryAndUptimeDoNotBackfill() {
        let beat = BeatEstimate(bpm: 96, referenceBeat: 0, confidence: 1)
        var game = RhythmGame(beat: beat)
        XCTAssertTrue(game.advance(to: 1_000_000.3).isEmpty)
        XCTAssertEqual(game.score, 0)
        XCTAssertNil(game.lastJudgement)
        var firstHit = RhythmGame(beat: beat)
        XCTAssertEqual(firstHit.strum(at: 1_000_000)?.grade, .perfect)
        XCTAssertEqual(firstHit.combo, 1)
    }

    func testPauseSilenceAndUnlockedBeatDoNotDeduct() {
        var unlocked = RhythmGame(beat: nil)
        XCTAssertTrue(unlocked.advance(to: 900).isEmpty)
        XCTAssertNil(unlocked.strum(at: 900))
        var uncertain = RhythmGame(beat: BeatEstimate(bpm: 96, referenceBeat: 0, confidence: 0.1))
        XCTAssertNil(uncertain.progress(at: 0))
        XCTAssertNil(uncertain.strum(at: 0))
        var game = RhythmGame(beat: BeatEstimate(bpm: 96, referenceBeat: 0, confidence: 1))
        _ = game.strum(at: 0)
        game.setPaused(true)
        XCTAssertTrue(game.advance(to: 100).isEmpty)
        game.setPaused(false)
        XCTAssertTrue(game.advance(to: 100).isEmpty)
        XCTAssertTrue(game.advance(to: 1000, isAudible: false).isEmpty)
        XCTAssertTrue(game.advance(to: 2000, isAudible: true).isEmpty)
        XCTAssertEqual(game.score, 100)
        XCTAssertEqual(game.combo, 1)
    }

    func testProgressResetAndInvalidTimes() throws {
        let beat = BeatEstimate(bpm: 96, referenceBeat: 1000, confidence: 1)
        var game = RhythmGame(beat: beat)
        let progress = try XCTUnwrap(game.progress(at: 1000.15625))
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(progress.previousBeat, 1000)
        XCTAssertEqual(progress.nextBeat, 1000.625)
        XCTAssertNil(game.strum(at: .nan))
        XCTAssertTrue(game.advance(to: .infinity).isEmpty)
        _ = game.strum(at: 1000)
        game.reset(beat: beat)
        XCTAssertEqual(game.score, 0)
        XCTAssertEqual(game.combo, 0)
        XCTAssertNil(game.lastJudgement)
        XCTAssertEqual(game.strum(at: 1000)?.grade, .perfect)
    }

    func testMissCatchupIsBoundedAndStrumAdvancesDeadlines() {
        let beat = BeatEstimate(bpm: 96, referenceBeat: 0, confidence: 1)
        var game = RhythmGame(beat: beat)
        _ = game.strum(at: 0)
        XCTAssertEqual(game.strum(at: 1.25)?.grade, .perfect)
        XCTAssertEqual(game.combo, 1, "The skipped 0.625s target resets the combo")
        XCTAssertLessThanOrEqual(game.advance(to: 1_000_000).count, 64)
    }

    func testExternalModeDoesNotLoseComboDuringUnobservedSilence() {
        let beat = BeatEstimate(bpm: 96, referenceBeat: 1000, confidence: 1)
        var game = RhythmGame(beat: beat, tracksMisses: false)
        XCTAssertEqual(game.strum(at: 1000)?.grade, .perfect)
        XCTAssertNil(game.strum(at: 1000.01), "Same-beat double strum still must not score")
        // The external phone might have stopped while no microphone is active.
        // Advancing its inferred grid must not turn these empty targets into misses.
        for tick in 1...150 {
            XCTAssertTrue(game.advance(to: 1000 + Double(tick) / 30).isEmpty)
        }
        XCTAssertEqual(game.score, 100)
        XCTAssertEqual(game.combo, 1)
        XCTAssertEqual(game.lastJudgement?.grade, .perfect)
        XCTAssertEqual(game.strum(at: 1005)?.grade, .perfect)
        XCTAssertEqual(game.combo, 2)
        XCTAssertEqual(game.score, 200)
        XCTAssertNil(game.strum(at: 1005.02))
        game.reset(beat: beat, tracksMisses: false)
        XCTAssertFalse(game.tracksMisses)
        XCTAssertEqual(game.score, 0)
        _ = game.strum(at: 1000)
        XCTAssertTrue(game.advance(to: 1010).isEmpty)
        XCTAssertEqual(game.combo, 1)
    }

    func testAssistedStrideWindowsAndUniformPositivePoints() throws {
        XCTAssertEqual(RhythmGame.targetBeatStride(forBPM: 96, assisted: true), 2)
        XCTAssertEqual(RhythmGame.targetBeatStride(forBPM: 134.9, assisted: true), 2)
        XCTAssertEqual(RhythmGame.targetBeatStride(forBPM: 135, assisted: true), 4)
        XCTAssertEqual(RhythmGame.targetBeatStride(forBPM: 96, assisted: false), 1)
        XCTAssertEqual(RhythmGame.targetBeatStride(forBPM: 135, assisted: false), 2)
        let beat = BeatEstimate(bpm: 48, referenceBeat: 10, confidence: 1)
        var game = RhythmGame(beat: beat, assisted: true)
        XCTAssertFalse(game.tracksMisses)
        XCTAssertEqual(try XCTUnwrap(game.timingWindows).tolerance, 0.3, accuracy: 0.0001)
        XCTAssertEqual(game.strum(at: 9.71)?.points, 100)
        XCTAssertEqual(game.strum(at: 11.54)?.points, 100)
        XCTAssertEqual(game.combo, 2)
        XCTAssertEqual(game.score, 200)
        XCTAssertTrue(game.advance(to: 30).isEmpty)
        XCTAssertEqual(game.combo, 2)
        XCTAssertNil(game.strum(at: 30.5))
        XCTAssertEqual(game.combo, 2)
    }

    func testAssistedJudgesOriginalGestureTimeAfterDisplayTickPassed() {
        var game = RhythmGame(beat: BeatEstimate(bpm: 48, referenceBeat: 1000, confidence: 1), assisted: true)
        _ = game.advance(to: 1000.8)
        _ = game.advance(to: 1001.7)
        // This event was collected at 1001.30 but delivered after the UI tick.
        let result = game.strum(at: 1001.30)
        XCTAssertEqual(result?.targetTime, 1001.25)
        XCTAssertEqual(result?.grade, .perfect)
        XCTAssertEqual(result?.points, 100)
        XCTAssertNil(game.strum(at: 1001.31))
    }

    func testAssistedDeduplicatesRetiredHistoryAndResetPreservesConfiguration() {
        let beat = BeatEstimate(bpm: 48, referenceBeat: 10, confidence: 1)
        var game = RhythmGame(beat: beat, assisted: true)
        for index in 0..<300 { XCTAssertNotNil(game.strum(at: 10 + Double(index) * 1.25)) }
        XCTAssertEqual(game.combo, 300)
        XCTAssertEqual(game.score, 30_000)
        game.setPaused(true); game.setPaused(false)
        XCTAssertNil(game.strum(at: 10), "Retiring old set entries must not let an old beat score twice")
        game.reset(beat: beat, tracksMisses: true, assisted: true)
        XCTAssertTrue(game.assisted)
        XCTAssertFalse(game.tracksMisses)
        XCTAssertEqual(game.score, 0)
        XCTAssertEqual(game.strum(at: 10)?.points, 100)
    }
}
