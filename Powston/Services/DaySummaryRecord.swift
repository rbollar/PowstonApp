//
//  DaySummaryRecord.swift
//  Powston
//
//  GRDB-compatible model for persisted day rate summaries
//  Mirrors DayRateSummary but optimized for SQLite storage
//

import Foundation

// MARK: - Day Summary Record (Persisted)

struct DaySummaryRecord: Codable, Sendable {
    var rowId: Int?
    var siteId: Int
    var date: String  // YYYY-MM-DD format
    
    // Financial (cents)
    var expectedBill: Double?
    var totalCosts: Double?
    var totalEarnings: Double?
    var rateCosts: Double?
    var rateEarnings: Double?
    var dailyCosts: Double?
    
    // Energy (kWh)
    var energyImported: Double?
    var energyExported: Double?
    var batteryKwh: Double?
    
    // Rates (cents/kWh averages)
    var buyRate: Double?
    var sellRate: Double?
    
    // Metadata
    var recordCount: Int?
    var isFinalized: Bool
    var createdAt: Date
    var updatedAt: Date
    
    // CodingKeys must match database column names (snake_case)
    enum CodingKeys: String, CodingKey {
        case rowId = "id"
        case siteId = "site_id"
        case date
        case expectedBill = "expected_bill"
        case totalCosts = "total_costs"
        case totalEarnings = "total_earnings"
        case rateCosts = "rate_costs"
        case rateEarnings = "rate_earnings"
        case dailyCosts = "daily_costs"
        case energyImported = "energy_imported"
        case energyExported = "energy_exported"
        case batteryKwh = "battery_kwh"
        case buyRate = "buy_rate"
        case sellRate = "sell_rate"
        case recordCount = "record_count"
        case isFinalized = "is_finalized"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    // MARK: - Computed Properties (Dollars)
    
    /// Net result in dollars (positive = profit, negative = loss)
    var netProfitDollars: Double {
        guard let bill = expectedBill else { return 0 }
        return -bill / 100.0
    }
    
    /// Earnings in dollars
    var earningsDollars: Double {
        (totalEarnings ?? 0) / 100.0
    }
    
    /// Total costs in dollars (includes supply)
    var costsDollars: Double {
        (totalCosts ?? 0) / 100.0
    }
    
    /// Energy costs only in dollars (excludes supply)
    var rateCostsDollars: Double {
        (rateCosts ?? 0) / 100.0
    }
    
    /// Supply/fixed costs in dollars
    var supplyCostsDollars: Double {
        (dailyCosts ?? 0) / 100.0
    }
    
    var isCredit: Bool {
        (expectedBill ?? 0) < 0
    }
    
    // MARK: - Init from DayRateSummary
    
    init(from summary: DayRateSummary, date: String) {
        self.rowId = nil
        self.siteId = summary.siteId
        self.date = date
        self.expectedBill = summary.expectedBill
        self.totalCosts = summary.totalCosts
        self.totalEarnings = summary.totalEarnings
        self.rateCosts = summary.rateCosts
        self.rateEarnings = summary.rateEarnings
        self.dailyCosts = summary.dailyCosts
        self.energyImported = summary.totalEnergyImported
        self.energyExported = summary.totalEnergyExported
        self.batteryKwh = summary.totalBatteryKwh
        self.buyRate = summary.buyRate
        self.sellRate = summary.sellRate
        self.recordCount = summary.recordCount
        self.isFinalized = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    // MARK: - Direct init
    
    init(
        rowId: Int? = nil,
        siteId: Int,
        date: String,
        expectedBill: Double? = nil,
        totalCosts: Double? = nil,
        totalEarnings: Double? = nil,
        rateCosts: Double? = nil,
        rateEarnings: Double? = nil,
        dailyCosts: Double? = nil,
        energyImported: Double? = nil,
        energyExported: Double? = nil,
        batteryKwh: Double? = nil,
        buyRate: Double? = nil,
        sellRate: Double? = nil,
        recordCount: Int? = nil,
        isFinalized: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.rowId = rowId
        self.siteId = siteId
        self.date = date
        self.expectedBill = expectedBill
        self.totalCosts = totalCosts
        self.totalEarnings = totalEarnings
        self.rateCosts = rateCosts
        self.rateEarnings = rateEarnings
        self.dailyCosts = dailyCosts
        self.energyImported = energyImported
        self.energyExported = energyExported
        self.batteryKwh = batteryKwh
        self.buyRate = buyRate
        self.sellRate = sellRate
        self.recordCount = recordCount
        self.isFinalized = isFinalized
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    // MARK: - Convert to DailySummary (for HistoryView charts)
    
    // MARK: - Convert to DailySummary (for HistoryView charts)
        
        func toDailySummary() -> DailySummary? {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = powstonTimezone()
            
            guard let parsedDate = formatter.date(from: date) else { return nil }
            
            return DailySummary(
                date: parsedDate,
                totalImport: energyImported ?? 0,
                totalExport: energyExported ?? 0,
                totalEarnings: earningsDollars,
                totalCosts: rateCostsDollars,
                avgSoc: 0,
                recordCount: recordCount ?? 0,
                netProfit: netProfitDollars  // Use authoritative value from expectedBill
            )
        }
}

// MARK: - Identifiable

extension DaySummaryRecord: Identifiable {
    var id: String { "\(siteId)_\(date)" }
}
