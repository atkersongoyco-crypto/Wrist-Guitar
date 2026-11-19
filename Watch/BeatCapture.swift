import AirGuitarCore
import AVFoundation
import Combine
import Darwin
import Foundation
import WatchKit

/// Beat sources only. The owner must pause its guitar/backing engine before
/// listening, then explicitly reactivate playback after this method returns.
/// No microphone audio is written to disk or routed to a speaker.
@MainActor
final class BeatCapture: ObservableObject {
    @Published private(set) var isBusy = false

    private var cancelled = false
    private var fileTask: Task<FileRhythmGuide, Error>?
    private var cancelWait: (() -> Void)?

    func cancel() {
        cancelled = true
        fileTask?.cancel()
        cancelWait?()
    }

    /// referenceBeat is measured from the beginning of the file, in seconds.
    /// Streaming decode and beat analysis run off the main actor, using at most
    /// 24 seconds by default and a bounded 16-second detector window.
    func analyzeFile(at url: URL, maxSeconds: TimeInterval = 24, startingAt: TimeInterval = 0) async throws -> BeatEstimate {
        let guide = try await scanFile(at: url, maxSeconds: maxSeconds, startingAt: startingAt, includeAccents: false)
        guard let beat = guide.beat else { throw BeatCaptureError.noStableBeat }
        return beat
    }

    /// Local recorded attacks and (when independently supported) periodic beats.
    /// The short look-ahead stays within the detector's rolling 16-second window.
    func analyzeFileRhythm(at url: URL, maxSeconds: TimeInterval = 14, startingAt: TimeInterval = 0) async throws -> FileRhythmGuide {
        try await scanFile(at: url, maxSeconds: min(16, maxSeconds), startingAt: startingAt, includeAccents: true)
    }

