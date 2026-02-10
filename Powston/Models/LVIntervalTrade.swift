//
//  LVIntervalTrade.swift
//  Powston
//
//  Per-interval P2P trade record from LocalVolts WebSocket API
//

import Foundation
import GRDB

// MARK: - LV Trade Direction

enum LVTradeDirection: String, Codable, CaseIterable {
    case sell = "Sell"
    case buy = "Buy"

    var displayName: String { rawValue }

    var icon: String {
        switch self {
        case .sell: return "arrow.up.circle.fill"
        case .buy: return "arrow.down.circle.fill"
        }
    }
}

// MARK: - LV Interval Trade Model

struct LVIntervalTrade: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lv_interval_trades"

    var id: UUID
    var siteId: Int
    var periodStart: Date
    var counterpartyName: String
    var cpFacility: String?
    var cpRegion: String?
    var direction: LVTradeDirection
    var volumeKwh: Double
    var sellPriceCents: Double?
    var buyPriceCents: Double?
    var category: String?
    var fetchedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case siteId = "site_id"
        case periodStart = "period_start"
        case counterpartyName = "counterparty_name"
        case cpFacility = "cp_facility"
        case cpRegion = "cp_region"
        case direction
        case volumeKwh = "volume_kwh"
        case sellPriceCents = "sell_price_cents"
        case buyPriceCents = "buy_price_cents"
        case category
        case fetchedAt = "fetched_at"
    }

    var priceCents: Double {
        switch direction {
        case .sell: return sellPriceCents ?? 0
        case .buy: return buyPriceCents ?? 0
        }
    }

    var revenue: Double {
        volumeKwh * priceCents / 100.0
    }

    var isSmartContract: Bool { category == "SC" }
    var isSelfReferral: Bool { category == "SR" }
}

// MARK: - API Parsing

extension LVIntervalTrade {
    static func parse(
        from dict: [String: Any],
        siteId: Int,
        periodStart: Date,
        fetchedAt: Date = Date()
    ) -> LVIntervalTrade? {
        guard let counterparty = dict["counterparty"] as? String,
              let volume = parseDouble(dict["volume"]),
              volume > 0 else {
            return nil
        }

        let dirStr = dict["direction"] as? String ?? "Sell"
        let direction: LVTradeDirection = dirStr.lowercased() == "buy" ? .buy : .sell

        // LocalVolts prices are in dollars (e.g., 0.278 = 27.8c/kWh)
        // Convert to cents for storage
        let sellPriceDollars = parseDouble(dict["sellPrice"])
        let buyPriceDollars = parseDouble(dict["buyPrice"])

        return LVIntervalTrade(
            id: UUID(),
            siteId: siteId,
            periodStart: periodStart,
            counterpartyName: counterparty,
            cpFacility: dict["cpFacility"] as? String,
            cpRegion: dict["cpRegion"] as? String,
            direction: direction,
            volumeKwh: volume,
            sellPriceCents: sellPriceDollars.map { $0 * 100.0 },  // Convert to cents
            buyPriceCents: buyPriceDollars.map { $0 * 100.0 },    // Convert to cents
            category: dict["category"] as? String,
            fetchedAt: fetchedAt
        )
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - Aggregation

struct LVIntervalTradeSummary: Identifiable {
    let id = UUID()
    let counterpartyName: String
    let direction: LVTradeDirection
    let totalVolumeKwh: Double
    let totalRevenue: Double
    let tradeCount: Int
    let avgPriceCents: Double
    let firstTrade: Date
    let lastTrade: Date
    let regions: Set<String>

    var daysSinceLastTrade: Int {
        Calendar.current.dateComponents([.day], from: lastTrade, to: Date()).day ?? 0
    }
}

extension Array where Element == LVIntervalTrade {
    func summarizeByCounterparty() -> [LVIntervalTradeSummary] {
        let grouped = Dictionary(grouping: self) { $0.counterpartyName }

        return grouped.compactMap { (name, trades) -> LVIntervalTradeSummary? in
            guard !trades.isEmpty else { return nil }

            let totalVolume = trades.reduce(0) { $0 + $1.volumeKwh }
            let totalRevenue = trades.reduce(0) { $0 + $1.revenue }
            let regions = Set(trades.compactMap { $0.cpRegion })
            let sortedDates = trades.map { $0.periodStart }.sorted()

            return LVIntervalTradeSummary(
                counterpartyName: name,
                direction: trades.first?.direction ?? .sell,
                totalVolumeKwh: totalVolume,
                totalRevenue: totalRevenue,
                tradeCount: trades.count,
                avgPriceCents: totalVolume > 0 ? (totalRevenue / totalVolume) * 100 : 0,
                firstTrade: sortedDates.first ?? Date(),
                lastTrade: sortedDates.last ?? Date(),
                regions: regions
            )
        }.sorted { $0.totalRevenue > $1.totalRevenue }
    }

    func groupByPeriod() -> [Date: [LVIntervalTrade]] {
        Dictionary(grouping: self) { $0.periodStart }
    }

    func groupByDay() -> [Date: [LVIntervalTrade]] {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        return Dictionary(grouping: self) { trade in
            calendar.startOfDay(for: trade.periodStart)
        }
    }
}
