import AVFoundation
import Combine
import Foundation
import WatchConnectivity

struct WatchSong: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let duration: Double
    let filename: String

    private static let practiceFile = "Demo-C-Am-F-G-96bpm.wav"
    static let practice: WatchSong? = {
        guard let url = Bundle.main.url(forResource: practiceFile, withExtension: nil) else { return nil }
        return WatchSong(id: UUID(uuidString: "A22D5CD3-2CEF-46FC-9F56-E039549A1CF3")!,
                         title: "随手练习", duration: 20, filename: url.lastPathComponent)
    }()

    var url: URL {
        if filename == Self.practiceFile, let resource = Bundle.main.url(forResource: filename, withExtension: nil) {
            return resource
        }
        return WatchSongLibrary.directory.appendingPathComponent(filename)
    }

    func matchesPracticeRecording() -> Bool {
        guard let practice = Self.practice else { return false }
        if url == practice.url { return true }
        // Files transferred by older versions used UUID-based names. Match the
        // recording itself so renaming a different song cannot select its score.
        let bundled = practice.url
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let expected = try? bundled.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == expected else { return false }
        return FileManager.default.contentsEqual(atPath: url.path, andPath: bundled.path)
    }
}

/// Persist received files before returning from WCSession's temporary-file callback.
final class WatchSongLibrary: NSObject, ObservableObject, WCSessionDelegate {
    struct Preparation: Codable, Equatable {
        enum State: String, Codable { case waiting, ready, skipped }
        let request: SongPreparation
        var state: State
    }
    private let preferenceKey = "AirGuitar.watchSongPreparation"
    @Published private(set) var preparation: Preparation? {
        didSet {
            if let preparation, let data = try? JSONEncoder().encode(preparation) {
                UserDefaults.standard.set(data, forKey: preferenceKey)
            }
        }
    }
    @Published private(set) var songs: [WatchSong] = []
    @Published var message: String?
    private var didCompleteActivation = false
    private var acceptsImmediateReceipts = false
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask)[0]
        .appendingPathComponent("Songs", isDirectory: true)

    override init() {
        super.init()
        refresh()
        if let data = UserDefaults.standard.data(forKey: preferenceKey) {
            preparation = try? JSONDecoder().decode(Preparation.self, from: data)
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func refresh() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory,
                          includingPropertiesForKeys: nil)) ?? []
        songs = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let song = try? JSONDecoder().decode(WatchSong.self, from: data),
                  FileManager.default.fileExists(atPath: song.url.path) else { return nil }
            return song
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func remove(_ song: WatchSong) {
        do {
            if song.url != WatchSong.practice?.url, FileManager.default.fileExists(atPath: song.url.path) {
                try FileManager.default.removeItem(at: song.url)
            }
            try FileManager.default.removeItem(at: Self.directory.appendingPathComponent("\(song.id).json"))
            songs.removeAll { $0.id == song.id }
            if preparation?.request.id == song.id { manualSelection(nil) }
        } catch { message = "删除失败：\(error.localizedDescription)" }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        let context = session.receivedApplicationContext
        let request = SongPreparation(context: context)
        DispatchQueue.main.async {
            self.didCompleteActivation = true
            if let error { self.message = error.localizedDescription }
            if let request { self.receive(request, isPractice: context["isPractice"] as? Bool == true) }
            else if activationState == .activated { self.reportPreparation() }
        }
    }

    /// Hold the SwiftUI refresh task until the connectivity delegate has been
    /// given its pending contexts and files, including on a cold watch launch.
    @MainActor
    func finishBackgroundDelivery() async {
        guard WCSession.isSupported() else { return }
        while !didCompleteActivation || WCSession.default.hasContentPending {
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let request = SongPreparation(context: context) else { return }
        DispatchQueue.main.async { self.receive(request, isPractice: context["isPractice"] as? Bool == true) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            let isPractice = message["isPractice"] as? Bool == true
            if let request = SongPreparation(context: message) {
                self.acceptsImmediateReceipts = true
                self.receive(request, isPractice: isPractice, reply: replyHandler)
            } else if message["type"] as? String == "songProbe",
                      let rawID = message["id"] as? String, let id = UUID(uuidString: rawID) {
                self.acceptsImmediateReceipts = true
                let present = self.availableSong(id, useBundledPractice: isPractice) != nil
                replyHandler(["type": present ? "songPresent" : "songNeeded", "id": rawID])
            } else {
                replyHandler(["type": "unsupported"])
            }
        }
    }

    private func receive(_ request: SongPreparation, isPractice: Bool,
                         reply: (([String: Any]) -> Void)? = nil) {
        if let current = preparation, request != current.request, request.revision <= current.request.revision {
            if let reply {
                var response = request.context
                response["type"] = "songSkipped"
                reply(response)
            }
            return
        }
        _ = availableSong(request.id, useBundledPractice: isPractice)
        if preparation?.request != request {
            preparation = Preparation(request: request, state: .waiting)
        }
        reportPreparation(reply: reply)
    }

    func finishPreparation(_ request: SongPreparation) {
        guard preparation?.request == request, preparation?.state == .waiting else { return }
        preparation = Preparation(request: request, state: .ready)
        reportPreparation()
    }

    func manualSelection(_ id: UUID?) {
        guard let current = preparation else { return }
        let state: Preparation.State = id == current.request.id ? .ready : .skipped
        guard current.state != state else { return }
        preparation = Preparation(request: current.request, state: state)
        reportPreparation()
    }

    private func reportPreparation(reply: (([String: Any]) -> Void)? = nil) {
        guard let current = preparation else { return }
        var response = current.request.context
        if current.state == .skipped {
            response["type"] = "songSkipped"
        } else if cachedSong(current.request.id) == nil {
            if current.state == .ready { preparation = Preparation(request: current.request, state: .waiting) }
            response["type"] = "songNeeded"
        } else if current.state == .ready {
            response["type"] = "songReady"
        } else {
            // Imported and playable. Selection can wait for the current performance to finish.
            response["type"] = "songPresent"
        }
        if let reply { reply(response) }
        else if acceptsImmediateReceipts || response["type"] as? String != "songPresent" { sendReceipt(response) }
    }

    private func sendReceipt(_ receipt: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if acceptsImmediateReceipts, session.isReachable {
            session.sendMessage(receipt, replyHandler: { ack in
                if ack["received"] as? Bool != true { session.transferUserInfo(receipt) }
            }, errorHandler: { _ in session.transferUserInfo(receipt) })
        } else {
            session.transferUserInfo(receipt)
        }
    }

    private func cachedSong(_ id: UUID) -> WatchSong? {
        guard let song = songs.first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: song.url.path) else { return nil }
        return song
    }

    private func availableSong(_ id: UUID, useBundledPractice: Bool) -> WatchSong? {
        if let existing = cachedSong(id) { return existing }
        guard useBundledPractice, let practice = WatchSong.practice else { return nil }
        let alias = WatchSong(id: id, title: practice.title, duration: practice.duration, filename: practice.filename)
        do {
            try store(alias)
            return alias
        } catch { return nil }
    }

    /// Commit the manifest before publishing a song. Called on the main queue, like removal.
    private func store(_ song: WatchSong) throws {
        let manifest = Self.directory.appendingPathComponent("\(song.id).json")
        try JSONEncoder().encode(song).write(to: manifest, options: .atomic)
        var next = songs.filter { $0.id != song.id }
        let index = next.firstIndex { song.title.localizedStandardCompare($0.title) == .orderedAscending }
        next.insert(song, at: index ?? next.endIndex)
        songs = next
    }

    private func onLibraryQueue<T>(_ commit: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try commit() }
        return try DispatchQueue.main.sync(execute: commit)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let identifier = file.metadata?["id"] as? String ?? ""
        var receipt: [String: Any] = ["id": identifier]
        if let variant = file.metadata?["audioVariant"] as? String, ["compact", "original"].contains(variant) {
            receipt["audioVariant"] = variant
        }
        do {
            guard let id = UUID(uuidString: identifier),
                  let title = file.metadata?["title"] as? String else { throw ImportError.invalid }
            try importFile(file, id: id, title: title) { song in
                receipt["type"] = "songImported"
                receipt["title"] = song.title
                sendReceipt(receipt)
                self.message = "已收到：\(song.title)"
            }
        } catch {
            onLibraryQueue {
                receipt["type"] = "songImportFailed"
                receipt["reason"] = (error as? ImportError)?.reason ?? "storage"
                receipt["error"] = error.localizedDescription
                sendReceipt(receipt)
                self.message = "歌曲接收失败：\(error.localizedDescription)"
            }
        }
    }

    private func importFile(_ file: WCSessionFile, id: UUID, title: String, didImport: (WatchSong) -> Void) throws {
        let reused = onLibraryQueue {
            guard let existing = availableSong(id, useBundledPractice: file.metadata?["isPractice"] as? Bool == true) else {
                return false
            }
            didImport(existing)
            return true
        }
        if reused { return }
        let supported = ["mp3", "m4a", "wav", "aiff", "aif"]
        let urlExtension = file.fileURL.pathExtension.lowercased()
        let ext = supported.contains(urlExtension) ? urlExtension : (file.metadata?["ext"] as? String)?.lowercased()
        guard let ext, supported.contains(ext) else { throw ImportError.decode }
        let size = try file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...100 * 1024 * 1024).contains(size) else { throw ImportError.tooLarge }
        guard let player = try? AVAudioPlayer(contentsOf: file.fileURL),
              player.duration.isFinite, player.duration > 0, player.numberOfChannels > 0 else {
            throw ImportError.decode
        }
        let song = WatchSong(id: id, title: String(title.prefix(120)), duration: player.duration,
                             filename: "\(id).\(ext)")
        try onLibraryQueue {
            // A foreground probe could have installed a bundled alias during validation.
            if let existing = cachedSong(id) { didImport(existing); return }
            let manager = FileManager.default
            try manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            // WatchConnectivity owns the temporary URL only until this delegate returns.
            // Moving directly into Application Support avoids a full-size staging copy.
            if manager.fileExists(atPath: song.url.path) {
                _ = try manager.replaceItemAt(song.url, withItemAt: file.fileURL)
            } else {
                try manager.moveItem(at: file.fileURL, to: song.url)
            }
            do { try store(song) }
            catch { try? manager.removeItem(at: song.url); throw error }
            didImport(song)
        }
    }

    private enum ImportError: LocalizedError {
        case invalid, decode, tooLarge
        var reason: String {
            switch self {
            case .decode: return "decode"
            case .invalid, .tooLarge: return "invalid"
            }
        }
        var errorDescription: String? {
            switch self {
            case .invalid: return "歌曲信息不完整，请重新传输。"
            case .decode: return "文件无法解码，请用 MP3、M4A、WAV 或 AIFF 音频。"
            case .tooLarge: return "文件为空或超过 100 MB。"
            }
        }
    }
}
