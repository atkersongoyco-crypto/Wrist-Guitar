import Foundation
import XCTest
@testable import AirGuitarCore

final class AssistedPerformanceTests: XCTestCase {
    func testListeningGestureChangesArticulationWhileKeepingTheImmediateFirstAttack() {
        var player = AssistedPerformance()
        let accents = [0.38, 0.92]
        let soft = player.listeningPhrase(at: 62, velocity: 0.50, source: .detected(.c),
                                          accentOffsets: accents)
        let firm = player.listeningPhrase(at: 64, velocity: 0.84, source: .detected(.c),
                                          accentOffsets: accents)
        XCTAssertTrue(soft.isArpeggio)
        XCTAssertEqual(soft.hits.map(\.offset), [0, 0.38, 0.92])
        XCTAssertEqual(soft.hits.map(\.voice), [.picked(60), .picked(64), .picked(67)])
        XCTAssertFalse(firm.isArpeggio)
        XCTAssertEqual(firm.hits.map(\.offset), [0, 0.92])
        XCTAssertEqual(firm.hits.first?.voice, .strum(.c))
        XCTAssertLessThan(soft.hits[2].gain, soft.hits[1].gain)
        XCTAssertLessThan(soft.hits[1].gain, soft.hits[0].gain)
        XCTAssertLessThan(soft.hits[0].gain, firm.hits[0].gain)
        XCTAssertFalse(soft.secondaryIsBeatAligned)
    }

    func testListeningNotesRespectLaterHarmonyAndUncertainHarmonyLeavesRest() {
        var player = AssistedPerformance()
        let changed = player.listeningPhrase(at: 12, velocity: 0.48, source: .detected(.c),
                                             accentOffsets: [0.32, 0.77]) { offset in
            offset < 0.5 ? .aMinor : .f
        }
        XCTAssertEqual(changed.hits.map(\.voice), [.picked(60), .picked(64), .picked(65)])
        let uncertain = player.listeningPhrase(at: 14, velocity: 0.48, source: .detected(.c),
                                               accentOffsets: [0.32, 0.77]) { offset in
            offset < 0.5 ? nil : .fSharpMinor
        }
        XCTAssertEqual(uncertain.hits.map(\.voice), [.picked(60), .picked(61)])
        XCTAssertEqual(uncertain.hits.map(\.offset), [0, 0.77])
        let firm = player.listeningPhrase(at: 15, velocity: 0.86, source: .detected(.d),
                                          accentOffsets: [0.35, 0.65]) { $0 < 0.5 ? .d : nil }
        XCTAssertEqual(firm.hits.map(\.offset), [0, 0.35])
        let muted = player.listeningPhrase(at: 16, velocity: 0.48, source: .unpitched,
                                           accentOffsets: [0.32, 0.77])
        XCTAssertEqual(muted.hits.map(\.voice), [.mutedStrum])
    }

    func testListeningRespondsToTrustedSubdivisionsOrOneRubatoClosingString() {
        let beat = BeatEstimate(bpm: 100, referenceBeat: 10, confidence: 0.9)
        var player = AssistedPerformance()
        let soft = player.listeningPhrase(at: 10, velocity: 0.48, source: .detected(.g), beat: beat)
        XCTAssertTrue(soft.secondaryIsBeatAligned)
        XCTAssertEqual(soft.hits[1].offset, 0.30, accuracy: 0.00001)
        XCTAssertEqual(soft.hits[2].offset, 0.60, accuracy: 0.00001)
        let offBeat = player.listeningPhrase(at: 10.3, velocity: 0.75, source: .detected(.g), beat: beat)
        XCTAssertEqual(offBeat.hits.first?.voice, .upstroke(.g))
        player.reset()
        let initial = player.listeningPhrase(at: 10, velocity: 0.52, source: .detected(.g))
        let rubato = player.listeningPhrase(at: 11.32, velocity: 0.52, source: .detected(.g),
                                            beat: BeatEstimate(bpm: 96, referenceBeat: 10, confidence: 0.02))
        XCTAssertEqual(initial.hits.count, 2)
        XCTAssertFalse(rubato.secondaryIsBeatAligned)
        XCTAssertEqual(rubato.hits.count, 2)
        XCTAssertEqual(rubato.hits[1].offset, 0.66, accuracy: 0.00001)
        XCTAssertNotEqual(initial.hits[1].offset, rubato.hits[1].offset)
    }

