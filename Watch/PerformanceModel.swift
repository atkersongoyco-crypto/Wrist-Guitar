import AirGuitarCore
import AVFoundation
import Combine
import Foundation
import WatchKit

@MainActor
final class PerformanceModel: ObservableObject {
    @Published private(set) var song: WatchSong? = WatchSong.practice
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var chord: Chord = .c
    @Published private(set) var strength: Double = 0
    @Published private(set) var wristTurn: Double = 0
    @Published private(set) var calibration = WristCalibrationStore.load()
    @Published private(set) var automaticBacking = UserDefaults.standard.object(forKey: "AirGuitar.autoBacking") as? Bool ?? true
    @Published private(set) var strumCount = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var status = "点开始，轻挥一下"
    @Published private(set) var muted = false
    @Published private(set) var externalMusic = false
    @Published private(set) var assisted = UserDefaults.standard.object(forKey: "AirGuitar.assisted") as? Bool ?? true
    var feelTitle: String { assisted ? "轻松跟弹" : "精准控弦" }
    var instrumentLabel: String { assisted && muted ? "闷音" : chord.name }
    @Published private(set) var route = ""
    @Published var error: String?
    @Published var sensitivity: Sensitivity = .high {
        didSet { motion.setSensitivity(sensitivity) }
    }
    @Published var guitarVolume: Double = 0.65 {
        didSet { audio.guitarVolume = Float(guitarVolume) }
    }
    @Published var backingVolume: Double = 0.5 {
        didSet { audio.backingVolume = Float(backingVolume) }
    }

