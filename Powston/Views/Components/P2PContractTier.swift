//
//  P2PContract.swift
//  Powston
//
//  Model for P2P trading contracts with tiered pricing
//  Tracks offered terms and links to actual trade records for performance analysis
//

import Foundation
import GRDB

// MARK: - Contract Tier

struct P2PContractTier: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var percentage: Double       // e.g. 40 (meaning 40%)
    var priceCents: Double       // e.g. 20 (meaning 20¢/kWh)
    var volumeKwh: Double        // e.g. 50.22
    
    var estimatedRevenue: Double {
        volumeKwh * priceCents / 100.0
    }
}

// MARK: - Contract Model

struct P2PContract: Identifiable, Equatable {
    var id: UUID
    let siteId: Int
    var startDate: Date
    var endDate: Date
    var startHour: Int           // 17 (5pm AEST)
    var endHour: Int             // 20 (8pm AEST)
    var tiers: [P2PContractTier]
    var totalVolumeKwh: Double
    var renewalDays: Int?        // 7 for weekly, nil for one-off
    var isActive: Bool
    var createdAt: Date
    var notes: String?
    
    // MARK: - Computed Properties
    
    var estimatedRevenue: Double {
        tiers.reduce(0) { $0 + $1.estimatedRevenue }
    }
    
    var blendedPriceCents: Double {
        guard totalVolumeKwh > 0 else { return 0 }
        return (estimatedRevenue / totalVolumeKwh) * 100
    }
    
    var dayCount: Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        return max(1, days + 1)
    }
    
    var dailyVolumeKwh: Double {
        totalVolumeKwh / Double(dayCount)
    }
    
    var hoursPerDay: Int {
        endHour - startHour
    }
    
    var dateRangeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        formatter.timeZone = powstonTimezone()
        return "\(formatter.string(from: startDate))–\(formatter.string(from: endDate))"
    }
    
    var hoursString: String {
        "\(String(format: "%02d:00", startHour))–\(String(format: "%02d:00", endHour))"
    }
    
    /// Check if this contract covers a specific date
    func coversDate(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        return targetDay >= start && targetDay <= end
    }
    
    /// Check if this contract overlaps with a date range
    func overlaps(start: Date, end: Date) -> Bool {
        let calendar = Calendar.current
        let thisStart = calendar.startOfDay(for: startDate)
        let thisEnd = calendar.startOfDay(for: endDate)
        let otherStart = calendar.startOfDay(for: start)
        let otherEnd = calendar.startOfDay(for: end)
        return thisStart <= otherEnd && thisEnd >= otherStart
    }
    
    // MARK: - Tier Bucketing
    
    /// Calculate dynamic midpoints between tier prices for bucketing actual trade prices
    /// e.g. tiers at 20/25/30 → midpoints at 22.5/27.5
    /// Trades ≤22.5 → 20¢ tier, ≤27.5 → 25¢ tier, >27.5 → 30¢ tier
    func tierBoundaries() -> [(tier: P2PContractTier, lowerBound: Double, upperBound: Double)] {
        let sorted = tiers.sorted { $0.priceCents < $1.priceCents }
        guard !sorted.isEmpty else { return [] }
        
        var boundaries: [(tier: P2PContractTier, lowerBound: Double, upperBound: Double)] = []
        
        for i in 0..<sorted.count {
            let lower: Double
            let upper: Double
            
            if i == 0 {
                lower = 0
            } else {
                lower = (sorted[i - 1].priceCents + sorted[i].priceCents) / 2.0
            }
            
            if i == sorted.count - 1 {
                upper = Double.infinity
            } else {
                upper = (sorted[i].priceCents + sorted[i + 1].priceCents) / 2.0
            }
            
            boundaries.append((tier: sorted[i], lowerBound: lower, upperBound: upper))
        }
        
        return boundaries
    }
    
    /// Find the matching tier for a given actual trade price
    func matchingTier(forPriceCents price: Double) -> P2PContractTier? {
        let boundaries = tierBoundaries()
        return boundaries.first { price >= $0.lowerBound && price < $0.upperBound }?.tier
    }
}

// MARK: - GRDB Persistence

