//
//  P2PCounterpartyTrade.swift
//  Powston
//
//  Model for storing individual counterparty trade details
//  Enables tracking buyer patterns over time for relationship building
//

import Foundation
import GRDB

// MARK: - Counterparty Trade Model

struct P2PCounterpartyTrade: Identifiable, Equatable, Sendable {
    var id: UUID
    let tradeRecordId: UUID      // Links to parent P2PTradeRecord
    let siteId: Int
    let counterpartyName: String
    let volumeKwh: Double
    let priceCents: Double
    let tradeDate: Date          // Date of the trade (from import range)
    let importedAt: Date
    let direction: P2PTradeDirection  // Sell or Buy
    let facility: String?        // Counterparty's facility/location (from LV API)
    
    // Computed properties
    var revenue: Double {
        volumeKwh * priceCents / 100.0
    }
    
    var isCommercial: Bool {
        let lower = counterpartyName.lowercased()
        return lower.contains("pty ltd") ||
               lower.contains("pty. ltd") ||
               lower.contains(" ltd") ||
               lower.contains("holdings") ||
               lower.contains("group") ||
               lower.contains("services") ||
               lower.contains("solutions") ||
               lower.contains("enterprises") ||
               lower.contains("industries") ||
               lower.contains("corp") ||
               lower.contains("inc") ||
               lower.contains("cafe") ||
               lower.contains("restaurant") ||
               lower.contains("hotel") ||
               lower.contains("meats") ||
               lower.contains("bakery") ||
               lower.contains("automation")
    }
}

// MARK: - GRDB Persistence

extension P2PCounterpartyTrade: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "p2p_counterparty_trades" }
    
    init(row: Row) {
        let idString: String = row["id"]
        id = UUID(uuidString: idString) ?? UUID()

        let tradeRecordIdString: String = row["trade_record_id"]
        tradeRecordId = UUID(uuidString: tradeRecordIdString) ?? UUID()

        siteId = row["site_id"]
        counterpartyName = row["counterparty_name"]
        volumeKwh = row["volume_kwh"]
        priceCents = row["price_cents"]
        tradeDate = row["trade_date"]
        importedAt = row["imported_at"]

        // Direction - default to sell for backwards compatibility
        if let directionStr: String = row["direction"],
           let dir = P2PTradeDirection(rawValue: directionStr) {
            direction = dir
        } else {
            direction = .sell
        }

        // Facility - only present for LV API trades
        facility = row["facility"]
    }
    
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["trade_record_id"] = tradeRecordId.uuidString
        container["site_id"] = siteId
        container["counterparty_name"] = counterpartyName
        container["volume_kwh"] = volumeKwh
        container["price_cents"] = priceCents
        container["trade_date"] = tradeDate
        container["imported_at"] = importedAt
        container["direction"] = direction.rawValue
    }
}

// MARK: - Counterparty Summary (Aggregated)

struct P2PCounterpartySummary: Identifiable {
    let id = UUID()
    let counterpartyName: String
    let totalVolumeKwh: Double
    let totalRevenue: Double
    let tradeCount: Int
    let avgPriceCents: Double
    let minPriceCents: Double
    let maxPriceCents: Double
    let firstTradeDate: Date
    let lastTradeDate: Date
    let isCommercial: Bool
    
    var daysSinceLastTrade: Int {
        Calendar.current.dateComponents([.day], from: lastTradeDate, to: Date()).day ?? 0
    }
    
    var tradingDurationDays: Int {
        max(1, Calendar.current.dateComponents([.day], from: firstTradeDate, to: lastTradeDate).day ?? 0 + 1)
    }
    
    var avgVolumePerTrade: Double {
        tradeCount > 0 ? totalVolumeKwh / Double(tradeCount) : 0
    }
}

// MARK: - Counterparty Trade History (for detail view)

struct P2PCounterpartyTradeHistory: Identifiable {
    let id = UUID()
    let tradeDate: Date
    let volumeKwh: Double
    let priceCents: Double
    let revenue: Double
    let tradeCount: Int  // Number of individual trades combined (for multi-day imports)
    let importStart: Date?  // Start date of the import this came from
    let importEnd: Date?    // End date of the import this came from
    let direction: P2PTradeDirection  // Sell or Buy

    /// Formatted import date range for display
    var importRangeString: String? {
        guard let start = importStart, let end = importEnd else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return formatter.string(from: start)
        } else {
            return "\(formatter.string(from: start))–\(formatter.string(from: end))"
        }
    }
}

// MARK: - Price Demand (Aggregated by price point)

struct P2PPriceDemand: Identifiable {
    let id = UUID()
    let priceCents: Double
    let actualVolumeKwh: Double
    let provisionalVolumeKwh: Double
    let actualRevenue: Double
    let provisionalRevenue: Double
    let actualBuyerCount: Int
    let provisionalBuyerCount: Int

    var totalVolumeKwh: Double {
        actualVolumeKwh + provisionalVolumeKwh
    }

    var totalRevenue: Double {
        actualRevenue + provisionalRevenue
    }

    var totalBuyerCount: Int {
        // Unique buyers across actual and provisional (approximation - may double count)
        actualBuyerCount + provisionalBuyerCount
    }
}

// MARK: - JSON Serialization for iCloud KVS

struct P2PCounterpartyTradeDTO: Codable {
    let id: UUID
    let tradeRecordId: UUID
    let siteId: Int
    let counterpartyName: String
    let volumeKwh: Double
    let priceCents: Double
    let tradeDate: Date
    let importedAt: Date
    let direction: P2PTradeDirection?  // Optional for backwards compatibility

    init(from trade: P2PCounterpartyTrade) {
        self.id = trade.id
        self.tradeRecordId = trade.tradeRecordId
        self.siteId = trade.siteId
        self.counterpartyName = trade.counterpartyName
        self.volumeKwh = trade.volumeKwh
        self.priceCents = trade.priceCents
        self.tradeDate = trade.tradeDate
        self.importedAt = trade.importedAt
        self.direction = trade.direction
    }

    func toTrade() -> P2PCounterpartyTrade {
        P2PCounterpartyTrade(
            id: id,
            tradeRecordId: tradeRecordId,
            siteId: siteId,
            counterpartyName: counterpartyName,
            volumeKwh: volumeKwh,
            priceCents: priceCents,
            tradeDate: tradeDate,
            importedAt: importedAt,
            direction: direction ?? .sell,  // Default to sell for old data
            facility: nil  // CSV imports don't have facility info
        )
    }
}

extension P2PCounterpartyTrade {
    /// Encode array to JSON for iCloud KVS storage
    static func encodeForSync(_ trades: [P2PCounterpartyTrade]) -> Data? {
        let dtos = trades.map { P2PCounterpartyTradeDTO(from: $0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(dtos)
    }
    
    /// Decode array from JSON from iCloud KVS
    static func decodeFromSync(_ data: Data) -> [P2PCounterpartyTrade]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let dtos = try? decoder.decode([P2PCounterpartyTradeDTO].self, from: data) else {
            return nil
        }
        return dtos.map { $0.toTrade() }
    }
}
