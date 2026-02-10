//
//  MeterRecordDB.swift
//  Powston
//
//  GRDB-compatible model for persisted meter records
//  Mirrors MeterRecord but optimized for SQLite storage
//

import Foundation
import GRDB

// MARK: - Meter Record DB (Persisted)

struct MeterRecordDB: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meter_records"
    
    // Primary key (composite: site_id + interval_time)
    var siteId: Int
    var intervalTime: Date
    
    // Energy - inverter data (kWh)
    var energyImport: Double?
    var energyExport: Double?
    
    // Energy - utility meter fallback (for effectiveImport/effectiveExport)
    var generalKwh: Double?
    var feedInKwh: Double?
    
    // Battery
    var startBatterySoc: Double?
    var endBatterySoc: Double?
    
    // Generation/Consumption (kWh)
    var ppvGeneration: Double?
    var houseConsumption: Double?
    
    // Financial (cents)
    var rrp: Double?
    var earnings: Double?
    var costs: Double?
    var energyCosts: Double?
    var fixedCosts: Double?
    
    // Metadata
    var isFinalized: Bool
    var createdAt: Date
    
    enum CodingKeys: String, CodingKey {
        case siteId = "site_id"
        case intervalTime = "interval_time"
        case energyImport = "energy_import"
        case energyExport = "energy_export"
        case generalKwh = "general_kwh"
        case feedInKwh = "feed_in_kwh"
        case startBatterySoc = "start_battery_soc"
        case endBatterySoc = "end_battery_soc"
        case ppvGeneration = "ppv_generation"
        case houseConsumption = "house_consumption"
        case rrp
        case earnings
        case costs
        case energyCosts = "energy_costs"
        case fixedCosts = "fixed_costs"
        case isFinalized = "is_finalized"
        case createdAt = "created_at"
    }
    
    // MARK: - Init from API MeterRecord
    
    init(from record: MeterRecord, siteId: Int, isFinalized: Bool = false) {
        self.siteId = siteId
        self.intervalTime = record.date ?? Date()
        self.energyImport = record.energyImport
        self.energyExport = record.energyExport
        self.generalKwh = record.generalKwh
        self.feedInKwh = record.feedInKwh
        self.startBatterySoc = record.startBatterySoc
        self.endBatterySoc = record.endBatterySoc
        self.ppvGeneration = record.ppvGeneration
        self.houseConsumption = record.houseConsumption
        self.rrp = record.rrp
        self.earnings = record.earnings
        self.costs = record.costs
        self.energyCosts = record.energyCosts
        self.fixedCosts = record.fixedCosts
        self.isFinalized = isFinalized
        self.createdAt = Date()
    }
    
    // MARK: - Direct init
    
    init(
        siteId: Int,
        intervalTime: Date,
        energyImport: Double? = nil,
        energyExport: Double? = nil,
        generalKwh: Double? = nil,
        feedInKwh: Double? = nil,
        startBatterySoc: Double? = nil,
        endBatterySoc: Double? = nil,
        ppvGeneration: Double? = nil,
        houseConsumption: Double? = nil,
        rrp: Double? = nil,
        earnings: Double? = nil,
        costs: Double? = nil,
        energyCosts: Double? = nil,
        fixedCosts: Double? = nil,
        isFinalized: Bool = false,
        createdAt: Date = Date()
    ) {
        self.siteId = siteId
        self.intervalTime = intervalTime
        self.energyImport = energyImport
        self.energyExport = energyExport
        self.generalKwh = generalKwh
        self.feedInKwh = feedInKwh
        self.startBatterySoc = startBatterySoc
        self.endBatterySoc = endBatterySoc
        self.ppvGeneration = ppvGeneration
        self.houseConsumption = houseConsumption
        self.rrp = rrp
        self.earnings = earnings
        self.costs = costs
        self.energyCosts = energyCosts
        self.fixedCosts = fixedCosts
        self.isFinalized = isFinalized
        self.createdAt = createdAt
    }
    
    // MARK: - Convert to API MeterRecord
    
    func toMeterRecord() -> MeterRecord {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let intervalTimeStr = formatter.string(from: intervalTime)
        
        return MeterRecord(
            intervalTime: intervalTimeStr,
            energyImport: energyImport,
            energyExport: energyExport,
            gridW: nil,
            batteryW: nil,
            startBatterySoc: startBatterySoc,
            endBatterySoc: endBatterySoc,
            houseConsumption: houseConsumption,
            ppvGeneration: ppvGeneration,
            rrp: rrp,
            earnings: earnings,
            costs: costs,
            energyCosts: energyCosts,
            fixedCosts: fixedCosts,
            generalKwh: generalKwh,
            feedInKwh: feedInKwh
        )
    }
}

// MARK: - Identifiable

extension MeterRecordDB: Identifiable {
    var id: String { "\(siteId)_\(intervalTime.timeIntervalSince1970)" }
}
