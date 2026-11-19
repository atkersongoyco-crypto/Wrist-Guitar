import Foundation
import Combine
import AVFoundation
import WatchConnectivity

enum PhoneVersion: String, CaseIterable {
    case original, backing
    var label: String { self == .original ? "原曲" : "伴奏版" }
}

/// Optional in old manifests. A decoder rejection pins only its immutable audio
/// version to the original file on subsequent sends.
enum PhoneWatchAudioCopy: String, Codable { case compact, original, originalOnly }

struct PhoneBacking: Codable, Identifiable {
    let id: UUID
    let filename: String
    let duration: TimeInterval
    let byteCount: Int64
    let method: BackingMethod
    var transferState: PhoneSong.TransferState = .local
    var watchCopy: PhoneWatchAudioCopy?
}

struct PhoneAudioItem {
    let id: UUID
    let title: String
    let filename: String
    let duration: TimeInterval
    let byteCount: Int64
    let transferState: PhoneSong.TransferState
    let watchCopy: PhoneWatchAudioCopy?
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
    var watchCopy: PhoneWatchAudioCopy?
    // Optional so libraries saved before companion processing stay readable.
    var backing: PhoneBacking?
    /// Only the bundled original recording may use its editorial cover/title.
    var isPracticeTrack: Bool?
    var embeddedTitle: String?
    var artist: String?
    var didReadTags: Bool?
    var displayTitle: String { isPracticeTrack == true ? "随手练习" : (embeddedTitle ?? title) }
}

