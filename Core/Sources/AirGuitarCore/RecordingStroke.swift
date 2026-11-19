import Foundation

/// The transport always carries the unmodified recording. A stroke opens a
/// second, sample-aligned part derived from the arrangement at this position.
public struct RecordingStroke: Sendable {
    private let sampleRate: Double
    private let channelCount: Int
    private let silenceLimit: Int
    private var part: RecordingPart
    private var silentFrames = 0
    private var age = 0
    private var attack = 1
    private var settleEnd = 2
    private var holdUntil = 0
    private var release = 0
    private var start: Float = 0
    private var peak: Float = 0
    private var level: Float = 0

    public init(sampleRate: Double, channels: Int) {
        precondition(sampleRate.isFinite && sampleRate > 0 && channels > 0)
        self.sampleRate = sampleRate
        channelCount = channels
        silenceLimit = max(1, Int(0.22 * sampleRate))
        part = RecordingPart(sampleRate: sampleRate)
    }

    public mutating func trigger(strength: Double, amount: Double, speaker: Bool) {
        guard strength.isFinite, amount.isFinite, amount > 0 else { return }
        let force = min(1, max(0, strength))
        let accent = Self.ease(Float(min(1, max(0, (force - 0.25) / 0.65))))
        let mix = Float(pow(min(1, amount) / 0.46, 0.62))
        let interval = Double(age) / sampleRate
        let followsStroke = release > 0 && (0.15...1.45).contains(interval)
        start = level
        peak = (0.52 + 0.73 * accent) * mix * (speaker ? 1 : 0.90)
        attack = frames(peak < level ? 0.14 : 0.035)
        settleEnd = attack + frames(0.30 + 0.12 * force)
        let hold = followsStroke ? min(1.05, max(0.52, 1.02 * interval + 0.06)) : 0.72
        holdUntil = max(settleEnd, frames(hold))
        release = frames(0.52 + 0.12 * force)
        age = 0
    }

    /// A continuing sweep can sustain the existing part but never play a note by itself.
    public mutating func continueMotion() {
        guard release > 0, age < holdUntil else { return }
        holdUntil = max(holdUntil, age + frames(0.36))
    }

    public mutating func reset() {
        part.reset()
        silentFrames = 0
        endStroke()
    }

    private func frames(_ seconds: Double) -> Int { max(1, Int(seconds * sampleRate)) }
    private static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    private mutating func endStroke() {
        release = 0
        age = 0
        level = 0
    }

    private mutating func tick() {
        age += 1
        let body = 0.53 * peak
        if age < attack {
            level = start + (peak - start) * Self.ease(Float(age) / Float(attack))
        } else if age < settleEnd {
            let t = Float(age - attack) / Float(settleEnd - attack)
            level = peak + (body - peak) * Self.ease(t)
        } else if age <= holdUntil {
            level = body
        } else if age < holdUntil + release {
            level = body * Self.ease(Float(holdUntil + release - age) / Float(release))
        } else {
            endStroke()
        }
    }

    public mutating func process(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        guard frames > 0 else { return }
        let left = channels[0]
        let stereo = channelCount > 1
        let right = channels[stereo ? 1 : 0]
        for i in 0..<frames {
            let l = left[i], r = right[i]
            // Update on dry frames too, so the first stroke inherits the current
            // instrumentation rather than treating the whole mix as a new onset.
            let instrument = part.next(left: l, right: r)
            guard release > 0 else { continue }
            tick()
            let inputPeak = max(abs(l), abs(r))
            if inputPeak < 0.00001 {
                silentFrames += 1
                if silentFrames >= silenceLimit { endStroke() }
            } else {
                silentFrames = 0
            }
            guard inputPeak > 0, level > 0 else { continue }
            let added = instrument * level
            // Apply a shared ceiling only to the added part, never to the master.
            // At maximum playback volume (0.5) this leaves 0.02 of peak headroom.
            let upper = max(0, 1.96 - max(l, r))
            let lower = min(0, -1.96 - min(l, r))
            let wet = min(upper, max(lower, added))
            left[i] = l + wet
            if stereo { right[i] = r + wet }
        }
    }
}
