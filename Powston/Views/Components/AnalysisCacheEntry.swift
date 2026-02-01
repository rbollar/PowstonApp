import Foundation

struct AnalysisCacheEntry: Codable, Sendable {
    var rowId: Int?
    var siteId: Int
    var analysisType: String
    var parametersHash: String
    var resultJson: String
    var computedAt: Date
    var validUntil: Date?

    enum CodingKeys: String, CodingKey {
        case rowId
        case siteId
        case analysisType
        case parametersHash
        case resultJson
        case computedAt
        case validUntil
    }

    var isValid: Bool {
        guard let until = validUntil else { return true }
        return Date() < until
    }
}

extension AnalysisCacheEntry: Identifiable {
    var id: String { "\(siteId)_\(analysisType)_\(parametersHash)" }
}
