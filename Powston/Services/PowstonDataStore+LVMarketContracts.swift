//
//  PowstonDataStore+LVMarketContracts.swift
//  Powston
//
//  GRDB persistence extension for LocalVolts market-wide contracts
//

import Foundation
import GRDB

extension PowstonDataStore {

    // MARK: - Schema Creation (called from performMigrations)

    // Migration version for market contracts - increment to force data clear
    private static let marketContractsVersion = 4  // v4: ContractTable uses actual trading date (no T+1 adjustment needed)

    func createLVMarketContractsSchema(_ db: Database) throws {
        // Check migration version in UserDefaults
        let currentVersion = UserDefaults.standard.integer(forKey: "lv_market_contracts_schema_version")

        // Check if table exists with old schema (has price_cents instead of sell_price_cents)
        if try db.tableExists("lv_market_contracts") {
            let columns = try db.columns(in: "lv_market_contracts").map { $0.name }
            let needsSchemaChange = columns.contains("price_cents") || !columns.contains("sell_price_cents")
            let needsDataClear = currentVersion < Self.marketContractsVersion

            if needsSchemaChange || needsDataClear {
                // Clear old data (schema change or ID format change)
                let reason = needsSchemaChange ? "schema change" : "ID format change to deterministic UUIDs"
                print("🔄 Migration: Clearing lv_market_contracts (\(reason))")
                try db.execute(sql: "DELETE FROM lv_market_contracts")

                if needsSchemaChange {
                    try db.drop(table: "lv_market_contracts")
                } else {
                    // Just data clear, update version and return
                    UserDefaults.standard.set(Self.marketContractsVersion, forKey: "lv_market_contracts_schema_version")
                    return
                }
            } else {
                // Schema and data are current
                return
            }
        }

        print("🔄 Migration: Creating lv_market_contracts table")

        try db.create(table: "lv_market_contracts") { t in
            t.column("id", .text).primaryKey()
            t.column("buyer", .text).notNull()
            t.column("seller", .text).notNull()
            t.column("buyer_facility", .text)
            t.column("seller_facility", .text)
            t.column("region", .text)
            t.column("sell_price_cents", .double).notNull()  // What seller receives
            t.column("buy_price_cents", .double).notNull()   // What buyer pays
            t.column("volume_kwh", .double).notNull()        // 0 = settled, >0 = pending
            t.column("period", .integer).notNull()
            t.column("trade_date", .datetime).notNull()
            t.column("fetched_at", .datetime).notNull()
            t.column("category", .text)                      // SR, SC, etc.
        }

        // Index for date and region queries
        try db.create(
            index: "idx_market_contracts_date_region",
            on: "lv_market_contracts",
            columns: ["trade_date", "region"]
        )

        // Index for seller queries
        try db.create(
            index: "idx_market_contracts_seller",
            on: "lv_market_contracts",
            columns: ["seller", "trade_date"]
        )

        // Index for buyer queries
        try db.create(
            index: "idx_market_contracts_buyer",
            on: "lv_market_contracts",
            columns: ["buyer", "trade_date"]
        )

        // Update schema version
        UserDefaults.standard.set(Self.marketContractsVersion, forKey: "lv_market_contracts_schema_version")

        print("✅ Migration complete: lv_market_contracts table created")
    }

    // MARK: - Save Operations

    /// Save market contracts using upsert (insert or replace)
    /// Contracts have deterministic IDs based on buyer/seller/period/date,
    /// so duplicates are automatically handled without delete-all
    func saveLVMarketContracts(_ contracts: [LVMarketContract], for date: Date) throws {
        guard let db = dbQueue, !contracts.isEmpty else { return }

        var insertCount = 0
        var updateCount = 0

        try db.write { db in
            for contract in contracts {
                // Check if exists
                let exists = try LVMarketContract.fetchOne(db, key: contract.id) != nil

                // Upsert (insert or replace)
                try contract.save(db, onConflict: .replace)

                if exists {
                    updateCount += 1
                } else {
                    insertCount += 1
                }
            }
        }

        if updateCount > 0 {
            print("💾 Market contracts: \(insertCount) new, \(updateCount) updated for \(formatDate(date))")
        } else {
            print("💾 Saved \(insertCount) market contracts for \(formatDate(date))")
        }
    }

