//
//  DaySummaryRecord+GRDB.swift
//  Powston
//
//  GRDB persistence conformance for DaySummaryRecord
//

import GRDB

extension DaySummaryRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "day_summaries"
    
    enum DBColumns: String, ColumnExpression {
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
    
    func encode(to container: inout PersistenceContainer) {
        container[DBColumns.rowId] = rowId
        container[DBColumns.siteId] = siteId
        container[DBColumns.date] = date
        container[DBColumns.expectedBill] = expectedBill
        container[DBColumns.totalCosts] = totalCosts
        container[DBColumns.totalEarnings] = totalEarnings
        container[DBColumns.rateCosts] = rateCosts
        container[DBColumns.rateEarnings] = rateEarnings
        container[DBColumns.dailyCosts] = dailyCosts
        container[DBColumns.energyImported] = energyImported
        container[DBColumns.energyExported] = energyExported
        container[DBColumns.batteryKwh] = batteryKwh
        container[DBColumns.buyRate] = buyRate
        container[DBColumns.sellRate] = sellRate
        container[DBColumns.recordCount] = recordCount
        container[DBColumns.isFinalized] = isFinalized
        container[DBColumns.createdAt] = createdAt
        container[DBColumns.updatedAt] = updatedAt
    }
}