/// UI calls and observable state live on the main queue. WCSession invokes delegates
/// on a background queue; each callback explicitly returns to the main queue.
final class PhoneLibrary: NSObject, ObservableObject, WCSessionDelegate, AVAudioPlayerDelegate {
    let gameLink = WristGameLink { packet, reply, failed in
        WCSession.default.sendMessage(packet, replyHandler: reply, errorHandler: failed)
    }
    @Published private(set) var songs: [PhoneSong] = []
    @Published private(set) var connectionText = "正在连接手表…"
    @Published private(set) var canTransfer = false
    @Published private(set) var previewID: UUID?
    @Published private(set) var transferProgress: [UUID: Double] = [:]
    @Published private var encodingWatchCopies: Set<UUID> = []
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
    private let transferCache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WatchTransferAudio", isDirectory: true)
    private var preparingFiles = [UUID: Task<Void, Never>]()
    private var explicitCopies = Set<UUID>()
    private var probingCopies = Set<UUID>()
    private var probingRevision: Int64?
    private var lastProbedRevision: Int64?
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
        preparingFiles.values.forEach { $0.cancel() }
    }

    func importFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            var imported: PhoneSong?
            for source in urls { imported = try importFile(source) }
            // A user-selected single file expresses a clear new choice. Bulk
            // import and the separately seeded practice track never auto-select.
            if urls.count == 1, let imported {
                selectedVersions[imported.id] = .original
                prepareForWatch(imported)
            }
        } catch {
            if (error as NSError).code == NSUserCancelledError { return }
            lastError = "无法导入：\(error.localizedDescription)"
        }
    }

    /// A deleted demo only comes back when the user explicitly chooses it again.
    func restorePracticeTrack() -> PhoneSong? {
        if let practice = songs.first(where: { $0.isPracticeTrack == true }) { return practice }
        guard let demo = Bundle.main.url(forResource: "Demo-C-Am-F-G-96bpm", withExtension: "wav") else {
            lastError = "找不到内置练习曲。"
            return nil
        }
        do { return try importFile(demo, isPractice: true) }
        catch {
            lastError = "无法恢复内置练习曲：\(error.localizedDescription)"
            return nil
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
            if let existing = try copyImportSource(source, to: destination, isPractice: isPractice) {
                notice = nil
                return existing
            }
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

    @MainActor
    func loadTrackInfo(for song: PhoneSong) async {
        guard song.isPracticeTrack != true, song.didReadTags != true else { return }
        let asset = AVURLAsset(url: originalURL(for: song))
        guard let items = try? await asset.load(.commonMetadata) else { return }
        func text(for key: AVMetadataKey) async -> String? {
            guard let tag = items.first(where: { $0.commonKey == key }),
                  let value = try? await tag.load(.stringValue) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let title = await text(for: .commonKeyTitle)
        let artist = await text(for: .commonKeyArtist)
        guard !Task.isCancelled, let index = songs.firstIndex(where: { $0.id == song.id }),
              songs[index].didReadTags != true else { return }
        var updated = songs
        updated[index].embeddedTitle = title
        updated[index].artist = artist
        updated[index].didReadTags = true
        // Metadata is optional. A failed cache write must not interrupt import or playback.
        try? commit(updated)
    }

    private func copyImportSource(_ source: URL, to destination: URL, isPractice: Bool) throws -> PhoneSong? {
        var coordinationError: NSError?
        var copyResult: Result<PhoneSong?, Error>?
        let title = source.deletingPathExtension().lastPathComponent
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
                // Keep the stable audio ID for a repeat import. Another recording
                // with the same display name and length still gets its own ID.
                if let existing = self.songs.first(where: {
                    (!isPractice || $0.isPracticeTrack == true) && $0.title == title && $0.byteCount == Int64(bytes)
                        && FileManager.default.contentsEqual(atPath: readableURL.path, andPath: self.originalURL(for: $0).path)
                }) { return existing }
                try FileManager.default.copyItem(at: readableURL, to: destination)
                return nil
            }
        }
        if let coordinationError { throw coordinationError }
        guard let copyResult else { throw LibraryError.message("无法读取此音频文件，请重新分享或从“文件”导入。") }
        return try copyResult.get()
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
                                  transferState: backing.transferState, watchCopy: backing.watchCopy)
        }
        return PhoneAudioItem(id: song.id, title: song.displayTitle, filename: song.filename,
                              duration: song.duration, byteCount: song.byteCount, transferState: song.transferState, watchCopy: song.watchCopy)
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

    struct WatchFileStatus {
        let title: String
        let detail: String
        var transferFraction: Double?
        var isSynthesizing = false
    }

    /// Both “用手表弹” and a file-only send use this view of the selected version.
    /// Only WatchConnectivity can supply a transfer percentage or a watch receipt.
    func watchFileStatus(for song: PhoneSong) -> WatchFileStatus? {
        let item = audioItem(for: song)
        let request = watchPreparation.flatMap { $0.id == item.id ? $0 : nil }
        let manual = explicitCopies.contains(item.id)
        if !manual, let request, item.transferState == .imported && !request.needsFile {
            if request.outcome == .ready {
                return .init(title: "手表已就绪", detail: "请在手表点播放，声音由手表发出。")
            }
            if request.outcome == .pending {
                return .init(title: "已送达手表，等待选曲", detail: "打开手表上的 Wrist Guitar。若正在演奏，会等本曲结束再切歌。")
            }
        }
        if probingCopies.contains(item.id) || (request.map { probingRevision == $0.revision } ?? false) {
            return .init(title: "正在检查手表曲库", detail: "手表上已有这首歌时可以直接使用。")
        }
        if preparingFiles[item.id] != nil && (manual || request?.outcome == .pending) {
            if encodingWatchCopies.contains(item.id) {
                return .init(title: "手表音频合成中", detail: "iPhone 正在将所选版本转换成更小的音频，完成后会自动传到手表。", isSynthesizing: true)
            }
            return .init(title: "正在准备音频文件", detail: "iPhone 会优先使用已有的手表版本。")
        }
        if !canTransfer, request?.outcome == .pending || item.transferState == .queued {
            let detail = request?.outcome == .pending ? "选曲已保存，连接恢复后会自动继续。" : "文件已排队，等待配对的手表可用。"
            return .init(title: "等待手表连接", detail: detail)
        }
        if item.transferState == .queued, let raw = transferProgress[item.id], raw.isFinite {
            let progress = min(max(raw, 0), 1)
            let title = progress > 0 ? "正在传到手表 · \(Int(progress * 100))%" : "等待传到手表"
            let detail = item.watchCopy == .compact ? "精简音频已合成，正在通过系统队列发送。" : "所选文件已加入系统传输队列，请将设备保持在附近。"
            return .init(title: title, detail: detail, transferFraction: progress)
        }
        if let request {
            switch request.outcome {
            case .skipped:
                return .init(title: "手表已改选其他歌曲", detail: "需要这首时，再点一次「用手表弹」。")
            case .failed:
                return .init(title: "手表未能准备这首歌", detail: request.failureMessage ?? "检查手表连接后，可重新点「用手表弹」。")
            case .ready, .pending:
                if let preparationIssue {
                    return .init(title: "等待重试", detail: preparationIssue)
                }
                if request.needsFile && item.transferState == .failed {
                    return .init(title: "等待重试", detail: "连接可用时会重新发送文件。")
                }
            }
        }
        switch item.transferState {
        case .local:
            return request == nil ? nil : .init(title: "准备发送到手表", detail: "手表将收到所选版本。")
        case .queued:
            return .init(title: "等待传到手表", detail: "文件已排队，请将设备保持在附近。")
        case .awaitingReceipt:
            return .init(title: "等待手表确认导入", detail: "文件已传送，手表确认后会在这里更新。")
        case .imported:
            if request?.needsFile == true {
                return .init(title: "准备重新发送", detail: "手表已请求重新导入这首歌。")
            }
            return .init(title: "手表已确认导入", detail: "这首歌已在手表曲库，可以从手表选曲播放。")
        case .failed:
            return .init(title: "文件传输未完成", detail: "检查手表连接后，可重新传输所选版本。")
        }
    }

    private func item(with id: UUID) -> PhoneAudioItem? {
        for song in songs {
            if song.id == id {
                return PhoneAudioItem(id: id, title: song.displayTitle, filename: song.filename,
                                      duration: song.duration, byteCount: song.byteCount, transferState: song.transferState, watchCopy: song.watchCopy)
            }
            if let backing = song.backing, backing.id == id {
                return PhoneAudioItem(id: id, title: song.displayTitle + " · 伴奏版", filename: backing.filename,
                                      duration: backing.duration, byteCount: backing.byteCount, transferState: backing.transferState, watchCopy: backing.watchCopy)
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
        guard let request = watchPreparation, [.pending, .ready].contains(request.outcome),
              let item = item(with: request.id) else { return }
        refreshConnection()
        guard let session, canTransfer else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let needsContext = sentPreparationRevision != request.revision || forceContext
            || (request.outcome == .pending && uptime - lastContextAttempt >= 20)
        var context = SongPreparation(id: request.id, revision: request.revision).context
        context["isPractice"] = isBundledOriginal(item.id)
        if sendContext, needsContext, forceContext || uptime - lastContextAttempt >= 3 {
            lastContextAttempt = uptime
            do {
                try session.updateApplicationContext(context)
                sentPreparationRevision = request.revision
                preparationIssue = nil
            } catch {
                preparationIssue = "选择已保存，手表连接恢复后会自动继续。"
            }
        }
        if sendContext, session.isReachable, lastProbedRevision != request.revision {
            lastProbedRevision = request.revision
            probingRevision = request.revision
            probe(context, session: session) { [weak self] reply in
                guard let self, self.probingRevision == request.revision,
                      self.watchPreparation?.revision == request.revision else { return }
                self.probingRevision = nil
                if let reply, (reply["revision"] as? NSNumber)?.int64Value == request.revision,
                   reply["id"] as? String == request.id.uuidString {
                    self.receiveReceipt(reply, fromProbe: true)
                }
                self.retryWatchPreparation(sendContext: false)
            }
        }
        guard probingRevision != request.revision, request.outcome == .pending, request.needsFile else { return }
        if let queued = request.lastQueuedAt {
            let age = Date().timeIntervalSince(queued)
            let delay: TimeInterval = item.transferState == .failed ? 12 : 60
            if age >= 0 && age < delay { return }
        }
        enqueue(item, using: session)
    }

    /// The file stays on the durable WCSession transport. Foreground messages
    /// exchange a few bytes to avoid resending audio already installed on Watch.
    private func probe(_ context: [String: Any], session: WCSession,
                       completion: @escaping ([String: Any]?) -> Void) {
        var finished = false
        func finish(_ reply: [String: Any]?) {
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(reply)
            }
        }
        session.sendMessage(context, replyHandler: { finish($0) }, errorHandler: { _ in finish(nil) })
        // Older watch apps may not implement live queries. Do not wait for
        // WatchConnectivity's long reply timeout before queuing a normal file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { finish(nil) }
    }

    private func isBundledOriginal(_ id: UUID) -> Bool {
        songs.contains { $0.id == id && $0.isPracticeTrack == true }
    }

    private func hasTransfer(for id: UUID) -> Bool {
        session?.outstandingFileTransfers.contains { ($0.file.metadata?["id"] as? String) == id.uuidString } ?? false
    }

    private func enqueue(_ item: PhoneAudioItem, using session: WCSession) {
        guard !hasTransfer(for: item.id), preparingFiles[item.id] == nil else { return }
        let source = directory.appendingPathComponent(item.filename)
        guard FileManager.default.fileExists(atPath: source.path) else {
            let message = "找不到这个版本的文件，请重新导入或制作。"
            if explicitCopies.remove(item.id) != nil { lastError = message }
            if var request = watchPreparation, request.id == item.id, request.outcome == .pending {
                request.outcome = .failed
                request.failureMessage = message
                do { try storePreparation(request) }
                catch { preparationIssue = message }
            }
            return
        }
        let practice = isBundledOriginal(item.id)
        let cache = transferCache
        preparingFiles[item.id] = Task { @MainActor [weak self] in
            let prepared = (practice || item.watchCopy == .originalOnly) ? source : await WatchTransferAudio.file(
                for: source, id: item.id, duration: item.duration, cacheDirectory: cache) { [weak self] in
                    guard !Task.isCancelled else { return }
                    self?.encodingWatchCopies.insert(item.id)
                }
            guard let self else { return }
            if !Task.isCancelled, let song = self.songs.first(where: { $0.id == item.id || $0.backing?.id == item.id }) {
                // Automatic sends can start before the song row has appeared.
                await self.loadTrackInfo(for: song)
            }
            guard !Task.isCancelled else {
                if !self.containsAudio(item.id) { self.removeCachedTransfer(item.id) }
                return
            }
            self.preparingFiles[item.id] = nil
            self.encodingWatchCopies.remove(item.id)
            let manual = self.explicitCopies.remove(item.id) != nil
            defer { self.refreshTransfers() }
            guard let latest = self.item(with: item.id), !self.hasTransfer(for: item.id) else { return }
            let file = latest.watchCopy == .originalOnly ? source : prepared
            let variant: PhoneWatchAudioCopy = file == source ? .original : .compact
            let request = self.watchPreparation
            let selected = request?.id == item.id && request?.outcome == .pending && request?.needsFile == true
            guard manual || selected else { return }
            guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
                if manual && !selected { self.lastError = "手表连接已改变，请稍后再传一次。" }
                return
            }
            session.transferFile(file, metadata: ["id": item.id.uuidString, "title": latest.title,
                "duration": item.duration, "ext": file.pathExtension.lowercased(), "isPractice": practice,
                "audioVariant": variant.rawValue])
            self.updateState(item.id, .queued, copy: latest.watchCopy == .originalOnly ? .originalOnly : variant)
            if selected, var request {
                request.lastQueuedAt = Date()
                self.preparationIssue = nil
                do { try self.storePreparation(request) }
                catch { self.preparationIssue = "文件已排队，但未能保存进度。" }
            }
        }
        refreshTransfers()
    }

    private func removeCachedTransfer(_ id: UUID) {
        guard !hasTransfer(for: id) else { return }
        try? FileManager.default.removeItem(at: transferCache.appendingPathComponent(id.uuidString + ".m4a"))
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
            lastError = "请先将手表与此 iPhone 配对，并在手表上安装 Wrist Guitar。"
            return
        }
        guard !hasTransfer(for: item.id) else { return }
        let url = directory.appendingPathComponent(item.filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "这个版本的文件已不存在，请重新导入或制作。"
            return
        }
        guard explicitCopies.insert(item.id).inserted else { return }
        if session.isReachable {
            probingCopies.insert(item.id)
            refreshTransfers()
            probe(["type": "songProbe", "id": item.id.uuidString, "isPractice": isBundledOriginal(item.id)], session: session) { [weak self] reply in
                guard let self else { return }
                self.probingCopies.remove(item.id)
                guard self.explicitCopies.contains(item.id), self.containsAudio(item.id) else { return }
                if reply?["type"] as? String == "songPresent", reply?["id"] as? String == item.id.uuidString {
                    self.explicitCopies.remove(item.id)
                    self.receiveReceipt(["type": "songImported", "id": item.id.uuidString])
                    self.notice = "这首歌已在手表曲库。"
                } else if self.hasTransfer(for: item.id) {
                    self.explicitCopies.remove(item.id)
                } else { self.enqueue(item, using: session) }
                self.refreshTransfers()
            }
        } else { enqueue(item, using: session) }
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
        for id in ids {
            preparingFiles.removeValue(forKey: id)?.cancel()
            encodingWatchCopies.remove(id)
            explicitCopies.remove(id)
            probingCopies.remove(id)
        }
        let strings = Set(ids.map(\.uuidString))
        session?.outstandingFileTransfers.filter {
            ($0.file.metadata?["id"] as? String).map(strings.contains) ?? false
        }.forEach { $0.cancel() }
        ids.forEach(removeCachedTransfer)
    }

    @discardableResult
    private func updateState(_ id: UUID, _ state: PhoneSong.TransferState, copy: PhoneWatchAudioCopy? = nil) -> Bool {
        var next = songs
        if let index = next.firstIndex(where: { $0.id == id }) {
            if next[index].transferState == .imported && state != .queued { return false }
            if next[index].transferState == state && (copy == nil || copy == next[index].watchCopy) { return true }
            next[index].transferState = state
            if let copy { next[index].watchCopy = copy }
        } else if let index = next.firstIndex(where: { $0.backing?.id == id }), var backing = next[index].backing {
            if backing.transferState == .imported && state != .queued { return false }
            if backing.transferState == state && (copy == nil || copy == backing.watchCopy) { return true }
            backing.transferState = state
            if let copy { backing.watchCopy = copy }
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
        gameLink.updateReachability(canTransfer && session.isReachable)
        if session.activationState != .activated { connectionText = "正在激活手表连接…" }
        else if !session.isPaired { connectionText = "请先配对 Apple Watch" }
        else if !session.isWatchAppInstalled { connectionText = "请在手表上安装 Wrist Guitar" }
        else { connectionText = "手表已配对 · 可后台传输" }
    }

    private func refreshTransfers() {
        refreshConnection()
        guard let session, session.activationState == .activated else { return }
        var progress = Dictionary(uniqueKeysWithValues: Set(preparingFiles.keys).union(probingCopies).map { ($0, 0.0) })
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
            if let cached = try? FileManager.default.contentsOfDirectory(at: self.transferCache, includingPropertiesForKeys: nil) {
                for file in cached where file.pathExtension == "m4a" {
                    if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !self.containsAudio(id) {
                        self.removeCachedTransfer(id)
                    }
                }
            }
            self.sentPreparationRevision = nil
            self.lastProbedRevision = nil
            self.retryWatchPreparation(forceContext: true)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshConnection()
            guard session.isReachable else { return }
            if self.probingRevision == nil { self.lastProbedRevision = nil }
            self.retryWatchPreparation()
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
            guard let current = self.item(with: id) else { self.removeCachedTransfer(id); return }
            // An import failure is the watch's verdict. A later successful
            // transport callback only means the bytes reached the other device.
            if current.transferState == .failed && error == nil { self.refreshTransfers(); return }
            if fileTransfer.file.metadata?["audioVariant"] as? String == "compact", current.watchCopy == .originalOnly {
                self.refreshTransfers()
                return
            }
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
        DispatchQueue.main.async { [weak self] in self?.receiveReceipt(userInfo) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        let receivedAt = WristGameLink.now
        DispatchQueue.main.async { [weak self] in
            if self?.gameLink.receive(message, receivedAt: receivedAt, reply: replyHandler) == true { return }
            self?.receiveReceipt(message)
            replyHandler(["received": true])
        }
    }

    private func receiveReceipt(_ userInfo: [String: Any], fromProbe: Bool = false) {
        guard let string = userInfo["id"] as? String, let id = UUID(uuidString: string),
              let type = userInfo["type"] as? String else { return }
        guard self.containsAudio(id) else { return }
        if ["songNeeded", "songPresent", "songReady", "songSkipped"].contains(type) {
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
            let checkPossiblyDelayedNeed = type == "songNeeded" && !fromProbe && !request.needsFile && session?.isReachable == true
            if type == "songReady" || type == "songPresent" {
                if type == "songReady" { request.outcome = .ready }
                request.needsFile = false
                request.failureMessage = nil
                self.updateState(id, .imported)
                self.preparationIssue = nil
                if fromProbe {
                    session?.outstandingFileTransfers.filter { ($0.file.metadata?["id"] as? String) == string }.forEach { $0.cancel() }
                }
            } else if type == "songSkipped" {
                request.outcome = .skipped
                self.preparationIssue = nil
            } else {
                if probingRevision == request.revision { return }
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
            if type == "songNeeded" {
                if checkPossiblyDelayedNeed { lastProbedRevision = nil }
                self.retryWatchPreparation(sendContext: checkPossiblyDelayedNeed)
            }
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
            guard let item = self.item(with: id) else { return }
            let variant = userInfo["audioVariant"] as? String
            // A delayed compact-file failure cannot fail a later original-file retry.
            if variant == "compact" && item.watchCopy != .compact { return }
            if variant == "original" && item.watchCopy == .compact { return }
            let reason = userInfo["reason"] as? String
            let retryOriginal = item.watchCopy == .compact && (reason == "decode" || reason == nil)
            if self.updateState(id, .failed, copy: retryOriginal ? .originalOnly : nil) {
                let message = retryOriginal ? "手表未能解码精简版。再点「用手表弹」会发送原始文件。" :
                    ((userInfo["error"] as? String) ?? "请重新传输")
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
