import AirGuitarCore
import AVFoundation
import Darwin
import Foundation

/// A completion belongs to one play request, never to an older song/resume.
struct BackingPlaybackCompletion {
    enum Outcome { case none, finished, failed }
    private var request: UUID?
    private(set) var outcome: Outcome = .none

    mutating func begin() -> UUID {
        let id = UUID()
        request = id
        outcome = .none
        return id
    }
    mutating func cancel() { request = nil; outcome = .none }
    @discardableResult mutating func complete(_ id: UUID, successfully: Bool) -> Bool {
        guard request == id else { return false }
        request = nil
        outcome = successfully ? .finished : .failed
        return true
    }
}

private final class BackingCompletionDelegate: NSObject, AVAudioPlayerDelegate {
    private let request: UUID
    private let completion: (UUID, Bool) -> Void
    init(request: UUID, completion: @escaping (UUID, Bool) -> Void) {
        self.request = request
        self.completion = completion
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        completion(request, flag)
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        completion(request, false)
    }
}

@MainActor
final class PerformanceAudio {
    private let engine = AVAudioEngine()
    private var nodes: [AVAudioPlayerNode] = []
    private var buffers: [Chord: AVAudioPCMBuffer] = [:]
    private var nextVoice = 0
    private var recording: RecordingPlayer?
    private var backing: AVAudioPlayer?
    private var backingCompletion = BackingPlaybackCompletion()
    private var backingDelegate: BackingCompletionDelegate?
    private var loadedSongID: UUID?
    private var prepared = false
    private var longFormSessionActive = false
    private let cueNode = AVAudioPlayerNode()
    private var cueBuffers: [RhythmCue: AVAudioPCMBuffer] = [:]
    private let assistedLeadNode = AVAudioPlayerNode()
    private let assistedReplyNodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private var assistedBuffers: [AssistedVoice: AVAudioPCMBuffer] = [:]
    private let songPick = SongPickVoice()
    private let songPickNode = AVAudioPlayerNode()
    private var songPickURL: URL?
    private var pickReferenceGain: Float = 0
    private var pickPeak: Float = 1
    private var usesWatchSpeaker = false
    private var assistance = AssistedPerformance()
    var addsAssistedReply = false {
        didSet { if prepared && !addsAssistedReply { assistedReplyNodes.forEach { $0.stop() } } }
    }
    var backingCompletionChanged: (() -> Void)?
    private enum InstrumentMode {
        case manual, assisted, songPick

        var mixGain: Float {
            switch self {
            case .manual: return 0.1
            case .assisted: return 0.26
            case .songPick: return 1
            }
        }
    }
    private var instrumentMode = InstrumentMode.manual
    var masterVolume: Float = 1 {
        didSet {
            backing?.volume = backingOutputVolume
            recording?.volume = backingOutputVolume
            if masterVolume <= 0 { recording?.clearStroke() }
            if prepared { engine.mainMixerNode.outputVolume = instrumentMode.mixGain * masterVolume }
        }
    }
    var guitarVolume: Float = 0.46 {
        didSet {
            if boundedGuitarVolume == 0 { recording?.clearStroke() }
            if prepared {
                songPickNode.volume = songPickGain
                if boundedGuitarVolume == 0 { songPickNode.stop() }
            }
        }
    }
    var backingVolume: Float = 0.5 {
        didSet {
            backing?.volume = backingOutputVolume
            recording?.volume = backingOutputVolume
            if backingOutputVolume <= 0 { recording?.clearStroke() }
            if prepared { songPickNode.volume = songPickGain }
        }
    }

    private var boundedGuitarVolume: Float { guitarVolume.isFinite ? min(1, max(0, guitarVolume)) : 0 }
    private var boundedBackingVolume: Float { backingVolume.isFinite ? min(1, max(0, backingVolume)) : 0 }
    private var backingOutputVolume: Float { boundedBackingVolume * 0.5 * masterVolume }
    private var songPickGain: Float {
        let headroom = (0.90 - 0.5 * boundedBackingVolume) / max(0.001, pickPeak)
        return min(1, headroom, pickReferenceGain * boundedGuitarVolume / 0.46)
    }

