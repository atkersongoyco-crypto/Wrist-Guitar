import Foundation

/// A narrow, mono-compatible contribution from the recording itself. It favors
/// off-centre instruments in stereo and short, broadband attacks in mono.
public struct RecordingPart: Sendable {
    private struct Pair {
        var mid: Float = 0
        var side: Float = 0
        static func - (lhs: Self, rhs: Self) -> Self {
            Self(mid: lhs.mid - rhs.mid, side: lhs.side - rhs.side)
        }
    }

    private struct Crossover {
        var first = Pair()
        var second = Pair()
        let alpha: Float
        mutating func lowPass(_ sample: Pair) -> Pair {
            first.mid += alpha * (sample.mid - first.mid)
            first.side += alpha * (sample.side - first.side)
            second.mid += alpha * (first.mid - second.mid)
            second.side += alpha * (first.side - second.side)
            return second
        }
    }

    private struct Band {
        var midLevel: Float = 0
        var sideLevel: Float = 0
        var cross: Float = 0
        var crossMagnitude: Float = 0
        var fast: Float = 0
        var slow: Float = 0
        var direction: Float = 0
        var desired: Float = 0
        var onset: Float = 0

        mutating func observe(_ v: Pair, fastRate: Float, slowRate: Float, spatialRate: Float, update: Bool) {
            let m = abs(v.mid)
            midLevel += spatialRate * (m - midLevel)
            sideLevel += spatialRate * (abs(v.side) - sideLevel)
            let product = v.mid * v.side
            cross += spatialRate * (product - cross)
            crossMagnitude += spatialRate * (abs(product) - crossMagnitude)
            fast += fastRate * (m - fast)
            slow += slowRate * (m - slow)
            if update {
                let width = sideLevel / (midLevel + sideLevel + 0.00010)
                // Quiet panned parts can still be distinct in a narrow mix.
                // Weight their local 45 ms levels, cap make-up at 2.3x, and
                // fade it out near dual mono or the recording's noise floor.
                let usableWidth = max(0, min(1, (width - 0.025) / 0.090))
                let aboveFloor = max(0, min(1, (sideLevel - 0.0005) / 0.0021))
                let narrow = max(0, min(1, (0.44 - width) / 0.31))
                let compensated = usableWidth * (0.48 + 1.82 * narrow * narrow)
                let wideSelection = max(0, min(1, (width - 0.14) / 0.34))
                let selection = aboveFloor * max(wideSelection, compensated)
                // Exchanging L and R negates BOTH side and its direction.
                // A hard-right instrument therefore reinforces, not cancels,
                // on the watch's single speaker, just like a hard-left one.
                let alignment = cross / (crossMagnitude + 0.00000004)
                desired = selection * tanh((2.2 + narrow) * alignment)
                onset = max(0, min(1, (fast / (slow + 0.0007) - 1.55) / 1.60))
            }
            direction += fastRate * (desired - direction)
        }
    }

    private let rate: Double
    private let fastRate: Float
    private let slowRate: Float
    private let spatialRate: Float
    private let controlPeriod: Int
    private var untilUpdate = 0
    private var bottom: Crossover
    private var lower: Crossover
    private var upper: Crossover
    private var top: Crossover
    private var lowBand = Band()
    private var midBand = Band()
    private var highBand = Band()
    private var trebleLevel: Float = 0
    private var trebleFloor: Float = 0
    private var transient: Float = 0
    private var desiredTransient: Float = 0

    public init(sampleRate: Double) {
        precondition(sampleRate.isFinite && sampleRate > 0)
        rate = sampleRate
        func lowPass(_ hz: Double) -> Crossover {
            Crossover(alpha: Float(1 - exp(-2 * .pi * min(hz, sampleRate * 0.42) / sampleRate)))
        }
        bottom = lowPass(180)
        lower = lowPass(540)
        upper = lowPass(1_220)
        top = lowPass(2_350)
        fastRate = Float(1 - exp(-1 / (0.004 * sampleRate)))
        slowRate = Float(1 - exp(-1 / (0.085 * sampleRate)))
        spatialRate = Float(1 - exp(-1 / (0.045 * sampleRate)))
        controlPeriod = max(1, Int((sampleRate * 0.001).rounded()))
    }

    public mutating func reset() { self = Self(sampleRate: rate) }

    public mutating func next(left: Float, right: Float) -> Float {
        let v = Pair(mid: (left + right) * 0.5, side: (left - right) * 0.5)
        let b0 = bottom.lowPass(v)
        let b1 = lower.lowPass(v)
        let b2 = upper.lowPass(v)
        let b3 = top.lowPass(v)
        let treble = v.mid - 2 * top.first.mid + b3.mid
        trebleLevel += fastRate * (abs(treble) - trebleLevel)
        trebleFloor += slowRate * (abs(treble) - trebleFloor)
        let low = b1 - b0, mid = b2 - b1, high = b3 - b2
        let update = untilUpdate == 0
        untilUpdate = update ? controlPeriod - 1 : untilUpdate - 1
        lowBand.observe(low, fastRate: fastRate, slowRate: slowRate, spatialRate: spatialRate, update: update)
        midBand.observe(mid, fastRate: fastRate, slowRate: slowRate, spatialRate: spatialRate, update: update)
        highBand.observe(high, fastRate: fastRate, slowRate: slowRate, spatialRate: spatialRate, update: update)
        if update {
            // Two rising bands suffice: a sustained low instrument can mask
            // the attack in the third. Treble energy adds confidence that
            // the onset extends beyond a single low, ringing partial.
            let body = lowBand.fast + midBand.fast + highBand.fast
            let broadband = max(0, min(1, (trebleLevel / (body + 0.0007) - 0.035) / 0.16))
            let trebleOnset = max(0, min(1, (trebleLevel / (trebleFloor + 0.0007) - 1.55) / 1.60))
            let lowerPair = min(lowBand.onset, midBand.onset)
            let upperPair = min(highBand.onset, max(lowBand.onset, midBand.onset, trebleOnset))
            desiredTransient = max(lowerPair, upperPair) * broadband
        }
        transient += fastRate * (desiredTransient - transient)
        if left == 0 && right == 0 { return 0 }
        let lateral = low.side * lowBand.direction + mid.side * midBand.direction + high.side * highBand.direction
        let rhythm = (low.mid * 0.55 + mid.mid + high.mid * 0.70) * transient
        return 0.78 * (lateral + 0.48 * rhythm)
    }
}
