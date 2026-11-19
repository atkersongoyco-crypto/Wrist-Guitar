import XCTest
@testable import AirGuitarCore

final class RecordingStrokeTests: XCTestCase {
    private let rate = 44_100.0

    private func tone(_ hz: Double, _ frames: Int, amplitude: Double = 0.24) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    private func render(_ left: [Float], _ right: [Float]? = nil, with stroke: inout RecordingStroke) -> [Float] {
        var l = left
        var r = right ?? []
        l.withUnsafeMutableBufferPointer { a in
            r.withUnsafeMutableBufferPointer { b in
                let channels = b.isEmpty ? [a.baseAddress!] : [a.baseAddress!, b.baseAddress!]
                channels.withUnsafeBufferPointer { stroke.process($0.baseAddress!, frames: a.count) }
            }
        }
        return l
    }

    private func rms(_ x: [Float]) -> Double {
        sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    private func difference(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map(-) }

    func testStrokeHighlightsPannedInstrumentAndProtectsSustainedCenter() {
        let voice = tone(211, 22_050)
        let keys = tone(704, voice.count)
        let left = zip(voice, keys).map(+)
        let right = voice
        func added(_ force: Double, _ l: [Float], _ r: [Float]) -> [Float] {
            var stroke = RecordingStroke(sampleRate: rate, channels: 2)
            _ = render(l, r, with: &stroke)
            stroke.trigger(strength: force, amount: 0.46, speaker: true)
            return difference(render(l, r, with: &stroke), l)
        }
        let strong = added(0.86, left, right)
        let light = added(0.34, left, right)
        let center = added(0.86, voice, voice)
        let flipped = added(0.86, right, left)
        XCTAssertGreaterThan(rms(strong), 0.014)
        XCTAssertGreaterThan(rms(strong), 1.8 * rms(light))
        XCTAssertLessThan(rms(center), 0.12 * rms(strong))
        XCTAssertLessThan(rms(difference(strong, flipped)), 0.02 * rms(strong))
        // Project the added part onto the known centered voice and panned keys.
        func projection(_ basis: [Float]) -> Double {
            abs(zip(strong, basis).reduce(0.0) { $0 + Double($1.0 * $1.1) }) / Double(basis.count)
        }
        XCTAssertLessThan(projection(voice), 0.15 * projection(keys))
    }

    func testNarrowStereoKeepsItsQuieterPannedPartPlayable() {
        let voice = tone(211, 22_050, amplitude: 0.32)
        let keys = tone(887, voice.count, amplitude: 0.068)
        let left = zip(voice, keys).map(+)
        let right = zip(voice, keys).map { $0 + 0.12 * $1 }
        var stroke = RecordingStroke(sampleRate: rate, channels: 2)
        _ = render(left, right, with: &stroke)
        stroke.trigger(strength: 0.86, amount: 0.46, speaker: true)
        let played = difference(render(left, right, with: &stroke), left)
        // A quieter part in a narrow stereo mix must remain playable when
        // there is an actual instrument there, even over a louder center.
        XCTAssertGreaterThan(rms(played), 0.025 * rms(left))
    }

    func testNoGestureNoChangeAndDecayReturnsToExactOriginal() {
        let l = tone(620, 4_410)
        let r = [Float](repeating: 0, count: l.count)
        var stroke = RecordingStroke(sampleRate: rate, channels: 2)
        stroke.continueMotion()
        XCTAssertEqual(render(l, r, with: &stroke), l)
        stroke.trigger(strength: 1, amount: 0, speaker: true)
        XCTAssertEqual(render(l, r, with: &stroke), l)
        stroke.trigger(strength: 0.9, amount: 0.46, speaker: true)
        for _ in 0..<26 {
            stroke.continueMotion()
            XCTAssertGreaterThan(rms(difference(render(l, r, with: &stroke), l)), 0.008)
        }
        for _ in 0..<25 { _ = render(l, r, with: &stroke) }
        stroke.continueMotion()
        XCTAssertEqual(render(l, r, with: &stroke), l)
        stroke.trigger(strength: 1, amount: 1, speaker: true)
        stroke.reset()
        XCTAssertEqual(render(l, r, with: &stroke), l)
    }

    func testPlayingThroughRestCannotMakeASoundOrReviveAnEarlierStroke() {
        let audio = tone(660, 8_820), silence = [Float](repeating: 0, count: 16_000)
        var stroke = RecordingStroke(sampleRate: rate, channels: 2)
        stroke.trigger(strength: 1, amount: 1, speaker: true)
        _ = render(audio, audio.map { $0 * 0.1 }, with: &stroke)
        XCTAssertEqual(render(silence, silence, with: &stroke), silence)
        XCTAssertEqual(render(audio, audio.map { $0 * 0.1 }, with: &stroke), audio)
    }

    func testEveryGestureRearticulatesPartWithoutCuttingItsTail() {
        let n = 22_050
        let l = tone(800, n), r = [Float](repeating: 0, count: n)
        var stroke = RecordingStroke(sampleRate: rate, channels: 2)
        _ = render(l, r, with: &stroke)
        var previous = [Float]()
        for _ in 0..<3 {
            stroke.trigger(strength: 0.8, amount: 0.46, speaker: true)
            let delta = difference(render(l, r, with: &stroke), l)
            let body = rms(Array(delta.suffix(882)))
            let peak = rms(Array(delta[1_764..<3_528]))
            XCTAssertGreaterThan(peak, 1.5 * body)
            if !previous.isEmpty {
                XCTAssertEqual(rms(Array(delta.prefix(220))), rms(Array(previous.suffix(220))), accuracy: 0.005)
            }
            previous = delta
        }
    }

    func testMonoRoleFollowsTransientsAndLeavesSteadyToneAlone() {
        var stroke = RecordingStroke(sampleRate: rate, channels: 1)
        let sustained = tone(450, 22_050)
        _ = render(sustained, with: &stroke)
        stroke.trigger(strength: 0.9, amount: 0.46, speaker: true)
        let center = rms(difference(render(sustained, with: &stroke), sustained))
        var burst = sustained
        for i in burst.indices {
            let t = Double(i % 5_512) / rate
            let phase = 2 * Double.pi * Double(i) / rate
            burst[i] += Float(0.43 * exp(-t * 38) * (sin(800 * phase) + 0.6 * sin(1_500 * phase)))
        }
        stroke.trigger(strength: 0.9, amount: 0.46, speaker: true)
        let transients = rms(difference(render(burst, with: &stroke), burst))
        XCTAssertGreaterThan(transients, 0.0003)
        XCTAssertGreaterThan(transients, 5 * center)
    }

    func testFrontChannelsSharePartAndMaximumPlaybackGainStaysBounded() {
        for rate in [8_000.0, 44_100.0, 192_000.0] {
            var stroke = RecordingStroke(sampleRate: rate, channels: 3)
            let n = Int(rate * 0.12)
            let left = (0..<n).map { Float(sin(2 * .pi * 680 * Double($0) / rate) >= 0 ? 1 : -1) }
            let right = left.map { -0.20 * $0 }
            var l = left, r = right, surround = left
            stroke.trigger(strength: 1, amount: 1, speaker: true)
            l.withUnsafeMutableBufferPointer { a in
                r.withUnsafeMutableBufferPointer { b in
                    surround.withUnsafeMutableBufferPointer { c in
                        let channels = [a.baseAddress!, b.baseAddress!, c.baseAddress!]
                        channels.withUnsafeBufferPointer { stroke.process($0.baseAddress!, frames: n) }
                    }
                }
            }
            XCTAssertEqual(surround, left)
            XCTAssertTrue(zip(difference(l, left), difference(r, right)).allSatisfy { abs($0 - $1) < 2e-7 })
            XCTAssertLessThanOrEqual(l.map { abs($0) }.max()!, 1.96001)
            XCTAssertLessThanOrEqual(r.map { abs($0) }.max()!, 1.96001)
        }
    }
}
