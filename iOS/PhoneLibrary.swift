import Foundation
import Combine
import AVFoundation
import WatchConnectivity

enum PhoneVersion: String, CaseIterable {
    case original, backing
    var label: String { self == .original ? "原曲" : "伴奏版" }
}

struct PhoneBacking: Codable, Identifiable {
    let id: UUID
    let filename: String
    let duration: TimeInterval
    let byteCount: Int64
    let method: BackingMethod
    var transferState: PhoneSong.TransferState = .local
}

struct PhoneAudioItem {
    let id: UUID
    let title: String
    let filename: String
    let duration: TimeInterval
    let byteCount: Int64
    let transferState: PhoneSong.TransferState
}

struct PhoneWatchPreparation: Codable {
    enum Outcome: String, Codable { case pending, ready, skipped, failed }
    let id: UUID
    let revision: Int64
    var outcome: Outcome = .pending
    var needsFile: Bool
    var lastQueuedAt: Date?
    var failureMessage: String?
}

struct PhoneSong: Codable, Identifiable {
    enum TransferState: String, Codable {
        case local, queued, awaitingReceipt, imported, failed

        var label: String {
            switch self {
            case .local: return "仅在 iPhone"
            case .queued: return "等待 / 正在传输"
            case .awaitingReceipt: return "等待手表确认导入"
            case .imported: return "手表已确认导入"
            case .failed: return "传输或导入失败，可重试"
            }
        }
    }

    let id: UUID
    let title: String
    let filename: String
    let duration: TimeInterval
    let byteCount: Int64
    var transferState: TransferState = .local
    // Optional so libraries saved before companion processing stay readable.
    var backing: PhoneBacking?
    /// Only the bundled original recording may use its editorial cover/title.
    var isPracticeTrack: Bool?
    var displayTitle: String { isPracticeTrack == true ? "随手练习" : title }
}

/// UI calls and observable state live on the main queue. WCSession invokes delegates
/// on a background queue; each callback explicitly returns to the main queue.
final class PhoneLibrary: NSObject, ObservableObject, WCSessionDelegate, AVAudioPlayerDelegate {
    @Published private(set) var songs: [PhoneSong] = []
    @Published private(set) var connectionText = "正在连接手表…"
    @Published private(set) var canTransfer = false
    @Published private(set) var previewID: UUID?
    @Published private(set) var transferProgress: [UUID: Double] = [:]
    @Published private(set) var selectedVersions: [UUID: PhoneVersion] = [:]
    @Published private(set) var processingID: UUID?
    @Published private(set) var processingProgress: Double = 0
    @Published private(set) var processingCancelling = false
    @Published private(set) var notice: String?
    @Published private(set) var watchPreparation: PhoneWatchPreparation?
    @Published private(set) var preparationIssue: String?
    @Published var lastError: String?

    private var player: AVAudioPlayer?
    private var pollTimer: Timer?
    private let session: WCSession?
    private let directory: URL
    private var processingJob: UUID?
    private var processingWorker: Task<BackingMaker.Output, Error>?
    private var processingCompletion: Task<Void, Never>?
    private var manifestURL: URL { directory.appendingPathComponent("library.json") }
    private var preparationURL: URL { directory.appendingPathComponent("watch-preparation.json") }
    private var lastPreparationRevision: Int64 = 0
    private var sentPreparationRevision: Int64?
    private var lastContextAttempt: TimeInterval = -.infinity

