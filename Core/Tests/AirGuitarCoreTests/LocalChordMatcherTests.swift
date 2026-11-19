import AirGuitarCore
import XCTest

final class LocalChordMatcherTests: XCTestCase {
    private func chord(_ midi: [Int]) -> [Float] {
        (0..<2000).map { i in
            let time = Double(i) / 5500
            let signal = midi.reduce(0.0) { partial, note in
                let phase = time * 2 * Double.pi * 440 * pow(2, Double(note - 69) / 12)
                return partial + sin(phase) + 0.18 * sin(2 * phase)
            }
            return Float(signal / Double(midi.count) * 0.3)
        }
    }

    func testAllTwelveMajorAndMinorRootsIncludingInversions() throws {
        for root in 0..<12 {
            for third in [3, 4] {
                let expected = try XCTUnwrap(Chord(pitchClass: root, isMinor: third == 3))
                let bass = 48 + root
                for notes in [[bass, bass + third, bass + 7],
                              [bass + third, bass + 7, bass + 12],
                              [bass + 7, bass + 12, bass + third + 12]] {
                    XCTAssertEqual(LocalChordMatcher.match(mono: chord(notes), sampleRate: 5500), expected,
                                   "\(expected.name), inversion \(notes)")
                }
            }
        }
    }

    func testUncertainAndNonTriadicHarmonyReturnsNoChord() {
        for notes in [[48], [48, 55], [48, 51, 52, 55], [48, 52, 56], [48, 51, 54],
                      [48, 49, 52, 53, 55, 56]] {
            XCTAssertNil(LocalChordMatcher.match(mono: chord(notes), sampleRate: 5500), "\(notes)")
        }
        XCTAssertNil(LocalChordMatcher.match(mono: [Float](repeating: 0, count: 2000), sampleRate: 5500))
    }

    func testInvalidAndQuietAudioDoesNotGuess() {
        for samples in [[Float](repeating: 0.00001, count: 2000),
                        [Float](repeating: .nan, count: 2000),
                        [Float](repeating: .infinity, count: 2000),
                        [Float](repeating: 0.2, count: 100),
                        [Float](repeating: 0.2, count: 8193)] {
            XCTAssertNil(LocalChordMatcher.match(mono: samples, sampleRate: 5500))
        }
        for rate in [0.0, 2999, 12001, .nan, .infinity] {
            XCTAssertNil(LocalChordMatcher.match(mono: chord([48, 52, 55]), sampleRate: rate))
        }
    }

    func testBassFifthHarmonicDoesNotInventMajorThird() {
        let root = 440 * pow(2, Double(50 - 69) / 12) // D3
        let fifth = 440 * pow(2, Double(57 - 69) / 12)
        let minorThird = 440 * pow(2, Double(65 - 69) / 12)
        let samples: [Float] = (0..<2000).map { index in
            let time = Double(index) / 5500
            let phase = 2 * Double.pi * time
            return Float(0.15 * sin(phase * root) + 0.12 * sin(phase * fifth)
                         + 0.015 * sin(phase * minorThird) + 0.3 * sin(phase * root * 5))
        }
        XCTAssertNil(LocalChordMatcher.match(mono: samples, sampleRate: 5500))
    }

    func testSynthesizedGuitarWindowsNeverMislabelMajorAndMinor() {
        let clearlyPitched: Set<Chord> = [.e, .eMinor, .fSharp, .fSharpMinor, .a, .aSharpMinor, .bMinor]
        for chord in Chord.allCases {
            let samples = PluckedStringRenderer.render(chord: chord, duration: 0.5)
            // The same averaging/downsample/window shape as LocalHarmonyReader.
            var mono: [Float] = []
            for index in stride(from: Int(44100 * 0.055), to: Int(44100 * 0.445) - 7, by: 8) {
                mono.append(samples[index..<(index + 8)].reduce(0, +) / 8)
            }
            let found = LocalChordMatcher.match(mono: mono, sampleRate: 44100.0 / 8)
            XCTAssertTrue(found == nil || found == chord, "\(chord.name) misidentified as \(found?.name ?? "nil")")
            if clearlyPitched.contains(chord) { XCTAssertEqual(found, chord) }
        }
    }

    func testLowBassCanGuideASingleNoteWithoutInventingATriad() {
        for midi in [28, 31, 33, 35] {
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            let samples = (0..<2160).map { index -> Float in
                let phase = 2 * Double.pi * frequency * Double(index) / 5500
                return Float(0.20 * sin(phase) + 0.08 * sin(2 * phase))
            }
            let estimate = LocalChordMatcher.analyze(mono: samples, sampleRate: 5500)
            XCTAssertNil(estimate.chord)
            XCTAssertEqual(estimate.bass, midi % 12)
        }
        let silence = LocalChordMatcher.analyze(mono: Array(repeating: 0, count: 2160), sampleRate: 5500)
        XCTAssertNil(silence.bass)
    }

    func testChordVocabularyAndOriginalManualContract() throws {
        XCTAssertEqual(Chord.allCases.count, 24)
        XCTAssertEqual(Set(Chord.allCases.map(\.name)).count, 24)
        XCTAssertEqual(Chord.manualVoicings, [.c, .aMinor, .f, .g])
        XCTAssertEqual(try JSONDecoder().decode(Chord.self, from: Data("\"aMinor\"".utf8)), .aMinor)
        XCTAssertEqual(try JSONDecoder().decode(Chord.self, from: Data("\"c\"".utf8)), .c)
        for chord in Chord.allCases {
            let root = chord.rootPitchClass
            let pitchClasses = Set(chord.midiNotes.map { $0 % 12 })
            XCTAssertEqual(pitchClasses, Set([root, (root + (chord.isMinor ? 3 : 4)) % 12, (root + 7) % 12]))
            XCTAssertTrue(pitchClasses.contains(chord.replyMIDINote % 12))
            XCTAssertEqual(Chord(pitchClass: root, isMinor: chord.isMinor), chord)
            XCTAssertEqual(try JSONDecoder().decode(Chord.self, from: JSONEncoder().encode(chord)), chord)
        }
        XCTAssertNil(Chord(pitchClass: -1, isMinor: false))
        XCTAssertNil(Chord(pitchClass: 12, isMinor: true))
    }
}
