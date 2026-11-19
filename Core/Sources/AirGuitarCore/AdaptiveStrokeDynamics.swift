import Foundation

/// A small, session-local correction to the sound of already accepted strokes.
/// The motion detector and the player's saved calibration do not depend on it.
public struct AdaptiveStrokeDynamics: Sendable {
    private var recent = [Double]()
    private var softOffset = 0.0
    private var accentOffset = 0.0

    public init() {}

    public mutating func adjusted(_ stroke: StrumEvent) -> StrumEvent {
        let strength = stroke.pickStrength
        let offset: Double
        switch strength {
        case ..<0.30:
            offset = softOffset * strength / 0.30
        case 0.80...:
            offset = accentOffset * (1 - strength) / 0.20
        default:
            let position = (strength - 0.30) / 0.50
            offset = softOffset + (accentOffset - softOffset) * position
        }
        // Use the preceding strokes to interpret this one. An isolated accent
        // should never move its own target or teach an all-soft passage.
        observe(strength)
        guard abs(offset) > 0.000_001 else { return stroke }
        return StrumEvent(timestamp: stroke.timestamp, chord: stroke.chord,
                          velocity: 0.45 + 0.55 * (strength + offset))
    }

    private mutating func observe(_ strength: Double) {
        recent.append(strength)
        if recent.count > 24 { recent.removeFirst() }
        guard recent.count >= 16 else { return }

        // Require two repeatedly demonstrated levels. Use their medians so
        // an occasional missed accent or a single unusually hard hit has little weight.
        let soft = recent.filter { $0 <= 0.44 }.sorted()
        let accents = recent.filter { $0 >= 0.53 }.sorted()
        guard soft.count >= 4, accents.count >= 4 else { return }
        let low = (soft[(soft.count - 1) / 2] + soft[soft.count / 2]) / 2
        let high = (accents[(accents.count - 1) / 2] + accents[accents.count / 2]) / 2
        guard high - low >= 0.22 else { return }

        // Limit correction to a tenth of the playable range and ease it in.
        // Silence, rejected motion and watch haptics never enter this history.
        softOffset += 0.08 * (min(0.10, max(-0.10, 0.30 - low)) - softOffset)
        accentOffset += 0.08 * (min(0.10, max(-0.10, 0.80 - high)) - accentOffset)
    }
}
