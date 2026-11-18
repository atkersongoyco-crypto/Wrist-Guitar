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
            try FileManager.default.removeItem(at: song.url)
            try FileManager.default.removeItem(at: Self.directory.appendingPathComponent("\(song.id).json"))
            refresh()
            if preparation?.request.id == song.id { manualSelection(nil) }
        } catch { message = "删除失败：\(error.localizedDescription)" }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        let request = SongPreparation(context: session.receivedApplicationContext)
        DispatchQueue.main.async {
            self.didCompleteActivation = true
            if let error { self.message = error.localizedDescription }
            if let request { self.receive(request) }
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
        DispatchQueue.main.async { self.receive(request) }
    }

    private func receive(_ request: SongPreparation) {
        if let current = preparation, request != current.request,
           request.revision <= current.request.revision { return }
        if preparation?.request != request {
            preparation = Preparation(request: request, state: .waiting)
        }
        reportPreparation()
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

    private func reportPreparation() {
        guard let current = preparation, WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        var reply = current.request.context
        if current.state == .skipped {
            reply["type"] = "songSkipped"
        } else if !songs.contains(where: { $0.id == current.request.id }) {
            if current.state == .ready { preparation = Preparation(request: current.request, state: .waiting) }
            reply["type"] = "songNeeded"
        } else if current.state == .ready {
            reply["type"] = "songReady"
        } else {
            return
        }
        WCSession.default.transferUserInfo(reply)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let identifier = file.metadata?["id"] as? String ?? ""
        do {
            guard let id = UUID(uuidString: identifier),
                  let title = file.metadata?["title"] as? String else { throw ImportError.invalid }
            let ext = file.fileURL.pathExtension.lowercased()
            guard ["mp3", "m4a", "wav", "aiff", "aif"].contains(ext) else { throw ImportError.invalid }
            let size = try file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 100 * 1024 * 1024 else { throw ImportError.tooLarge }
            let player = try AVAudioPlayer(contentsOf: file.fileURL)
            guard player.duration.isFinite, player.duration > 0 else { throw ImportError.invalid }
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let name = "\(id).\(ext)"
            let destination = Self.directory.appendingPathComponent(name)
            // Stage on disk, then replace atomically without buffering a whole song in RAM.
            let staged = Self.directory.appendingPathComponent(".import-\(UUID()).\(ext)")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: file.fileURL, to: staged)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
            let song = WatchSong(id: id, title: String(title.prefix(120)),
                                 duration: player.duration, filename: name)
            try JSONEncoder().encode(song).write(to: Self.directory.appendingPathComponent("\(id).json"),
                                                options: .atomic)
            session.transferUserInfo(["type": "songImported", "id": identifier, "title": song.title])
            DispatchQueue.main.async { self.refresh(); self.message = "已收到：\(song.title)" }
        } catch {
            session.transferUserInfo(["type": "songImportFailed", "id": identifier,
                                      "error": error.localizedDescription])
            DispatchQueue.main.async { self.message = "歌曲接收失败：\(error.localizedDescription)" }
        }
    }

    private enum ImportError: LocalizedError {
        case invalid, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: return "文件无法解码，请用 MP3、M4A、WAV 或 AIFF 音频。"
            case .tooLarge: return "文件为空或超过 100 MB。"
            }
        }
    }
}