    // MARK: - Query Operations

    /// Get market contracts for a specific date
    func getLVMarketContracts(for date: Date) -> [LVMarketContract] {
        guard let db = dbQueue else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        do {
            return try db.read { db in
                try LVMarketContract.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM lv_market_contracts
                        WHERE trade_date >= ? AND trade_date < ?
                        ORDER BY period ASC
                        """,
                    arguments: [dayStart, dayEnd]
                )
            }
        } catch {
            print("❌ getLVMarketContracts failed: \(error)")
            return []
        }
    }

    /// Get market contracts for a specific seller
    func getLVMarketContracts(seller: String, date: Date) -> [LVMarketContract] {
        guard let db = dbQueue else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        do {
            return try db.read { db in
                try LVMarketContract.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM lv_market_contracts
                        WHERE seller = ? AND trade_date >= ? AND trade_date < ?
                        ORDER BY period ASC
                        """,
                    arguments: [seller, dayStart, dayEnd]
                )
            }
        } catch {
            print("❌ getLVMarketContracts for seller failed: \(error)")
            return []
        }
    }

    /// Get market contracts for a specific region
    func getLVMarketContracts(region: String, date: Date) -> [LVMarketContract] {
        guard let db = dbQueue else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        do {
            return try db.read { db in
                try LVMarketContract.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM lv_market_contracts
                        WHERE region = ? AND trade_date >= ? AND trade_date < ?
                        ORDER BY period ASC
                        """,
                    arguments: [region, dayStart, dayEnd]
                )
            }
        } catch {
            print("❌ getLVMarketContracts for region failed: \(error)")
            return []
        }
    }

    /// Count market contracts for a date
    func countLVMarketContracts(for date: Date) -> Int {
        guard let db = dbQueue else { return 0 }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        return (try? db.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM lv_market_contracts
                    WHERE trade_date >= ? AND trade_date < ?
                    """,
                arguments: [dayStart, dayEnd]
            )
        }) ?? 0
    }

    /// Get unique regions from market contracts
    func getLVMarketRegions(for date: Date) -> [String] {
        guard let db = dbQueue else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        do {
            return try db.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT region FROM lv_market_contracts
                        WHERE trade_date >= ? AND trade_date < ?
                        AND region IS NOT NULL
                        ORDER BY region
                        """,
                    arguments: [dayStart, dayEnd]
                )
            }
        } catch {
            print("❌ getLVMarketRegions failed: \(error)")
            return []
        }
    }

    /// Get last fetch time for market contracts
    func getLastLVMarketContractsFetchTime() -> Date? {
        guard let db = dbQueue else { return nil }

        return try? db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT last_sync_time FROM sync_metadata
                    WHERE entity_type = 'lv_market_contracts'
                    """
            )
            return row?["last_sync_time"] as? Date
        }
    }

    /// Set last fetch time for market contracts
    func setLastLVMarketContractsFetchTime(date: Date = Date()) {
        guard let db = dbQueue else { return }

        do {
            try db.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sync_metadata
                        (entity_type, site_id, inverter_id, last_sync_time, record_count)
                        VALUES ('lv_market_contracts', 0, NULL, ?, 0)
                        ON CONFLICT(entity_type, site_id, inverter_id)
                        DO UPDATE SET last_sync_time = excluded.last_sync_time
                        """,
                    arguments: [date]
                )
            }
        } catch {
            print("❌ setLastLVMarketContractsFetchTime failed: \(error)")
        }
    }

    /// Check if market data is stale (>5 minutes old)
    func isLVMarketContractsStale(maxAge: TimeInterval = 300) -> Bool {
        guard let lastFetch = getLastLVMarketContractsFetchTime() else {
            return true
        }
        return Date().timeIntervalSince(lastFetch) > maxAge
    }

    // MARK: - Date Range Queries

    /// Get market contracts for a date range (for pricing analysis)
    func getLVMarketContracts(from startDate: Date, to endDate: Date) -> [LVMarketContract] {
        guard let db = dbQueue else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let rangeStart = calendar.startOfDay(for: startDate)
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate))!

        do {
            return try db.read { db in
                try LVMarketContract.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM lv_market_contracts
                        WHERE trade_date >= ? AND trade_date < ?
                        ORDER BY trade_date ASC, period ASC
                        """,
                    arguments: [rangeStart, rangeEnd]
                )
            }
        } catch {
            print("❌ getLVMarketContracts(range) failed: \(error)")
            return []
        }
    }

    /// Get dates that have market contract data
    func getLVMarketContractDates() -> [Date] {
        guard let db = dbQueue else { return [] }

        do {
            return try db.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT DATE(trade_date) as date_str
                        FROM lv_market_contracts
                        ORDER BY date_str DESC
                        """
                )

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")

                return rows.compactMap { row -> Date? in
                    guard let dateStr = row["date_str"] as? String else { return nil }
                    return formatter.date(from: dateStr)
                }
            }
        } catch {
            print("❌ getLVMarketContractDates failed: \(error)")
            return []
        }
    }

    // MARK: - Price Analysis

    /// Market price statistics for a date
    /// Note: Uses sell price (what sellers receive) as the primary price metric.
    /// Volume field is a settlement indicator (0=settled, >0=pending), not trade size.
    struct MarketPriceStats {
        let date: Date
        let minSellPrice: Double      // Lowest sell price in cents
        let maxSellPrice: Double      // Highest sell price in cents
        let avgSellPrice: Double      // Average sell price
        let avgBuyPrice: Double       // Average buy price (what buyers pay)
        let avgMatchingFee: Double    // Average LV matching fee (buy - sell)
        let avgMatchingFeePercent: Double  // Fee as % of sell price
        let tradeCount: Int           // Total number of contracts
        let settledCount: Int         // Contracts with volume=0 (past periods)
        let pendingCount: Int         // Contracts with volume>0 (future periods)
        let p25Price: Double          // 25th percentile sell price
        let p50Price: Double          // Median sell price
        let p75Price: Double          // 75th percentile sell price

        // Legacy compatibility
        var minPrice: Double { minSellPrice }
        var maxPrice: Double { maxSellPrice }
        var avgPrice: Double { avgSellPrice }
        var volumeWeightedAvgPrice: Double { avgSellPrice }  // No longer meaningful
        var totalVolume: Double { 0 }  // Volume is settlement status, not trade size
    }

    /// Get price statistics for a date
    func getLVMarketPriceStats(for date: Date) -> MarketPriceStats? {
        let contracts = getLVMarketContracts(for: date)
        guard !contracts.isEmpty else { return nil }

        let sellPrices = contracts.map { $0.sellPriceCents }
        let buyPrices = contracts.map { $0.buyPriceCents }
        let sortedSellPrices = sellPrices.sorted()

        let avgSellPrice = sellPrices.reduce(0, +) / Double(max(sellPrices.count, 1))
        let avgBuyPrice = buyPrices.reduce(0, +) / Double(max(buyPrices.count, 1))
        let avgMatchingFee = avgBuyPrice - avgSellPrice
        let avgMatchingFeePercent = avgSellPrice > 0 ? (avgMatchingFee / avgSellPrice) * 100 : 0

        let settledCount = contracts.filter { $0.isSettled }.count
        let pendingCount = contracts.filter { $0.isPending }.count

        // Percentiles
        let p25Index = Int(Double(sortedSellPrices.count) * 0.25)
        let p50Index = Int(Double(sortedSellPrices.count) * 0.50)
        let p75Index = Int(Double(sortedSellPrices.count) * 0.75)

        return MarketPriceStats(
            date: date,
            minSellPrice: sortedSellPrices.first ?? 0,
            maxSellPrice: sortedSellPrices.last ?? 0,
            avgSellPrice: avgSellPrice,
            avgBuyPrice: avgBuyPrice,
            avgMatchingFee: avgMatchingFee,
            avgMatchingFeePercent: avgMatchingFeePercent,
            tradeCount: contracts.count,
            settledCount: settledCount,
            pendingCount: pendingCount,
            p25Price: sortedSellPrices.indices.contains(p25Index) ? sortedSellPrices[p25Index] : 0,
            p50Price: sortedSellPrices.indices.contains(p50Index) ? sortedSellPrices[p50Index] : 0,
            p75Price: sortedSellPrices.indices.contains(p75Index) ? sortedSellPrices[p75Index] : 0
        )
    }

    /// Get price statistics for a date range (for trend analysis)
    func getLVMarketPriceHistory(days: Int = 60) -> [MarketPriceStats] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!

        var stats: [MarketPriceStats] = []
        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            if let dayStat = getLVMarketPriceStats(for: date) {
                stats.append(dayStat)
            }
        }

        return stats.reversed()  // Oldest first
    }

    /// Get contract count by price tier for a date (histogram data)
    /// Note: Volume is a settlement indicator, so we count contracts instead
    func getLVMarketPriceTiers(for date: Date, tierSize: Double = 5.0) -> [(priceTier: Int, count: Int, avgMatchingFee: Double)] {
        let contracts = getLVMarketContracts(for: date)
        guard !contracts.isEmpty else { return [] }

        // Group by sell price tier
        var tiers: [Int: (count: Int, totalFee: Double)] = [:]
        for contract in contracts {
            let tier = Int((contract.sellPriceCents / tierSize).rounded()) * Int(tierSize)
            let existing = tiers[tier] ?? (count: 0, totalFee: 0)
            tiers[tier] = (count: existing.count + 1, totalFee: existing.totalFee + contract.matchingFeeCents)
        }

        return tiers.map { tier, data in
            (priceTier: tier, count: data.count, avgMatchingFee: data.count > 0 ? data.totalFee / Double(data.count) : 0)
        }
        .sorted { $0.priceTier < $1.priceTier }
    }

    /// Legacy compatibility wrapper
    func getLVMarketVolumeTiers(for date: Date, tierSize: Double = 5.0) -> [(priceTier: Int, volume: Double, count: Int)] {
        getLVMarketPriceTiers(for: date, tierSize: tierSize).map { (priceTier: $0.priceTier, volume: 0.0, count: $0.count) }
    }

    /// Get top sellers by contract count for a date
    /// Note: Since volume is a settlement indicator (not trade size), we rank by contract count
    func getLVMarketTopSellers(for date: Date, limit: Int = 10) -> [(seller: String, contractCount: Int, avgSellPrice: Double, avgMatchingFee: Double)] {
        let contracts = getLVMarketContracts(for: date)
        guard !contracts.isEmpty else { return [] }

        // Group by seller
        var sellers: [String: (count: Int, totalSellPrice: Double, totalMatchingFee: Double)] = [:]
        for contract in contracts {
            let existing = sellers[contract.seller] ?? (count: 0, totalSellPrice: 0, totalMatchingFee: 0)
            sellers[contract.seller] = (
                count: existing.count + 1,
                totalSellPrice: existing.totalSellPrice + contract.sellPriceCents,
                totalMatchingFee: existing.totalMatchingFee + contract.matchingFeeCents
            )
        }

        return sellers.map { seller, data in
            (
                seller: seller,
                contractCount: data.count,
                avgSellPrice: data.count > 0 ? data.totalSellPrice / Double(data.count) : 0,
                avgMatchingFee: data.count > 0 ? data.totalMatchingFee / Double(data.count) : 0
            )
        }
        .sorted { $0.contractCount > $1.contractCount }
        .prefix(limit)
        .map { $0 }
    }

    // MARK: - Cleanup

    /// Delete market contracts older than specified days (default 60 for pricing analysis)
    func cleanupOldLVMarketContracts(olderThanDays: Int = 60) {
        guard let db = dbQueue else { return }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let cutoffDate = calendar.date(byAdding: .day, value: -olderThanDays, to: Date())!

        do {
            try db.write { db in
                try db.execute(
                    sql: "DELETE FROM lv_market_contracts WHERE trade_date < ?",
                    arguments: [cutoffDate]
                )
                let changesCount = db.changesCount
                if changesCount > 0 {
                    print("🗑️ Cleaned up \(changesCount) old market contracts (>\(olderThanDays) days)")
                }
            }
        } catch {
            print("❌ cleanupOldLVMarketContracts failed: \(error)")
        }
    }

    /// Delete all market contracts
    func clearAllLVMarketContracts() {
        guard let db = dbQueue else { return }

        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM lv_market_contracts")
            }
            print("🗑️ Cleared all market contracts")
        } catch {
            print("❌ clearAllLVMarketContracts failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        return formatter.string(from: date)
    }
}
