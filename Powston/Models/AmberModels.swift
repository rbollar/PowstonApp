//
//  AmberModels.swift
//  Powston
//
//  Models for the Amber Electric public API (https://api.amber.com.au/v1)
//  Spec: https://app.amber.com.au/developers/documentation/
//

import Foundation
import SwiftUI

// MARK: - Site

struct AmberSite: Codable, Identifiable {
    let id: String
    let nmi: String
    let channels: [AmberChannel]
    let network: String
    let status: AmberSiteStatus
    let activeFrom: String?
    let closedOn: String?
    let intervalLength: Int
}

struct AmberChannel: Codable {
    let identifier: String
    let type: AmberChannelType
    let tariff: String
}

enum AmberSiteStatus: String, Codable {
    case pending, active, closed
}

enum AmberChannelType: String, Codable {
    case general
    case controlledLoad
    case feedIn

    var displayName: String {
        switch self {
        case .general: return "General"
        case .controlledLoad: return "Controlled Load"
        case .feedIn: return "Feed In"
        }
    }
}

// MARK: - Price Descriptor

enum AmberPriceDescriptor: String, Codable {
    case negative, extremelyLow, veryLow, low, neutral, high, spike

    var displayName: String {
        switch self {
        case .negative: return "Negative"
        case .extremelyLow: return "Extremely Low"
        case .veryLow: return "Very Low"
        case .low: return "Low"
        case .neutral: return "Neutral"
        case .high: return "High"
        case .spike: return "Spike"
        }
    }

    /// Color for a buy (general) price — low is good
    var buyColor: Color {
        switch self {
        case .negative, .extremelyLow: return .teal
        case .veryLow, .low: return .green
        case .neutral: return .primary
        case .high: return .orange
        case .spike: return .red
        }
    }

    /// Color for a sell (feedIn) price — high is good
    var sellColor: Color {
        switch self {
        case .negative, .extremelyLow: return .red
        case .veryLow, .low: return .orange
        case .neutral: return .primary
        case .high: return .green
        case .spike: return .teal
        }
    }
}

enum AmberSpikeStatus: String, Codable {
    case none, potential, spike
}

// MARK: - Intervals (prices)

struct AmberTariffInformation: Codable {
    let period: String?
    let season: String?
    let block: Int?
    let demandWindow: Bool?
}

struct AmberAdvancedPrice: Codable {
    let low: Double
    let predicted: Double
    let high: Double
}

/// A price interval from /prices or /prices/current.
/// `type` distinguishes ActualInterval / CurrentInterval / ForecastInterval.
struct AmberInterval: Codable, Identifiable {
    let type: String
    let date: String
    let duration: Int
    let startTime: String
    let endTime: String
    let nemTime: String
    let perKwh: Double
    let renewables: Double
    let spotPerKwh: Double
    let channelType: AmberChannelType
    let spikeStatus: AmberSpikeStatus
    let tariffInformation: AmberTariffInformation?
    let descriptor: AmberPriceDescriptor
    let estimate: Bool?          // CurrentInterval only
    let advancedPrice: AmberAdvancedPrice?  // Current/Forecast only
    let range: AmberAdvancedPriceRange?

    var id: String { "\(channelType.rawValue)-\(nemTime)" }

    var isCurrent: Bool { type == "CurrentInterval" }
    var isForecast: Bool { type == "ForecastInterval" }

    /// NEM interval end as a Date
    var nemDate: Date? {
        Self.isoFormatter.date(from: nemTime)
    }

    private static let isoFormatter = ISO8601DateFormatter()
}

struct AmberAdvancedPriceRange: Codable {
    let min: Double?
    let max: Double?
}

// MARK: - Usage

struct AmberUsageRecord: Codable, Identifiable {
    let type: String
    let duration: Int
    let date: String
    let startTime: String
    let endTime: String
    let nemTime: String
    let perKwh: Double
    let renewables: Double?
    let spotPerKwh: Double?
    let channelType: AmberChannelType
    let channelIdentifier: String
    let kwh: Double
    let quality: String          // "estimated" | "billable"
    let cost: Double             // cents, negative for feedIn earnings
    let spikeStatus: AmberSpikeStatus?
    let tariffInformation: AmberTariffInformation?
    let descriptor: AmberPriceDescriptor?

    var id: String { "\(channelIdentifier)-\(nemTime)" }
}

// MARK: - Usage Summary

/// Aggregated daily usage across channels
struct AmberDailyUsage: Identifiable {
    let date: String
    let importKwh: Double
    let importCostDollars: Double      // positive = cost
    let exportKwh: Double
    let exportEarningsDollars: Double  // positive = earnings, NEGATIVE when the
                                       // site paid to export (negative feed-in prices)
    let allBillable: Bool

    var id: String { date }
    var netCostDollars: Double { importCostDollars - exportEarningsDollars }

    static func aggregate(_ records: [AmberUsageRecord]) -> [AmberDailyUsage] {
        let byDate = Dictionary(grouping: records) { $0.date }
        return byDate.map { date, recs in
            let imports = recs.filter { $0.channelType != .feedIn }
            let exports = recs.filter { $0.channelType == .feedIn }
            return AmberDailyUsage(
                date: date,
                importKwh: imports.reduce(0) { $0 + $1.kwh },
                importCostDollars: imports.reduce(0) { $0 + $1.cost } / 100.0,
                // Observed API behavior (Aug 2026): feedIn kwh is positive on
                // the B1 channel; abs() on the sum tolerates either convention
                // since a volume total can't legitimately be negative
                exportKwh: abs(exports.reduce(0) { $0 + $1.kwh }),
                // feedIn cost is negative when earning, positive when the site
                // PAYS to export — negating preserves that sign, abs() would not
                exportEarningsDollars: -exports.reduce(0) { $0 + $1.cost } / 100.0,
                allBillable: recs.allSatisfy { $0.quality == "billable" }
            )
        }.sorted { $0.date < $1.date }
    }
}