    override init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Songs", isDirectory: true)
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Only our abandoned processing outputs are removed on a later launch.
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix(".processing-") {
                try? FileManager.default.removeItem(at: url)
            }
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                songs = try JSONDecoder().decode([PhoneSong].self, from: Data(contentsOf: manifestURL))
            }
            // Migrate old records once using their actual recording, never a
            // user-controlled filename. External imports receive false below.
            if songs.contains(where: { $0.isPracticeTrack == nil }) {
                let demo = Bundle.main.url(forResource: "Demo-C-Am-F-G-96bpm", withExtension: "wav")
                var demoByteCount: Int64?
                if let demo, let attributes = try? FileManager.default.attributesOfItem(atPath: demo.path),
                   let size = attributes[.size] as? NSNumber { demoByteCount = size.int64Value }
                for index in songs.indices where songs[index].isPracticeTrack == nil {
                    let source = directory.appendingPathComponent(songs[index].filename)
                    songs[index].isPracticeTrack = demo.map {
                        guard let demoByteCount, songs[index].byteCount == demoByteCount else { return false }
                        return FileManager.default.contentsEqual(atPath: source.path, andPath: $0.path)
                    } ?? false
                }
                try commit(songs)
            }
        } catch {
            lastError = "无法读取本地曲库：\(error.localizedDescription)"
        }
        // A small original practice backing makes the first device test self-contained.
        let demoKey = "AirGuitar.didSeedPracticeTrack"
        if !UserDefaults.standard.bool(forKey: demoKey),
           let demo = Bundle.main.url(forResource: "Demo-C-Am-F-G-96bpm", withExtension: "wav") {
            do {
                if songs.isEmpty { try importFile(demo, isPractice: true) }
                UserDefaults.standard.set(true, forKey: demoKey)
            } catch { lastError = "练习伴奏导入失败：\(error.localizedDescription)" }
        }
        lastPreparationRevision = (UserDefaults.standard.object(forKey: "AirGuitar.lastPreparationRevision") as? NSNumber)?.int64Value ?? 0
        if let data = try? Data(contentsOf: preparationURL),
           let saved = try? JSONDecoder().decode(PhoneWatchPreparation.self, from: data) {
            lastPreparationRevision = max(lastPreparationRevision, saved.revision)
            if containsAudio(saved.id) {
                watchPreparation = saved
                if let song = songs.first(where: { $0.backing?.id == saved.id }) {
                    selectedVersions[song.id] = .backing
                }
            }
        }
        guard let session else {
            connectionText = "此设备不支持 Watch Connectivity"
            return
        }
        session.delegate = self
        session.activate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshTransfers()
            self?.retryWatchPreparation()
        }
    }

    deinit {
        pollTimer?.invalidate()
        processingWorker?.cancel()
        processingCompletion?.cancel()
    }

    func importFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            var imported: PhoneSong?
            for source in urls { imported = try importFile(source) }
            // A user-selected single file expresses a clear new choice. Bulk
            // import and the separately seeded practice track never auto-select.
            if urls.count == 1, let imported { prepareForWatch(imported) }
        } catch {
            if (error as NSError).code == NSUserCancelledError { return }
            lastError = "无法导入：\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func importFile(_ source: URL, isPractice: Bool = false) throws -> PhoneSong {
        guard source.isFileURL else {
            throw LibraryError.message("请分享实际的音频文件，或先将音频保存到“文件”后再导入。")
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard ["mp3", "m4a", "wav", "aif", "aiff"].contains(ext) else {
            throw LibraryError.message("请选择 MP3、M4A、WAV 或 AIFF 文件。")
        }
        let id = UUID()
        let destination = directory.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            try copyImportSource(source, to: destination)
            let audio = try AVAudioPlayer(contentsOf: destination)
            guard audio.duration.isFinite, audio.duration > 0, audio.numberOfChannels > 0 else {
                throw LibraryError.message("文件不包含可播放的音频。")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0, bytes <= 100 * 1024 * 1024 else {
                throw LibraryError.message("文件为空或超过 100 MB，请选择较小的音频文件。")
            }
            var next = songs
            let imported = PhoneSong(id: id,
                                  title: source.deletingPathExtension().lastPathComponent,
                                  filename: destination.lastPathComponent,
                                  duration: audio.duration,
                                  byteCount: bytes, isPracticeTrack: isPractice)
            next.insert(imported, at: 0)
            try commit(next)
            notice = nil
            return imported
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func originalURL(for song: PhoneSong) -> URL {
        directory.appendingPathComponent(song.filename)
    }

    private func copyImportSource(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyResult: Result<Void, Error>?
        // File Provider URLs may be security-scoped or need coordinated access.
        // The source grant is still active, and the copy finishes before returning.
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            copyResult = Result {
                let values = try readableURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw LibraryError.message("请选择可读取的音频文件。")
                }
                let bytes = values.fileSize ?? 0
                guard bytes > 0, bytes <= 100 * 1024 * 1024 else {
                    throw LibraryError.message("文件为空或超过 100 MB，请选择较小的音频文件。")
                }
                try FileManager.default.copyItem(at: readableURL, to: destination)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let copyResult else { throw LibraryError.message("无法读取此音频文件，请重新分享或从“文件”导入。") }
        try copyResult.get()
    }

    func selectedVersion(for song: PhoneSong) -> PhoneVersion {
        song.backing == nil ? .original : (selectedVersions[song.id] ?? .original)
    }

    func selectVersion(_ version: PhoneVersion, for song: PhoneSong) {
        guard version == .original || song.backing != nil else { return }
        if previewID == song.id || previewID == song.backing?.id { stopPreview() }
        selectedVersions[song.id] = version
    }

    func audioItem(for song: PhoneSong) -> PhoneAudioItem {
        if selectedVersion(for: song) == .backing, let backing = song.backing {
            return PhoneAudioItem(id: backing.id, title: song.displayTitle + " · 伴奏版", filename: backing.filename,
                                  duration: backing.duration, byteCount: backing.byteCount,
                                  transferState: backing.transferState)
        }
        return PhoneAudioItem(id: song.id, title: song.displayTitle, filename: song.filename,
                              duration: song.duration, byteCount: song.byteCount, transferState: song.transferState)
    }

    /// Persist the user's latest choice before attempting any background work.
    /// Sending the context selects music on Watch; it never starts playback.
    func prepareForWatch(_ song: PhoneSong) {
        guard let current = songs.first(where: { $0.id == song.id }) else { return }
        let item = audioItem(for: current)
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        guard lastPreparationRevision < Int64.max else {
            lastError = "无法创建新的选曲请求，请重新打开应用。"
            return
        }
        let revision = max(now, lastPreparationRevision + 1)
        let previousDate = watchPreparation?.id == item.id && item.transferState != .failed
            ? watchPreparation?.lastQueuedAt : nil
        let request = PhoneWatchPreparation(id: item.id, revision: revision,
            needsFile: item.transferState != .imported,
            lastQueuedAt: previousDate ?? ([.queued, .awaitingReceipt].contains(item.transferState) ? Date() : nil))
        do {
            try storePreparation(request)
            lastPreparationRevision = revision
            UserDefaults.standard.set(NSNumber(value: revision), forKey: "AirGuitar.lastPreparationRevision")
            sentPreparationRevision = nil
            preparationIssue = nil
            notice = nil
            stopPreview()
            retryWatchPreparation(forceContext: true)
        } catch { lastError = "无法保存选曲请求：\(error.localizedDescription)" }
    }

    func watchPreparationMessage(for song: PhoneSong) -> String? {
        let item = audioItem(for: song)
        guard let request = watchPreparation, request.id == item.id else { return nil }
        switch request.outcome {
        case .ready: return "手表已就绪"
        case .skipped: return "手表已改选其他歌曲"
        case .failed: return "手表未能准备这首歌"
        case .pending:
            if !canTransfer { return "等待手表连接" }
            if item.transferState == .imported && !request.needsFile { return "已送达手表" }
            if preparationIssue != nil { return "暂未完成，会自动重试" }
            if let progress = transferProgress[item.id] {
                return progress > 0 ? "正在发送到手表 · \(Int(progress * 100))%" : "准备发送到手表"
            }
            return "等待手表准备"
        }
    }

    func watchPreparationHint(for song: PhoneSong) -> String {
        guard let request = watchPreparation, request.id == audioItem(for: song).id else {
            return "点「用手表弹」会自动发送所选版本，请在手表点播放。"
        }
        if request.outcome == .ready { return "请在手表点播放，声音由手表发出。" }
        if request.outcome == .skipped { return "需要这首时，再点一次「用手表弹」。" }
        if request.outcome == .failed { return request.failureMessage ?? "请检查手表后重新点「用手表弹」。" }
        if !canTransfer { return "选择已保存。配对并安装手表端后会自动继续。" }
        if audioItem(for: song).transferState == .imported && !request.needsFile {
            return "打开手表上的 AirGuitar 即可选好。若正在演奏，会等本曲结束；之后点播放。"
        }
        return preparationIssue ?? "手表正在演奏时会等本曲结束；准备完成后仍需在手表点播放。"
    }

    private func item(with id: UUID) -> PhoneAudioItem? {
        for song in songs {
            if song.id == id {
                return PhoneAudioItem(id: id, title: song.displayTitle, filename: song.filename,
                                      duration: song.duration, byteCount: song.byteCount, transferState: song.transferState)
            }
            if let backing = song.backing, backing.id == id {
                return PhoneAudioItem(id: id, title: song.displayTitle + " · 伴奏版", filename: backing.filename,
                                      duration: backing.duration, byteCount: backing.byteCount, transferState: backing.transferState)
            }
        }
        return nil
    }

    private func storePreparation(_ request: PhoneWatchPreparation?) throws {
        if let request {
            try JSONEncoder().encode(request).write(to: preparationURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: preparationURL.path) {
            try FileManager.default.removeItem(at: preparationURL)
        }
        watchPreparation = request
    }

    private func forgetPreparation(ifMatching ids: [UUID]) {
        guard let request = watchPreparation, ids.contains(request.id) else { return }
        do { try storePreparation(nil) }
        catch {
            watchPreparation = nil
            lastError = "选曲记录未能清理：\(error.localizedDescription)"
        }
        preparationIssue = nil
        sentPreparationRevision = nil
    }

    private func retryWatchPreparation(forceContext: Bool = false, sendContext: Bool = true) {
        guard var request = watchPreparation, [.pending, .ready].contains(request.outcome),
              let item = item(with: request.id) else { return }
        refreshConnection()
        guard let session, canTransfer else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let needsContext = sentPreparationRevision != request.revision || forceContext
            || (request.outcome == .pending && uptime - lastContextAttempt >= 20)
        if sendContext, needsContext, forceContext || uptime - lastContextAttempt >= 3 {
            lastContextAttempt = uptime
            do {
                try session.updateApplicationContext(SongPreparation(id: request.id, revision: request.revision).context)
                sentPreparationRevision = request.revision
                preparationIssue = nil
            } catch {
                preparationIssue = "选择已保存，手表连接恢复后会自动继续。"
                return
            }
        }
        guard request.outcome == .pending, request.needsFile || item.transferState != .imported else { return }
        guard !hasTransfer(for: item.id) else { return }
        if let queued = request.lastQueuedAt {
            let age = Date().timeIntervalSince(queued)
            let delay: TimeInterval = item.transferState == .failed ? 12 : 60
            if age >= 0 && age < delay { return }
        }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(item.filename).path) else {
            preparationIssue = "找不到这个版本的文件，请重新导入或制作。"
            return
        }
        enqueue(item, using: session)
        request.lastQueuedAt = Date()
        preparationIssue = nil
        do { try storePreparation(request) }
        catch { preparationIssue = "发送已排队，但未能保存进度。请稍后再点「用手表弹」。" }
    }

    private func hasTransfer(for id: UUID) -> Bool {
        session?.outstandingFileTransfers.contains { ($0.file.metadata?["id"] as? String) == id.uuidString } ?? false
    }

    private func enqueue(_ item: PhoneAudioItem, using session: WCSession) {
        session.transferFile(directory.appendingPathComponent(item.filename), metadata: [
            "id": item.id.uuidString, "title": item.title, "duration": item.duration
        ])
        updateState(item.id, .queued)
        refreshTransfers()
    }

    func makeBacking(_ song: PhoneSong) {
        guard processingID == nil else {
            lastError = "已有歌曲正在制作伴奏，请等它完成，或先取消。"
            return
        }
        guard let current = songs.first(where: { $0.id == song.id }) else { return }
        stopPreview()
        notice = nil
        let job = UUID()
        let input = directory.appendingPathComponent(current.filename)
        let output = directory.appendingPathComponent(".processing-\(job.uuidString).m4a")
        processingJob = job
        processingID = song.id
        processingProgress = 0
        processingCancelling = false
        let worker = Task.detached(priority: .userInitiated) { [weak self] () throws -> BackingMaker.Output in
            var previous = -1.0
            return try BackingMaker.process(input: input, output: output, progress: { value in
                guard value.isFinite else { return }
                // Keep the UI below completion until the finalized file and its
                // manifest entry have both been committed successfully.
                let bounded = min(0.99, max(0, value))
                guard bounded >= previous + 0.005 else { return }
                previous = bounded
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.processingJob == job else { return }
                    self.processingProgress = max(self.processingProgress, bounded)
                }
            }, isCancelled: { Task.isCancelled })
        }
        processingWorker = worker
        processingCompletion = Task { @MainActor [weak self] in
            do {
                let result = try await worker.value
                guard let self, self.processingJob == job else {
                    try? FileManager.default.removeItem(at: output)
                    return
                }
                guard !self.processingCancelling else { throw CancellationError() }
                try self.finishBacking(result, songID: song.id, staged: output)
                self.notice = "伴奏版已生成。先试听，再选择要传到手表的版本。"
            } catch {
                try? FileManager.default.removeItem(at: output)
                if let self, self.processingJob == job {
                    if error is CancellationError { self.notice = "已取消制作，原曲和已有伴奏版均已保留。" }
                    else { self.lastError = "制作伴奏失败：\(error.localizedDescription)\n原曲已保留，可继续试听或传输。" }
                }
            }
            guard let self, self.processingJob == job else { return }
            self.processingJob = nil
            self.processingID = nil
            self.processingProgress = 0
            self.processingCancelling = false
            self.processingWorker = nil
            self.processingCompletion = nil
        }
    }

    func cancelBackingCreation() {
        guard processingID != nil else { return }
        processingCancelling = true
        processingWorker?.cancel()
    }

    private func finishBacking(_ output: BackingMaker.Output, songID: UUID, staged: URL) throws {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { throw CancellationError() }
        let previous = songs[index].backing
        let id = UUID()
        let destination = directory.appendingPathComponent("\(id.uuidString).m4a")
        try FileManager.default.moveItem(at: staged, to: destination)
        do {
            var next = songs
            next[index].backing = PhoneBacking(id: id, filename: destination.lastPathComponent,
                                               duration: output.duration, byteCount: output.byteCount, method: output.method)
            try commit(next)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        if previewID == songID || previewID == previous?.id { stopPreview() }
        selectedVersions[songID] = .backing
        if let previous {
            forgetPreparation(ifMatching: [previous.id])
            if previewID == previous.id { stopPreview() }
            cancelTransfers(ids: [previous.id])
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous.filename))
            transferProgress[previous.id] = nil
        }
    }

    func togglePreview(_ song: PhoneSong) {
        guard let current = songs.first(where: { $0.id == song.id }) else { return }
        let item = audioItem(for: current)
        if previewID == item.id { stopPreview(); return }
        stopPreview()
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
            let audio = try AVAudioPlayer(contentsOf: directory.appendingPathComponent(item.filename))
            audio.delegate = self
            guard audio.play() else { throw LibraryError.message("音频无法播放。") }
            player = audio
            previewID = item.id
        } catch {
            stopPreview()
            lastError = "试听失败：\(error.localizedDescription)"
        }
    }

    func stopPreview() {
        player?.stop()
        player = nil
        previewID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func sendToWatch(_ song: PhoneSong) {
        guard let current = songs.first(where: { $0.id == song.id }) else { return }
        let item = audioItem(for: current)
        refreshConnection()
        guard let session, canTransfer else {
            lastError = "请先将手表与此 iPhone 配对，并在手表上安装 AirGuitar。"
            return
        }
        guard !hasTransfer(for: item.id) else { return }
        let url = directory.appendingPathComponent(item.filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "这个版本的文件已不存在，请重新导入或制作。"
            return
        }
        enqueue(item, using: session)
        if var request = watchPreparation, request.id == item.id {
            request.lastQueuedAt = Date()
            try? storePreparation(request)
        }
    }

    func remove(_ song: PhoneSong) {
        guard processingID != song.id else {
            lastError = "请先取消制作，等处理停止后再删除。"
            return
        }
        guard let current = songs.first(where: { $0.id == song.id }) else { return }
        do {
            try commit(songs.filter { $0.id != song.id })
            let ids = [current.id] + (current.backing.map { [$0.id] } ?? [])
            forgetPreparation(ifMatching: ids)
            if previewID.map(ids.contains) == true { stopPreview() }
            cancelTransfers(ids: ids)
            for filename in [current.filename] + (current.backing.map { [$0.filename] } ?? []) {
                let url = directory.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            for id in ids { transferProgress[id] = nil }
            selectedVersions[song.id] = nil
        } catch {
            lastError = "删除失败：\(error.localizedDescription)"
        }
    }

    private func cancelTransfers(ids: [UUID]) {
        let strings = Set(ids.map(\.uuidString))
        session?.outstandingFileTransfers.filter {
            ($0.file.metadata?["id"] as? String).map(strings.contains) ?? false
        }.forEach { $0.cancel() }
    }

    @discardableResult
    private func updateState(_ id: UUID, _ state: PhoneSong.TransferState) -> Bool {
        var next = songs
        if let index = next.firstIndex(where: { $0.id == id }) {
            if next[index].transferState == .imported && state != .queued { return false }
            next[index].transferState = state
        } else if let index = next.firstIndex(where: { $0.backing?.id == id }), var backing = next[index].backing {
            if backing.transferState == .imported && state != .queued { return false }
            backing.transferState = state
            next[index].backing = backing
        } else { return false }
        do { try commit(next); return true }
        catch { lastError = "保存传输状态失败：\(error.localizedDescription)"; return false }
    }

    private func commit(_ next: [PhoneSong]) throws {
        try JSONEncoder().encode(next).write(to: manifestURL, options: .atomic)
        songs = next
    }

    private func containsAudio(_ id: UUID) -> Bool {
        songs.contains { $0.id == id || $0.backing?.id == id }
    }

    private func refreshConnection() {
        guard let session else { canTransfer = false; return }
        canTransfer = session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
        if session.activationState != .activated { connectionText = "正在激活手表连接…" }
        else if !session.isPaired { connectionText = "请先配对 Apple Watch" }
        else if !session.isWatchAppInstalled { connectionText = "请在手表上安装 AirGuitar" }
        else { connectionText = "手表已配对 · 可后台传输" }
    }

    private func refreshTransfers() {
        refreshConnection()
        guard let session, session.activationState == .activated else { return }
        var progress: [UUID: Double] = [:]
        for transfer in session.outstandingFileTransfers {
            guard let string = transfer.file.metadata?["id"] as? String,
                  let id = UUID(uuidString: string) else { continue }
            progress[id] = transfer.progress.fractionCompleted
        }
        transferProgress = progress
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshTransfers()
            if let error { self.lastError = "手表连接失败：\(error.localizedDescription)" }
            let pending = Set(session.outstandingFileTransfers.compactMap {
                ($0.file.metadata?["id"] as? String).flatMap(UUID.init(uuidString:))
            })
            for song in self.songs where song.transferState == .queued && !pending.contains(song.id) {
                self.updateState(song.id, .awaitingReceipt)
            }
            for backing in self.songs.compactMap(\.backing)
                where backing.transferState == .queued && !pending.contains(backing.id) {
                self.updateState(backing.id, .awaitingReceipt)
            }
            self.sentPreparationRevision = nil
            self.retryWatchPreparation(forceContext: true)
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshTransfers()
            self?.sentPreparationRevision = nil
            self?.retryWatchPreparation(forceContext: true)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in self?.refreshConnection() }
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        DispatchQueue.main.async { [weak self] in self?.refreshConnection() }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let string = fileTransfer.file.metadata?["id"] as? String,
              let id = UUID(uuidString: string) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.containsAudio(id) else { return }
            let accepted = self.updateState(id, error == nil ? .awaitingReceipt : .failed)
            self.refreshTransfers()
            if accepted, let error {
                if self.watchPreparation?.id == id {
                    self.preparationIssue = "文件未能送达，连接恢复后会自动重试。"
                } else { self.lastError = "传输失败：\(error.localizedDescription)" }
            }
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let string = userInfo["id"] as? String, let id = UUID(uuidString: string),
              let type = userInfo["type"] as? String else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.containsAudio(id) else { return }
            if ["songNeeded", "songReady", "songSkipped"].contains(type) {
                var context = userInfo
                context["type"] = "prepareSong"
                guard let receipt = SongPreparation(context: context) else { return }
                guard var request = self.watchPreparation,
                      request.id == receipt.id, request.revision == receipt.revision else {
                    if type == "songReady" { self.updateState(id, .imported) }
                    return
                }
                // A manual choice on Watch is terminal for this revision. An
                // older queued reply cannot undo it; a new phone tap can.
                if request.outcome == .skipped && type != "songSkipped" {
                    if type == "songReady" { self.updateState(id, .imported) }
                    return
                }
                if type == "songReady" {
                    request.outcome = .ready
                    request.needsFile = false
                    request.failureMessage = nil
                    self.updateState(id, .imported)
                    self.preparationIssue = nil
                } else if type == "songSkipped" {
                    request.outcome = .skipped
                    self.preparationIssue = nil
                } else {
                    // A Watch may have removed a previously confirmed file.
                    // Only its first current request resets the retry cooldown.
                    if !request.needsFile { request.lastQueuedAt = nil }
                    request.needsFile = true
                    request.outcome = .pending
                    request.failureMessage = nil
                    self.sentPreparationRevision = request.revision
                    self.lastContextAttempt = ProcessInfo.processInfo.systemUptime
                }
                do { try self.storePreparation(request) }
                catch { self.preparationIssue = "未能保存手表准备状态，请重新点「用手表弹」。" }
                if type == "songNeeded" { self.retryWatchPreparation(sendContext: false) }
                return
            }
            if type == "songImported" {
                self.updateState(id, .imported)
                if var request = self.watchPreparation, request.id == id {
                    request.needsFile = false
                    try? self.storePreparation(request)
                }
            }
            else if type == "songImportFailed" {
                if self.updateState(id, .failed) {
                    let message = (userInfo["error"] as? String) ?? "请重新传输"
                    if var request = self.watchPreparation, request.id == id, request.outcome == .pending {
                        request.outcome = .failed
                        request.failureMessage = message
                        try? self.storePreparation(request)
                        self.preparationIssue = message
                    }
                    self.lastError = "手表导入失败：\(message)"
                }
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard self?.player === player else { return }
            self?.stopPreview()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard self?.player === player else { return }
            self?.stopPreview()
            self?.lastError = "音频解码失败：\(error?.localizedDescription ?? "请选择其他文件")"
        }
    }
}

private enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
