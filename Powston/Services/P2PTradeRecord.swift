//
//  P2PTradeRecord.swift
//  Powston
//
//  Model for storing imported P2P trade data
//

import Foundation
import GRDB

// MARK: - P2P Trade Record Model

struct P2PTradeRecord: Identifiable, Equatable {
    var id: UUID
    let siteId: Int
    let startDate: Date          // Range start (or single date)
    let endDate: Date            // Range end (same as start for single day)
    let p2pKwh: Double
    let p2pRevenue: Double       // Actual $ received
    let counterpartyCount: Int
    let importedAt: Date
    let source: String           // "mobile" or "desktop"
    let isProvisional: Bool      // true = forecast/estimate, false = actual data
    let direction: P2PTradeDirection  // Sell or Buy
    
    // Computed properties
    var avgPriceCents: Double {
        guard p2pKwh > 0 else { return 0 }
        return (p2pRevenue / p2pKwh) * 100
    }
    
    var dayCount: Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        return max(1, days + 1)
    }
    
    var dailyKwh: Double {
        p2pKwh / Double(dayCount)
    }
    
    var dailyRevenue: Double {
        p2pRevenue / Double(dayCount)
    }
    
    /// Check if this record covers a specific date
    func coversDate(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        return targetDay >= start && targetDay <= end
    }
    
    /// Check if this record overlaps with another date range
    func overlaps(start: Date, end: Date) -> Bool {
        let calendar = Calendar.current
        let thisStart = calendar.startOfDay(for: startDate)
        let thisEnd = calendar.startOfDay(for: endDate)
        let otherStart = calendar.startOfDay(for: start)
        let otherEnd = calendar.startOfDay(for: end)
        
        return thisStart <= otherEnd && thisEnd >= otherStart
    }
}

// MARK: - GRDB Persistence

extension P2PTradeRecord: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "p2p_trade_records" }
    
    init(row: Row) {
        // UUID stored as text in SQLite
        let idString: String = row["id"]
        id = UUID(uuidString: idString) ?? UUID()
        siteId = row["site_id"]
        startDate = row["start_date"]
        endDate = row["end_date"]
        p2pKwh = row["p2p_kwh"]
        p2pRevenue = row["p2p_revenue"]
        counterpartyCount = row["counterparty_count"]
        importedAt = row["imported_at"]
        source = row["source"]
        isProvisional = row["is_provisional"] ?? false

        // Direction - default to sell for backwards compatibility
        if let directionStr: String = row["direction"],
           let dir = P2PTradeDirection(rawValue: directionStr) {
            direction = dir
        } else {
            direction = .sell
        }
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["site_id"] = siteId
        container["start_date"] = startDate
        container["end_date"] = endDate
        container["p2p_kwh"] = p2pKwh
        container["p2p_revenue"] = p2pRevenue
        container["counterparty_count"] = counterpartyCount
        container["imported_at"] = importedAt
        container["source"] = source
        container["is_provisional"] = isProvisional
        container["direction"] = direction.rawValue
    }
}

// MARK: - JSON Serialization for iCloud KVS

struct P2PTradeRecordDTO: Codable {
    let id: UUID
    let siteId: Int
    let startDate: Date
    let endDate: Date
    let p2pKwh: Double
    let p2pRevenue: Double
    let counterpartyCount: Int
    let importedAt: Date
    let source: String
    let isProvisional: Bool?  // Optional for backwards compatibility
    let direction: P2PTradeDirection?  // Optional for backwards compatibility

    init(from record: P2PTradeRecord) {
        self.id = record.id
        self.siteId = record.siteId
        self.startDate = record.startDate
        self.endDate = record.endDate
        self.p2pKwh = record.p2pKwh
        self.p2pRevenue = record.p2pRevenue
        self.counterpartyCount = record.counterpartyCount
        self.importedAt = record.importedAt
        self.source = record.source
        self.isProvisional = record.isProvisional
        self.direction = record.direction
    }

    func toRecord() -> P2PTradeRecord {
        P2PTradeRecord(
            id: id,
            siteId: siteId,
            startDate: startDate,
            endDate: endDate,
            p2pKwh: p2pKwh,
            p2pRevenue: p2pRevenue,
            counterpartyCount: counterpartyCount,
            importedAt: importedAt,
            source: source,
            isProvisional: isProvisional ?? false,
            direction: direction ?? .sell  // Default to sell for old data
        )
    }
}

extension P2PTradeRecord {
    /// Encode array to JSON for iCloud KVS storage
    static func encodeForSync(_ records: [P2PTradeRecord]) -> Data? {
        let dtos = records.map { P2PTradeRecordDTO(from: $0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(dtos)
    }
    
    /// Decode array from JSON from iCloud KVS
    static func decodeFromSync(_ data: Data) -> [P2PTradeRecord]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let dtos = try? decoder.decode([P2PTradeRecordDTO].self, from: data) else {
            return nil
        }
        return dtos.map { $0.toRecord() }
    }
}