    private let audio = PerformanceAudio()
    private let motion = MotionDriver()
    let round = RhythmRound()
    private let capture = BeatCapture()
    private let freeBeatCapture = BeatCapture()
    private let harmony = LocalHarmonyGuide()
    private var tempoTask: Task<Void, Never>?
    private var cancelledTempoTask: Task<Void, Never>?
    private var freeTempoSegment: Int?
    private var beatHapticTask: Task<Void, Never>?
    private var beatHapticRunID = UUID()
    private var beatPulseCursor = BeatPulseCursor()
    private var sourceBeat: BeatEstimate?
    private var containsPractice = false
    private var playsExternalMusic = false
    private var playsFile = false
    private var lastAccent = -Double.infinity
    private var finishedFreeTrack = false
    private var startTask: Task<Void, Never>?
    private var runID = UUID()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        round.willPlayBeatHaptic = { [weak self] in
            guard let self, self.isRunning else { return }
            self.motion.prepareForBeatHaptic()
        }
        round.beatHapticPreferenceDidChange = { [weak self] in
            self?.refreshBeatHaptics()
        }
        round.willPlayHaptic = { [weak self] kind in
            guard let self, self.isRunning else { return }
            self.motion.suppressGestures(for: kind == .click ? 0.12 : 0.30)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in self?.pause(reason: "播放被打断，点击继续") }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in
                guard let self, self.isRunning || self.isStarting else { return }
                self.pause(reason: "音频输出已改变，点击继续")
            }
        })
    }

    func select(_ song: WatchSong?, external: Bool = false) {
        pause()
        round.reset()
        self.song = song
        externalMusic = external
        muted = assisted && external
        chord = .c
        elapsed = 0
        strumCount = 0
        finishedFreeTrack = false
        status = assisted ? "点开始，轻挥一下" : "转腕选和弦，点击开始"
        // Rewind even when reselecting the same song.
        audio.rewind()
    }

    func setAssisted(_ enabled: Bool) {
        guard enabled != assisted else { return }
        let performingFree = isRunning && round.phase == .ready
        if !performingFree {
            pause()
            round.reset()
        }
        round.assisted = enabled
        assisted = enabled
        muted = enabled && externalMusic
        UserDefaults.standard.set(enabled, forKey: "AirGuitar.assisted")
        audio.resetAssistance()
        if performingFree {
            motion.setAssisted(enabled)
            audio.setInstrumentMode(assisted: enabled)
            harmony.configure(url: playsFile && enabled && !containsPractice ? song?.url : nil)
            updateAssistedInstrument(at: audio.currentTime)
            if enabled { estimateFreeTempo() }
        } else { strumCount = 0 }
        status = enabled ? "轻挥一下，和弦自动跟上" : "转腕选和弦，挥动控制轻重"
        if performingFree { refreshBeatHaptics() }
    }

    func toggle() async {
        if isRunning { pause(); return }
        guard !isStarting else { return }
        if finishedFreeTrack || round.phase != .ready {
            strumCount = 0
            finishedFreeTrack = false
            audio.rewind()
        }
        round.reset()
        await scheduleStart(nil, resuming: false).value
    }

    func startChallenge(_ source: ChallengeSource) {
        guard !isRunning, !isStarting else { return }
        if source == .song, song == nil {
            round.unavailable("先在曲库选择一首伴奏")
            return
        }
        if source == .taps, round.manualBeat == nil {
            round.unavailable("请跟着音乐连续点四拍")
            return
        }
        audio.rewind()
        elapsed = 0
        strumCount = 0
        scheduleStart(source, resuming: false)
    }

    func resumeChallenge() {
        guard !isStarting, !isRunning, round.phase == .paused, let source = round.source else { return }
        scheduleStart(source, resuming: true)
    }

    @discardableResult
    private func scheduleStart(_ source: ChallengeSource?, resuming: Bool) -> Task<Void, Never> {
        let previous = startTask
        isStarting = true
        // A cancelled microphone activation may still be restoring the old audio
        // route. Never activate playback on top of its pending cleanup.
        let task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.start(source: source, resuming: resuming)
        }
        startTask = task
        return task
    }

    func tapTempo() {
        guard !isRunning && !isStarting else { return }
        round.tap(at: ProcessInfo.processInfo.systemUptime)
    }

    func resetChallenge() {
        pause()
        round.reset()
    }

    func finishChallenge() {
        pause(notify: false)
        round.finish()
    }

    private func start(source: ChallengeSource?, resuming: Bool) async {
        isStarting = true
        status = "正在准备音色和音频输出"
        let id = UUID()
        runID = id
        do {
            round.assisted = assisted
            let usesSelection = source == nil || source == .song
            playsFile = usesSelection && song != nil && (source == .song || automaticBacking)
            playsExternalMusic = !usesSelection || (!playsFile && (externalMusic || AVAudioSession.sharedInstance().isOtherAudioPlaying))
            containsPractice = false
            if usesSelection, let song {
                containsPractice = await Task.detached(priority: .utility) { song.matchesPracticeRecording() }.value
                try checkRun(id)
            }
            harmony.configure(url: self.playsFile && assisted && !containsPractice ? song?.url : nil)
            updateAssistedInstrument(at: audio.currentTime)
            if !resuming { sourceBeat = nil; freeTempoSegment = nil }
            if source == nil, playsFile, containsPractice {
                sourceBeat = BeatEstimate(bpm: 96, referenceBeat: 0, confidence: 1)
            }
            if let source, !resuming {
                round.listen(source)
                let estimate: BeatEstimate
                switch source {
                case .song:
                    guard let song else { throw CancellationError() }
                    if containsPractice {
                        estimate = BeatEstimate(bpm: 96, referenceBeat: 0, confidence: 1)
                    } else {
                        estimate = try await capture.analyzeFile(at: song.url)
                    }
                case .speaker:
                    estimate = try await capture.listenToSpeaker(seconds: 10)
                case .taps:
                    guard let manual = round.manualBeat else { throw CancellationError() }
                    estimate = manual
                }
                try checkRun(id)
                guard estimate.isValid, estimate.confidence >= RhythmGame.minimumConfidence else {
                    throw RhythmStartError.noBeat
                }
                sourceBeat = estimate
                round.use(estimate)
            }
            try await audio.activate(mixWithOtherMusic: !playsFile)
            guard runID == id else {
                audio.pause()
                return
            }
            try audio.prepare(song: usesSelection ? song : nil)
            if let source, let beat = sourceBeat {
                try audio.startInstruments()
                try await countIn(id: id, beat: beat, external: source != .song)
            }
            try checkRun(id)
            try audio.play(includingBacking: playsFile)
            isRunning = true
            isStarting = false
            if !assisted { chord = .c }
            updateAssistedInstrument(at: audio.currentTime)
            route = audio.routeName
            status = assisted ? "轻轻一挥，也可点屏幕" : "挥臂拨弦 · 转腕换和弦"
            if source == nil { estimateFreeTempo() }
            if let source {
                round.begin(at: challengeClock(source))
                if round.sounds { audio.cue(.go) }
            }
            if motion.isAvailable {
                motion.start(sensitivity: sensitivity, assisted: assisted, calibration: calibration, state: { [weak self] chord, strength in
                    guard let self, self.runID == id, self.isRunning else { return }
                    if !self.assisted { self.chord = chord }
                    let remaining = max(0, 1 - (ProcessInfo.processInfo.systemUptime - self.lastAccent) / 0.22)
                    self.strength = self.assisted ? max(strength, remaining) : strength
                }, strum: { [weak self] event in
                    guard let self, self.runID == id, self.isRunning else { return }
                    self.playStrum(event)
                }, failure: { [weak self] message in
                    guard let self, self.runID == id, self.isRunning else { return }
                    if self.assisted {
                        self.status = "轻点屏幕继续演奏"
                        return
                    }
                    self.pause(reason: "动作采集已停止")
                    self.error = message
                }, telemetry: { [weak self] reading in
                    guard let self, self.runID == id, self.isRunning else { return }
                    let dominant = abs(reading.gyroX) > abs(reading.gyroY) ? reading.gyroX : reading.gyroY
                    let axis = abs(dominant) > abs(reading.gyroZ) ? dominant : reading.gyroZ
                    let target = reading.gyroStrength * (axis < 0 ? -1 : 1)
                    self.wristTurn = self.wristTurn * 0.35 + target * 0.65
                })
            } else {
                status = "轻点屏幕演奏"
            }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: source == nil ? 0.2 : 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.runID == id, self.isRunning else { return }
                    if self.playsFile {
                        self.elapsed = self.audio.currentTime
                        self.updateAssistedInstrument(at: self.elapsed)
                    }
                    if self.playsFile, !self.audio.backingIsPlaying {
                        self.audio.rewind()
                        let completed = source == nil && self.assisted && self.strumCount > 0
                        let message = completed ? "乐段完成 · 拨弦 \(self.strumCount) 次" : "伴奏结束，点击重新演奏"
                        self.pause(reason: message, notify: source == nil)
                        self.finishedFreeTrack = source == nil
                        if completed { self.round.touch(.success) }
                        self.elapsed = 0
                        if source != nil { self.round.finish() }
                    } else if let source {
                        self.round.tick(at: self.challengeClock(source),
                                        audible: source != .song || self.audio.backingHasSignal())
                    } else {
                        self.estimateFreeTempo()
                    }
                }
            }
            refreshBeatHaptics()
        } catch {
            guard runID == id else { return }
            pause(reason: "启动失败，请重试")
            if source != nil { round.unavailable(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    private func checkRun(_ id: UUID) throws {
        guard runID == id, !Task.isCancelled else { throw CancellationError() }
    }

    func setAutomaticBacking(_ enabled: Bool) {
        guard enabled != automaticBacking, !isStarting else { return }
        if isRunning, song != nil, round.phase == .ready {
            do { try audio.setBackingPlaying(enabled) }
            catch { self.error = error.localizedDescription; return }
            playsFile = enabled
            if !enabled {
                cancelFreeTempoAnalysis()
                if !containsPractice { sourceBeat = nil }
            }
            playsExternalMusic = !enabled && AVAudioSession.sharedInstance().isOtherAudioPlaying
            harmony.configure(url: enabled && assisted && !containsPractice ? song?.url : nil)
            updateAssistedInstrument(at: audio.currentTime)
            if enabled { estimateFreeTempo() }
            status = enabled ? "伴奏播放中" : "只弹吉他"
        }
        automaticBacking = enabled
        UserDefaults.standard.set(enabled, forKey: "AirGuitar.autoBacking")
        refreshBeatHaptics()
    }

    private func estimateFreeTempo() {
        guard isRunning, playsFile, round.phase == .ready, !containsPractice,
              tempoTask == nil, let song,
              assisted || (round.haptics && round.beatHaptics) else { return }
        let segment = Int(max(0, audio.currentTime) / 12)
        guard segment != freeTempoSegment else { return }
        freeTempoSegment = segment
        // A new section must earn its own tempo evidence. Do not keep an old
        // intro/verse grid running over silence or a different musical tempo.
        sourceBeat = nil
        stopBeatHaptics()
        let start = min(Double(segment) * 12, max(0, song.duration - 8))
        let id = runID
        let previous = cancelledTempoTask
        cancelledTempoTask = nil
        tempoTask = Task { [weak self] in
            await previous?.value
            guard let self, self.runID == id, !Task.isCancelled else { return }
            let estimate = try? await self.freeBeatCapture.analyzeFile(at: song.url, maxSeconds: 12, startingAt: start)
            guard self.runID == id, !Task.isCancelled else { return }
            self.tempoTask = nil
            guard self.isRunning, self.playsFile, self.round.phase == .ready else { return }
            guard Int(max(0, self.audio.currentTime) / 12) == segment else {
                self.estimateFreeTempo()
                return
            }
            if let estimate, estimate.isValid, estimate.confidence >= RhythmGame.minimumConfidence {
                self.sourceBeat = estimate
            }
            self.refreshBeatHaptics()
        }
    }

    private func cancelFreeTempoAnalysis() {
        cancelledTempoTask = tempoTask ?? cancelledTempoTask
        tempoTask?.cancel()
        tempoTask = nil
        freeTempoSegment = nil
        freeBeatCapture.cancel()
    }

    private func stopBeatHaptics() {
        beatHapticRunID = UUID()
        beatHapticTask?.cancel()
        beatHapticTask = nil
        beatPulseCursor.reset()
        round.setBeatHapticsActive(false)
    }

    /// Sleep until the next file-clock/uptime target instead of polling at a
    /// higher display rate. Recheck the real playback clock after every wake;
    /// task delays never change musical phase or replay elapsed beats.
    private func refreshBeatHaptics() {
        stopBeatHaptics()
        guard isRunning, round.haptics, round.beatHaptics,
              WKApplication.shared().applicationState == .active else { return }
        if round.phase == .ready, playsFile { estimateFreeTempo() }
        let source: ChallengeSource?
        let beat: BeatEstimate
        if round.phase == .playing, let challengeSource = round.source, let target = round.targetBeat {
            source = challengeSource
            beat = target
        } else if round.phase == .ready, playsFile, let estimate = sourceBeat {
            source = nil
            beat = estimate
        } else {
            if round.phase == .ready { estimateFreeTempo() }
            return
        }
        beatPulseCursor.reset(beat: beat, startingAt: beatHapticClock(source))
        guard beatPulseCursor.nextBeatTime != nil else { return }
        round.setBeatHapticsActive(true)
        let id = beatHapticRunID
        beatHapticTask = Task { [weak self] in
            defer {
                if let self, self.beatHapticRunID == id {
                    self.beatHapticTask = nil
                    self.round.setBeatHapticsActive(false)
                }
            }
            while !Task.isCancelled {
                guard let self, self.isRunning, self.beatHapticRunID == id,
                      self.round.beatHapticsActive,
                      WKApplication.shared().applicationState == .active,
                      let next = self.beatPulseCursor.nextBeatTime else { return }
                let delay = min(2, max(0.004, next - self.beatHapticClock(source)))
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, self.isRunning, self.beatHapticRunID == id,
                      self.round.beatHapticsActive,
                      WKApplication.shared().applicationState == .active else { return }
                let time = self.beatHapticClock(source)
                if source == nil, !self.containsPractice,
                   Int(max(0, time) / 12) != self.freeTempoSegment {
                    self.estimateFreeTempo()
                    return
                }
                let audible = source == .speaker || source == .taps
                    || (self.playsFile && self.audio.backingIsPlaying && self.audio.backingHasSignal())
                if let due = self.beatPulseCursor.consume(at: time, isAudible: audible),
                   source == nil || self.round.acceptsBeatHaptic(at: due) {
                    self.round.playBeatHaptic()
                }
            }
        }
    }

    /// A short inactive interruption can stop the cue task without pausing
    /// playback. The app's scenePhase=.active calls this to rearm future beats.
    func resumeBeatHapticsIfNeeded() {
        if isRunning { refreshBeatHaptics() }
    }

    private func beatHapticClock(_ source: ChallengeSource?) -> TimeInterval {
        source == .speaker || source == .taps ? ProcessInfo.processInfo.systemUptime : audio.currentTime
    }

    func applyCalibration(_ profile: MotionCalibrationProfile?) {
        calibration = profile
        motion.setCalibration(profile)
        status = profile == nil ? "已恢复默认幅度" : "已保存你的挥动幅度"
    }

    private func countIn(id: UUID, beat: BeatEstimate, external: Bool) async throws {
        let now = ProcessInfo.processInfo.systemUptime
        var deadline = now
        if external {
            let next = ceil((now - beat.referenceBeat) / beat.period)
            deadline = beat.referenceBeat + next * beat.period
        }
        for n in (0...3).reversed() {
            let delay = deadline - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            try checkRun(id)
            if n > 0 {
                round.preparing(n)
                if round.sounds { audio.cue(.count) }
            }
            deadline += beat.period
        }
    }

    private func challengeClock(_ source: ChallengeSource) -> TimeInterval {
        source == .song ? audio.currentTime : ProcessInfo.processInfo.systemUptime
    }

    private func playStrum(_ event: StrumEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if assisted {
            lastAccent = now
            strength = 1
            let time = audio.currentTime
            let beat = playsFile ? sourceBeat.map {
                BeatCapture.anchorFileEstimate($0, playbackTime: time, uptime: now)
            } : (round.phase == .playing ? sourceBeat : nil)
            let phrase = audio.assistedStrum(event, source: assistedSource(at: time), beat: beat)
            if let label = phrase?.chord { chord = label }
            muted = phrase?.chord == nil
        } else {
            audio.strum(event)
            chord = event.chord
        }
        strumCount += 1
        if assisted, round.phase != .playing {
            status = strumCount.isMultiple(of: 4) ? "已跟上 \(strumCount) 次" : "接上了 · 再轻挥一次"
            if !round.beatHapticsActive { round.touch(strumCount.isMultiple(of: 4) ? .success : .click) }
        } else if !assisted && round.phase != .playing {
            if !round.beatHapticsActive { round.touch(.click) }
        }
        guard round.phase == .playing, let source = round.source else { return }
        let age = max(0, ProcessInfo.processInfo.systemUptime - event.timestamp)
        let clock = source == .song ? max(0, audio.currentTime - age) : event.timestamp
        if round.strum(at: clock, audible: source != .song || audio.backingHasSignal()), round.sounds {
            audio.cue(.streak)
        }
    }

    private func assistedSource(at time: Double) -> AssistedSource {
        if playsExternalMusic { return .unpitched }
        if !playsFile { return .freePlay }
        if containsPractice { return .originalDemo(playbackTime: time) }
        return harmony.chord(at: time).map(AssistedSource.detected) ?? .unpitched
    }

    private func updateAssistedInstrument(at time: Double) {
        guard assisted else { return }
        switch assistedSource(at: time) {
        case .originalDemo(let time):
            chord = AssistedPerformance.guidedChord(playbackTime: time)
            muted = false
        case .detected(let match):
            chord = match
            muted = false
        case .unpitched: muted = true
        case .freePlay: muted = false
        }
    }

    func pause(reason: String = "已暂停 · 点击继续", notify: Bool = true) {
        stopBeatHaptics()
        runID = UUID() // Discard stale motion deliveries and a pending route activation.
        startTask?.cancel()
        capture.cancel()
        cancelFreeTempoAnalysis()
        harmony.configure(url: nil)
        round.pause(reason, notify: notify)
        isRunning = false
        isStarting = false
        motion.stop()
        timer?.invalidate()
        timer = nil
        if !capture.isBusy { audio.pause() }
        lastAccent = -.infinity
        strength = 0
        wristTurn = 0
        status = reason
    }

    func rewind() {
        pause(reason: "已回到歌曲开头")
        round.reset()
        audio.rewind()
        elapsed = 0
        strumCount = 0
        finishedFreeTrack = false
        chord = .c
    }

    func calibrate() {
        motion.calibrate()
        chord = .c
        status = isRunning ? "已校准 · 转腕换和弦" : "开始时自动校准手腕"
    }

    func audition() {
        guard isRunning else { error = "请先在演奏页点击开始。"; return }
        playStrum(StrumEvent(timestamp: ProcessInfo.processInfo.systemUptime, chord: chord, velocity: 0.7))
    }
}

private enum RhythmStartError: LocalizedError {
    case noBeat
    var errorDescription: String? { "节拍不够稳定，请重新听拍，或跟音乐点四拍。" }
}
