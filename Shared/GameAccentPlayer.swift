import AVFoundation
import Foundation

/// Kept on the selected music output. All decoding and player allocation happen before countdown.
@MainActor
final class GameAccentPlayer {
    static let backingGain: Float = 0.60
    private var voices: [AVAudioPlayer] = []
    private var next = 0
    private var lastAttack = -Double.infinity

    func prepare() throws {
        guard voices.isEmpty else { return }
        guard let url = Bundle.main.url(forResource: "GameStroke", withExtension: "wav") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        let warmed = try (0..<3).map { _ -> AVAudioPlayer in
            let player = try AVAudioPlayer(data: data)
            guard player.prepareToPlay() else { throw CocoaError(.fileReadUnknown) }
            return player
        }
        voices = warmed
    }

    func play(strength: Double, grade: SongGameGrade = .free, level: Float = 1) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !voices.isEmpty, level.isFinite, level > 0, now - lastAttack >= 0.050 else { return }
        lastAttack = now
        let voice = voices[next]
        next = (next + 1) % voices.count
        let force = Float(strength.isFinite ? min(1, max(0, strength)) : 0.5)
        let accent: Float = grade == .perfect ? 0.10 : (grade == .good ? 0.065 : 0)
        voice.volume = min(1, level) * (0.25 + 0.11 * force + accent)
        voice.currentTime = 0
        voice.play()
    }

    func stop() {
        for voice in voices { voice.stop() }
        voices.removeAll()
        next = 0
        lastAttack = -.infinity
    }
}
