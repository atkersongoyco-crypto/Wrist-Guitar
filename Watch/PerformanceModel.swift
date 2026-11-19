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
    @Published private(set) var lastPickStrength: Double?
    @Published private(set) var externalMusic = false
    @Published private(set) var assisted = UserDefaults.standard.object(forKey: "AirGuitar.assisted") as? Bool ?? true
    @Published var addsAssistedReply = UserDefaults.standard.object(forKey: "WristGuitar.listeningPhrases") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(addsAssistedReply, forKey: "WristGuitar.listeningPhrases")
            audio.addsAssistedReply = addsAssistedReply
        }
    }
    var feelTitle: String { assisted ? "轻松跟弹" : "精准控弦" }
    // Built-in aliases resolve to the same bundled recording. Every file in
    // the user's library directory retains the source-only gesture path.
    private var isImportedRecording = false
    private var playingRecording: Bool { playsFile && isImportedRecording }
    var usesRecordingControls: Bool {
        guard isImportedRecording else { return false }
        if isRunning || isStarting { return playsFile }
        return round.source == .song || (round.phase == .ready && automaticBacking)
    }
    var usesSongPick: Bool { assisted && automaticBacking && song != nil && round.phase == .ready }
    var instrumentLabel: String {
        if usesRecordingControls || usesSongPick {
            guard isRunning, let lastPickStrength else { return "拨奏" }
            return lastPickStrength >= SongPickVoice.accentThreshold ? "重拨" : "轻拨"
        }
        return assisted && muted ? "闷音" : chord.name
    }
    private var playingPrompt: String {
        if usesRecordingControls { return "轻挥，带出歌里的伴奏" }
        guard assisted else { return "挥臂拨弦 · 转腕换和弦" }
        if usesSongPick { return "轻挥拨单音，重挥更饱满" }
        return addsAssistedReply && round.phase == .ready ? "轻甩分解 · 利落扫弦" : "轻挥或点一下和弦"
    }
    @Published private(set) var route = ""
    @Published var error: String?
    @Published var sensitivity = UserDefaults.standard.string(forKey: "AirGuitar.sensitivity")
        .flatMap(Sensitivity.init(rawValue:)) ?? .high {
        didSet {
            UserDefaults.standard.set(sensitivity.rawValue, forKey: "AirGuitar.sensitivity")
            motion.setSensitivity(sensitivity)
            adaptiveMapper = AdaptiveStrokeDynamics()
        }
    }
    @Published var adaptiveDynamics = UserDefaults.standard.object(forKey: "WristGuitar.adaptiveDynamics") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(adaptiveDynamics, forKey: "WristGuitar.adaptiveDynamics")
            adaptiveMapper = AdaptiveStrokeDynamics()
        }
    }
    @Published var guitarVolume = UserDefaults.standard.object(forKey: "AirGuitar.guitarVolume") as? Double ?? 0.46 {
        didSet {
            audio.guitarVolume = Float(guitarVolume)
            UserDefaults.standard.set(guitarVolume, forKey: "AirGuitar.guitarVolume")
        }
    }
    @Published var backingVolume: Double = 0.5 {
        didSet { audio.backingVolume = Float(backingVolume) }
    }
    private static let masterVolumeKey = "WristGuitar.masterVolume"
    @Published var masterVolume: Double {
        didSet {
            if !masterVolume.isFinite { masterVolume = oldValue }
            else if !(0...1).contains(masterVolume) { masterVolume = min(1, max(0, masterVolume)) }
            guard masterVolume != oldValue else { return }
            audio.masterVolume = Float(masterVolume)
            UserDefaults.standard.set(masterVolume, forKey: Self.masterVolumeKey)
        }
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
    private var containsPractice: Bool { song != nil && !isImportedRecording }
    private var playsExternalMusic = false
    private var playsFile = false
    private var finishedFreeTrack = false
    private var startTask: Task<Void, Never>?
    private var runID = UUID()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var sceneIsActive = WKApplication.shared().applicationState == .active
    private var isInBackground = false
    private var continuingBackingInBackground = false
    private var scenePausedChallenge = false
    private var playbackStoppedAt: TimeInterval?
    private var motionNeedsRestart = false
    private var adaptiveMapper = AdaptiveStrokeDynamics()
    private var recordingMotion = RecordingMotionFollow()
    private var calibrationAuditionID: UUID?
    private var calibrationAuditionReady = false

    init() {
        let savedVolume = UserDefaults.standard.object(forKey: Self.masterVolumeKey) as? Double ?? 1
        masterVolume = savedVolume.isFinite ? min(1, max(0, savedVolume)) : 1
        audio.masterVolume = Float(masterVolume)
        audio.guitarVolume = Float(guitarVolume)
        audio.addsAssistedReply = addsAssistedReply
        audio.backingCompletionChanged = { [weak self] in
            guard let self, self.isRunning else { return }
            _ = self.handleBackingCompletion(source: self.round.source)
        }
        round.willPlayBeatHaptic = { [weak self] in
            guard let self, self.isRunning else { return }
            self.recordingMotion.ignoreHaptic(at: ProcessInfo.processInfo.systemUptime, duration: 0.12)
            self.motion.prepareForBeatHaptic()
        }
        round.beatHapticPreferenceDidChange = { [weak self] in
            self?.refreshBeatHaptics()
        }
        round.willPlayHaptic = { [weak self] kind in
            guard let self, self.isRunning else { return }
            let duration = kind == .click ? 0.12 : 0.30
            self.recordingMotion.ignoreHaptic(at: ProcessInfo.processInfo.systemUptime, duration: duration)
            self.motion.suppressGestures(for: duration)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in
                guard let self else { return }
                self.endCalibrationAudition()
                guard self.isRunning || self.isStarting else { return }
                self.pause(reason: "播放被打断，点击继续")
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let lostDevice = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable
            Task { @MainActor in
                guard let self else { return }
                self.audio.refreshOutputRoute()
                guard lostDevice else { return }
                self.endCalibrationAudition()
                guard self.isRunning || self.isStarting else { return }
                self.pause(reason: "音频输出已改变，点击继续")
            }
        })
    }

    func select(_ song: WatchSong?, external: Bool = false) {
        pause()
        round.reset()
        isImportedRecording = song.map { $0.url != WatchSong.practice?.url } ?? false
        self.song = song
        externalMusic = external
        muted = assisted && external
        chord = .c
        elapsed = 0
        strumCount = 0
        finishedFreeTrack = false
        status = assisted || usesRecordingControls ? "点开始，轻挥一下" : "转腕选和弦，点击开始"
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
            if !playingRecording { audio.setInstrumentMode(assisted: enabled) }
            configureSongVoicing(freePlay: true)
            updateAssistedInstrument(at: audio.currentTime)
            if enabled { estimateFreeTempo() }
        } else { strumCount = 0 }
        status = playingPrompt
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
        endCalibrationAudition()
        adaptiveMapper = AdaptiveStrokeDynamics()
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
            configureSongVoicing(freePlay: source == nil)
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
            try audio.prepare(song: usesSelection ? song : nil, followsRecording: usesSelection && isImportedRecording)
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
            status = playingPrompt
            if source == nil { estimateFreeTempo() }
            if let source {
                round.begin(at: challengeClock(source))
                if round.sounds && !playingRecording { audio.cue(.go) }
            }
            if !sceneIsActive, round.phase == .playing {
                scenePausedChallenge = true
                round.pause("抬腕后接着跟拍", notify: false)
            }
            startMotion(for: id)
            installPerformanceTimer(source: source)
            refreshBeatHaptics()
        } catch {
            guard runID == id else { return }
            pause(reason: "启动失败，请重试")
            if source != nil { round.unavailable(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    private func startMotion(for id: UUID) {
        recordingMotion = RecordingMotionFollow()
        motionNeedsRestart = false
        if motion.isAvailable {
            motion.start(sensitivity: sensitivity, assisted: assisted, calibration: calibration,
                         allowsWristReversals: usesSongPick && playsFile, state: { [weak self] chord, strength in
                guard let self, self.runID == id, self.isRunning, !self.isInBackground else { return }
                if !self.assisted && !self.playingRecording { self.chord = chord }
                guard self.sceneIsActive else { return }
                self.strength = strength
            }, strum: { [weak self] event in
                guard let self, self.runID == id, self.isRunning, !self.isInBackground else { return }
                self.playStrum(event)
            }, failure: { [weak self] message in
                guard let self, self.runID == id, self.isRunning, !self.isInBackground else { return }
                self.motionNeedsRestart = true
                self.status = "可轻点屏幕继续演奏"
                self.strength = 0
                self.wristTurn = 0
            }, telemetry: { [weak self] reading in
                guard let self, self.runID == id, self.isRunning, !self.isInBackground else { return }
                if self.playingRecording, self.recordingMotion.follows(reading, profile: self.calibration,
                                                                      now: ProcessInfo.processInfo.systemUptime) {
                    self.audio.continueRecordingMotion()
                }
                guard self.sceneIsActive else { return }
                let dominant = abs(reading.gyroX) > abs(reading.gyroY) ? reading.gyroX : reading.gyroY
                let axis = abs(dominant) > abs(reading.gyroZ) ? dominant : reading.gyroZ
                let target = reading.gyroStrength * (axis < 0 ? -1 : 1)
                self.wristTurn = self.wristTurn * 0.35 + target * 0.65
            })
        } else {
            motionNeedsRestart = true
            status = "轻点屏幕演奏"
        }
    }

    private func installPerformanceTimer(source: ChallengeSource?) {
        timer?.invalidate()
        timer = nil
        playbackStoppedAt = nil
        guard !isInBackground, isRunning else { return }
        let id = runID
        if !sceneIsActive {
            // A lowered wrist can still play while the app is frontmost. Keep
            // the song material ready without refreshing the screen or score.
            guard usesSongPick && playsFile && containsPractice else { return }
            let prefetchTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.runID == id, self.isRunning, !self.isInBackground else { return }
                    self.harmony.warm(at: self.audio.currentTime)
                }
            }
            timer = prefetchTimer
            RunLoop.main.add(prefetchTimer, forMode: .common)
            return
        }
        let timer = Timer(timeInterval: source == nil ? 0.2 : 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.runID == id, self.isRunning,
                      self.sceneIsActive, !self.isInBackground else { return }
                if self.playsFile {
                    self.elapsed = self.audio.currentTime
                    self.updateAssistedInstrument(at: self.elapsed)
                }
                if self.handleBackingCompletion(source: source) { return }
                if !self.audio.instrumentsAreRunning || (self.playsFile && !self.audio.backingIsPlaying) {
                    let now = ProcessInfo.processInfo.systemUptime
                    if let since = self.playbackStoppedAt, now - since >= 0.5 {
                        // isPlaying=false can mean interruption, not end of song.
                        // Preserve the file position and the round for user resume.
                        self.pause(reason: "音频已暂停，点击继续", notify: false)
                    } else if self.playbackStoppedAt == nil { self.playbackStoppedAt = now }
                    return
                }
                self.playbackStoppedAt = nil
                if let source {
                    self.round.tick(at: self.challengeClock(source),
                                    audible: source != .song || self.audio.backingHasSignal())
                } else { self.estimateFreeTempo() }
            }
        }
        timer.tolerance = source == nil ? 0.04 : 0.004
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @discardableResult
    private func handleBackingCompletion(source: ChallengeSource?) -> Bool {
        guard playsFile else { return false }
        if audio.backingFinishedNaturally {
            let completed = source == nil && assisted && strumCount > 0
            let message = completed ? "乐段完成 · 拨弦 \(strumCount) 次" : "伴奏结束，点击重新演奏"
            pause(reason: message, notify: false)
            audio.rewind()
            finishedFreeTrack = source == nil
            elapsed = 0
            if source != nil { round.finish() }
            return true
        }
        if audio.backingPlaybackFailed {
            pause(reason: "伴奏播放中断，点击重试", notify: false)
            return true
        }
        return false
    }

    /// A dimmed, frontmost watch can still be strummed. Suppress display-only
    /// updates and scoring while the visual target is not available.
    func sceneWillResignActive() {
        sceneIsActive = false
        installPerformanceTimer(source: round.source)
        stopBeatHaptics()
        if isRunning, round.phase == .playing {
            scenePausedChallenge = true
            round.pause("抬腕后接着跟拍", notify: false)
        }
    }

    func sceneDidEnterBackground() {
        recordingMotion = RecordingMotionFollow()
        sceneIsActive = false
        isInBackground = true
        endCalibrationAudition()
        guard isRunning || isStarting else { return }
        if handleBackingCompletion(source: round.source) { return }
        guard isRunning, playsFile, audio.canContinueBackingInBackground else {
            pause(reason: "回到前台后，点击继续", notify: false)
            return
        }
        continuingBackingInBackground = true
        runID = UUID() // Retire queued motion/UI work while preserving file playback.
        timer?.invalidate()
        timer = nil
        stopBeatHaptics()
        motion.stop()
        motionNeedsRestart = true
        capture.cancel()
        cancelFreeTempoAnalysis()
        harmony.configure(url: nil)
        audio.setSongPickSource(nil)
        if round.phase == .playing {
            scenePausedChallenge = true
            round.pause("伴奏继续播放，抬腕后接着跟拍", notify: false)
        }
        audio.suspendInstrumentsForBackground()
        strength = 0
        wristTurn = 0
        status = "伴奏继续播放，抬腕后接着弹"
    }

    func sceneDidBecomeActive() {
        sceneIsActive = true
        isInBackground = false
        guard isRunning else {
            continuingBackingInBackground = false
            scenePausedChallenge = false
            return
        }
        let source = round.source
        if handleBackingCompletion(source: source) { return }
        if continuingBackingInBackground, !audio.backingIsPlaying {
            pause(reason: "伴奏已暂停，点击继续", notify: false)
            return
        }
        continuingBackingInBackground = false
        do { try audio.startInstruments() }
        catch {
            pause(reason: "音频暂不可用，点击继续", notify: false)
            self.error = error.localizedDescription
            return
        }
        if motionNeedsRestart {
            cancelFreeTempoAnalysis()
            runID = UUID()
            startMotion(for: runID)
        }
        if playsFile {
            elapsed = audio.currentTime
            configureSongVoicing(freePlay: source == nil)
            updateAssistedInstrument(at: elapsed)
        }
        if scenePausedChallenge, round.phase == .paused, let source {
            round.begin(at: challengeClock(source))
        }
        scenePausedChallenge = false
        installPerformanceTimer(source: source)
        refreshBeatHaptics()
        status = playingPrompt
    }

    private func checkRun(_ id: UUID) throws {
        guard runID == id, !Task.isCancelled, !isInBackground else { throw CancellationError() }
    }

    func setAutomaticBacking(_ enabled: Bool) {
        guard enabled != automaticBacking, !isStarting else { return }
        if enabled, isRunning, song != nil, round.phase == .ready, !audio.hasLongFormPlaybackSession {
            // Moving from external/instrument playback to a real local file
            // needs the same long-form route activation as a normal start.
            // Preserve position/counts and let existing start cancellation win.
            pause(reason: "正在开启伴奏", notify: false)
            automaticBacking = true
            UserDefaults.standard.set(true, forKey: "AirGuitar.autoBacking")
            scheduleStart(nil, resuming: false)
            return
        }
        if isRunning, song != nil, round.phase == .ready {
            do { try audio.setBackingPlaying(enabled) }
            catch { self.error = error.localizedDescription; return }
            playsFile = enabled
            if !enabled {
                cancelFreeTempoAnalysis()
                if !containsPractice { sourceBeat = nil }
            }
            playsExternalMusic = !enabled && AVAudioSession.sharedInstance().isOtherAudioPlaying
            automaticBacking = enabled
            configureSongVoicing(freePlay: true)
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
              round.haptics && round.beatHaptics else { return }
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
            let guide = try? await self.freeBeatCapture.analyzeFileRhythm(at: song.url, maxSeconds: 14, startingAt: start)
            guard self.runID == id, !Task.isCancelled else { return }
            self.tempoTask = nil
            guard self.isRunning, self.playsFile, self.round.phase == .ready else { return }
            guard Int(max(0, self.audio.currentTime) / 12) == segment else {
                self.estimateFreeTempo()
                return
            }
            self.sourceBeat = guide?.beat
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
        adaptiveMapper = AdaptiveStrokeDynamics()
        calibration = profile
        motion.setCalibration(profile)
        status = profile == nil ? "默认挥幅 · 点播放试弹" : "挥幅已保存 · 点播放试弹"
    }

    /// Share the graph and audio route with the performance player. Queuing
    /// activation also lets cancelled microphone or route work finish first.
    func beginCalibrationAudition() async throws {
        try Task.checkCancellation()
        guard !isRunning, !isStarting, !isInBackground else { throw CancellationError() }
        guard guitarVolume > 0 else { throw CalibrationAudioError.muted }
        endCalibrationAudition()
        let id = UUID()
        calibrationAuditionID = id
        let previous = startTask
        let activation = Task {
            await previous?.value
            try Task.checkCancellation()
            guard calibrationAuditionID == id else { throw CancellationError() }
            do {
                try await audio.activate(mixWithOtherMusic: AVAudioSession.sharedInstance().isOtherAudioPlaying)
                try Task.checkCancellation()
                guard calibrationAuditionID == id else { throw CancellationError() }
                try audio.prepareInstruments()
                try audio.startInstruments()
                calibrationAuditionReady = true
            } catch {
                // The next activation waits on this task, so its route cannot
                // be torn down by a late callback from this one.
                audio.pause()
                if calibrationAuditionID == id { calibrationAuditionID = nil }
                throw error
            }
        }
        startTask = Task { _ = await activation.result }
        try await withTaskCancellationHandler {
            try await activation.value
        } onCancel: {
            activation.cancel()
        }
    }

    func playCalibrationStroke(_ event: StrumEvent, onHaptic: ((WKHapticType) -> Void)? = nil) -> Bool {
        guard calibrationAuditionReady, !isInBackground, audio.playCalibrationPick(strength: event.pickStrength) else { return false }
        round.touchStroke(strength: event.pickStrength, beforePlaying: onHaptic)
        return true
    }

    func endCalibrationAudition() {
        guard calibrationAuditionID != nil else { return }
        calibrationAuditionID = nil
        if calibrationAuditionReady {
            calibrationAuditionReady = false
            audio.pause()
        }
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

    private func playStrum(_ detected: StrumEvent, fromWrist: Bool = true) {
        let now = ProcessInfo.processInfo.systemUptime
        var articulation = "已拨弦"
        guard guitarVolume > 0 || playingRecording else {
            status = "演奏音量为零 · 在「更多」调整"
            return
        }
        var nextMapper = adaptiveMapper
        let event = fromWrist && adaptiveDynamics ? nextMapper.adjusted(detected) : detected
        if playingRecording {
            // Both wrist and touch play the accompaniment at this position. A
            // silent passage still accepts the gesture for feedback and score.
            guard audio.strokeRecording(strength: event.pickStrength) else { return }
            if fromWrist { recordingMotion.acceptWrist(at: now) }
            else { recordingMotion = RecordingMotionFollow() }
            lastPickStrength = event.pickStrength
            articulation = instrumentLabel
        } else if usesSongPick && playsFile {
            let time = audio.currentTime
            let force = event.pickStrength
            var context = harmony.pick(at: time, strength: force)
            context.use(chord: AssistedPerformance.guidedChord(playbackTime: time), strength: force)
            guard audio.playSongPick(strength: force, context: context) else {
                pause(reason: "拨奏声音未就绪 · 点播放重试", notify: false)
                return
            }
            lastPickStrength = force
            articulation = instrumentLabel
        } else if assisted {
            let time = audio.currentTime
            let beat = playsFile ? sourceBeat.map {
                BeatCapture.anchorFileEstimate($0, playbackTime: time, uptime: now)
            } : (round.phase == .playing ? sourceBeat : nil)
            let listening = round.phase == .ready && addsAssistedReply
            guard let phrase = audio.assistedStrum(event, source: assistedSource(at: time), beat: beat,
                                                   listening: listening) else {
                pause(reason: "吉他声音未就绪 · 点播放重试", notify: false)
                return
            }
            if let label = phrase.chord { chord = label }
            muted = phrase.chord == nil
            if listening { articulation = muted ? "闷音" : (phrase.isArpeggio ? "分解和弦" : "扫弦") }
        } else {
            guard audio.strum(event) else {
                pause(reason: "吉他声音未就绪 · 点播放重试", notify: false)
                return
            }
            chord = event.chord
        }
        adaptiveMapper = nextMapper
        strumCount += 1
        if sceneIsActive, round.phase == .ready, !playingRecording { status = "\(articulation) · \(strumCount) 次" }
        if round.phase == .ready {
            let untilBeat = beatPulseCursor.nextBeatTime.map { $0 - audio.currentTime }
            round.touchStroke(strength: event.pickStrength, untilNextBeat: untilBeat) { [weak self] kind in
                guard let self else { return }
                let window = kind == .click ? 0.12 : 0.18
                self.recordingMotion.ignoreHaptic(at: ProcessInfo.processInfo.systemUptime, duration: window)
                if fromWrist { self.motion.prepareForBeatHaptic(window: window) }
                else { self.motion.suppressGestures(for: window) }
            }
        }
        guard round.phase == .playing, let source = round.source else { return }
        let age = max(0, ProcessInfo.processInfo.systemUptime - event.timestamp)
        let clock = source == .song ? max(0, audio.currentTime - age) : event.timestamp
        if round.strum(at: clock, audible: source != .song || audio.backingHasSignal()), round.sounds, !playingRecording {
            audio.cue(.streak)
        }
    }

    private func assistedSource(at time: Double) -> AssistedSource {
        if playsExternalMusic { return .unpitched }
        if !playsFile { return .freePlay }
        if containsPractice { return .originalDemo(playbackTime: time) }
        return .unpitched
    }

    private func configureSongVoicing(freePlay: Bool) {
        recordingMotion = RecordingMotionFollow()
        let practiceURL = freePlay && assisted && playsFile && containsPractice ? song?.url : nil
        audio.setSongPickSource(practiceURL)
        motion.setWristReversals(freePlay && assisted && playsFile)
        harmony.configure(url: practiceURL)
        if practiceURL != nil { harmony.warm(at: audio.currentTime) }
        lastPickStrength = nil
    }

    private func updateAssistedInstrument(at time: Double) {
        if playingRecording {
            muted = false
            return
        }
        guard assisted else { return }
        if usesSongPick && playsFile {
            harmony.warm(at: time)
            muted = false
            return
        }
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
        recordingMotion = RecordingMotionFollow()
        endCalibrationAudition()
        continuingBackingInBackground = false
        scenePausedChallenge = false
        playbackStoppedAt = nil
        stopBeatHaptics()
        runID = UUID() // Discard stale motion deliveries and a pending route activation.
        startTask?.cancel()
        capture.cancel()
        cancelFreeTempoAnalysis()
        harmony.configure(url: nil)
        audio.setSongPickSource(nil)
        lastPickStrength = nil
        round.pause(reason, notify: notify)
        isRunning = false
        isStarting = false
        motion.stop()
        timer?.invalidate()
        timer = nil
        if !capture.isBusy { audio.pause() }
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
        status = isRunning ? (usesRecordingControls ? "已校准 · 挥腕跟拍" : "已校准 · 转腕换和弦") : "开始时自动校准手腕"
    }

    func audition() {
        guard isRunning else { error = "请先在演奏页点击开始。"; return }
        playStrum(StrumEvent(timestamp: ProcessInfo.processInfo.systemUptime, chord: chord, velocity: 0.7),
                  fromWrist: false)
    }
}

/// Only a detected wrist stroke can open this short window. Directionally
/// consistent movement can then hold the phrase through a slower sweep. Touch,
/// a delayed telemetry delivery or a haptic by itself cannot open the window.
private struct RecordingMotionFollow {
    private var allowedUntil = -Double.infinity
    private var maskedUntil = -Double.infinity
    private var previous: MotionTelemetry?
    private var coherentSince = 0.0

    mutating func acceptWrist(at time: Double) {
        allowedUntil = time + 0.38
        maskedUntil = max(maskedUntil, time)
        previous = nil
    }

    mutating func ignoreHaptic(at time: Double, duration: Double) {
        maskedUntil = max(maskedUntil, time + duration)
        previous = nil
    }

    mutating func follows(_ sample: MotionTelemetry, profile: MotionCalibrationProfile?, now: Double) -> Bool {
        let t = sample.timestamp
        let armOnly = profile?.usesRotation == false
        guard t <= allowedUntil, t >= maskedUntil, now >= t, now - t <= 0.16,
              sample.strength >= 0.48,
              armOnly ? sample.accelerationMagnitude >= max(0.065, (profile?.quietAcceleration ?? 0) * 3)
                      : sample.gyroMagnitude >= max(0.30, (profile?.quietRotation ?? 0) * 3) && sample.gyroStrength >= 0.45
        else { previous = nil; return false }
        let prior = previous
        previous = sample
        guard let prior, (0.024...0.105).contains(t - prior.timestamp) else {
            coherentSince = t
            return false
        }
        if armOnly {
            // Telemetry carries arm magnitude only. Demand a longer sustained
            // trace for an arm-only calibration so a single impact cannot hold.
            guard t - coherentSince >= 0.10 else { return false }
        } else {
            let dot = sample.gyroX * prior.gyroX + sample.gyroY * prior.gyroY + sample.gyroZ * prior.gyroZ
            guard dot >= 0.72 * sample.gyroMagnitude * prior.gyroMagnitude else { return false }
        }
        allowedUntil = t + 0.38
        return true
    }
}

private enum CalibrationAudioError: LocalizedError {
    case muted
    var errorDescription: String? { "演奏音量为零。可在「更多」调高吉他音量后试听。" }
}

private enum RhythmStartError: LocalizedError {
    case noBeat
    var errorDescription: String? { "节拍不够稳定，请重新听拍，或跟音乐点四拍。" }
}
