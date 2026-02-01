//
//  ManualAction.swift
//  Powston
//

import Foundation

struct ManualActionsResponse: Codable {
    let total: Int
    let items: [ManualAction]
}

struct ManualAction: Codable, Identifiable {
    let id: Int
    let inverterId: Int
    let mode: String
    let notes: String?
    let minutes: Int?
    let startTime: String?
    let endTime: String?
    let minSoc: Int?
    let maxSoc: Int?
    let minBuyPrice: Double?
    let maxBuyPrice: Double?
    let minSellPrice: Double?
    let maxSellPrice: Double?
    let exportLimit: Bool?
    let createdAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case inverterId = "inverter_id"
        case mode
        case notes
        case minutes
        case startTime = "start_time"
        case endTime = "end_time"
        case minSoc = "min_soc"
        case maxSoc = "max_soc"
        case minBuyPrice = "min_buy_price"
        case maxBuyPrice = "max_buy_price"
        case minSellPrice = "min_sell_price"
        case maxSellPrice = "max_sell_price"
        case exportLimit = "export_limit"
        case createdAt = "created_at"
    }
    
    var isActive: Bool {
        // Active if no end_time or end_time is in the future
        guard let endTimeStr = endTime else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let endDate = formatter.date(from: endTimeStr) {
            return endDate > Date()
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let endDate = formatter.date(from: endTimeStr) {
            return endDate > Date()
        }
        return false
    }
    
    var startDate: Date? {
        guard let startTimeStr = startTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: startTimeStr) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: startTimeStr)
    }
    
    var endDate: Date? {
        guard let endTimeStr = endTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: endTimeStr) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: endTimeStr)
    }
}