    func testListeningFiltersBunchedAccentsAndNeverAddsUnboundedNotes() {
        var player = AssistedPerformance()
        let phrase = player.listeningPhrase(at: 1, velocity: 0.52, source: .detected(.d),
                                            accentOffsets: [.nan, -0.2, 0.02, 0.8, 0.4, 0.41, 2, 12, .infinity])
        XCTAssertEqual(phrase.hits.map(\.offset), [0, 0.4, 0.8])
        XCTAssertLessThanOrEqual(phrase.duration, 1.24 + 0.32 + 0.00001)
        XCTAssertTrue(AssistedSoundRenderer.render(voice: .picked(Int.min)).isEmpty)
    }

    func testQuietBackingSoftensTheGuitarAndLoudBackingNeverBoostsIt() {
        let quiet = AssistedPerformance.backingBlend(averagePowerDB: -40)
        let verse = AssistedPerformance.backingBlend(averagePowerDB: -25)
        XCTAssertEqual(quiet, pow(10, -6.0 / 20), accuracy: 0.000_001)
        XCTAssertGreaterThan(verse, quiet)
        XCTAssertLessThan(verse, 1)
        XCTAssertEqual(AssistedPerformance.backingBlend(averagePowerDB: -10), 1)
        XCTAssertEqual(AssistedPerformance.backingBlend(averagePowerDB: .nan), 1)
    }

    func testDisablingReplyKeepsTheImmediateSweepAndChordProgression() {
        var player = AssistedPerformance()
        for index in 0..<5 {
            let phrase = player.phrase(at: Double(index), velocity: 0.15, source: .freePlay,
                                       includeReply: false)
            XCTAssertEqual(phrase.hits.map(\.voice), [.strum(index < 4 ? .c : .aMinor)])
            XCTAssertEqual(phrase.hits.first?.offset, 0)
            XCTAssertFalse(phrase.secondaryIsBeatAligned)
        }
        let muted = player.phrase(at: 6, velocity: 0.2, source: .unpitched, includeReply: false)
        XCTAssertEqual(muted.hits.map(\.voice), [.mutedStrum])
    }

    func testOriginalScoreChangesOnlyAtKnownChordBoundariesAndLoops() {
        let cases: [(Double, Chord)] = [(0, .c), (2.499, .c), (2.5, .aMinor),
                                       (4.999, .aMinor), (5, .f), (7.5, .g),
                                       (9.999, .g), (10, .c), (12.5, .aMinor), (20, .c)]
        for (time, chord) in cases {
            XCTAssertEqual(AssistedPerformance.guidedChord(playbackTime: time), chord)
            var player = AssistedPerformance()
            XCTAssertEqual(player.phrase(at: 1_000, velocity: 0.2,
                                         source: .originalDemo(playbackTime: time)).chord, chord)
        }
        for time in [-1.0, .nan, .infinity] {
            XCTAssertEqual(AssistedPerformance.guidedChord(playbackTime: time), .c)
        }
    }

    func testFreePlayAdvancesEveryFourGesturesAndResets() {
        var player = AssistedPerformance()
        let chords = (0..<20).map { index in
            player.phrase(at: Double(index), velocity: 0.1, source: .freePlay).chord
        }
        XCTAssertEqual(chords, Array(repeating: Chord.c, count: 4)
                       + Array(repeating: .aMinor, count: 4) + Array(repeating: .f, count: 4)
                       + Array(repeating: .g, count: 4) + Array(repeating: .c, count: 4))
        player.reset()
        XCTAssertEqual(player.freePlayStrumCount, 0)
        XCTAssertEqual(player.phrase(at: 30, velocity: 0, source: .freePlay).chord, .c)
    }

