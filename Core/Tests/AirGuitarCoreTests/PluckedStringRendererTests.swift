import XCTest
@testable import AirGuitarCore

final class PluckedStringRendererTests: XCTestCase {
    func testAllChordsAreAudibleFiniteAndBoundedAtSupportedRates() {
        for chord in Chord.allCases {
            for rate in [8_000, 44_100, 96_000] {
                let waveform = PluckedStringRenderer.render(chord: chord, sampleRate: rate, duration: 0.3)
                XCTAssertEqual(waveform.count, Int(Double(rate) * 0.3))
                XCTAssertTrue(waveform.allSatisfy { $0.isFinite && abs($0) <= 0.700_01 })
                XCTAssertTrue(waveform.contains { abs($0) > 0.05 })
            }
        }
    }

    func testRenderingIsDeterministic() {
        let first = PluckedStringRenderer.render(chord: .c, sampleRate: 16_000, duration: 0.4)
        let second = PluckedStringRenderer.render(chord: .c, sampleRate: 16_000, duration: 0.4)
        XCTAssertEqual(first, second)
    }

    func testManualVoicingsRemainSampleIdenticalAfterSingleStringExtraction() {
        // Recorded from the original public renderer before extracting notes:.
        let expected: [Chord: UInt64] = [.c: 7_920_538_771_624_046_292,
                                         .aMinor: 3_643_292_146_219_449_976,
                                         .f: 4_117_292_520_510_953_276,
                                         .g: 1_332_641_420_153_682_740]
        for chord in Chord.manualVoicings {
            var fingerprint: UInt64 = 14_695_981_039_346_656_037
            for sample in PluckedStringRenderer.render(chord: chord, sampleRate: 16_000, duration: 0.3) {
                fingerprint = (fingerprint ^ UInt64(sample.bitPattern)) &* 1_099_511_628_211
            }
            XCTAssertEqual(fingerprint, expected[chord])
        }
    }

    func testInvalidInputIsRejected() {
        for rate in [-1, 0, 7_999, 96_001, Int.max] {
            XCTAssertTrue(PluckedStringRenderer.render(chord: .g, sampleRate: rate).isEmpty)
        }
        for duration in [-1.0, 0, 0.000_001, .nan, .infinity, 10.1] {
            XCTAssertTrue(PluckedStringRenderer.render(chord: .g, duration: duration).isEmpty)
        }
    }

    func testEveryChordProducesADistinctAudibleWaveform() {
        let waves = Chord.allCases.map {
            PluckedStringRenderer.render(chord: $0, sampleRate: 16_000, duration: 0.4)
        }
        for lhs in waves.indices {
            for rhs in waves.indices where rhs > lhs {
                let difference = zip(waves[lhs], waves[rhs]).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) }
                XCTAssertGreaterThan(difference / Double(waves[lhs].count), 0.01)
            }
        }
    }

    func testPlucksStartAndFinishAtZeroWithAttenuatedTail() {
        for chord in Chord.allCases {
            let waveform = PluckedStringRenderer.render(chord: chord, sampleRate: 16_000, duration: 0.5)
            XCTAssertEqual(waveform.first, 0)
            XCTAssertEqual(waveform.last, 0)
            let early = waveform[800..<2400].reduce(0.0) { $0 + Double($1 * $1) } / 1600
            let tail = waveform.suffix(320).reduce(0.0) { $0 + Double($1 * $1) } / 320
            XCTAssertLessThan(tail, early * 0.1)
        }
    }
}