    private func scanFile(at url: URL, maxSeconds: TimeInterval, startingAt: TimeInterval,
                          includeAccents: Bool) async throws -> FileRhythmGuide {
        try begin()
        defer { finish() }
        guard url.isFileURL, startingAt.isFinite, startingAt >= 0 else { throw BeatCaptureError.invalidFile }
        let seconds = max(8, min(45, maxSeconds.isFinite ? maxSeconds : 24))
        let task = Task.detached(priority: .utility) {
            try Self.decodeFile(url, seconds: seconds, startingAt: startingAt, includeAccents: includeAccents)
        }
        fileTask = task
        let guide = try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: { task.cancel() })
        try checkCancellation()
        return guide
    }

    /// Listen to nearby phone SPEAKER audio for 8–12 seconds. referenceBeat is
    /// monotonic uptime, in the same time domain as CoreMotion timestamps.
    /// Restores the previous session configuration, leaving it inactive so the
    /// owner can safely decide whether foreground playback should resume.
    func listenToSpeaker(seconds: TimeInterval = 10) async throws -> BeatEstimate {
        try begin()
        defer { finish() }
        try microphoneConfiguration()
        try checkCancellation()
        let allowed = try await microphonePermission()
        try checkCancellation()
        guard allowed else { throw BeatCaptureError.microphoneDenied }

        let duration = max(8, min(12, seconds.isFinite ? seconds : 10))
        let session = AVAudioSession.sharedInstance()
        let previous = SessionConfiguration(session)
        let engine = AVAudioEngine()
        var tappedInput: AVAudioInputNode?
        let outcome: Result<BeatEstimate, Error>
        do {
            // Some routes reject measurement mode; the record/default fallback
            // still captures real microphone samples without playing audio.
            do { try session.setCategory(.record, mode: .measurement, policy: .default, options: []) }
            catch { try session.setCategory(.record, mode: .default, policy: .default, options: []) }
            // Do not short-circuit this activation on cancel: its eventual
            // callback must complete before session restoration and playback.
            try await activate(session)
            try checkCancellation()
            guard WKApplication.shared().applicationState != .background else {
                throw BeatCaptureError.notForeground
            }
            guard session.isInputAvailable, !session.currentRoute.inputs.isEmpty else {
                throw BeatCaptureError.inputUnavailable
            }
            guard session.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }) else {
                throw BeatCaptureError.headsetInput
            }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
                throw BeatCaptureError.inputUnavailable
            }

            let promise = BeatResultPromise<BeatEstimate>()
            let collector = LiveBeatCollector(promise: promise, expectedSeconds: duration)
            cancelWait = { collector.abort(CancellationError()) }
            let hostToUptime = ProcessInfo.processInfo.systemUptime
                - AVAudioTime.seconds(forHostTime: mach_absolute_time())
            input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, time in
                // Buffers belong to the audio engine. Copy the small chunk
                // before this callback returns; never retain borrowed memory.
                guard let mono = BeatPCM.monoCopy(buffer) else {
                    collector.abort(BeatCaptureError.unsupportedInput)
                    return
                }
                let rate = buffer.format.sampleRate
                guard time.isHostTimeValid || time.isSampleTimeValid else {
                    collector.abort(BeatCaptureError.unsupportedInput)
                    return
                }
                let firstSample = time.isHostTimeValid
                    ? AVAudioTime.seconds(forHostTime: time.hostTime) + hostToUptime
                    : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / rate
                collector.append(mono, sampleRate: rate, firstSampleUptime: firstSample,
                                 streamFrame: time.isSampleTimeValid ? time.sampleTime : nil,
                                 preciseTimestamp: time.isHostTimeValid)
            }
            tappedInput = input
            engine.prepare()
            try engine.start()
            let observers = recordingObservers(engine: engine, collector: collector)
            defer { observers.forEach(NotificationCenter.default.removeObserver) }
            let deadline = Task {
                do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
                catch { return }
                collector.complete()
            }
            defer { deadline.cancel() }
            let estimate = try await withTaskCancellationHandler(operation: {
                try await promise.value()
            }, onCancel: { collector.abort(CancellationError()) })
            try checkCancellation()
            outcome = .success(estimate)
        } catch { outcome = .failure(error) }

        // This cleanup is synchronous and completes before the caller can
        // start the guitar again, including permission/route/cancel failures.
        engine.stop()
        tappedInput?.removeTap(onBus: 0)
        cancelWait = nil
        var restoreFailure: Error?
        do { try session.setActive(false, options: .notifyOthersOnDeactivation) }
        catch { restoreFailure = error }
        do { try previous.restore(session) }
        catch { restoreFailure = error }
        if restoreFailure != nil { throw BeatCaptureError.sessionRestore }
        switch outcome {
        case .failure(let error): throw error
        case .success(let estimate):
            try checkCancellation()
            return estimate
        }
    }

    /// Anchor a file-domain estimate to an observed AVAudioPlayer.currentTime.
    static func anchorFileEstimate(_ estimate: BeatEstimate, playbackTime: TimeInterval,
                                   uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> BeatEstimate {
        BeatEstimate(bpm: estimate.bpm, referenceBeat: uptime - playbackTime + estimate.referenceBeat,
                     confidence: estimate.confidence)
    }

    private func begin() throws {
        guard !isBusy else { throw BeatCaptureError.busy }
        isBusy = true
        cancelled = false
    }

    private func finish() {
        fileTask = nil
        cancelWait = nil
        isBusy = false
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func microphoneConfiguration() throws {
        guard WKApplication.shared().applicationState != .background else { throw BeatCaptureError.notForeground }
        guard let description = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
              !description.isEmpty else { throw BeatCaptureError.missingUsageDescription }
    }

    private func microphonePermission() async throws -> Bool {
        let promise = BeatResultPromise<Bool>()
        cancelWait = { promise.resolve(.failure(CancellationError())) }
        defer { cancelWait = nil }
        return try await withTaskCancellationHandler(operation: {
            AVAudioApplication.requestRecordPermission { allowed in promise.resolve(.success(allowed)) }
            return try await promise.value()
        }, onCancel: { promise.resolve(.failure(CancellationError())) })
    }

    private func activate(_ session: AVAudioSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.activate(options: []) { allowed, error in
                if let error { continuation.resume(throwing: error) }
                else if allowed { continuation.resume() }
                else { continuation.resume(throwing: BeatCaptureError.inputUnavailable) }
            }
        }
    }

    private func recordingObservers(engine: AVAudioEngine, collector: LiveBeatCollector) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        return [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { notification in
                if let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   AVAudioSession.InterruptionType(rawValue: value) == .began {
                    collector.abort(BeatCaptureError.interrupted)
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { notification in
                guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: value),
                      reason != .categoryChange else { return }
                collector.abort(BeatCaptureError.routeChanged)
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
                collector.abort(BeatCaptureError.routeChanged)
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
                collector.abort(BeatCaptureError.inputUnavailable)
            },
            center.addObserver(forName: WKApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
                collector.abort(BeatCaptureError.notForeground)
            }
        ]
    }

    nonisolated private static func decodeFile(_ url: URL, seconds: TimeInterval, startingAt start: TimeInterval,
                                                includeAccents: Bool) throws -> FileRhythmGuide {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate.isFinite, rate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw BeatCaptureError.invalidFile
        }
        guard start < Double(file.length) / rate else { throw BeatCaptureError.insufficientAudio }
        let first = AVAudioFramePosition((start * rate).rounded(.down))
        let frames = min(file.length - first, AVAudioFramePosition(rate * seconds))
        guard Double(frames) / rate >= 4 else { throw BeatCaptureError.insufficientAudio }
        let limit = first + frames
        file.framePosition = first
        var tracker = RhythmBeatTracker(windowDuration: 16, minBPM: 60, maxBPM: 180)
        var position = first
        var energy: Double = 0
        var sampleCount = 0
        var best: BeatEstimate?
        var nextCheck: TimeInterval = Double(first) / rate + 8
        while position < limit {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, limit - position)))
            guard buffer.frameLength > 0, let mono = BeatPCM.monoCopy(buffer) else { break }
            tracker.appendPCM(mono, sampleRate: rate, startingAt: Double(position) / rate)
            energy += mono.reduce(0) { $0 + Double($1) * Double($1) }
            sampleCount += mono.count
            position += AVAudioFramePosition(buffer.frameLength)
            if Double(position) / rate >= nextCheck {
                if let estimate = tracker.estimate(), best == nil || estimate.confidence > best!.confidence { best = estimate }
                nextCheck += 4
            }
        }
        try Task.checkCancellation()
        if let estimate = tracker.estimate(), best == nil || estimate.confidence > best!.confidence { best = estimate }
        guard sampleCount >= Int(rate * 4) else { throw BeatCaptureError.insufficientAudio }
        guard sqrt(energy / Double(sampleCount)) > 0.0005 else { throw BeatCaptureError.silentFile }
        let beat = best.flatMap { $0.isValid && $0.confidence >= RhythmGame.minimumConfidence ? $0 : nil }
        return FileRhythmGuide(startTime: Double(first) / rate, endTime: Double(position) / rate,
                               beat: beat, accents: includeAccents ? tracker.recordedAccents() : [])
    }
}