    func testUnknownMusicStaysUnpitchedAndDetectedHarmonyIsExplicit() {
        var player = AssistedPerformance()
        let unknown = player.phrase(at: 10, velocity: 1, source: .unpitched,
                                    beat: BeatEstimate(bpm: 96, referenceBeat: 10, confidence: 1))
        XCTAssertNil(unknown.chord)
        XCTAssertEqual(unknown.hits.map(\.voice), [.mutedStrum, .mutedReply])
        for chord in Chord.allCases {
            let known = player.phrase(at: 11, velocity: 0.2, source: .detected(chord))
            XCTAssertEqual(known.chord, chord)
            XCTAssertEqual(known.hits.map(\.voice), [.strum(chord), .reply(chord)])
        }
        // Non-free-play sources cannot silently advance the empty-room score.
        XCTAssertEqual(player.freePlayStrumCount, 0)
    }

    func testGentleGestureIsImmediateAudibleAndAlwaysHasBoundedReply() {
        for source in [AssistedSource.freePlay, .originalDemo(playbackTime: 0.7), .unpitched] {
            var player = AssistedPerformance()
            for index in 0..<80 {
                let phrase = player.phrase(at: 500 + Double(index) * 0.07, velocity: 0, source: source)
                XCTAssertEqual(phrase.hits.count, 2)
                XCTAssertEqual(phrase.hits[0].offset, 0)
                XCTAssertEqual(phrase.hits[0].gain, 0.48, accuracy: 0.000_001)
                XCTAssertLessThan(phrase.hits[1].gain, phrase.hits[0].gain * 0.4)
                XCTAssertTrue((0.15...0.40).contains(phrase.hits[1].offset))
                XCTAssertLessThanOrEqual(phrase.duration, 0.48 + 0.000_001)
            }
        }
        var player = AssistedPerformance()
        let first = player.phrase(at: 2_000, velocity: 0.1, source: .freePlay)
        XCTAssertEqual(first.hits[1].offset, 0.3125, accuracy: 0.000_001)
        XCTAssertTrue(first.secondaryIsBeatAligned)
    }

    func testReplyUsesNextEligibleHalfBeatAndNeverAWholeDelayedPhrase() {
        let beat = BeatEstimate(bpm: 120, referenceBeat: 10, confidence: 0.8)
        var player = AssistedPerformance()
        let near = player.phrase(at: 10.24, velocity: 0.3, source: .detected(.f), beat: beat)
        XCTAssertEqual(near.hits[1].offset, 0.26, accuracy: 0.000_001)
        XCTAssertTrue(near.secondaryIsBeatAligned)
        let usual = player.phrase(at: 10.28, velocity: 0.3, source: .detected(.f), beat: beat)
        XCTAssertEqual(usual.hits[1].offset, 0.22, accuracy: 0.000_001)
        let slow = player.phrase(at: 10.02, velocity: 0.3, source: .unpitched,
                                 beat: BeatEstimate(bpm: 60, referenceBeat: 10, confidence: 0.8))
        XCTAssertEqual(slow.hits[1].offset, 0.4, accuracy: 0.000_001)
        XCTAssertFalse(slow.secondaryIsBeatAligned)
    }

    func testInvalidVelocityAndBeatDoNotProduceUnboundedLevelsOrTiming() {
        for velocity in [-1.0, 100, .nan, .infinity] {
            var player = AssistedPerformance()
            let phrase = player.phrase(at: .nan, velocity: velocity, source: .freePlay,
                                       beat: BeatEstimate(bpm: .nan, referenceBeat: .infinity, confidence: 1))
            XCTAssertEqual(phrase.timestamp, 0)
            XCTAssertTrue(phrase.hits.allSatisfy { $0.gain.isFinite && (0...1).contains($0.gain) })
            XCTAssertEqual(phrase.hits[1].offset, 0.3125, accuracy: 0.000_001)
        }
    }

