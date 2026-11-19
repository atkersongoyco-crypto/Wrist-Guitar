import AVFoundation
import Combine
import Foundation

enum PhoneGamePhase: Equatable { case lobby, preparing, countdown, playing, finished }
enum PhoneGameInput: String { case watch, screen }

struct PhoneGameRecord: Codable, Equatable {
    var score: Int
    var combo: Int
}

@MainActor
final class PhoneGameController: ObservableObject {
    @Published private(set) var phase: PhoneGamePhase = .lobby
    @Published private(set) var position = 0.0
    @Published private(set) var countdown = 3
    @Published private(set) var chart: SongGameChart?
    @Published private(set) var score = 0
    @Published private(set) var hits = 0
    @Published private(set) var combo = 0
    @Published private(set) var bestCombo = 0
    @Published private(set) var resolvedTarget = 0
    @Published private(set) var previousBest: PhoneGameRecord?
    @Published private(set) var completedSong = false
    @Published private(set) var grade: SongGameGrade?
    @Published private(set) var motion = 0
    @Published private(set) var feedbackAt = -Double.infinity
    @Published private(set) var strength = 0.5
    @Published private(set) var message = ""
    @Published private(set) var needsTransfer = false
    @Published var input: PhoneGameInput = .watch
    @Published var output: WristGameOutput = .phone
    private let library: PhoneLibrary
    private let accents = GameAccentPlayer()
    private var player: AVAudioPlayer?
    private var judge: SongGameJudge?
    private var preparation: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var session: UUID?
    private var recordKey: String?
    private var watchOffset = 0.0
    private var startTime = 0.0
    private var anchor: (watch: Double, song: Double)?
    private var lastSequence = -1
    private var awaitingReady = false
    private var waitingForFirstHead = false
    private var ownsAudio = false
    private var hasLocalPlayback = false
    private var songDuration = 0.0
    private var link: WristGameLink { library.gameLink }
    private var now: Double { WristGameLink.now }

    init(library: PhoneLibrary) { self.library = library }

    func appear() {
        link.onMessage = { [weak self] message in self?.receive(message) }
    }

    func leave() {
        cancel()
        link.onMessage = nil
    }

    func cancel(reason: String = "") {
        if let session, input == .watch { link.send(.stop(session: session)) }
        cleanUp()
        phase = .lobby
        message = reason
        needsTransfer = false
    }

