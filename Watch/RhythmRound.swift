import AirGuitarCore
import Combine
import Foundation
import WatchKit

enum ChallengeSource { case song, speaker, taps }
enum ChallengePhase { case ready, analyzing, countdown, playing, paused, finished }

@MainActor
final class RhythmRound: ObservableObject {
    @Published private(set) var phase: ChallengePhase = .ready
    @Published private(set) var source: ChallengeSource?
    @Published private(set) var feedback = "选择跟拍的音乐"
    @Published private(set) var countdown = 0
    @Published private(set) var fraction = 0.0
    @Published private(set) var bpm = 0.0
    @Published private(set) var score = 0
    @Published private(set) var combo = 0
    @Published private(set) var bestCombo = 0
    @Published private(set) var hits = 0
    @Published private(set) var misses = 0
    @Published private(set) var tapsTaken = 0
    @Published private(set) var manualBeat: BeatEstimate?
    @Published var haptics = UserDefaults.standard.object(forKey: "AirGuitar.haptics") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(haptics, forKey: "AirGuitar.haptics")
            if !haptics { beatHapticsActive = false }
            beatHapticPreferenceDidChange?()
        }
    }
    /// Independent automatic beat cues; haptics remains the master switch.
    @Published var beatHaptics = UserDefaults.standard.bool(forKey: "AirGuitar.beatHaptics") {
        didSet {
            UserDefaults.standard.set(beatHaptics, forKey: "AirGuitar.beatHaptics")
            if !beatHaptics { beatHapticsActive = false }
            beatHapticPreferenceDidChange?()
        }
    }
    /// True only while the foreground player has a trusted, enabled beat clock.
    @Published private(set) var beatHapticsActive = false
    var beatHapticPreferenceDidChange: (() -> Void)?
    var willPlayBeatHaptic: (() -> Void)?
    @Published var sounds = UserDefaults.standard.bool(forKey: "AirGuitar.cues") {
        didSet { UserDefaults.standard.set(sounds, forKey: "AirGuitar.cues") }
    }
    private var lastTouch = -Double.infinity
    var willPlayHaptic: ((WKHapticType) -> Void)?
    @Published var assisted = true
    private(set) var targetBeat: BeatEstimate?
    private var game = RhythmGame(beat: nil)
    private var taps = [TimeInterval]()
    private var signalUntil = -Double.infinity
    private var minTargetTime = 0.0
    var targetBeatStride: Int { RhythmGame.targetBeatStride(forBPM: bpm, assisted: assisted) }
    var everyOtherBeat: Bool { targetBeatStride > 1 }

    func reset() {
        beatHapticsActive = false
        phase = .ready
        source = nil
        targetBeat = nil
        bpm = 0
        fraction = 0
        countdown = 0
        taps.removeAll()
        tapsTaken = 0
        manualBeat = nil
        feedback = "选择跟拍的音乐"
        clearScore()
    }

    private func clearScore() {
        game.reset(beat: nil, assisted: assisted)
        score = 0
        combo = 0
        bestCombo = 0
        hits = 0
        misses = 0
        signalUntil = -.infinity
    }

    func listen(_ source: ChallengeSource) {
        beatHapticsActive = false
        clearScore()
        self.source = source
        targetBeat = nil
        bpm = 0
        fraction = 0
        countdown = 0
        phase = .analyzing
        feedback = source == .speaker ? "听拍中 · 请让手表靠近外放音乐" : "正在寻找稳定拍点"
    }

    func use(_ beat: BeatEstimate) {
        bpm = beat.bpm
        targetBeat = BeatEstimate(bpm: bpm / Double(targetBeatStride),
                                  referenceBeat: beat.referenceBeat, confidence: beat.confidence)
        game.reset(beat: targetBeat, tracksMisses: source == .song, assisted: assisted)
    }

    func preparing(_ n: Int) {
        phase = .countdown
        countdown = n
        feedback = "准备"
        touch(.click)
    }

    func begin(at time: TimeInterval) {
        phase = .playing
        game.setPaused(false)
        minTargetTime = time
        // A target already under the playhead when playback starts or resumes
        // cannot be anticipated. Give the player a visible run-up to the first one.
        if let beat = targetBeat, let windows = game.timingWindows {
            let index = ceil((time + beat.period * 0.50 - beat.referenceBeat) / beat.period)
            minTargetTime = beat.referenceBeat + index * beat.period - windows.tolerance
        }
        feedback = assisted ? "轻轻动一下 · 跟着光点" : (everyOtherBeat ? "开始 · 每两拍挥一次" : "开始 · 每拍挥一次")
        touch(.start)
    }

    func tick(at time: TimeInterval, audible: Bool) {
        guard phase == .playing else { return }
        if audible { signalUntil = time + 0.24 }
        if let progress = game.progress(at: time) { fraction = progress.fraction }
        guard time >= minTargetTime else { return }
        for event in game.advance(to: time, isAudible: time <= signalUntil) { show(event) }
    }

    func strum(at time: TimeInterval, audible: Bool) -> Bool {
        guard phase == .playing else { return false }
        if audible { signalUntil = time + 0.24 }
        guard time >= minTargetTime else { feedback = assisted ? "慢慢来 · 等下个光点" : "等下一拍"; return false }
        guard time <= signalUntil else { feedback = assisted ? "等音乐回来，再轻轻动一下" : "等待音乐"; return false }
        for event in game.advance(to: time) { show(event) }
        if let result = game.strum(at: time, isAudible: true) {
            show(result)
            return result.combo > 0 && result.combo.isMultiple(of: assisted ? 4 : 8)
        }
        if let progress = game.progress(at: time) {
            let nearest = progress.fraction < 0.5 ? progress.beatIndex : progress.beatIndex + 1
            if let last = game.lastJudgement, last.grade != .miss, last.beatIndex == nearest {
                feedback = assisted ? "接住了 · 等下个光点" : "这一拍已弹过"
            } else {
                feedback = assisted ? "慢慢来 · 接下个光点" : (progress.fraction < 0.5 ? "偏晚 · 跟下一拍" : "偏早 · 等光点到线")
            }
        }
        return false
    }

    private func show(_ event: RhythmJudgement) {
        if assisted && event.grade == .miss { return }
        combo = event.combo
        score += event.points
        bestCombo = max(bestCombo, combo)
        if event.grade == .miss {
            misses += 1
            feedback = "漏拍 · 接下一拍"
            if game.lastJudgement == event { performanceTouch(.directionDown) }
            return
        }
        hits += 1
        if assisted {
            feedback = hits.isMultiple(of: 4) ? "完成 \(hits) 次" : "接上了"
            performanceTouch(hits.isMultiple(of: 4) ? .success : .click)
            return
        }
        let label: String
        switch event.grade {
        case .perfect: label = "精准"
        case .good: label = "合拍"
        case .early: label = "偏早"
        case .late: label = "偏晚"
        case .miss: return
        }
        let ms = Int((abs(event.offset) * 1000).rounded())
        let timing = ms == 0 ? "正拍" : (event.offset < 0 ? "早" : "晚") + "\(ms) ms"
        feedback = combo.isMultiple(of: 8) ? "\(combo) 连击 · \(label)" : "\(label) · \(timing)"
        if combo.isMultiple(of: 8) { performanceTouch(.success) }
        else if event.grade == .late { performanceTouch(.directionUp) }
        else if event.grade == .early { performanceTouch(.directionDown) }
        else { performanceTouch(.click) }
    }

    func pause(_ message: String, notify: Bool) {
        beatHapticsActive = false
        guard phase != .ready && phase != .finished else { return }
        game.setPaused(true)
        phase = targetBeat == nil ? .ready : .paused
        feedback = message == "已暂停 · 点击继续" ? "已暂停" : message
        countdown = 0
        if notify { touch(.stop) }
    }

    func unavailable(_ message: String) {
        beatHapticsActive = false
        phase = .ready
        source = nil
        targetBeat = nil
        bpm = 0
        fraction = 0
        countdown = 0
        feedback = message
        touch(.retry)
    }

    func finish() {
        beatHapticsActive = false
        game.setPaused(true)
        phase = .finished
        countdown = 0
        feedback = assisted && hits > 0 ? "完成 \(hits) 次" : "本轮完成"
        touch(.success)
    }

    func tap(at time: TimeInterval) {
        source = .taps
        if let last = taps.last, !(0.27...1.5).contains(time - last) { taps.removeAll() }
        if taps.count == 4 { taps.removeAll() }
        taps.append(time)
        tapsTaken = taps.count
        manualBeat = nil
        touch(.click)
        guard taps.count == 4 else {
            feedback = "已点 \(taps.count)/4 拍"
            return
        }
        let gaps = zip(taps.dropFirst(), taps).map { $0.0 - $0.1 }.sorted()
        let period = gaps[1]
        guard gaps.last! - gaps.first! < period * 0.3 else {
            taps.removeAll()
            tapsTaken = 0
            feedback = "间隔不稳，请再点四拍"
            return
        }
        manualBeat = BeatEstimate(bpm: 60 / period, referenceBeat: time, confidence: 1)
        feedback = "已定拍 · \(Int((60 / period).rounded())) BPM"
    }

    func acceptsBeatHaptic(at scheduledTime: TimeInterval) -> Bool {
        phase == .playing && scheduledTime.isFinite && scheduledTime >= minTargetTime
    }

    func setBeatHapticsActive(_ active: Bool) {
        beatHapticsActive = active && haptics && beatHaptics
    }

    /// Playing feedback yields to the metronomic cue, rather than vibrating
    /// again for a strum, a streak or a missed target around that same beat.
    private func performanceTouch(_ kind: WKHapticType) {
        guard !beatHapticsActive else { return }
        touch(kind)
    }

    func playBeatHaptic() {
        let now = ProcessInfo.processInfo.systemUptime
        guard beatHapticsActive, haptics, beatHaptics,
              WKApplication.shared().applicationState == .active,
              now - lastTouch >= 0.1 else { return }
        lastTouch = now
        // This route needs the dedicated, short haptic artifact rejection;
        // ordinary gestures must remain usable on the target beat itself.
        willPlayBeatHaptic?()
        WKInterfaceDevice.current().play(.click)
    }

    /// Keep the timing cue when a free-play stroke and a beat would overlap.
    /// A stroke in the gap can still have its own light or accented feedback.
    func touchStroke(strength: Double, untilNextBeat: TimeInterval? = nil,
                     beforePlaying: ((WKHapticType) -> Void)? = nil) {
        if beatHapticsActive, let untilNextBeat, untilNextBeat < 0.18 { return }
        touch(strength >= SongPickVoice.accentThreshold ? .directionUp : .click, beforePlaying: beforePlaying)
    }

    func touch(_ kind: WKHapticType, beforePlaying: ((WKHapticType) -> Void)? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        guard haptics, WKApplication.shared().applicationState == .active,
              now - lastTouch >= 0.18 else { return }
        lastTouch = now
        (beforePlaying ?? willPlayHaptic)?(kind)
        WKInterfaceDevice.current().play(kind)
    }
}