    func testBankIsDeterministicAudibleShortAndFinite() {
        XCTAssertEqual(AssistedVoice.allVoices.count, 90)
        for voice in AssistedVoice.allVoices {
            let samples = AssistedSoundRenderer.render(voice: voice, sampleRate: 16_000)
            XCTAssertEqual(samples.count, Int(16_000 * voice.duration))
            XCTAssertEqual(samples, AssistedSoundRenderer.render(voice: voice, sampleRate: 16_000))
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 0.700_01 })
            XCTAssertTrue(samples.contains { abs($0) > 0.1 })
            XCTAssertEqual(samples.first, 0)
            XCTAssertEqual(samples.last, 0)
        }
        let muted = AssistedSoundRenderer.render(voice: .mutedStrum, sampleRate: 16_000)
        let pitched = AssistedSoundRenderer.render(voice: .strum(.c), sampleRate: 16_000)
        XCTAssertNotEqual(Array(muted.prefix(1_000)), Array(pitched.prefix(1_000)))
    }

    func testPitchedReplyIsOneHighAnsweringStringRatherThanAnotherSweep() {
        let targets: [(Chord, Double)] = [(.c, 391.995), (.aMinor, 440), (.f, 349.228), (.g, 391.995)]
        for (chord, frequency) in targets {
            let reply = AssistedSoundRenderer.render(voice: .reply(chord), sampleRate: 44_100)
            let repeatedSweep = PluckedStringRenderer.render(chord: chord, sampleRate: 44_100, duration: 0.08)
            XCTAssertEqual(reply.count, 3_528)
            XCTAssertNotEqual(reply, repeatedSweep)
            // Independent waveform-period check across the high-string register.
            // Karplus–Strong's integer delay causes a small tuning approximation.
            let correlations = (80...150).map { lag -> (Int, Double) in
                let count = reply.count - lag - 512
                var meanA = 0.0, meanB = 0.0
                for index in 256..<(256 + count) {
                    meanA += Double(reply[index]); meanB += Double(reply[index + lag])
                }
                meanA /= Double(count); meanB /= Double(count)
                var cross = 0.0, energyA = 0.0, energyB = 0.0
                for index in 256..<(256 + count) {
                    let a = Double(reply[index]) - meanA, b = Double(reply[index + lag]) - meanB
                    cross += a * b; energyA += a * a; energyB += b * b
                }
                return (lag, cross / sqrt(energyA * energyB))
            }
            let best = correlations.max { $0.1 < $1.1 }!
            XCTAssertGreaterThan(best.1, 0.75)
            XCTAssertEqual(44_100 / Double(best.0), frequency, accuracy: frequency * 0.03)
        }
        XCTAssertEqual(AssistedSoundRenderer.render(voice: .reply(.c)),
                       AssistedSoundRenderer.render(voice: .reply(.g)))
        XCTAssertNotEqual(AssistedSoundRenderer.render(voice: .reply(.c)),
                          AssistedSoundRenderer.render(voice: .reply(.aMinor)))
    }

    func testExpandedBankIsBoundedAndNewChordRepliesStayInTheirTriad() {
        XCTAssertEqual(Set(AssistedVoice.allVoices).count, 90)
        var bytes = 0
        for voice in AssistedVoice.allVoices {
            let samples = AssistedSoundRenderer.render(voice: voice, sampleRate: AssistedSoundRenderer.watchSampleRate)
            bytes += samples.count * MemoryLayout<Float>.size
        }
        XCTAssertLessThan(bytes, 1_250_000, "Keep the complete short-voice bank small enough to prewarm.")
        for chord in Chord.allCases where !Chord.manualVoicings.contains(chord) {
            let reply = AssistedSoundRenderer.render(voice: .reply(chord), sampleRate: 44_100)
            XCTAssertTrue(reply.contains { abs($0) > 0.05 })
            XCTAssertTrue(reply.allSatisfy { $0.isFinite && abs($0) <= 0.700_01 })
            let expected = PluckedStringRenderer.render(notes: [chord.replyMIDINote], sampleRate: 44_100, duration: 0.08)
            XCTAssertEqual(reply, expected)
            XCTAssertTrue(Set(chord.midiNotes.map { $0 % 12 }).contains(chord.replyMIDINote % 12))
        }
    }

    func testNewGestureRemovesOldReplyFromOfflinePerformance() {
        var player = AssistedPerformance()
        let first = player.phrase(at: 0, velocity: 0.5, source: .detected(.c))
        let second = player.phrase(at: 0.22, velocity: 0.5, source: .detected(.g))
        let rendered = AssistedSoundRenderer.render(phrases: [first, second], sampleRate: 16_000)
        let head = AssistedSoundRenderer.render(voice: first.hits[0].voice, sampleRate: 16_000)
        let replacement = AssistedSoundRenderer.render(phrase: second, sampleRate: 16_000)
        var expected = [Float](repeating: 0, count: rendered.count)
        for index in 0..<min(3_520, head.count) { expected[index] = head[index] * Float(first.hits[0].gain) }
        for index in replacement.indices { expected[3_520 + index] += replacement[index] }
        XCTAssertEqual(rendered, expected)
    }

    func testVeryFastNewGestureAlsoReplacesTheSingleLeadVoice() {
        var player = AssistedPerformance()
        let first = player.phrase(at: 0, velocity: 1, source: .detected(.c))
        let second = player.phrase(at: 0.1, velocity: 1, source: .detected(.f))
        let mixed = AssistedSoundRenderer.render(phrases: [first, second], sampleRate: 16_000)
        let replacement = AssistedSoundRenderer.render(phrase: second, sampleRate: 16_000)
        XCTAssertEqual(Array(mixed[1_600...]), replacement)
    }

    func testWAVHeaderAndPCMMatchTheSameOfflineRender() throws {
        var player = AssistedPerformance()
        let phrase = player.phrase(at: 777, velocity: 0.1, source: .detected(.aMinor))
        let samples = AssistedSoundRenderer.render(phrase: phrase, sampleRate: 16_000)
        let data = try XCTUnwrap(AssistedSoundRenderer.wavData(phrases: [phrase], sampleRate: 16_000))
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<16], encoding: .ascii), "WAVEfmt ")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(Array(data[22..<24]), [1, 0])
        XCTAssertEqual(Array(data[34..<36]), [16, 0])
        for index in stride(from: 0, to: samples.count, by: 137) {
            let offset = 44 + index * 2
            let word = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
            let decoded = Double(Int16(bitPattern: word)) / Double(Int16.max)
            XCTAssertEqual(decoded, Double(samples[index]), accuracy: 1 / Double(Int16.max))
        }
    }

    func testExportsRejectInvalidRatesEmptyAndUnboundedTimeline() {
        var player = AssistedPerformance()
        let first = player.phrase(at: 0, velocity: 1, source: .freePlay)
        let distant = player.phrase(at: 61, velocity: 1, source: .freePlay)
        XCTAssertTrue(AssistedSoundRenderer.render(phrases: [first, distant]).isEmpty)
        XCTAssertNil(AssistedSoundRenderer.wavData(phrases: []))
        for rate in [0, 7_999, 96_001, Int.max] {
            XCTAssertTrue(AssistedSoundRenderer.render(voice: .mutedStrum, sampleRate: rate).isEmpty)
            XCTAssertNil(AssistedSoundRenderer.wavData(phrases: [first], sampleRate: rate))
        }
    }
}
