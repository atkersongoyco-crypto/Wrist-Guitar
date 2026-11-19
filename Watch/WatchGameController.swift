import AirGuitarCore
import AVFAudio
import Combine
import Foundation
import WatchKit

/// The iPhone owns the score. The Watch owns the motion timestamps and, only
/// when selected as the output, the precisely scheduled audio transport.
@MainActor
final class WatchGameController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Phase: Equatable {
        case waiting, preparing, ready, countdown, playing, finished
    }

    @Published private(set) var presented = false
    @Published private(set) var phase = Phase.waiting
    @Published private(set) var connected = false
    @Published private(set) var message = "在 iPhone 选歌开始"
    @Published private(set) var title = ""
    @Published private(set) var output = WristGameOutput.phone
    @Published private(set) var strokes = 0
    @Published private(set) var matched = false
    @Published private(set) var startTime: Double?

    private weak var library: WatchSongLibrary?
    private weak var performance: PerformanceModel?
    private weak var link: WristGameLink?
    private var observation: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private let motion = MotionDriver()
    private let accent = GameAccentPlayer()
    private var player: AVAudioPlayer?
    private var id: UUID?
    private var songID: UUID?
    private var finishedIDs: [UUID] = []
    private var activationPending: UUID?
    private var ownsAudio = false
    private var timer: Task<Void, Never>?
    private var prep: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var lastFeedback = 0

    func bind(library: WatchSongLibrary, performance: PerformanceModel) {
        if link === library.gameLink { return }
        self.library = library
        self.performance = performance
        link = library.gameLink
        connected = library.gameLink.isReachable
        library.gameLink.onMessage = { [weak self] message in self?.receive(message) }
        observation = library.gameLink.$isReachable.removeDuplicates().sink { [weak self] reachable in
            Task { @MainActor in
                guard let self, self.link?.isReachable == reachable else { return }
                self.connected = reachable
                if !reachable, self.id != nil { self.finish("连接已断开，请在 iPhone 重新开始") }
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let type = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.audioFailed("声音被系统打断，请重新开始") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            guard let type = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  type == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.audioFailed("声音输出已断开，请重新开始") }
        })
    }

    func open() {
        guard !presented else { return }
        performance?.pause(reason: "已进入双端音游", notify: false)
        phase = .waiting
        message = "在 iPhone 选歌开始"
        title = ""
        presented = true
    }

    func leave() {
        if let id { link?.send(.stop(session: id)); finish("本轮已结束") }
        presented = false
    }

    func enteredBackground() {
        if let id { link?.send(.stop(session: id)); finish("已离开游戏，请在 iPhone 重新开始") }
    }

    private func receive(_ message: WristGameMessage) {
        switch message {
        case let .prepare(session, song, practice, output):
            prepare(session: session, song: song, practice: practice, output: output)
        case let .commit(session, start):
            commit(session: session, start: start)
        case let .feedback(session, seq, hit):
            guard id == session, phase == .playing, seq > lastFeedback, seq == strokes else { return }
            lastFeedback = seq
            matched = hit
        case let .stop(session):
            if id == session { finish("iPhone 已结束本轮") }
            else { remember(session) } // An overtaken prepare must not revive this session.
        case let .ended(session):
            if id == session { finish("本轮完成") }
            else { remember(session) }
        case let .reject(session, reason):
            if id == session { finish(reason) }
        default:
            break
        }
    }

    private func prepare(session: UUID, song: UUID, practice: Bool, output: WristGameOutput) {
        guard WKApplication.shared().applicationState != .background else {
            link?.send(.reject(session: session, reason: "请先打开手表上的 Wrist Guitar"))
            return
        }
        if id == session {
            guard song == songID, self.output == output else { return }
            if phase == .ready { emit(.ready(session: session), for: session) }
            return
        }
        guard !finishedIDs.contains(session) else { return }
        guard id == nil, activationPending == nil, performance?.isStarting != true else {
            link?.send(.reject(session: session, reason: "手表正忙，请结束当前操作后重试"))
            return
        }
        open()
        id = session
        songID = song
        phase = .preparing
        message = "正在准备手表"
        self.output = output
        strokes = 0; matched = false; lastFeedback = 0
        let track = library?.songs.first { $0.id == song } ?? (practice ? WatchSong.practice : nil)
        title = track?.title ?? "iPhone 选曲"
        guard motion.isAvailable, let performance else {
            reject("未检测到可用的手腕动作传感器", session: session)
            return
        }
        motion.start(sensitivity: performance.sensitivity, assisted: true, calibration: performance.calibration,
                     allowsWristReversals: true, state: { _, _ in }, strum: { [weak self] event in
            self?.stroke(event, session: session)
        }, failure: { [weak self] reason in
            self?.reject("动作感应暂不可用：\(reason)", session: session)
        })
        timeout(session: session, seconds: 35, message: "手表准备超时，请在 iPhone 重试")
        if output == .phone {
            ready(session)
            return
        }
        guard let track, FileManager.default.fileExists(atPath: track.url.path) else {
            reject("这首歌还没到手表。请先在 iPhone 点「用手表弹」，或选择手机出声。", session: session)
            return
        }
        prep = Task { [weak self] in
            guard let self, self.id == session else { return }
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback, mode: .default, policy: .longFormAudio)
                self.activationPending = session
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    audio.activate(options: []) { ok, error in
                        if ok { continuation.resume() }
                        else { continuation.resume(throwing: error ?? CocoaError(.userCancelled)) }
                    }
                }
                self.activationPending = nil
                guard self.id == session, !Task.isCancelled else {
                    if self.performance?.isRunning != true, self.performance?.isStarting != true {
                        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
                    }
                    return
                }
                self.ownsAudio = true
                let player = try AVAudioPlayer(contentsOf: track.url)
                player.volume = Float(performance.masterVolume) * GameAccentPlayer.backingGain
                player.delegate = self
                guard player.duration > 0, player.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
                self.player = player
                try self.accent.prepare()
                self.ready(session)
            } catch {
                self.activationPending = nil
                self.reject("手表无法播放这首歌：\(error.localizedDescription)", session: session)
            }
        }
    }

    private func ready(_ session: UUID) {
        guard id == session else { return }
        phase = .ready
        message = "等待 iPhone 开始"
        timeout(session: session, seconds: 18, message: "未收到开始信号，请重试")
        emit(.ready(session: session), for: session)
    }

    private func commit(session: UUID, start: Double) {
        guard id == session, phase == .ready else { return }
        let delay = start - WristGameLink.now
        guard start.isFinite, (-0.18...12).contains(delay) else {
            reject("两端播放时间已失效，请重新开始", session: session); return
        }
        timer?.cancel()
        if output == .watch {
            guard let player else { reject("手表音频尚未就绪", session: session); return }
            player.currentTime = max(0, -delay)
            let ok = delay > 0 ? player.play(atTime: player.deviceCurrentTime + delay) : player.play()
            guard ok else { reject("手表未能启动播放", session: session); return }
        }
        startTime = start
        phase = .countdown
        timer = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            guard let self, self.id == session else { return }
            self.phase = .playing
            self.message = "跟着手机的光点挥腕"
            self.emit(.started(session: session), for: session)
            if self.output == .watch {
                self.sendPosition(session)
                self.meter = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard let self, self.id == session else { return }
                        self.sendPosition(session)
                    }
                }
            }
        }
    }

    private func sendPosition(_ session: UUID) {
        guard let player else { return }
        emit(.playhead(session: session, watchTime: WristGameLink.now, songTime: player.currentTime), for: session)
    }

    private func stroke(_ event: StrumEvent, session: UUID) {
        guard id == session, phase == .playing, let startTime,
              event.timestamp >= startTime, let performance else { return }
        strokes += 1
        matched = false
        if output == .watch, performance.masterVolume > 0 {
            accent.play(strength: event.pickStrength, level: Float(performance.masterVolume))
        }
        performance.round.touchStroke(strength: event.pickStrength) { [weak self] kind in
            self?.motion.suppressGestures(for: kind == .directionUp ? 0.12 : 0.09)
        }
        emit(.stroke(session: session, sequence: strokes, watchTime: event.timestamp, strength: event.pickStrength), for: session)
    }

    private func emit(_ message: WristGameMessage, for session: UUID) {
        link?.send(message) { [weak self] _ in
            guard let self, self.id == session else { return }
            self.finish("iPhone 连接中断，请重新开始")
        }
    }

    private func timeout(session: UUID, seconds: Double, message: String) {
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.reject(message, session: session)
        }
    }

    private func audioFailed(_ reason: String) {
        guard output == .watch, ownsAudio, let id else { return }
        reject(reason, session: id)
    }

    private func reject(_ reason: String, session: UUID) {
        guard id == session else { return }
        link?.send(.reject(session: session, reason: reason))
        finish(reason)
    }

    private func remember(_ session: UUID) {
        if !finishedIDs.contains(session) { finishedIDs.append(session) }
        if finishedIDs.count > 32 { finishedIDs.removeFirst() }
    }

    private func finish(_ reason: String) {
        if let id { remember(id) }
        id = nil
        prep?.cancel(); prep = nil
        timer?.cancel(); timer = nil
        meter?.cancel(); meter = nil
        motion.stop()
        player?.stop(); player?.delegate = nil; player = nil
        accent.stop()
        if ownsAudio {
            ownsAudio = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        songID = nil; startTime = nil
        message = reason
        phase = .finished
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, let id = self.id else { return }
            if flag { self.link?.send(.ended(session: id)); self.finish("本轮完成") }
            else { self.reject("手表播放中断，请重试", session: id) }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.audioFailed("手表音频解码失败，请重新传送歌曲")
        }
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }
}