private struct SessionConfiguration {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let policy: AVAudioSession.RouteSharingPolicy
    let options: AVAudioSession.CategoryOptions

    init(_ session: AVAudioSession) {
        category = session.category; mode = session.mode
        policy = session.routeSharingPolicy; options = session.categoryOptions
    }

    func restore(_ session: AVAudioSession) throws {
        try session.setCategory(category, mode: mode, policy: policy, options: options)
    }
}

/// One-shot results can arrive before or after a waiter, from permission,
/// cancellation, route notifications, or the serial audio-analysis queue.
private final class BeatResultPromise<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { self.continuation = continuation; lock.unlock() }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(with: result)
    }
}

private final class LiveBeatCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "AirGuitar.BeatCapture", qos: .userInitiated)
    private let promise: BeatResultPromise<BeatEstimate>
    private let minimumSeconds: TimeInterval
    private var tracker = RhythmBeatTracker(windowDuration: 16, minBPM: 60, maxBPM: 180)
    private var firstSample: TimeInterval?
    private var frameOrigin: AVAudioFramePosition?
    private var sampleRate: Double = 0
    private var count = 0
    private var energy: Double = 0
    private var finished = false

    init(promise: BeatResultPromise<BeatEstimate>, expectedSeconds: TimeInterval) {
        self.promise = promise
        minimumSeconds = max(4, expectedSeconds - 1)
    }

    func append(_ samples: [Float], sampleRate: Double, firstSampleUptime: TimeInterval,
                streamFrame: AVAudioFramePosition? = nil, preciseTimestamp: Bool = true) {
        queue.async {
            guard !self.finished else { return }
            guard sampleRate.isFinite, sampleRate > 0, firstSampleUptime.isFinite else {
                self.finish(.failure(BeatCaptureError.unsupportedInput)); return
            }
            if self.firstSample == nil { self.firstSample = firstSampleUptime; self.sampleRate = sampleRate }
            guard abs(self.sampleRate - sampleRate) < 0.5 else {
                self.finish(.failure(BeatCaptureError.routeChanged)); return
            }
            if let streamFrame {
                if self.frameOrigin == nil { self.frameOrigin = streamFrame - AVAudioFramePosition(self.count) }
                let expectedFrame = self.frameOrigin! + AVAudioFramePosition(self.count)
                guard abs(Double(streamFrame) - Double(expectedFrame)) <= 2 else {
                    self.finish(.failure(BeatCaptureError.interrupted)); return
                }
            }
            let start = self.firstSample! + Double(self.count) / sampleRate
            // Valid hardware host timestamps should not contain callback jitter.
            // Reject gaps instead of compressing lost PCM into a false beat phase.
            let tolerance: TimeInterval = preciseTimestamp ? 0.02 : 0.5
            guard abs(firstSampleUptime - start) <= tolerance else {
                self.finish(.failure(BeatCaptureError.interrupted)); return
            }
            self.tracker.appendPCM(samples, sampleRate: sampleRate, startingAt: start)
            self.energy += samples.reduce(0) { $0 + Double($1) * Double($1) }
            self.count += samples.count
        }
    }

    func abort(_ error: Error) { queue.async { self.finish(.failure(error)) } }

    func complete() {
        queue.async {
            guard !self.finished else { return }
            guard self.sampleRate > 0, Double(self.count) / self.sampleRate >= self.minimumSeconds else {
                self.finish(.failure(BeatCaptureError.inputUnavailable)); return
            }
            guard sqrt(self.energy / Double(self.count)) > 0.001 else {
                self.finish(.failure(BeatCaptureError.tooQuiet)); return
            }
            guard let estimate = self.tracker.estimate(), estimate.isValid, estimate.confidence >= 0.35 else {
                self.finish(.failure(BeatCaptureError.noStableBeat)); return
            }
            self.finish(.success(estimate))
        }
    }

    private func finish(_ result: Result<BeatEstimate, Error>) {
        guard !finished else { return }
        finished = true
        tracker.reset()
        promise.resolve(result)
    }
}

