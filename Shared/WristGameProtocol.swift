import Combine
import Foundation

enum WristGameOutput: String, Codable, CaseIterable {
    case phone, watch
}

/// Times on the wire are seconds on the watch's monotonic uptime clock.
enum WristGameMessage: Codable, Equatable {
    case prepare(session: UUID, song: UUID, practice: Bool, output: WristGameOutput)
    case ready(session: UUID)
    case reject(session: UUID, reason: String)
    case commit(session: UUID, watchStart: Double)
    case started(session: UUID)
    case stroke(session: UUID, sequence: Int, watchTime: Double, strength: Double)
    case feedback(session: UUID, sequence: Int, hit: Bool)
    case playhead(session: UUID, watchTime: Double, songTime: Double)
    case stop(session: UUID)
    case ended(session: UUID)

    var sessionID: UUID {
        switch self {
        case let .prepare(id, _, _, _), let .ready(id), let .reject(id, _),
             let .commit(id, _), let .started(id), let .stroke(id, _, _, _),
             let .feedback(id, _, _), let .playhead(id, _, _), let .stop(id), let .ended(id):
            return id
        }
    }

    fileprivate var isValid: Bool {
        switch self {
        case let .commit(_, start):
            return start.isFinite && start >= 0
        case let .stroke(_, number, time, strength):
            return number >= 0 && time.isFinite && time >= 0 && (0...1).contains(strength)
        case let .playhead(_, time, position):
            return time.isFinite && time >= 0 && position.isFinite && position >= 0
        case let .feedback(_, number, _):
            return number >= 0
        case let .reject(_, reason):
            return !reason.isEmpty && reason.utf8.count <= 1024
        default:
            return true
        }
    }
}

/// Uses WCSession's live request/reply path only. Game gestures must never be delivered
/// later as background song transfers. A transport ACK does not start a game.
final class WristGameLink: ObservableObject {
    typealias Packet = [String: Any]
    typealias Transport = (Packet, @escaping (Packet) -> Void, @escaping (Error) -> Void) -> Void
    private typealias Reply = (packet: Packet, receivedAt: Double)

    @Published private(set) var isReachable = false
    var onMessage: ((WristGameMessage) -> Void)?
    private let transport: Transport
    private static let channel = "WristGuitar.liveGame"
    static var now: Double { ProcessInfo.processInfo.systemUptime }

    init(transport: @escaping Transport) { self.transport = transport }

    func updateReachability(_ reachable: Bool) {
        if isReachable != reachable { isReachable = reachable }
    }

    @MainActor
    func send(_ message: WristGameMessage, onFailure: ((String) -> Void)? = nil) {
        guard message.isValid, let data = try? JSONEncoder().encode(message) else {
            onFailure?("游戏消息无效。")
            return
        }
        exchange(["command": "event", "event": data]) { result in
            if case let .failure(error) = result { onFailure?(error.localizedDescription) }
        }
    }

    /// Remote uptime minus local uptime. Four timestamps remove time spent on the
    /// peer's main queue. Pick the least congested of three short exchanges.
    @MainActor
    func clockOffset() async throws -> Double {
        var best: (trip: Double, offset: Double)?
        for _ in 0..<3 {
            try Task.checkCancellation()
            let sent = Self.now
            do {
                let sample: Reply = try await withCheckedThrowingContinuation { continuation in
                    exchange(["command": "clock"]) { result in
                        continuation.resume(with: result)
                    }
                }
                guard let receive = sample.packet["receivedAt"] as? Double, let reply = sample.packet["repliedAt"] as? Double,
                      receive.isFinite, reply.isFinite, reply >= receive else { throw LinkError.invalidReply }
                let trip = max(0, (sample.receivedAt - sent) - (reply - receive))
                let offset = ((receive - sent) + (reply - sample.receivedAt)) / 2
                if trip < (best?.trip ?? .infinity) { best = (trip, offset) }
            } catch {
                if best != nil { break }
                throw error
            }
        }
        try Task.checkCancellation()
        guard let best else { throw LinkError.invalidReply }
        return best.offset
    }

    /// Called on the main queue by each app's existing WCSession delegate.
    /// false leaves all pre-existing song selection and file receipt messages alone.
    func receive(_ packet: Packet, receivedAt: Double, reply: (Packet) -> Void) -> Bool {
        guard packet["channel"] as? String == Self.channel else { return false }
        var acknowledgement: Packet = ["channel": Self.channel, "version": 1, "accepted": false]
        guard packet["version"] as? Int == 1 else { reply(acknowledgement); return true }
        switch packet["command"] as? String {
        case "clock":
            acknowledgement["accepted"] = true
            acknowledgement["receivedAt"] = receivedAt
            acknowledgement["repliedAt"] = Self.now
        case "event":
            guard let callback = onMessage, let data = packet["event"] as? Data, data.count <= 8192,
                  let message = try? JSONDecoder().decode(WristGameMessage.self, from: data), message.isValid else {
                reply(acknowledgement)
                return true
            }
            acknowledgement["accepted"] = true
            reply(acknowledgement)
            callback(message)
            return true
        default: break
        }
        reply(acknowledgement)
        return true
    }

    @MainActor
    private func exchange(_ fields: Packet, completion: @escaping (Result<Reply, Error>) -> Void) {
        guard isReachable else { completion(.failure(LinkError.unreachable)); return }
        var packet = fields
        packet["channel"] = Self.channel
        packet["version"] = 1
        var completed = false
        func finish(_ result: Result<Reply, Error>) {
            guard !completed else { return }
            completed = true
            completion(result)
        }
        transport(packet, { reply in
            let receivedAt = Self.now
            DispatchQueue.main.async {
                if reply["channel"] as? String == Self.channel,
                   reply["version"] as? Int == 1, reply["accepted"] as? Bool == true {
                    finish(.success((reply, receivedAt)))
                } else { finish(.failure(LinkError.invalidReply)) }
            }
        }, { _ in DispatchQueue.main.async { finish(.failure(LinkError.unreachable)) } })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { finish(.failure(LinkError.timeout)) }
    }

    private enum LinkError: LocalizedError {
        case unreachable, invalidReply, timeout
        var errorDescription: String? {
            switch self {
            case .unreachable: return "手机与手表未联机，请在两端打开 Wrist Guitar。"
            case .invalidReply: return "另一台设备尚未进入联机游戏，请确认两端已更新并打开 App。"
            case .timeout: return "另一台设备未及时回应，请在两端打开 App 后重试。"
            }
        }
    }
}
