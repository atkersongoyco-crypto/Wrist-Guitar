import Foundation

/// Only the latest application context requests selection. Audio files can
/// arrive independently, in any order, and each version has its own ID.
struct SongPreparation: Codable, Equatable {
    let id: UUID
    let revision: Int64

    init(id: UUID, revision: Int64) {
        self.id = id
        self.revision = revision
    }

    init?(context: [String: Any]) {
        guard context["type"] as? String == "prepareSong",
              let rawID = context["id"] as? String, let id = UUID(uuidString: rawID),
              let revision = (context["revision"] as? NSNumber)?.int64Value, revision > 0 else { return nil }
        self.init(id: id, revision: revision)
    }

    var context: [String: Any] {
        ["type": "prepareSong", "id": id.uuidString, "revision": revision]
    }
}