private enum BeatPCM {
    static func monoCopy(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        var result = [Float](repeating: 0, count: frames)
        let interleaved = buffer.format.isInterleaved
        for channel in 0..<channels {
            for frame in 0..<frames {
                let index = interleaved ? frame * channels + channel : frame
                let value: Float
                if let data = buffer.floatChannelData { value = data[interleaved ? 0 : channel][index] }
                else if let data = buffer.int16ChannelData { value = Float(data[interleaved ? 0 : channel][index]) / 32768 }
                else if let data = buffer.int32ChannelData { value = Float(data[interleaved ? 0 : channel][index]) / 2_147_483_648 }
                else { return nil }
                result[frame] += value.isFinite ? value / Float(channels) : 0
            }
        }
        return result
    }
}

enum BeatCaptureError: LocalizedError {
    case busy, invalidFile, insufficientAudio, silentFile, noStableBeat
    case notForeground, missingUsageDescription, microphoneDenied, inputUnavailable
    case headsetInput, unsupportedInput, tooQuiet, routeChanged, interrupted, sessionRestore

    var errorDescription: String? {
        switch self {
        case .busy: return "正在识别节拍，请等待或先取消。"
        case .invalidFile: return "无法读取这首本地音乐，请重新导入。"
        case .insufficientAudio: return "可分析的音频太短，请换一段至少数秒的音乐。"
        case .silentFile: return "本地音频太安静，暂时无法估计节拍。"
        case .noStableBeat: return "没有找到稳定节拍，请换一段鼓点更清楚的音乐重试。"
        case .notForeground: return "请保持 Wrist Guitar 在手表前台，再开始听外放。"
        case .missingUsageDescription: return "应用未配置麦克风用途说明，暂时不能听外放。"
        case .microphoneDenied: return "没有麦克风权限。请在系统设置允许 Wrist Guitar 访问麦克风后重试。"
        case .inputUnavailable: return "当前没有可用的麦克风音频，请在手表真机上重试。"
        case .headsetInput: return "当前输入来自耳机。请断开耳机，让手表麦克风听手机外放。"
        case .unsupportedInput: return "当前麦克风音频格式或时间信息不可用，请重试。"
        case .tooQuiet: return "没有听到清晰的外放音乐。请把手机扬声器靠近手表；若手机在用耳机，手表无法听到。"
        case .routeChanged: return "音频输出或麦克风已切换，请重新听外放。"
        case .interrupted: return "采样被打断，请保持前台再重试。"
        case .sessionRestore: return "采样已结束，但播放音频未恢复。请重新点击开始。"
        }
    }
}
