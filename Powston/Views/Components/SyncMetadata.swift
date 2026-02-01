import Foundation

struct SyncMetadata: Codable, Sendable {
    var rowId: Int?
    var entityType: String
    var siteId: Int
    var inverterId: Int?
    var lastSyncTime: Date?
    var lastRecordTime: Date?
    var recordCount: Int

    enum CodingKeys: String, CodingKey {
        case rowId
        case entityType
        case siteId
        case inverterId
        case lastSyncTime
        case lastRecordTime
        case recordCount
    }

    static func actionsKey(siteId: Int, inverterId: Int) -> String {
        "actions_\(siteId)_\(inverterId)"
    }

    static func summariesKey(siteId: Int) -> String {
        "summaries_\(siteId)"
    }
}
