//
//  ManualAction.swift
//  Powston
//

import Foundation

struct ManualActionsResponse: Codable {
    let total: Int
    let items: [ManualAction]
}

// MARK: - Action Params

/// A value inside a manual action's `action_params` dictionary.
/// The API mixes numbers (power limits, SOC) with strings (reason).
enum ActionParamValue: Codable, Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.typeMismatch(
                ActionParamValue.self,
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Unsupported action_params value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .bool(let b): try container.encode(b)
        }
    }

    var numberValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }
}

/// One parameter definition from GET /api/action_params/metadata/{brand}
struct ActionParamField: Codable, Identifiable {
    let key: String
    let label: String
    let type: String           // "number" | "string"
    let unit: String?
    let min: Double?
    let max: Double?
    let maxLength: Int?
    let description: String?

    var id: String { key }
}

/// GET /api/action_params/metadata/{brand} response:
/// common params plus brand-specific extras
struct ActionParamsMetadata: Codable {
    let brand: String
    let common: [ActionParamField]
    let extras: [ActionParamField]

    /// Numeric params worth exposing in the override UI. min_soc/max_soc are
    /// already dedicated bailout fields and `reason` duplicates notes.
    var overrideFields: [ActionParamField] {
        (common + extras).filter {
            $0.type == "number" && !["min_soc", "max_soc", "reason"].contains($0.key)
        }
    }
}

struct ManualAction: Codable, Identifiable {
    let id: Int
    let inverterId: Int
    let action: String  // API returns "action" not "mode"
    let reason: String?
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
    let userCode: String?
    let time: String?
    let actionParams: [String: ActionParamValue]?

    // Alias for consistency
    var mode: String { action }

    /// Compact human-readable summary of any brand action params, e.g.
    /// "Charge ≤ 5 kW • Feed-in ≤ 10 kW"
    var actionParamsSummary: String? {
        guard let params = actionParams, !params.isEmpty else { return nil }
        let labels: [String: (String, String)] = [
            "optimal_charging": ("Charge ≤", "W"),
            "optimal_discharging": ("Discharge ≤", "W"),
            "feed_in_power_limitation": ("Feed-in ≤", "W"),
            "grid_power": ("Grid", "W"),
            "backup_soc": ("Backup SOC", "%"),
            "min_soc": ("Min SOC", "%"),
            "max_soc": ("Max SOC", "%")
        ]
        let parts: [String] = params.keys.sorted().compactMap { key in
            guard let value = params[key]?.numberValue else { return nil }
            let (label, unit) = labels[key] ?? (key, "")
            if unit == "W" && abs(value) >= 1000 {
                return String(format: "%@ %.1f kW", label, value / 1000)
            }
            return String(format: "%@ %.0f%@", label, value, unit)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case inverterId = "inverter_id"
        case action
        case reason
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
        case userCode = "user_code"
        case time
        case actionParams = "action_params"
    }
    
    var isActive: Bool {
        guard let endTimeStr = endTime else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let endDate = formatter.date(from: endTimeStr) {
            return endDate > Date()
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let endDate = formatter.date(from: endTimeStr) {
            return endDate > Date()
        }
        return false
    }
    
    /// Currently executing (started and not ended)
    var isCurrentlyActive: Bool {
        let now = Date()
        let start = startDate ?? Date.distantPast
        let end = endDate ?? Date.distantFuture
        return start <= now && end > now
    }
    
    /// Scheduled for future (not yet started)
    var isScheduled: Bool {
        guard let start = startDate else { return false }
        return start > Date()
    }
    
    /// Check if this action overlaps with a given time range
    func overlaps(with start: Date, end: Date) -> Bool {
        let myStart = startDate ?? Date.distantPast
        let myEnd = endDate ?? Date.distantFuture
        // Overlap exists if one starts before the other ends
        return myStart < end && start < myEnd
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
    
    var formattedRemainingTime: String {
        guard let end = endDate else { return "No end time" }
        let remaining = end.timeIntervalSince(Date())
        guard remaining > 0 else { return "Expired" }
        
        let minutes = Int(remaining / 60)
        if minutes < 60 {
            return "\(minutes)m remaining"
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            if mins == 0 {
                return "\(hours)h remaining"
            }
            return "\(hours)h \(mins)m remaining"
        }
    }
    
    var formattedTimeRange: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        
        let startStr = startDate.map { formatter.string(from: $0) } ?? "?"
        let endStr = endDate.map { formatter.string(from: $0) } ?? "?"
        return "\(startStr) – \(endStr)"
    }
    
    var formattedStartsIn: String {
        guard let start = startDate else { return "Unknown" }
        let remaining = start.timeIntervalSince(Date())
        guard remaining > 0 else { return "Now" }
        
        let minutes = Int(remaining / 60)
        if minutes < 60 {
            return "in \(minutes)m"
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            if mins == 0 {
                return "in \(hours)h"
            }
            return "in \(hours)h \(mins)m"
        }
    }
}