    var currentTime: Double { recording?.currentTime ?? backing?.currentTime ?? 0 }
    var duration: Double { recording?.duration ?? backing?.duration ?? 0 }
    var backingIsPlaying: Bool { recording?.isPlaying ?? backing?.isPlaying ?? false }
    var backingFinishedNaturally: Bool { backingCompletion.outcome == .finished }
    var backingPlaybackFailed: Bool { backingCompletion.outcome == .failed }
    var instrumentsAreRunning: Bool { engine.isRunning || recording?.isPlaying == true }
    var hasLongFormPlaybackSession: Bool { longFormSessionActive }
    var canContinueBackingInBackground: Bool { backingIsPlaying && longFormSessionActive }
    func backingHasSignal() -> Bool {
        if let recording { return recording.hasSignal }
        guard let backing, backing.isPlaying else { return false }
        backing.updateMeters()
        return (0..<backing.numberOfChannels).contains { backing.peakPower(forChannel: $0) > -48 }
    }
    private var assistedMixGain: Float {
        guard let backing, backing.isPlaying, boundedBackingVolume > 0 else { return boundedGuitarVolume }
        backing.updateMeters()
        let level = (0..<backing.numberOfChannels).map { backing.averagePower(forChannel: $0) }.max() ?? -18
        return boundedGuitarVolume * Float(AssistedPerformance.backingBlend(averagePowerDB: Double(level)))
    }
    var routeName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: " · ")
    }

    func refreshOutputRoute() {
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
        usesWatchSpeaker = !ports.isEmpty && ports.allSatisfy { $0.portType == .builtInSpeaker }
    }

    func prepareInstruments() throws {
        if !prepared {
            songPick.prepare()
            let assistedRate = AssistedSoundRenderer.watchSampleRate
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
                  let assistedFormat = AVAudioFormat(standardFormatWithSampleRate: Double(assistedRate), channels: 1),
                  let pickFormat = AVAudioFormat(standardFormatWithSampleRate: SongPickVoice.sampleRate, channels: 2)
                else { throw PlaybackError.engine }
            // Wrist control remains C/Am/F/G. Do not allocate 24 long tails
            // when imported harmony uses the much smaller assisted bank.
            for chord in Chord.manualVoicings {
                let samples = PluckedStringRenderer.render(chord: chord)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else { throw PlaybackError.engine }
                buffer.frameLength = buffer.frameCapacity
                samples.withUnsafeBufferPointer { pointer in
                    if let base = pointer.baseAddress { channel.update(from: base, count: samples.count) }
                }
                buffers[chord] = buffer
            }
            for voice in AssistedVoice.allVoices {
                let samples = AssistedSoundRenderer.render(voice: voice, sampleRate: assistedRate)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: assistedFormat,
                                                    frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else { throw PlaybackError.engine }
                buffer.frameLength = buffer.frameCapacity
                samples.withUnsafeBufferPointer { pointer in
                    if let base = pointer.baseAddress { channel.update(from: base, count: samples.count) }
                }
                assistedBuffers[voice] = buffer
            }
            // Fixed voice pool permits overlapping chord tails without unbounded allocations.
            for _ in 0..<6 {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                nodes.append(node)
            }
            engine.attach(cueNode)
            engine.connect(cueNode, to: engine.mainMixerNode, format: format)
            engine.attach(assistedLeadNode)
            engine.connect(assistedLeadNode, to: engine.mainMixerNode, format: assistedFormat)
            engine.attach(songPickNode)
            engine.connect(songPickNode, to: engine.mainMixerNode, format: pickFormat)
            songPickNode.volume = songPickGain
            for node in assistedReplyNodes {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: assistedFormat)
            }
            for cue in RhythmCue.allCases {
                let count = AVAudioFrameCount(format.sampleRate * cue.duration)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                      let channel = buffer.floatChannelData?[0] else { throw PlaybackError.engine }
                buffer.frameLength = count
                for i in 0..<Int(count) {
                    let t = Double(i) / format.sampleRate
                    let envelope = min(1, t / 0.004) * pow(1 - t / cue.duration, 3)
                    channel[i] = Float(0.48 * envelope * sin(2 * .pi * cue.frequency * t))
                }
                cueBuffers[cue] = buffer
            }
            // Manual mode has six overlapping voices. The listening instrument
            // has its own mixer gain and a bounded three-note phrase.
            engine.mainMixerNode.outputVolume = instrumentMode.mixGain * masterVolume
            engine.prepare()
            prepared = true
        }
    }

    func prepare(song: WatchSong?, followsRecording: Bool = false) throws {
        let useRecording = song != nil && followsRecording
        if !useRecording { try prepareInstruments() }
        guard loadedSongID != song?.id || (recording != nil) != useRecording else { return }
        resetAssistance()
        cancelBackingCompletion()
        recording?.pause()
        recording = nil
        backing?.stop()
        backing = nil
        loadedSongID = nil
        if let song {
            if useRecording {
                let player = try RecordingPlayer(url: song.url)
                player.volume = backingOutputVolume
                recording = player
            } else {
                let player = try AVAudioPlayer(contentsOf: song.url)
                player.volume = backingOutputVolume
                player.isMeteringEnabled = true
                player.prepareToPlay()
                backing = player
            }
            loadedSongID = song.id
        }
    }

    func activate(mixWithOtherMusic: Bool) async throws {
        longFormSessionActive = false
        let session = AVAudioSession.sharedInstance()
        // For external accompaniment the existing player owns the music route.
        // Only our instrument and cues should be added to it.
        if mixWithOtherMusic {
            try session.setCategory(.playback, mode: .default, policy: .default, options: [.mixWithOthers])
        } else {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.activate(options: []) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: PlaybackError.route) }
            }
        }
        longFormSessionActive = !mixWithOtherMusic
        refreshOutputRoute()
    }

    func startInstruments() throws {
        if recording?.isPlaying == true {
            refreshOutputRoute()
            return
        }
        try prepareInstruments()
        if !engine.isRunning { engine.prepare(); try engine.start() }
        refreshOutputRoute()
    }

    func cue(_ cue: RhythmCue) {
        guard masterVolume > 0, engine.isRunning, let buffer = cueBuffers[cue] else { return }
        cueNode.stop()
        cueNode.scheduleBuffer(buffer)
        cueNode.play()
    }

    func play(includingBacking: Bool) throws {
        if !includingBacking || recording == nil { try startInstruments() }
        try setBackingPlaying(includingBacking)
    }

    func setBackingPlaying(_ enabled: Bool) throws {
        if let recording {
            if enabled {
                // A solo chord or countdown may still be ringing as the recording starts.
                // The recording is the only audible source for the duration of the song.
                suspendInstrumentsForBackground()
                let request = backingCompletion.begin()
                recording.didFinish = { [weak self, weak recording] success in
                    guard let self, let recording, self.recording === recording else { return }
                    if self.backingCompletion.complete(request, successfully: success) {
                        self.backingCompletionChanged?()
                    }
                }
                do { try recording.play() }
                catch {
                    backingCompletion.complete(request, successfully: false)
                    throw error
                }
                refreshOutputRoute()
            } else {
                cancelBackingCompletion()
                recording.pause()
                try startInstruments()
            }
            return
        }
        guard let backing else {
            if enabled { throw PlaybackError.file }
            return
        }
        if !enabled {
            cancelBackingCompletion()
            backing.pause()
            if prepared { songPickNode.stop() }
            return
        }
        if backing.currentTime >= backing.duration - 0.05 { backing.currentTime = 0 }
        let request = backingCompletion.begin()
        let delegate = BackingCompletionDelegate(request: request) { [weak self, weak backing] id, success in
            Task { @MainActor in
                guard let self, let backing, self.backing === backing else { return }
                if self.backingCompletion.complete(id, successfully: success) {
                    self.backingCompletionChanged?()
                }
            }
        }
        backingDelegate = delegate
        backing.delegate = delegate
        guard backing.play() else {
            backingCompletion.complete(request, successfully: false)
            throw PlaybackError.file
        }
    }

    private func cancelBackingCompletion() {
        backingCompletion.cancel()
        recording?.didFinish = nil
        backing?.delegate = nil
        backingDelegate = nil
    }

    func setSongPickSource(_ url: URL?) {
        guard url != songPickURL else { return }
        if prepared { songPickNode.stop() }
        songPickURL = url
        pickReferenceGain = 0
    }

    @discardableResult
    func playSongPick(strength: Double, context: SongPickContext) -> Bool {
        guard backingIsPlaying, songPickURL != nil else { return false }
        return playPick(strength: strength, context: context)
    }

    /// Articulates the accompaniment part at the current recording position.
    func strokeRecording(strength: Double) -> Bool {
        guard let recording, recording.isPlaying else { return false }
        if masterVolume > 0 && boundedGuitarVolume > 0 {
            recording.stroke(strength: strength, amount: Double(boundedGuitarVolume), speaker: usesWatchSpeaker)
        }
        return true
    }

    func continueRecordingMotion() {
        guard masterVolume > 0, boundedGuitarVolume > 0 else { return }
        recording?.continueMotion()
    }

    func playCalibrationPick(strength: Double) -> Bool {
        var context = SongPickContext(sourceRMS: 0.1)
        context.use(chord: .c, strength: strength)
        return playPick(strength: strength, context: context)
    }

    private func playPick(strength: Double, context: SongPickContext) -> Bool {
        guard prepared, engine.isRunning, boundedGuitarVolume > 0 else { return false }
        // A muted player still owns the gesture. Skip the attack entirely so
        // a newly connected voice cannot leak a transient during the mixer ramp.
        guard masterVolume > 0 else { return true }
        let buffer = songPick.buffer(midiNote: context.midiNote, strength: strength,
                                     harmonyNote: context.harmonyNote, forWatchSpeaker: usesWatchSpeaker)
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return false }
        let length = Int(buffer.frameLength)
        let onset = min(length, Int(0.12 * buffer.format.sampleRate))
        var energy: Float = 0
        pickPeak = 0
        for i in 0..<length {
            let value = samples[i]
            pickPeak = max(pickPeak, abs(value))
            if i < onset { energy += value * value }
        }
        let rms = sqrt(energy / Float(onset))
        let source = max(usesWatchSpeaker ? 0.036 : 0.018, context.sourceRMS ?? 0.06)
        // Match the gesture to the local programme, then leave space for the
        // vocal. The reference is the default backing level; each volume slider
        // can still be used independently, including for solo audition.
        let relativeDB = SongPickVoice.relativeDB(strength: strength, hasPitch: context.midiNote != nil)
            + (usesWatchSpeaker ? 5.0 : 0)
        pickReferenceGain = 0.25 * source * Float(pow(10, relativeDB / 20)) / max(0.001, rms)
        selectInstrument(.songPick)
        songPickNode.volume = songPickGain
        // Replace the previous tail on the same player; a rapid second stroke
        // is immediate and never queues a second, later sound.
        songPickNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !songPickNode.isPlaying { songPickNode.play() }
        return true
    }

    @discardableResult
    func strum(_ event: StrumEvent) -> Bool {
        guard engine.isRunning, let buffer = buffers[event.chord], !nodes.isEmpty else { return false }
        guard masterVolume > 0 else { return true }
        setInstrumentMode(assisted: false)
        let node = nodes[nextVoice]
        nextVoice = (nextVoice + 1) % nodes.count
        node.stop()
        node.volume = min(1, boundedGuitarVolume * Float(0.26 + 0.74 * sqrt(event.pickStrength))
                          * (usesWatchSpeaker ? 1.65 : 1))
        node.scheduleBuffer(buffer, at: nil, options: [])
        node.play()
        return true
    }

    /// Give the gesture immediate feedback. Schedule the rest of the phrase
    /// against one host-clock anchor and retire it on the next gesture.
    @discardableResult
    func assistedStrum(_ event: StrumEvent, source: AssistedSource,
                       beat: BeatEstimate? = nil, listening: Bool = true,
                       accentOffsets: [TimeInterval] = [],
                       chordAtOffset: ((TimeInterval) -> Chord?)? = nil) -> AssistedPhrase? {
        guard engine.isRunning, !nodes.isEmpty else { return nil }
        setInstrumentMode(assisted: true)
        let now = ProcessInfo.processInfo.systemUptime
        let hostStart = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let phrase: AssistedPhrase
        if listening && addsAssistedReply {
            phrase = assistance.listeningPhrase(at: now, velocity: event.velocity, source: source,
                                                beat: beat, accentOffsets: accentOffsets,
                                                chordAtOffset: chordAtOffset)
        } else {
            phrase = assistance.phrase(at: now, velocity: event.velocity, source: source, beat: beat, includeReply: false)
        }
        let hits = phrase.hits
        guard let first = hits.first, let firstBuffer = assistedBuffers[first.voice],
              hits.count <= assistedReplyNodes.count + 1,
              hits.dropFirst().allSatisfy({ assistedBuffers[$0.voice] != nil }) else { return nil }
        guard masterVolume > 0 else { return phrase }
        assistedReplyNodes.forEach { $0.stop() }
        assistedLeadNode.stop()
        let gain = assistedMixGain * (usesWatchSpeaker ? 1.65 : 1)
        assistedLeadNode.volume = min(1, gain * Float(first.gain))
        assistedLeadNode.scheduleBuffer(firstBuffer)
        assistedLeadNode.play()

        for (node, hit) in zip(assistedReplyNodes, hits.dropFirst()) {
            guard let buffer = assistedBuffers[hit.voice] else { continue }
            let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: hostStart + hit.offset))
            node.volume = min(1, gain * Float(hit.gain))
            node.scheduleBuffer(buffer)
            node.play(at: when)
        }
        return phrase
    }

    func resetAssistance() {
        assistance.reset()
        if prepared {
            songPickNode.stop()
            assistedLeadNode.stop()
            assistedReplyNodes.forEach { $0.stop() }
        }
    }

    func setInstrumentMode(assisted: Bool) {
        selectInstrument(assisted ? .assisted : .manual)
    }

    private func selectInstrument(_ mode: InstrumentMode) {
        guard instrumentMode != mode else { return }
        nodes.forEach { $0.stop() }
        assistedLeadNode.stop()
        assistedReplyNodes.forEach { $0.stop() }
        songPickNode.stop()
        cueNode.stop()
        instrumentMode = mode
        engine.mainMixerNode.outputVolume = mode.mixGain * masterVolume
        cueNode.volume = mode == .songPick ? 0.1 : 1
    }

    /// Keep only the user's real file playback in the background. A silent
    /// synthesis graph must not be used to hold the app awake.
    func suspendInstrumentsForBackground() {
        recording?.clearStroke()
        nodes.forEach { $0.stop() }
        if prepared {
            cueNode.stop()
            assistedLeadNode.stop()
            assistedReplyNodes.forEach { $0.stop() }
            songPickNode.stop()
            instrumentMode = .manual
            cueNode.volume = 1
            engine.mainMixerNode.outputVolume = instrumentMode.mixGain * masterVolume
        }
        engine.pause()
    }

    func pause() {
        cancelBackingCompletion()
        recording?.pause()
        backing?.pause()
        suspendInstrumentsForBackground()
        longFormSessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func rewind() {
        cancelBackingCompletion()
        recording?.currentTime = 0
        backing?.currentTime = 0
        resetAssistance()
    }

    private enum PlaybackError: LocalizedError {
        case route, engine, file
        var errorDescription: String? {
            switch self {
            case .route: return "没有可用的音频输出。S10 请离开充电器，或连接耳机后重试。"
            case .engine: return "音色准备失败，请重新打开应用。"
            case .file: return "歌曲无法播放，请重新传输。"
            }
        }
    }
}

enum RhythmCue: CaseIterable {
    case count, go, streak
    var frequency: Double {
        switch self { case .count: return 660; case .go: return 990; case .streak: return 1320 }
    }
    var duration: Double { self == .count ? 0.065 : 0.115 }
}