extension P2PContract: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "p2p_contracts" }
    
    init(row: Row) {
        let idString: String = row["id"]
        id = UUID(uuidString: idString) ?? UUID()
        siteId = row["site_id"]
        startDate = row["start_date"]
        endDate = row["end_date"]
        startHour = row["start_hour"]
        endHour = row["end_hour"]
        totalVolumeKwh = row["total_volume_kwh"]
        renewalDays = row["renewal_days"]
        isActive = row["is_active"]
        createdAt = row["created_at"]
        notes = row["notes"]
        
        // Decode tiers from JSON
        if let tiersJson: String = row["tiers_json"],
           let data = tiersJson.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([P2PContractTier].self, from: data) {
            tiers = decoded
        } else {
            tiers = []
        }
    }
    
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["site_id"] = siteId
        container["start_date"] = startDate
        container["end_date"] = endDate
        container["start_hour"] = startHour
        container["end_hour"] = endHour
        container["total_volume_kwh"] = totalVolumeKwh
        container["renewal_days"] = renewalDays
        container["is_active"] = isActive
        container["created_at"] = createdAt
        container["notes"] = notes
        
        // Encode tiers as JSON
        if let data = try? JSONEncoder().encode(tiers),
           let json = String(data: data, encoding: .utf8) {
            container["tiers_json"] = json
        } else {
            container["tiers_json"] = "[]"
        }
    }
}

// MARK: - JSON Serialization for iCloud KVS

struct P2PContractDTO: Codable {
    let id: UUID
    let siteId: Int
    let startDate: Date
    let endDate: Date
    let startHour: Int
    let endHour: Int
    let tiers: [P2PContractTier]
    let totalVolumeKwh: Double
    let renewalDays: Int?
    let isActive: Bool
    let createdAt: Date
    let notes: String?
    
    init(from contract: P2PContract) {
        self.id = contract.id
        self.siteId = contract.siteId
        self.startDate = contract.startDate
        self.endDate = contract.endDate
        self.startHour = contract.startHour
        self.endHour = contract.endHour
        self.tiers = contract.tiers
        self.totalVolumeKwh = contract.totalVolumeKwh
        self.renewalDays = contract.renewalDays
        self.isActive = contract.isActive
        self.createdAt = contract.createdAt
        self.notes = contract.notes
    }
    
    func toContract() -> P2PContract {
        P2PContract(
            id: id,
            siteId: siteId,
            startDate: startDate,
            endDate: endDate,
            startHour: startHour,
            endHour: endHour,
            tiers: tiers,
            totalVolumeKwh: totalVolumeKwh,
            renewalDays: renewalDays,
            isActive: isActive,
            createdAt: createdAt,
            notes: notes
        )
    }
}

extension P2PContract {
    /// Encode array to JSON for iCloud KVS storage
    static func encodeForSync(_ contracts: [P2PContract]) -> Data? {
        let dtos = contracts.map { P2PContractDTO(from: $0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(dtos)
    }
    
    /// Decode array from JSON from iCloud KVS
    static func decodeFromSync(_ data: Data) -> [P2PContract]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let dtos = try? decoder.decode([P2PContractDTO].self, from: data) else {
            return nil
        }
        return dtos.map { $0.toContract() }
    }
}

// MARK: - Contract Performance

/// Aggregated performance data for a contract
struct P2PContractPerformance {
    let contract: P2PContract
    let tradeRecords: [P2PTradeRecord]
    let tierPerformance: [P2PTierPerformance]
    let totalMatchedKwh: Double
    let totalRevenue: Double
    let counterpartyCount: Int
    
    var overallFillRate: Double {
        guard contract.totalVolumeKwh > 0 else { return 0 }
        return totalMatchedKwh / contract.totalVolumeKwh * 100
    }
    
    var revenueVsForecast: Double {
        guard contract.estimatedRevenue > 0 else { return 0 }
        return totalRevenue / contract.estimatedRevenue * 100
    }
    
    var actualBlendedPrice: Double {
        guard totalMatchedKwh > 0 else { return 0 }
        return (totalRevenue / totalMatchedKwh) * 100
    }
}

/// Performance breakdown for a single tier
struct P2PTierPerformance: Identifiable {
    var id: UUID { tier.id }
    let tier: P2PContractTier
    let matchedKwh: Double
    let matchedRevenue: Double
    let tradeCount: Int
    
    var fillRate: Double {
        guard tier.volumeKwh > 0 else { return 0 }
        return matchedKwh / tier.volumeKwh * 100
    }
}