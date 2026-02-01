//
//  P2PTradeRecord.swift
//  Powston
//
//  Model for storing imported P2P trade data
//

import Foundation
import GRDB

// MARK: - P2P Trade Record Model

struct P2PTradeRecord: Codable, Identifiable, Equatable {
    var id: UUID
    let siteId: Int
    let startDate: Date          // Range start (or single date)
    let endDate: Date            // Range end (same as start for single day)
    let p2pKwh: Double
    let p2pRevenue: Double       // Actual $ received
    let counterpartyCount: Int
    let importedAt: Date
    let source: String           // "mobile" or "desktop"
    
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
    
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let siteId = Column(CodingKeys.siteId)
        static let startDate = Column(CodingKeys.startDate)
        static let endDate = Column(CodingKeys.endDate)
        static let p2pKwh = Column(CodingKeys.p2pKwh)
        static let p2pRevenue = Column(CodingKeys.p2pRevenue)
        static let counterpartyCount = Column(CodingKeys.counterpartyCount)
        static let importedAt = Column(CodingKeys.importedAt)
        static let source = Column(CodingKeys.source)
    }
    
    init(row: Row) {
        id = row[Columns.id]
        siteId = row[Columns.siteId]
        startDate = row[Columns.startDate]
        endDate = row[Columns.endDate]
        p2pKwh = row[Columns.p2pKwh]
        p2pRevenue = row[Columns.p2pRevenue]
        counterpartyCount = row[Columns.counterpartyCount]
        importedAt = row[Columns.importedAt]
        source = row[Columns.source]
    }
    
    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.siteId] = siteId
        container[Columns.startDate] = startDate
        container[Columns.endDate] = endDate
        container[Columns.p2pKwh] = p2pKwh
        container[Columns.p2pRevenue] = p2pRevenue
        container[Columns.counterpartyCount] = counterpartyCount
        container[Columns.importedAt] = importedAt
        container[Columns.source] = source
    }
}

// MARK: - JSON Serialization for iCloud KVS

extension P2PTradeRecord {
    /// Encode array to JSON for iCloud KVS storage
    static func encodeForSync(_ records: [P2PTradeRecord]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(records)
    }
    
    /// Decode array from JSON from iCloud KVS
    static func decodeFromSync(_ data: Data) -> [P2PTradeRecord]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([P2PTradeRecord].self, from: data)
    }
}