//
//  PowstonDataStore+P2PTrades.swift
//  Powston
//
//  P2P trade record persistence with iCloud KVS sync
//
//  IMPORTANT: Requires schema migration in PowstonDataStore.swift
//  Add Migration 5 in performMigrations() to create p2p_trade_records table
//

import Foundation
import GRDB

// MARK: - iCloud KVS Keys

private let kP2PTradeRecordsKey = "p2p_trade_records_v1"

// MARK: - PowstonDataStore P2P Extension

extension PowstonDataStore {
    
    // MARK: - Schema Creation
    
    /// Call this from PowstonDataStore.createSchema()
    func createP2PTradeSchema(_ db: Database) throws {
        try db.create(table: "p2p_trade_records", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("site_id", .integer).notNull()
            t.column("start_date", .datetime).notNull()
            t.column("end_date", .datetime).notNull()
            t.column("p2p_kwh", .double).notNull()
            t.column("p2p_revenue", .double).notNull()
            t.column("counterparty_count", .integer).notNull()
            t.column("imported_at", .datetime).notNull()
            t.column("source", .text).notNull()
            t.column("is_provisional", .boolean).notNull().defaults(to: false)
            t.column("direction", .text).notNull().defaults(to: "Sell")
        }
        
        try db.create(
            index: "idx_p2p_trades_site_date",
            on: "p2p_trade_records",
            columns: ["site_id", "start_date", "end_date"],
            ifNotExists: true
        )
    }
    
    // MARK: - Save Operations
    
    /// Save a P2P trade record, checking for overlaps
    /// Returns (success, overlappingRecords) tuple
    /// Note: Overlaps are only checked within the same direction (buy/sell can coexist on same date)
    @MainActor
    func saveP2PTradeRecord(_ record: P2PTradeRecord, replaceOverlaps: Bool = false) -> (success: Bool, overlaps: [P2PTradeRecord]) {
        guard let db = dbQueue else { return (false, []) }

        // Check for overlapping records with same direction only
        // (buy and sell records can coexist for the same date range)
        let overlaps = getOverlappingP2PRecords(
            siteId: record.siteId,
            start: record.startDate,
            end: record.endDate,
            direction: record.direction
        )
        
        if !overlaps.isEmpty && !replaceOverlaps {
            return (false, overlaps)
        }
        
        do {
            try db.write { db in
                // Delete overlapping records if replacing
                if replaceOverlaps && !overlaps.isEmpty {
                    for overlap in overlaps {
                        // Delete associated counterparty trades first
                        try db.execute(
                            sql: "DELETE FROM p2p_counterparty_trades WHERE trade_record_id = ?",
                            arguments: [overlap.id.uuidString]
                        )
                        // Then delete the trade record
                        try db.execute(
                            sql: "DELETE FROM p2p_trade_records WHERE id = ?",
                            arguments: [overlap.id.uuidString]
                        )
                    }
                    print("🗑️ Deleted \(overlaps.count) overlapping P2P records and their counterparty trades")
                }

                // Insert new record
                try record.insert(db)
            }
            
            print("💾 Saved P2P trade record: \(record.p2pKwh) kWh, $\(String(format: "%.2f", record.p2pRevenue))")
            
            // Sync to iCloud
            syncP2PRecordsToCloud(siteId: record.siteId)
            
            return (true, [])
        } catch {
            print("❌ Failed to save P2P trade record: \(error)")
            return (false, [])
        }
    }
    
    /// Delete a P2P trade record and its associated counterparty trades
    @MainActor
    func deleteP2PTradeRecord(_ record: P2PTradeRecord) -> Bool {
        guard let db = dbQueue else { return false }

        do {
            try db.write { db in
                // Delete associated counterparty trades first
                try db.execute(
                    sql: "DELETE FROM p2p_counterparty_trades WHERE trade_record_id = ?",
                    arguments: [record.id.uuidString]
                )
                // Then delete the trade record
                try db.execute(
                    sql: "DELETE FROM p2p_trade_records WHERE id = ?",
                    arguments: [record.id.uuidString]
                )
            }

            print("🗑️ Deleted P2P trade record and associated counterparty trades")
            syncP2PRecordsToCloud(siteId: record.siteId)
            return true
        } catch {
            print("❌ Failed to delete P2P trade record: \(error)")
            return false
        }
    }
    
    // MARK: - Query Operations
    
