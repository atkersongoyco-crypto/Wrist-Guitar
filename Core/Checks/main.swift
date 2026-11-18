// Run with `swift run AirGuitarCoreChecks` on Macs with Command Line Tools only.
import Foundation
import AirGuitarCore

private struct CheckFailed: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailed(description: message) }
}

private func sample(_ time: Double, roll: Double = 0,
                    acceleration: Double = 0, rotation: Double = 0) -> MotionSample {
    MotionSample(timestamp: time, roll: roll,
                 accelerationX: acceleration, accelerationY: 0, accelerationZ: 0,
                 rotationX: rotation, rotationY: 0, rotationZ: 0)
}

private let checks: [(String, () throws -> Void)] = [
    ("idle noise and single-channel motion rejection", {
        var engine = MotionInterpreter()
        for tick in 0..<500 {
            try require(engine.consume(sample(Double(tick) / 50,
                                               acceleration: 0.03, rotation: 0.06)) == nil, "idle triggered")
        }
        try require(engine.consume(sample(11, acceleration: 3, rotation: 0.01)) == nil, "impact triggered")
        try require(engine.consume(sample(12, acceleration: 0.01, rotation: 5)) == nil, "rotation triggered")
        try require(engine.consume(sample(13, acceleration: 0.7, rotation: 2.5)) != nil, "strum rejected")
    }),
    ("sustained motion, release, and repeated strums", {
        var engine = MotionInterpreter()
        try require(engine.consume(sample(0, acceleration: 0.7, rotation: 2.5)) != nil, "first strum rejected")
        for tick in 1...30 {
            try require(engine.consume(sample(Double(tick) / 50, acceleration: 0.7, rotation: 2.5)) == nil,
                        "sustained motion retriggered")
        }
        _ = engine.consume(sample(0.7))
        _ = engine.consume(sample(0.74))
        try require(engine.consume(sample(0.8, acceleration: 0.7, rotation: 2.5)) != nil, "release did not rearm")
    }),
    ("cooldown consumes fast edge without delayed note", {
        var engine = MotionInterpreter()
        _ = engine.consume(sample(0, acceleration: 1, rotation: 3))
        _ = engine.consume(sample(0.02))
        _ = engine.consume(sample(0.06))
        try require(engine.consume(sample(0.08, acceleration: 1, rotation: 3)) == nil, "cooldown failed")
        try require(engine.consume(sample(0.3, acceleration: 1, rotation: 3)) == nil, "delayed note occurred")
        _ = engine.consume(sample(0.32))
        _ = engine.consume(sample(0.36))
        try require(engine.consume(sample(0.4, acceleration: 1, rotation: 3)) != nil, "later valid edge rejected")
    }),
    ("calibrated chord zones and angle wrapping", {
        var engine = MotionInterpreter()
        engine.calibrate(roll: .pi - 0.1)
        try require(engine.currentChord(forRoll: .pi - 0.1) == .c, "neutral chord wrong")
        try require(engine.currentChord(forRoll: .pi - 0.6) == .aMinor, "inward chord wrong")
        try require(engine.currentChord(forRoll: -.pi + 0.5) == .f, "wrapped F chord wrong")
        try require(engine.currentChord(forRoll: -.pi + 1.1) == .g, "wrapped G chord wrong")
    }),
    ("invalid and stale sensor data", {
        var engine = MotionInterpreter()
        _ = engine.consume(sample(1))
        for invalid in [sample(.nan, acceleration: 1, rotation: 3),
                        sample(-1, acceleration: 1, rotation: 3),
                        sample(1.1, roll: .infinity, acceleration: 1, rotation: 3),
                        sample(0.5, acceleration: 1, rotation: 3),
                        sample(1, acceleration: 1, rotation: 3)] {
            try require(engine.consume(invalid) == nil, "bad sample accepted")
        }
        try require(engine.consume(sample(1.2, acceleration: 1, rotation: 3)) != nil, "bad sample polluted state")
    }),
    ("sensitivity and bounded expressive velocity", {
        var low = MotionInterpreter(sensitivity: .low)
        var high = MotionInterpreter(sensitivity: .high)
        let gentle = sample(0, acceleration: 0.3, rotation: 1.2)
        try require(low.consume(gentle) == nil, "low sensitivity accepted gentle motion")
        guard let gentleEvent = high.consume(gentle) else { throw CheckFailed(description: "high sensitivity rejected gentle motion") }
        try require((0...1).contains(gentleEvent.velocity), "gentle velocity out of bounds")
        high.calibrate(roll: 0)
        guard let hardEvent = high.consume(sample(1, acceleration: 10, rotation: 20)) else {
            throw CheckFailed(description: "strong motion rejected")
        }
        try require(hardEvent.velocity == 1 && hardEvent.velocity > gentleEvent.velocity, "hard velocity wrong")
    }),
    ("calibration clears timing and invalid calibration preserves pose", {
        var engine = MotionInterpreter()
        _ = engine.consume(sample(1, acceleration: 1, rotation: 3))
        engine.calibrate(roll: 1)
        try require(engine.consume(sample(1.01, roll: 1, acceleration: 1, rotation: 3)) != nil, "calibration retained cooldown")
        engine.calibrate(roll: .nan)
        try require(engine.currentChord(forRoll: 1) == .c, "invalid calibration changed reference")
    }),
    ("event chord and playable guitar voicings", {
        var engine = MotionInterpreter()
        try require(engine.consume(sample(0, roll: 0.6, acceleration: 1, rotation: 3))?.chord == .f, "event chord wrong")
        for chord in Chord.allCases {
            try require((5...6).contains(chord.midiNotes.count), "voicing does not use guitar string count")
            try require(chord.midiNotes.allSatisfy { (40...88).contains($0) }, "voicing outside guitar range")
        }
    }),
    ("rendered guitar is audible, finite, and bounded at supported rates", {
        for chord in Chord.allCases {
            for rate in [8_000, 44_100, 96_000] {
                let waveform = PluckedStringRenderer.render(chord: chord, sampleRate: rate, duration: 0.3)
                try require(waveform.count == Int(Double(rate) * 0.3), "wrong rendered duration")
                try require(waveform.allSatisfy { $0.isFinite && abs($0) <= 0.700_01 }, "nonfinite or clipping sample")
                try require(waveform.contains { abs($0) > 0.05 }, "silent waveform")
            }
        }
    }),
    ("rendering is deterministic", {
        let first = PluckedStringRenderer.render(chord: .c, sampleRate: 16_000, duration: 0.4)
        let second = PluckedStringRenderer.render(chord: .c, sampleRate: 16_000, duration: 0.4)
        try require(first == second, "same chord rendered different waveforms")
    }),
    ("invalid rendering parameters return empty output", {
        for rate in [-1, 0, 7_999, 96_001, Int.max] {
            try require(PluckedStringRenderer.render(chord: .g, sampleRate: rate).isEmpty, "invalid rate accepted")
        }
        for duration in [-1.0, 0, 0.000_001, .nan, .infinity, 10.1] {
            try require(PluckedStringRenderer.render(chord: .g, duration: duration).isEmpty, "invalid duration accepted")
        }
    }),
    ("distinct chords produce different audible waveforms", {
        let waves = Chord.allCases.map {
            PluckedStringRenderer.render(chord: $0, sampleRate: 16_000, duration: 0.4)
        }
        for lhs in waves.indices {
            for rhs in waves.indices where rhs > lhs {
                let difference = zip(waves[lhs], waves[rhs]).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) }
                try require(difference / Double(waves[lhs].count) > 0.01, "two chords sound effectively identical")
            }
        }
    }),
    ("plucks start and finish at zero with an attenuated tail", {
        for chord in Chord.allCases {
            let waveform = PluckedStringRenderer.render(chord: chord, sampleRate: 16_000, duration: 0.5)
            try require(waveform.first == 0 && waveform.last == 0, "nonzero waveform boundary may click")
            let early = waveform[800..<2400].reduce(0.0) { $0 + Double($1 * $1) } / 1600
            let tail = waveform.suffix(320).reduce(0.0) { $0 + Double($1 * $1) } / 320
            try require(tail < early * 0.1, "tail did not fade sufficiently")
        }
    })
]

do {
    for (name, check) in checks {
        try check()
        print("PASS: \(name)")
    }
    print("\(checks.count) core checks passed.")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