    func begin(_ song: PhoneSong) {
        cancel()
        guard input != .watch || link.isReachable else {
            message = "请打开手表上的 Wrist Guitar，或选择「点屏练习」。"
            return
        }
        if input == .screen { output = .phone }
        library.stopPreview()
        let id = UUID()
        session = id
        let item = library.audioItem(for: song)
        let key = "WristGuitar.game.personalBest.\(item.id.uuidString).\(input.rawValue)"
        recordKey = key
        previousBest = UserDefaults.standard.data(forKey: key).flatMap {
            try? JSONDecoder().decode(PhoneGameRecord.self, from: $0)
        }
        completedSong = false
        let practice = song.isPracticeTrack == true && item.id == song.id
        let url = library.originalURL(for: song).deletingLastPathComponent().appendingPathComponent(item.filename)
        position = 0; score = 0; hits = 0; combo = 0; bestCombo = 0
        motion = 0; grade = nil; feedbackAt = -.infinity; lastSequence = -1
        resolvedTarget = 0; chart = nil; waitingForFirstHead = false; anchor = nil
        phase = .preparing
        message = "正在从歌曲中提取拍点…"
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let built = try await SongGameChart.load(url: url, practice: practice)
                try Task.checkCancellation()
                guard session == id else { return }
                chart = built
                songDuration = built.duration
                judge = SongGameJudge(targets: built.targets)
                if output == .phone {
                    let audio = AVAudioSession.sharedInstance()
                    try audio.setCategory(.playback, mode: .default)
                    try audio.setActive(true)
                    ownsAudio = true
                    let local = try AVAudioPlayer(contentsOf: url)
                    local.volume = GameAccentPlayer.backingGain
                    guard local.prepareToPlay() else { throw GameFailure.audio }
                    player = local
                    try accents.prepare()
                }
                if input == .screen {
                    try schedule(id: id)
                } else {
                    message = "正在连接手表…"
                    let offset = try await link.clockOffset()
                    try Task.checkCancellation()
                    guard session == id else { return }
                    watchOffset = offset
                    awaitingReady = true
                    armTimeout(id, seconds: output == .watch ? 35 : 9,
                               reason: "手表准备超时。请在表上确认声音输出，并保持 App 在前台。")
                    send(.prepare(session: id, song: item.id, practice: practice, output: output), id: id)
                }
            } catch {
                guard session == id, !Task.isCancelled else { return }
                cancel(reason: error.localizedDescription)
            }
        }
    }

    private func schedule(id: UUID) throws {
        let start = now + 3.0
        if output == .phone {
            guard let player, player.play(atTime: player.deviceCurrentTime + max(0.1, start - now)) else { throw GameFailure.audio }
        }
        startTime = start
        if input == .watch {
            send(.commit(session: id, watchStart: start + watchOffset), id: id)
            guard session == id else { return }
            armTimeout(id, seconds: 7, reason: "手表没有确认开始。请打开手表 App 后重试。")
        }
        message = ""
        countdown = 3
        phase = .countdown
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.session == id else { return }
                self.tick()
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
    }

    private func send(_ message: WristGameMessage, id: UUID) {
        link.send(message) { [weak self] error in
            guard let self, self.session == id else { return }
            self.cancel(reason: error)
        }
    }

    private func armTimeout(_ id: UUID, seconds: Double, reason: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.session == id else { return }
            self.cancel(reason: reason)
        }
    }

    private func receive(_ m: WristGameMessage) {
        guard let id = session, id == m.sessionID, input == .watch else { return }
        switch m {
        case .ready where awaitingReady:
            awaitingReady = false
            watchdog?.cancel()
            do { try schedule(id: id) } catch { cancel(reason: error.localizedDescription) }
        case let .reject(_, reason):
            let transfer = output == .watch && reason.contains("还没到手表")
            cancel(reason: reason)
            needsTransfer = transfer
        case .started:
            if output == .watch, anchor == nil {
                if !waitingForFirstHead {
                    waitingForFirstHead = true
                    armTimeout(id, seconds: 3, reason: "没有收到手表的播放进度，请检查连接后再试。")
                }
            } else { watchdog?.cancel() }
        case let .playhead(_, t, seconds):
            guard output == .watch, t.isFinite, seconds.isFinite, seconds >= 0, seconds <= songDuration + 1,
                  anchor.map({ t >= $0.watch }) ?? true else { return }
            anchor = (t, seconds)
            waitingForFirstHead = false
            watchdog?.cancel()
        case let .stroke(_, sequence, timestamp, force):
            guard sequence > lastSequence, timestamp.isFinite, force.isFinite,
                  phase == .playing || phase == .countdown else { return }
            let phoneTime = timestamp - watchOffset
            guard phoneTime >= startTime, phoneTime <= now + 0.15, now - phoneTime < 1.4 else { return }
            lastSequence = sequence
            let t: Double
            if output == .watch {
                // The first wrist packet can beat the first playhead packet across WCSession.
                if let anchor { t = anchor.song + timestamp - anchor.watch }
                else { t = phoneTime - startTime }
            } else {
                guard let player else { return }
                t = player.currentTime - max(0, now-phoneTime)
            }
            let result = strike(at: t, force: force)
            if result != .free {
                link.send(.feedback(session: id, sequence: sequence, hit: true))
            }
        case .ended:
            if output == .watch { finish() }
        case .stop:
            cleanUp(); phase = .lobby; message = "手表已结束本局。"
        default: break
        }
    }

    private func tick() {
        let clock = now
        guard clock >= startTime else {
            countdown = max(1, Int(ceil(startTime-clock)))
            return
        }
        if output == .watch {
            guard let anchor else { return }
            let age = clock + watchOffset - anchor.watch
            guard age < 5 else { cancel(reason: "手表播放进度已中断，请重新开始。"); return }
            position = min(songDuration, max(0, anchor.song + age))
        } else if let player {
            if player.isPlaying {
                hasLocalPlayback = true
                position = player.currentTime
            } else if hasLocalPlayback, position > songDuration - 0.30 {
                position = songDuration
                finish()
                return
            } else if hasLocalPlayback || clock > startTime + 1.0 {
                cancel(reason: "手机播放已中断，请重新开始。")
                return
            } else { return }
        }
        if phase == .countdown { phase = .playing }
        // Keep recently passed notes available for timestamped WatchConnectivity events.
        judge?.expire(before: position)
        syncScore()
    }

    func tap() {
        guard phase == .playing, input == .screen, let player else { return }
        _ = strike(at: player.currentTime, force: 0.65)
    }

    @discardableResult private func strike(at seconds: Double, force: Double) -> SongGameGrade {
        guard seconds >= 0, seconds < songDuration, let result = judge?.strike(at: seconds) else { return .free }
        syncScore()
        grade = result; strength = min(1, max(0, force)); motion += 1; feedbackAt = now
        if output == .phone { accents.play(strength: strength, grade: result) }
        return result
    }

    private func syncScore() {
        guard let judge else { return }
        if score != judge.score { score = judge.score }
        if combo != judge.combo { combo = judge.combo }
        if bestCombo != judge.bestCombo { bestCombo = judge.bestCombo }
        if hits != judge.hits { hits = judge.hits }
        if resolvedTarget != judge.targetIndex { resolvedTarget = judge.targetIndex }
    }

    func endEarly() {
        guard phase == .countdown || phase == .playing else { return }
        if let session, input == .watch { link.send(.stop(session: session)) }
        cleanUp()
        phase = .finished
    }

    private func finish() {
        guard phase == .playing || phase == .countdown else { return }
        position = songDuration
        judge?.expire(before: songDuration + 1)
        syncScore()
        completedSong = true
        if let recordKey {
            let record = PhoneGameRecord(score: max(previousBest?.score ?? 0, score),
                                         combo: max(previousBest?.combo ?? 0, bestCombo))
            if record != previousBest, let data = try? JSONEncoder().encode(record) {
                UserDefaults.standard.set(data, forKey: recordKey)
            }
        }
        if let session, input == .watch { link.send(.stop(session: session)) }
        cleanUp(); phase = .finished
    }

    private func cleanUp() {
        session = nil; awaitingReady = false; hasLocalPlayback = false
        preparation?.cancel(); preparation = nil
        ticker?.cancel(); ticker = nil
        watchdog?.cancel(); watchdog = nil
        player?.stop(); player = nil
        accents.stop()
        if ownsAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudio = false
        }
    }

    private enum GameFailure: LocalizedError {
        case audio
        var errorDescription: String? { "手机无法开始播放，请检查这首歌后重试。" }
    }
}