    /// Get all P2P records for a site
    func getP2PTradeRecords(siteId: Int) -> [P2PTradeRecord] {
        guard let db = dbQueue else { return [] }
        
        do {
            return try db.read { db in
                try P2PTradeRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM p2p_trade_records
                        WHERE site_id = ?
                        ORDER BY start_date DESC
                        """,
                    arguments: [siteId]
                )
            }
        } catch {
            print("❌ getP2PTradeRecords failed: \(error)")
            return []
        }
    }
    
    /// Get P2P records for a date range
    func getP2PTradeRecords(siteId: Int, from startDate: Date, to endDate: Date) -> [P2PTradeRecord] {
        guard let db = dbQueue else { return [] }
        
        do {
            return try db.read { db in
                try P2PTradeRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM p2p_trade_records
                        WHERE site_id = ?
                        AND start_date <= ?
                        AND end_date >= ?
                        ORDER BY start_date DESC
                        """,
                    arguments: [siteId, endDate, startDate]
                )
            }
        } catch {
            print("❌ getP2PTradeRecords(range) failed: \(error)")
            return []
        }
    }
    
    /// Get P2P data for a specific date (may be pro-rated from a range record)
    func getP2PDataForDate(siteId: Int, date: Date) -> (kwh: Double, revenue: Double, avgPrice: Double)? {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let normalizedDate = calendar.startOfDay(for: date)
        
        print("🔍 getP2PDataForDate: input=\(date), normalized=\(normalizedDate)")
        
        let records = getP2PTradeRecords(siteId: siteId, from: normalizedDate, to: normalizedDate)
        
        print("🔍 getP2PDataForDate: found \(records.count) records")
        
        guard !records.isEmpty else { return nil }
        
        var totalKwh: Double = 0
        var totalRevenue: Double = 0
        
        for record in records {
            if record.dayCount == 1 {
                // Single day record - use full values
                totalKwh += record.p2pKwh
                totalRevenue += record.p2pRevenue
            } else {
                // Multi-day record - pro-rate
                totalKwh += record.dailyKwh
                totalRevenue += record.dailyRevenue
            }
        }
        
        let avgPrice = totalKwh > 0 ? (totalRevenue / totalKwh) * 100 : 0
        return (totalKwh, totalRevenue, avgPrice)
    }
    
    /// Get overlapping records for a date range (optionally filtered by direction)
    func getOverlappingP2PRecords(siteId: Int, start: Date, end: Date, direction: P2PTradeDirection? = nil) -> [P2PTradeRecord] {
        guard let db = dbQueue else { return [] }

        do {
            return try db.read { db in
                if let direction = direction {
                    // Filter by direction - buy and sell can coexist on the same date
                    return try P2PTradeRecord.fetchAll(
                        db,
                        sql: """
                            SELECT * FROM p2p_trade_records
                            WHERE site_id = ?
                            AND start_date <= ?
                            AND end_date >= ?
                            AND direction = ?
                            """,
                        arguments: [siteId, end, start, direction.rawValue]
                    )
                } else {
                    // No direction filter - return all overlapping records
                    return try P2PTradeRecord.fetchAll(
                        db,
                        sql: """
                            SELECT * FROM p2p_trade_records
                            WHERE site_id = ?
                            AND start_date <= ?
                            AND end_date >= ?
                            """,
                        arguments: [siteId, end, start]
                    )
                }
            }
        } catch {
            print("❌ getOverlappingP2PRecords failed: \(error)")
            return []
        }
    }
    
    /// P2P premium calculation result with separate sell and buy data
    struct P2PPremiumResult {
        let p2pRevenue: Double           // Total (legacy, for backwards compat)
        let spotEquivalent: Double       // What P2P kWh would have earned/cost at spot
        let premium: Double              // p2pRevenue - spotEquivalent

        // Separate sell data
        let sellRevenue: Double
        let sellKwh: Double
        let sellSpotEquivalent: Double   // What sell kWh would have earned at spot

        // Separate buy data
        let buyCost: Double
        let buyKwh: Double
        let buySpotEquivalent: Double    // What buy kWh would have cost at spot

        // NTB (Needed to Balance) — DLF/MLF adjustment between effective rate and raw spot
        let ntb: Double                  // Positive = our premium is overstated by this amount
    }

    /// P2P range calculation result - same structure as P2PPremiumResult but for date ranges
    /// Used by week/month/year/custom views
    struct P2PRangeResult {
        let p2pRevenue: Double           // Total P2P sell revenue
        let spotEquivalent: Double       // What P2P kWh would have earned at spot
        let premium: Double              // p2pRevenue - spotEquivalent

        // Separate sell data
        let sellRevenue: Double
        let sellKwh: Double
        let sellSpotEquivalent: Double

        // Separate buy data
        let buyCost: Double
        let buyKwh: Double
        let buySpotEquivalent: Double

        // NTB (Needed to Balance) — DLF/MLF adjustment
        let ntb: Double
    }

    /// Calculate P2P premium for a date by comparing to spot sell/buy prices
    /// Returns separate sell and buy data for memo display
    /// Note: P2P premium is NOT included in Powston API earnings — it is added by the calculator
    /// Combines data from both CSV imports (p2p_trade_records) and LocalVolts API (lv_interval_trades)
    @MainActor
    func calculateP2PPremium(siteId: Int, date: Date) -> P2PPremiumResult? {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let normalizedDate = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: normalizedDate)!.addingTimeInterval(-1)

        // Use ONE source — prefer LV interval trades over CSV imports
        var sellKwh: Double = 0
        var sellRevenue: Double = 0
        var buyKwh: Double = 0
        var buyCost: Double = 0
        var hasData = false

        let lvTrades = getLVIntervalTrades(siteId: siteId, from: normalizedDate, to: endOfDay)

        if !lvTrades.isEmpty {
            // Use LV interval trades (canonical source)
            hasData = true
            for trade in lvTrades {
                if trade.direction == .sell {
                    sellKwh += trade.volumeKwh
                    sellRevenue += trade.revenue
                } else {
                    buyKwh += trade.volumeKwh
                    buyCost += trade.revenue
                }
            }
        } else {
            // Fallback: CSV imports (p2p_trade_records)
            let records = getP2PTradeRecords(siteId: siteId, from: normalizedDate, to: normalizedDate)
            for record in records {
                hasData = true
                let kwh = record.dayCount == 1 ? record.p2pKwh : record.dailyKwh
                let revenue = record.dayCount == 1 ? record.p2pRevenue : record.dailyRevenue

                if record.direction == .sell {
                    sellKwh += kwh
                    sellRevenue += revenue
                } else {
                    buyKwh += kwh
                    buyCost += revenue
                }
            }
        }

        // Settlement data fallback: if lv_interval_trades are incomplete (e.g. only captured
        // partial Identity response), use authoritative settlement totals from lv_daily_cashflow.
        // QtyReport doesn't return individual P2P counterparty trades for historical dates,
        // so lv_interval_trades can be incomplete while settlement data is complete.
        if let cashflow = getLVCashflowSummary(siteId: siteId, date: normalizedDate) {
            if cashflow.p2pMatchedRevenue > sellRevenue + 0.01 {
                sellRevenue = cashflow.p2pMatchedRevenue
                sellKwh = cashflow.energySoldP2PKwh
                hasData = true
            }
        }

        guard hasData else { return nil }

        // Build per-interval effective spot rate from action records (earnings/kWh)
        // Use lead inverter only to avoid double-counting with multi-inverter sites
        let actions = fetchActions(siteId: siteId, from: normalizedDate, to: endOfDay)
        let leadInverterId = actions.first?.inverterId  // First inverter returned is typically lead
        let leadActions = leadInverterId != nil ? actions.filter { $0.inverterId == leadInverterId! } : actions

        // Round timestamps to 5-minute AEMO interval boundaries for matching
        func roundTo5Min(_ date: Date) -> Date {
            let ti = date.timeIntervalSince1970
            return Date(timeIntervalSince1970: (ti / 300.0).rounded(.down) * 300.0)
        }

        // Per-interval effective sell rate (earnings ÷ export kWh = effective $/kWh including DLF/MLF)
        // Note: earnings/costs from API are in CENTS, so divide by 100 to get $/kWh
        var effectiveSellByInterval: [Date: Double] = [:]
        var effectiveBuyByInterval: [Date: Double] = [:]
        for action in leadActions {
            let key = roundTo5Min(action.intervalTime)
            if let earnings = action.earnings, let exportKwh = action.energyExport, exportKwh > 0.001 {
                effectiveSellByInterval[key] = (earnings / 100.0) / exportKwh
            }
            if let costs = action.costs, let importKwh = action.energyImport, importKwh > 0.001 {
                effectiveBuyByInterval[key] = (costs / 100.0) / importKwh
            }
        }

        // Calculate sell spot equivalent using per-interval effective rates
        var sellSpotEquivalent: Double = 0
        var unmatchedSellKwh: Double = 0
        var matchedSellCount = 0
        for trade in lvTrades where trade.direction == .sell {
            let key = roundTo5Min(trade.periodStart)
            if let effectiveRate = effectiveSellByInterval[key] {
                sellSpotEquivalent += trade.volumeKwh * effectiveRate
                matchedSellCount += 1
            } else {
                unmatchedSellKwh += trade.volumeKwh
            }
        }

        // Calculate buy spot equivalent using per-interval effective rates
        var buySpotEquivalent: Double = 0
        var unmatchedBuyKwh: Double = 0
        var matchedBuyCount = 0
        for trade in lvTrades where trade.direction == .buy {
            let key = roundTo5Min(trade.periodStart)
            if let effectiveRate = effectiveBuyByInterval[key] {
                buySpotEquivalent += trade.volumeKwh * effectiveRate
                matchedBuyCount += 1
            } else {
                unmatchedBuyKwh += trade.volumeKwh
            }
        }

        // For unmatched intervals (or CSV imports), fall back to daily average effective rate
        let exports = leadActions.filter { ($0.energyExport ?? 0) > 0 && $0.earnings != nil }
        let totalExportKwh = exports.compactMap { $0.energyExport }.reduce(0, +)
        let totalExportEarnings = exports.compactMap { $0.earnings }.reduce(0, +)
        let avgSellRate = totalExportKwh > 0 ? (totalExportEarnings / 100.0 / totalExportKwh) : 0  // $/kWh

        let csvSellKwh = sellKwh - lvTrades.filter { $0.direction == .sell }.reduce(0) { $0 + $1.volumeKwh }
        if unmatchedSellKwh + csvSellKwh > 0.001 {
            sellSpotEquivalent += (unmatchedSellKwh + csvSellKwh) * avgSellRate
        }

        let imports = leadActions.filter { ($0.energyImport ?? 0) > 0 && $0.costs != nil }
        let totalImportKwh = imports.compactMap { $0.energyImport }.reduce(0, +)
        let totalImportCosts = imports.compactMap { $0.costs }.reduce(0, +)
        let avgBuyRate = totalImportKwh > 0 ? (totalImportCosts / 100.0 / totalImportKwh) : 0  // $/kWh

        let csvBuyKwh = buyKwh - lvTrades.filter { $0.direction == .buy }.reduce(0) { $0 + $1.volumeKwh }
        if unmatchedBuyKwh + csvBuyKwh > 0.001 {
            buySpotEquivalent += (unmatchedBuyKwh + csvBuyKwh) * avgBuyRate
        }

        // NTB placeholder — not yet computed from a reliable source
        let ntb: Double = 0

        // Debug: show matching stats
        let sellTradeCount = lvTrades.filter { $0.direction == .sell }.count
        _ = lvTrades.filter { $0.direction == .buy }.count
        let sellPremium = sellRevenue - sellSpotEquivalent
        let buyPremium = buySpotEquivalent - buyCost
        print("📊 P2P Premium (\(normalizedDate)): sell \(matchedSellCount)/\(sellTradeCount) matched, premium=$\(String(format: "%.2f", sellPremium + buyPremium))")
        if unmatchedSellKwh > 0.001 || unmatchedBuyKwh > 0.001 {
            print("  unmatched: sell=\(String(format: "%.3f", unmatchedSellKwh))kWh buy=\(String(format: "%.3f", unmatchedBuyKwh))kWh")
        }

        // Use settlement data when available (authoritative source)
        // settle IS spot-only, matchAmount IS P2P revenue (separate, additive)
        if let cf = getLVCashflowSummary(siteId: siteId, date: normalizedDate),
           cf.p2pMatchedRevenue > 0.001 || cf.energySoldP2PKwh > 0.001 {
            sellRevenue = cf.p2pMatchedRevenue
            sellKwh = cf.energySoldP2PKwh
            let spotRate = cf.energySoldSpotKwh > 0.001 ? cf.spotEnergyRevenue / cf.energySoldSpotKwh : 0
            sellSpotEquivalent = spotRate * cf.energySoldP2PKwh
        }

        // Legacy totals for backwards compatibility
        let totalRevenue = sellRevenue  // Only count sell as "revenue"
        let spotEquivalent = sellSpotEquivalent
        let premium = totalRevenue - spotEquivalent

        return P2PPremiumResult(
            p2pRevenue: totalRevenue,
            spotEquivalent: spotEquivalent,
            premium: premium,
            sellRevenue: sellRevenue,
            sellKwh: sellKwh,
            sellSpotEquivalent: sellSpotEquivalent,
            buyCost: buyCost,
            buyKwh: buyKwh,
            buySpotEquivalent: buySpotEquivalent,
            ntb: ntb
        )
    }
    
    // MARK: - Summary Statistics
    
    /// Get total P2P stats for a site
    func getP2PTotalStats(siteId: Int) -> (totalKwh: Double, totalRevenue: Double, recordCount: Int) {
        let records = getP2PTradeRecords(siteId: siteId)
        
        let totalKwh = records.reduce(0) { $0 + $1.p2pKwh }
        let totalRevenue = records.reduce(0) { $0 + $1.p2pRevenue }
        
        return (totalKwh, totalRevenue, records.count)
    }
    
    /// Calculate P2P premium for a date range (week/month/custom views)
    /// Returns (p2pRevenue, spotEquivalent, premium) summed across all days
    /// Note: P2P premium is NOT included in Powston API earnings — it is added by the calculator
    @MainActor
    func calculateP2PPremiumForRange(siteId: Int, from startDate: Date, to endDate: Date) -> (p2pRevenue: Double, spotEquivalent: Double, premium: Double)? {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        var totalP2PRevenue: Double = 0
        var totalP2PKwh: Double = 0
        var hasAnyData = false
        
        // Get all P2P records that overlap this range
        let records = getP2PTradeRecords(siteId: siteId, from: startDate, to: endDate)
        
        guard !records.isEmpty else { return nil }
        
        // Calculate P2P totals for the range, handling pro-rating
        var currentDate = calendar.startOfDay(for: startDate)
        let rangeEnd = calendar.startOfDay(for: endDate)
        
        while currentDate <= rangeEnd {
            if let dayData = getP2PDataForDate(siteId: siteId, date: currentDate) {
                totalP2PKwh += dayData.kwh
                totalP2PRevenue += dayData.revenue
                hasAnyData = true
            }
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate.addingTimeInterval(86400)
        }
        
        guard hasAnyData else { return nil }
        
        // Get average spot sell price for the period from action records
        let actions = fetchActions(siteId: siteId, from: startDate, to: endDate)
        let exports = actions.filter { $0.action.lowercased().contains("export") && ($0.energyExport ?? 0) > 0 }
        
        guard !exports.isEmpty else {
            // No spot exports to compare - return P2P revenue as pure premium
            return (totalP2PRevenue, 0, totalP2PRevenue)
        }
        
        let totalExportKwh = exports.compactMap { $0.energyExport }.reduce(0, +)
        let totalExportEarnings = exports.compactMap { $0.earnings }.reduce(0, +)
        
        let avgSpotSellCents = totalExportKwh > 0 ? (totalExportEarnings / totalExportKwh) * 100 : 0
        
        // Calculate what P2P kWh would have earned at spot
        let spotEquivalent = totalP2PKwh * avgSpotSellCents / 100
        let premium = totalP2PRevenue - spotEquivalent
        
        return (totalP2PRevenue, spotEquivalent, premium)
    }

    /// Calculate detailed P2P premium for a date range with full sell/buy breakdown
    /// Returns P2PRangeResult with separate sell and buy data for week/month/year/custom views
    /// Note: P2P premium is NOT included in Powston API earnings — it is added by the calculator
    /// Combines data from both CSV imports (p2p_trade_records) and LocalVolts API (lv_interval_trades)
    @MainActor
    func calculateP2PPremiumForRangeDetailed(siteId: Int, from startDate: Date, to endDate: Date, settlementCutoff: Date? = nil) -> P2PRangeResult? {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        // Accumulate totals from ONE source — prefer LV interval trades over CSV imports
        var totalSellKwh: Double = 0
        var totalSellRevenue: Double = 0
        var totalBuyKwh: Double = 0
        var totalBuyCost: Double = 0

        let lvTrades = getLVIntervalTrades(siteId: siteId, from: startDate, to: endDate)

        if !lvTrades.isEmpty {
            // Use LV interval trades (canonical source)
            for trade in lvTrades {
                if trade.direction == .sell {
                    totalSellKwh += trade.volumeKwh
                    totalSellRevenue += trade.revenue
                } else {
                    totalBuyKwh += trade.volumeKwh
                    totalBuyCost += trade.revenue
                }
            }
        } else {
            // Fallback: CSV imports (p2p_trade_records) - iterate by day for pro-rating
            var currentDate = calendar.startOfDay(for: startDate)
            let rangeEnd = calendar.startOfDay(for: endDate)

            while currentDate <= rangeEnd {
                let dayRecords = getP2PTradeRecords(siteId: siteId, from: currentDate, to: currentDate)

                for record in dayRecords {
                    let kwh = record.dayCount == 1 ? record.p2pKwh : record.dailyKwh
                    let revenue = record.dayCount == 1 ? record.p2pRevenue : record.dailyRevenue

                    if record.direction == .sell {
                        totalSellKwh += kwh
                        totalSellRevenue += revenue
                    } else {
                        totalBuyKwh += kwh
                        totalBuyCost += revenue
                    }
                }

                currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate.addingTimeInterval(86400)
            }
        }

        guard totalSellKwh > 0 || totalBuyKwh > 0 else { return nil }

        // Build per-interval effective spot rate from action records (earnings/kWh)
        // Use lead inverter only to avoid double-counting
        let actions = fetchActions(siteId: siteId, from: startDate, to: endDate)
        let leadInverterId = actions.first?.inverterId
        let leadActions = leadInverterId != nil ? actions.filter { $0.inverterId == leadInverterId! } : actions

        // Round timestamps to 5-minute AEMO interval boundaries for matching
        func roundTo5Min(_ date: Date) -> Date {
            let ti = date.timeIntervalSince1970
            return Date(timeIntervalSince1970: (ti / 300.0).rounded(.down) * 300.0)
        }

        // Per-interval effective rate (earnings/kWh after DLF/MLF)
        var effectiveSellByInterval: [Date: Double] = [:]
        var effectiveBuyByInterval: [Date: Double] = [:]
        for action in leadActions {
            let key = roundTo5Min(action.intervalTime)
            if let earnings = action.earnings, let exportKwh = action.energyExport, exportKwh > 0.001 {
                effectiveSellByInterval[key] = (earnings / 100.0) / exportKwh
            }
            if let costs = action.costs, let importKwh = action.energyImport, importKwh > 0.001 {
                effectiveBuyByInterval[key] = (costs / 100.0) / importKwh
            }
        }

        // Calculate sell spot equivalent using per-interval effective rates
        var sellSpotEquivalent: Double = 0
        var unmatchedSellKwh: Double = 0
        for trade in lvTrades where trade.direction == .sell {
            let key = roundTo5Min(trade.periodStart)
            if let effectiveRate = effectiveSellByInterval[key] {
                sellSpotEquivalent += trade.volumeKwh * effectiveRate
            } else {
                unmatchedSellKwh += trade.volumeKwh
            }
        }

        // Calculate buy spot equivalent using per-interval effective rates
        var buySpotEquivalent: Double = 0
        var unmatchedBuyKwh: Double = 0
        for trade in lvTrades where trade.direction == .buy {
            let key = roundTo5Min(trade.periodStart)
            if let effectiveRate = effectiveBuyByInterval[key] {
                buySpotEquivalent += trade.volumeKwh * effectiveRate
            } else {
                unmatchedBuyKwh += trade.volumeKwh
            }
        }

        // For unmatched intervals (or CSV imports), fall back to daily average effective rate
        let exports = leadActions.filter { ($0.energyExport ?? 0) > 0 && $0.earnings != nil }
        let totalExportKwh = exports.compactMap { $0.energyExport }.reduce(0, +)
        let totalExportEarnings = exports.compactMap { $0.earnings }.reduce(0, +)
        let avgSellRate = totalExportKwh > 0 ? (totalExportEarnings / 100.0 / totalExportKwh) : 0

        let csvSellKwh = totalSellKwh - lvTrades.filter { $0.direction == .sell }.reduce(0) { $0 + $1.volumeKwh }
        if unmatchedSellKwh + csvSellKwh > 0.001 {
            sellSpotEquivalent += (unmatchedSellKwh + csvSellKwh) * avgSellRate
        }

        let imports = leadActions.filter { ($0.energyImport ?? 0) > 0 && $0.costs != nil }
        let totalImportKwh = imports.compactMap { $0.energyImport }.reduce(0, +)
        let totalImportCosts = imports.compactMap { $0.costs }.reduce(0, +)
        let avgBuyRate = totalImportKwh > 0 ? (totalImportCosts / 100.0 / totalImportKwh) : 0

        let csvBuyKwh = totalBuyKwh - lvTrades.filter { $0.direction == .buy }.reduce(0) { $0 + $1.volumeKwh }
        if unmatchedBuyKwh + csvBuyKwh > 0.001 {
            buySpotEquivalent += (unmatchedBuyKwh + csvBuyKwh) * avgBuyRate
        }

        // NTB placeholder — not yet computed from a reliable source
        let ntb: Double = 0

        // Use settlement data when available (authoritative source)
        // settle IS spot-only, matchAmount IS P2P revenue (separate, additive)
        // Cap at settlementCutoff to exclude unfinalized days
        let settlementEnd = settlementCutoff.map { min(endDate, $0) } ?? endDate
        let lvCashflows = getLVCashflowSummaries(siteId: siteId, from: startDate, to: settlementEnd)
        if !lvCashflows.isEmpty {
            let agg = lvCashflows.aggregated()
            if agg.p2pMatchedRevenue > 0.001 || agg.energySoldP2PKwh > 0.001 {
                totalSellRevenue = agg.p2pMatchedRevenue
                totalSellKwh = agg.energySoldP2PKwh
                let spotRate = agg.energySoldSpotKwh > 0.001 ? agg.spotEnergyRevenue / agg.energySoldSpotKwh : 0
                sellSpotEquivalent = spotRate * agg.energySoldP2PKwh
            }
        }

        // Legacy totals
        let totalRevenue = totalSellRevenue
        let spotEquivalent = sellSpotEquivalent
        let premium = totalRevenue - spotEquivalent

        return P2PRangeResult(
            p2pRevenue: totalRevenue,
            spotEquivalent: spotEquivalent,
            premium: premium,
            sellRevenue: totalSellRevenue,
            sellKwh: totalSellKwh,
            sellSpotEquivalent: sellSpotEquivalent,
            buyCost: totalBuyCost,
            buyKwh: totalBuyKwh,
            buySpotEquivalent: buySpotEquivalent,
            ntb: ntb
        )
    }

    // MARK: - iCloud KVS Sync
    
    /// Sync P2P records to iCloud KVS
    private func syncP2PRecordsToCloud(siteId: Int) {
        let records = getP2PTradeRecords(siteId: siteId)
        
        guard let data = P2PTradeRecord.encodeForSync(records) else {
            print("❌ Failed to encode P2P records for sync")
            return
        }
        
        // Store per-site to avoid conflicts
        let key = "\(kP2PTradeRecordsKey)_site\(siteId)"
        NSUbiquitousKeyValueStore.default.set(data, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
        
        print("☁️ Synced \(records.count) P2P records to iCloud for site \(siteId)")
    }
    
    /// Pull P2P records from iCloud KVS and merge with local
    @MainActor
        func syncP2PRecordsFromCloud(siteId: Int) {
            let key = "\(kP2PTradeRecordsKey)_site\(siteId)"
            
            // Debug: Check what's in iCloud KVS
            print("☁️ Syncing P2P from iCloud for site \(siteId), key: \(key)")
            
            // Force sync from iCloud first
            NSUbiquitousKeyValueStore.default.synchronize()
            
            // List all keys in iCloud KVS for debugging
            let allKeys = NSUbiquitousKeyValueStore.default.dictionaryRepresentation.keys
            let p2pKeys = allKeys.filter { $0.hasPrefix("p2p_trade") }
            print("☁️ All P2P keys in iCloud: \(p2pKeys)")
            
            guard let data = NSUbiquitousKeyValueStore.default.data(forKey: key) else {
                print("☁️ No data found for key: \(key)")
                return
            }
            
            print("☁️ Found \(data.count) bytes of P2P data in iCloud")
            
            guard let cloudRecords = P2PTradeRecord.decodeFromSync(data) else {
                print("☁️ Failed to decode P2P data from iCloud")
                return
            }
            
            print("☁️ Decoded \(cloudRecords.count) P2P records from iCloud")
        
        let localRecords = getP2PTradeRecords(siteId: siteId)
        let localIds = Set(localRecords.map { $0.id })
        
        // Find records in cloud that aren't local
        let newRecords = cloudRecords.filter { !localIds.contains($0.id) }
        
        if newRecords.isEmpty {
            print("☁️ No new P2P records from iCloud")
            return
        }
        
        guard let db = dbQueue else { return }
        
        do {
            try db.write { db in
                for record in newRecords {
                    try record.insert(db)
                }
            }
            print("☁️ Merged \(newRecords.count) P2P records from iCloud")
        } catch {
            print("❌ Failed to merge P2P records from iCloud: \(error)")
        }
    }
    
    /// Register for iCloud KVS change notifications
    func registerForP2PCloudSync() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] notification in
            guard let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
                return
            }
            
            // Check if any P2P keys changed
            let p2pKeysChanged = changedKeys.filter { $0.hasPrefix(kP2PTradeRecordsKey) }
            if !p2pKeysChanged.isEmpty {
                print("☁️ P2P records changed externally, syncing...")
                // Extract site IDs from keys and sync each
                let weakSelf = self
                for key in p2pKeysChanged {
                    if let siteIdStr = key.components(separatedBy: "_site").last,
                       let siteId = Int(siteIdStr) {
                        Task { @MainActor [weak weakSelf] in
                            guard let strongSelf = weakSelf else { return }
                            strongSelf.syncP2PRecordsFromCloud(siteId: siteId)
                        }
                    }
                }
            }
        }
        
        // Initial sync
        NSUbiquitousKeyValueStore.default.synchronize()
    }
    
    // MARK: - Calendar Support

    /// Get all dates that have P2P data for calendar display
    func getP2PImportedDates(siteId: Int) -> Set<Date> {
        let records = getP2PTradeRecords(siteId: siteId)
        var dates = Set<Date>()

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        for record in records {
            // Expand each record's date range into individual dates
            var currentDate = calendar.startOfDay(for: record.startDate)
            let endDate = calendar.startOfDay(for: record.endDate)

            while currentDate <= endDate {
                dates.insert(currentDate)
                currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate.addingTimeInterval(86400)
            }
        }

        return dates
    }

    /// Get dates with P2P data separated by direction (sell vs buy) and provisional status
    /// Includes both CSV imports and LocalVolts API synced data
    func getP2PImportedDatesByDirection(siteId: Int) -> (sell: Set<Date>, buy: Set<Date>, sellProvisional: Set<Date>, buyProvisional: Set<Date>, lvSyncedDates: Set<Date>) {
        let records = getP2PTradeRecords(siteId: siteId)
        var sellDates = Set<Date>()
        var buyDates = Set<Date>()
        var sellProvisional = Set<Date>()
        var buyProvisional = Set<Date>()
        var lvSyncedDates = Set<Date>()

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        // Process CSV import records
        for record in records {
            var currentDate = calendar.startOfDay(for: record.startDate)
            let endDate = calendar.startOfDay(for: record.endDate)

            while currentDate <= endDate {
                if record.direction == .sell {
                    sellDates.insert(currentDate)
                    if record.isProvisional {
                        sellProvisional.insert(currentDate)
                    }
                } else {
                    buyDates.insert(currentDate)
                    if record.isProvisional {
                        buyProvisional.insert(currentDate)
                    }
                }
                currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate.addingTimeInterval(86400)
            }
        }

        // Get LV API synced dates
        if let db = dbQueue {
            do {
                let lvTableExists = try db.read { db in
                    try db.tableExists("lv_interval_trades")
                }

                if lvTableExists {
                    let lvDates = try db.read { db -> [(Date, String)] in
                        let rows = try Row.fetchAll(
                            db,
                            sql: """
                                SELECT DISTINCT date(period_start) as trade_day, direction
                                FROM lv_interval_trades
                                WHERE site_id = ?
                                """,
                            arguments: [siteId]
                        )
                        return rows.compactMap { row -> (Date, String)? in
                            guard let dayStr: String = row["trade_day"],
                                  let direction: String = row["direction"] else {
                                return nil
                            }
                            let formatter = DateFormatter()
                            formatter.dateFormat = "yyyy-MM-dd"
                            formatter.timeZone = powstonTimezone()
                            guard let date = formatter.date(from: dayStr) else { return nil }
                            return (date, direction)
                        }
                    }

                    for (date, direction) in lvDates {
                        lvSyncedDates.insert(date)
                        if direction == "Sell" {
                            sellDates.insert(date)
                        } else if direction == "Buy" {
                            buyDates.insert(date)
                        }
                    }
                }
            } catch {
                print("❌ Failed to get LV synced dates: \(error)")
            }
        }

        return (sell: sellDates, buy: buyDates, sellProvisional: sellProvisional, buyProvisional: buyProvisional, lvSyncedDates: lvSyncedDates)
    }

    /// Get all dates covered by P2P contracts for calendar display
    func getP2PContractDates(siteId: Int) -> Set<Date> {
        let contracts = getP2PContracts(siteId: siteId)
        var dates = Set<Date>()

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        for contract in contracts {
            // Expand each contract's date range into individual dates
            var currentDate = calendar.startOfDay(for: contract.startDate)
            let endDate = calendar.startOfDay(for: contract.endDate)

            while currentDate <= endDate {
                dates.insert(currentDate)
                currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate.addingTimeInterval(86400)
            }
        }

        return dates
    }

    /// Get all dates that have provisional (forecast) P2P data for calendar display
    func getP2PProvisionalDates(siteId: Int) -> Set<Date> {
        let records = getP2PTradeRecords(siteId: siteId).filter { $0.isProvisional }
        var dates = Set<Date>()

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        for record in records {
            // Expand each record's date range into individual dates
            var currentDate = calendar.startOfDay(for: record.startDate)
            let endDate = calendar.startOfDay(for: record.endDate)

            while currentDate <= endDate {
                dates.insert(currentDate)
                currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate.addingTimeInterval(86400)
            }
        }

        return dates
    }

    /// Get provisional dates that now have finalized data available (ready for update)
    /// These are dates where we have provisional/forecast P2P data but actual data should now be available
    func getP2PProvisionalDatesNeedingUpdate(siteId: Int, latestCompleteDataDate: Date) -> Set<Date> {
        let provisionalDates = getP2PProvisionalDates(siteId: siteId)

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let latestDay = calendar.startOfDay(for: latestCompleteDataDate)

        // Filter to only dates that are on or before latestCompleteDataDate
        return provisionalDates.filter { date in
            let dayStart = calendar.startOfDay(for: date)
            return dayStart <= latestDay
        }
    }

    /// Get provisional P2P trade records that overlap with finalized data dates
    func getProvisionalRecordsNeedingUpdate(siteId: Int, latestCompleteDataDate: Date) -> [P2PTradeRecord] {
        let records = getP2PTradeRecords(siteId: siteId).filter { $0.isProvisional }

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let latestDay = calendar.startOfDay(for: latestCompleteDataDate)

        // Return records where at least part of their date range is on or before latestCompleteDataDate
        return records.filter { record in
            let startDay = calendar.startOfDay(for: record.startDate)
            return startDay <= latestDay
        }
    }

    // MARK: - Maintenance

    /// Clear P2P records for a site
    @MainActor
    func clearP2PTradeRecords(siteId: Int) {
        guard let db = dbQueue else { return }
        
        do {
            try db.write { db in
                try db.execute(
                    sql: "DELETE FROM p2p_trade_records WHERE site_id = ?",
                    arguments: [siteId]
                )
            }
            
            // Also clear from iCloud
            let key = "\(kP2PTradeRecordsKey)_site\(siteId)"
            NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
            NSUbiquitousKeyValueStore.default.synchronize()
            
            print("🗑️ Cleared P2P records for site \(siteId)")
        } catch {
            print("❌ Failed to clear P2P records: \(error)")
        }
    }
}

