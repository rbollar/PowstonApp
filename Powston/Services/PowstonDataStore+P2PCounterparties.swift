//
//  PowstonDataStore_P2PCounterparties.swift
//  Powston
//
//  P2P counterparty trade persistence with aggregation queries
//  Enables tracking buyer patterns for relationship building
//
//  IMPORTANT: Requires schema migration in PowstonDataStore.swift
//  Add in performMigrations(): try createP2PCounterpartySchema(db)
//

import Foundation
import GRDB

// MARK: - iCloud KVS Keys

private let kP2PCounterpartyTradesKey = "p2p_counterparty_trades_v1"

// MARK: - PowstonDataStore P2P Counterparty Extension

extension PowstonDataStore {
    
    // MARK: - Schema Creation
    
    /// Call this from PowstonDataStore.performMigrations()
    func createP2PCounterpartySchema(_ db: Database) throws {
        try db.create(table: "p2p_counterparty_trades", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("trade_record_id", .text).notNull()
            t.column("site_id", .integer).notNull()
            t.column("counterparty_name", .text).notNull()
            t.column("volume_kwh", .double).notNull()
            t.column("price_cents", .double).notNull()
            t.column("trade_date", .datetime).notNull()
            t.column("imported_at", .datetime).notNull()
            t.column("direction", .text).notNull().defaults(to: "Sell")
        }
        
        // Index for querying by site
        try db.create(
            index: "idx_counterparty_trades_site",
            on: "p2p_counterparty_trades",
            columns: ["site_id"],
            ifNotExists: true
        )
        
        // Index for querying by counterparty name
        try db.create(
            index: "idx_counterparty_trades_name",
            on: "p2p_counterparty_trades",
            columns: ["site_id", "counterparty_name"],
            ifNotExists: true
        )
        
        // Index for querying by parent trade record
        try db.create(
            index: "idx_counterparty_trades_record",
            on: "p2p_counterparty_trades",
            columns: ["trade_record_id"],
            ifNotExists: true
        )
        
        // Index for date-based queries
        try db.create(
            index: "idx_counterparty_trades_date",
            on: "p2p_counterparty_trades",
            columns: ["site_id", "trade_date"],
            ifNotExists: true
        )
        
        print("✅ Created p2p_counterparty_trades schema")
    }
    
    // MARK: - Save Operations
    
    /// Save counterparty trades for a trade record
    /// Replaces any existing trades for the same trade_record_id
    @MainActor
    func saveP2PCounterpartyTrades(_ trades: [P2PCounterpartyTrade], forTradeRecord tradeRecordId: UUID) -> Bool {
        guard let db = dbQueue else { return false }
        
        do {
            try db.write { db in
                // Delete existing trades for this record (in case of re-import)
                try db.execute(
                    sql: "DELETE FROM p2p_counterparty_trades WHERE trade_record_id = ?",
                    arguments: [tradeRecordId.uuidString]
                )
                
                // Insert new trades
                for trade in trades {
                    try trade.insert(db)
                }
            }
            
            print("💾 Saved \(trades.count) counterparty trades for record \(tradeRecordId)")
            
            // Sync to iCloud
            if let firstTrade = trades.first {
                syncCounterpartyTradesToCloud(siteId: firstTrade.siteId)
            }
            
            return true
        } catch {
            print("❌ Failed to save counterparty trades: \(error)")
            return false
        }
    }
    
    /// Delete counterparty trades for a trade record
    @MainActor
    func deleteP2PCounterpartyTrades(forTradeRecord tradeRecordId: UUID) -> Bool {
        guard let db = dbQueue else { return false }
        
        do {
            // Get site ID before deleting for cloud sync
            let siteId = try db.read { db -> Int? in
                try Int.fetchOne(
                    db,
                    sql: "SELECT site_id FROM p2p_counterparty_trades WHERE trade_record_id = ? LIMIT 1",
                    arguments: [tradeRecordId.uuidString]
                )
            }
            
            try db.write { db in
                try db.execute(
                    sql: "DELETE FROM p2p_counterparty_trades WHERE trade_record_id = ?",
                    arguments: [tradeRecordId.uuidString]
                )
            }
            
            print("🗑️ Deleted counterparty trades for record \(tradeRecordId)")
            
            if let siteId = siteId {
                syncCounterpartyTradesToCloud(siteId: siteId)
            }
            
            return true
        } catch {
            print("❌ Failed to delete counterparty trades: \(error)")
            return false
        }
    }
    
    // MARK: - Query Operations
    
    /// Get all counterparty trades for a site
    func getP2PCounterpartyTrades(siteId: Int) -> [P2PCounterpartyTrade] {
        guard let db = dbQueue else { return [] }
        
        do {
            return try db.read { db in
                try P2PCounterpartyTrade.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM p2p_counterparty_trades
                        WHERE site_id = ?
                        ORDER BY trade_date DESC
                        """,
                    arguments: [siteId]
                )
            }
        } catch {
            print("❌ getP2PCounterpartyTrades failed: \(error)")
            return []
        }
    }
    
    /// Get counterparty trades for a specific trade record
    func getP2PCounterpartyTrades(forTradeRecord tradeRecordId: UUID) -> [P2PCounterpartyTrade] {
        guard let db = dbQueue else { return [] }
        
        do {
            return try db.read { db in
                try P2PCounterpartyTrade.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM p2p_counterparty_trades
                        WHERE trade_record_id = ?
                        ORDER BY volume_kwh DESC
                        """,
                    arguments: [tradeRecordId.uuidString]
                )
            }
        } catch {
            print("❌ getP2PCounterpartyTrades(forRecord) failed: \(error)")
            return []
        }
    }
    
    /// Get all trades for a specific counterparty
    /// Uses LV data if available (canonical source), otherwise CSV imports
    /// - Parameters:
    ///   - siteId: The site ID
    ///   - counterpartyName: Name of the counterparty
    ///   - includeContracts: If false, only shows actual executed trades (period_start <= now)
    func getP2PCounterpartyTrades(siteId: Int, counterpartyName: String, includeContracts: Bool = false) -> [P2PCounterpartyTrade] {
        guard let db = dbQueue else { return [] }

        do {
            // Check if lv_interval_trades table exists and has data for this counterparty
            let lvTableExists = try db.read { db in
                try db.tableExists("lv_interval_trades")
            }

            let sql: String
            let arguments: [DatabaseValueConvertible]

            if lvTableExists {
                // Check if we have LV data for this counterparty
                let lvTradeCount = try db.read { db -> Int in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM lv_interval_trades WHERE site_id = ? AND counterparty_name = ?",
                        arguments: [siteId, counterpartyName]
                    ) ?? 0
                }

                if lvTradeCount > 0 {
                    // Use ONLY LV data (canonical source)
                    var whereClause = "site_id = ? AND counterparty_name = ?"
                    arguments = [siteId, counterpartyName]

                    // Filter to only actual executed trades (not future contracts)
                    if !includeContracts {
                        whereClause += " AND period_start <= datetime('now')"
                    }

                    sql = """
                        SELECT
                            id,
                            '00000000-0000-0000-0000-000000000000' as trade_record_id,
                            site_id,
                            counterparty_name,
                            volume_kwh,
                            COALESCE(
                                CASE WHEN direction = 'Sell' THEN sell_price_cents ELSE buy_price_cents END,
                                0
                            ) as price_cents,
                            period_start as trade_date,
                            fetched_at as imported_at,
                            direction,
                            cp_facility as facility
                        FROM lv_interval_trades
                        WHERE \(whereClause)
                        ORDER BY period_start DESC
                        """
                } else {
                    // No LV data for this counterparty, use CSV imports
                    sql = """
                        SELECT *, NULL as facility FROM p2p_counterparty_trades
                        WHERE site_id = ? AND counterparty_name = ?
                        ORDER BY trade_date DESC
                        """
                    arguments = [siteId, counterpartyName]
                }
            } else {
                // Only CSV imports
                sql = """
                    SELECT *, NULL as facility FROM p2p_counterparty_trades
                    WHERE site_id = ? AND counterparty_name = ?
                    ORDER BY trade_date DESC
                    """
                arguments = [siteId, counterpartyName]
            }

            return try db.read { db in
                try P2PCounterpartyTrade.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            }
        } catch {
            print("❌ getP2PCounterpartyTrades(name) failed: \(error)")
            return []
        }
    }

    /// Get counterparty trades for a date range
    /// Uses LV data if available (canonical source), otherwise CSV imports
    func getP2PCounterpartyTrades(siteId: Int, from startDate: Date, to endDate: Date) -> [P2PCounterpartyTrade] {
        guard let db = dbQueue else { return [] }

        do {
            // Check if lv_interval_trades table exists
            let lvTableExists = try db.read { db in
                try db.tableExists("lv_interval_trades")
            }

            let sql: String
            let arguments: [DatabaseValueConvertible]

            if lvTableExists {
                // Check if we have LV data in the requested date range
                let lvTradeCount = try db.read { db -> Int in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM lv_interval_trades WHERE site_id = ? AND period_start >= ? AND period_start <= ?",
                        arguments: [siteId, startDate, endDate]
                    ) ?? 0
                }

                if lvTradeCount > 0 {
                    // Use ONLY LV data (canonical source)
                    sql = """
                        SELECT
                            id,
                            '00000000-0000-0000-0000-000000000000' as trade_record_id,
                            site_id,
                            counterparty_name,
                            volume_kwh,
                            COALESCE(
                                CASE WHEN direction = 'Sell' THEN sell_price_cents ELSE buy_price_cents END,
                                0
                            ) as price_cents,
                            period_start as trade_date,
                            fetched_at as imported_at,
                            direction,
                            cp_facility as facility
                        FROM lv_interval_trades
                        WHERE site_id = ?
                        AND period_start >= ?
                        AND period_start <= ?
                        ORDER BY period_start DESC
                        """
                    arguments = [siteId, startDate, endDate]
                } else {
                    // No LV data in this range, use CSV imports
                    sql = """
                        SELECT *, NULL as facility FROM p2p_counterparty_trades
                        WHERE site_id = ?
                        AND trade_date >= ?
                        AND trade_date <= ?
                        ORDER BY trade_date DESC
                        """
                    arguments = [siteId, startDate, endDate]
                }
            } else {
                sql = """
                    SELECT *, NULL as facility FROM p2p_counterparty_trades
                    WHERE site_id = ?
                    AND trade_date >= ?
                    AND trade_date <= ?
                    ORDER BY trade_date DESC
                    """
                arguments = [siteId, startDate, endDate]
            }

            return try db.read { db in
                try P2PCounterpartyTrade.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            }
        } catch {
            print("❌ getP2PCounterpartyTrades(range) failed: \(error)")
            return []
        }
    }
    
    // MARK: - Aggregation Queries
    
    /// Check if a counterparty name indicates a commercial entity
    /// Uses P2PCounterpartyClassifier for three-layer classification
    private func isCommercialCounterparty(_ name: String) -> Bool {
        // Use the shared classifier (heuristics + manual overrides + AI cache)
        return P2PCounterpartyClassifier.shared.isCommercial(name)
    }
    
    /// Get counterparty leaderboard (aggregated stats per counterparty)
    /// Uses LV data if available (canonical source), otherwise CSV imports
    /// - Parameters:
    ///   - siteId: The site ID
    ///   - limit: Maximum number of counterparties to return
    ///   - direction: Filter by trade direction (nil = all)
    ///   - includeContracts: If false, only shows actual executed trades (period_start <= now)
    func getP2PCounterpartyLeaderboard(siteId: Int, limit: Int = 50, direction: P2PTradeDirection? = nil, includeContracts: Bool = false) -> [P2PCounterpartySummary] {
        guard let db = dbQueue else { return [] }

        do {
            // Check if lv_interval_trades table exists
            let lvTableExists = try db.read { db in
                try db.tableExists("lv_interval_trades")
            }

            // Build direction filter clause for CSV imports
            var csvDirectionClause = ""
            var arguments: [DatabaseValueConvertible] = [siteId]

            if let dir = direction {
                csvDirectionClause = " AND ct.direction = ?"
                arguments.append(dir.rawValue)
            }

            var sql: String

            if lvTableExists {
                // Check if we have LV data for this site
                let lvTradeCount = try db.read { db -> Int in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM lv_interval_trades WHERE site_id = ?",
                        arguments: [siteId]
                    ) ?? 0
                }

                if lvTradeCount > 0 {
                    // We have LV data - use ONLY LV data (it's the canonical source)
                    // This avoids double-counting with CSV imports
                    var lvWhereClause = "site_id = ?"
                    arguments = [siteId]

                    // Filter to only actual executed trades (not future contracts)
                    if !includeContracts {
                        lvWhereClause += " AND period_start <= datetime('now')"
                    }

                    if let dir = direction {
                        lvWhereClause += " AND direction = ?"
                        arguments.append(dir.rawValue)
                    }

                    sql = """
                        SELECT
                            counterparty_name,
                            SUM(volume_kwh) as total_volume,
                            SUM(volume_kwh * COALESCE(
                                CASE WHEN direction = 'Sell' THEN sell_price_cents ELSE buy_price_cents END,
                                0
                            ) / 100.0) as total_revenue,
                            COUNT(*) as trade_count,
                            CASE WHEN SUM(volume_kwh) > 0
                                 THEN SUM(volume_kwh * COALESCE(
                                     CASE WHEN direction = 'Sell' THEN sell_price_cents ELSE buy_price_cents END,
                                     0
                                 )) / SUM(volume_kwh)
                                 ELSE 0 END as avg_price,
                            MIN(COALESCE(
                                CASE WHEN direction = 'Sell' THEN sell_price_cents ELSE buy_price_cents END,
                                0
                            )) as min_price,
                            MAX(COALESCE(
                                CASE WHEN direction = 'Sell' THEN sell_price_cents ELSE buy_price_cents END,
                                0
                            )) as max_price,
                            MIN(period_start) as first_trade,
                            MAX(period_start) as last_trade
                        FROM lv_interval_trades
                        WHERE \(lvWhereClause)
                        GROUP BY counterparty_name
                        ORDER BY total_volume DESC
                        LIMIT \(limit)
                        """
                } else {
                    // No LV data yet, use CSV imports
                    sql = """
                        SELECT
                            ct.counterparty_name,
                            SUM(ct.volume_kwh) as total_volume,
                            SUM(ct.volume_kwh * ct.price_cents / 100.0) as total_revenue,
                            COUNT(*) as trade_count,
                            CASE WHEN SUM(ct.volume_kwh) > 0
                                 THEN SUM(ct.volume_kwh * ct.price_cents) / SUM(ct.volume_kwh)
                                 ELSE 0 END as avg_price,
                            MIN(ct.price_cents) as min_price,
                            MAX(ct.price_cents) as max_price,
                            MIN(ct.trade_date) as first_trade,
                            MAX(ct.trade_date) as last_trade
                        FROM p2p_counterparty_trades ct
                        INNER JOIN p2p_trade_records tr ON ct.trade_record_id = tr.id
                        WHERE ct.site_id = ?\(csvDirectionClause)
                        GROUP BY ct.counterparty_name
                        ORDER BY total_volume DESC
                        LIMIT \(limit)
                        """
                }
            } else {
                // LV table doesn't exist yet, use only CSV imports
                sql = """
                    SELECT
                        ct.counterparty_name,
                        SUM(ct.volume_kwh) as total_volume,
                        SUM(ct.volume_kwh * ct.price_cents / 100.0) as total_revenue,
                        COUNT(*) as trade_count,
                        CASE WHEN SUM(ct.volume_kwh) > 0
                             THEN SUM(ct.volume_kwh * ct.price_cents) / SUM(ct.volume_kwh)
                             ELSE 0 END as avg_price,
                        MIN(ct.price_cents) as min_price,
                        MAX(ct.price_cents) as max_price,
                        MIN(ct.trade_date) as first_trade,
                        MAX(ct.trade_date) as last_trade
                    FROM p2p_counterparty_trades ct
                    INNER JOIN p2p_trade_records tr ON ct.trade_record_id = tr.id
                    WHERE ct.site_id = ?\(csvDirectionClause)
                    GROUP BY ct.counterparty_name
                    ORDER BY total_volume DESC
                    LIMIT \(limit)
                    """
            }

            print("📊 getP2PCounterpartyLeaderboard: siteId=\(siteId), lvTableExists=\(lvTableExists), args=\(arguments)")

            let rows = try db.read { db in
                try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            }

            print("📊 getP2PCounterpartyLeaderboard: found \(rows.count) rows")

            var results: [P2PCounterpartySummary] = []
            
            for row in rows {
                guard let name: String = row["counterparty_name"],
                      let totalVolume: Double = row["total_volume"],
                      let totalRevenue: Double = row["total_revenue"],
                      let tradeCount: Int = row["trade_count"],
                      let avgPrice: Double = row["avg_price"],
                      let minPrice: Double = row["min_price"],
                      let maxPrice: Double = row["max_price"],
                      let firstTrade: Date = row["first_trade"],
                      let lastTrade: Date = row["last_trade"] else {
                    continue
                }
                
                let summary = P2PCounterpartySummary(
                    counterpartyName: name,
                    totalVolumeKwh: totalVolume,
                    totalRevenue: totalRevenue,
                    tradeCount: tradeCount,
                    avgPriceCents: avgPrice,
                    minPriceCents: minPrice,
                    maxPriceCents: maxPrice,
                    firstTradeDate: firstTrade,
                    lastTradeDate: lastTrade,
                    isCommercial: isCommercialCounterparty(name)
                )
                results.append(summary)
            }
            
            return results
        } catch {
            print("❌ getP2PCounterpartyLeaderboard failed: \(error)")
            return []
        }
    }
    
    /// Get trade history for a specific counterparty (for detail view)
    /// Uses LV data if available (canonical source), otherwise CSV imports
    /// Groups by day for display
    /// - Parameters:
    ///   - siteId: The site ID
    ///   - counterpartyName: Name of the counterparty
    ///   - includeContracts: If false, only shows actual executed trades (period_start <= now)
    func getP2PCounterpartyHistory(siteId: Int, counterpartyName: String, includeContracts: Bool = false) -> [P2PCounterpartyTradeHistory] {
        guard let db = dbQueue else { return [] }

        do {
            // Check if lv_interval_trades table exists
            let lvTableExists = try db.read { db in
                try db.tableExists("lv_interval_trades")
            }

            return try db.read { db in
                var results: [P2PCounterpartyTradeHistory] = []

                if lvTableExists {
                    // Check if we have LV data for this counterparty
                    let lvTradeCount = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM lv_interval_trades WHERE site_id = ? AND counterparty_name = ?",
                        arguments: [siteId, counterpartyName]
                    ) ?? 0

                    if lvTradeCount > 0 {
                        // Use ONLY LV data (canonical source) - grouped by day
                        var whereClause = "site_id = ? AND counterparty_name = ?"

                        // Filter to only actual executed trades (not future contracts)
                        if !includeContracts {
                            whereClause += " AND period_start <= datetime('now')"
                        }

                        let lvRows = try Row.fetchAll(
                            db,
                            sql: """
                                SELECT
                                    date(period_start) as trade_day,
                                    MIN(period_start) as trade_date,
                                    SUM(volume_kwh) as volume,
                                    CASE WHEN SUM(volume_kwh) > 0
                                         THEN SUM(volume_kwh * COALESCE(
                                             CASE WHEN direction = 'Sell' THEN sell_price_cents ELSE buy_price_cents END,
                                             0
                                         )) / SUM(volume_kwh)
                                         ELSE 0 END as price,
                                    SUM(volume_kwh * COALESCE(
                                        CASE WHEN direction = 'Sell' THEN sell_price_cents ELSE buy_price_cents END,
                                        0
                                    ) / 100.0) as revenue,
                                    COUNT(*) as trade_count,
                                    MIN(period_start) as import_start,
                                    MAX(period_start) as import_end,
                                    direction,
                                    'lv' as source
                                FROM lv_interval_trades
                                WHERE \(whereClause)
                                GROUP BY date(period_start), direction
                                ORDER BY trade_day DESC
                                """,
                            arguments: [siteId, counterpartyName]
                        )

                        for row in lvRows {
                            if let history = self.parseHistoryRow(row) {
                                results.append(history)
                            }
                        }

                        return results.sorted { $0.tradeDate > $1.tradeDate }
                    }
                }

                // No LV data - use CSV imports (grouped by trade_record_id)
                let csvRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT
                            ct.trade_date,
                            SUM(ct.volume_kwh) as volume,
                            SUM(ct.volume_kwh * ct.price_cents) / SUM(ct.volume_kwh) as price,
                            SUM(ct.volume_kwh * ct.price_cents / 100.0) as revenue,
                            COUNT(*) as trade_count,
                            tr.start_date as import_start,
                            tr.end_date as import_end,
                            tr.direction as direction,
                            'csv' as source
                        FROM p2p_counterparty_trades ct
                        INNER JOIN p2p_trade_records tr ON ct.trade_record_id = tr.id
                        WHERE ct.site_id = ? AND ct.counterparty_name = ?
                        GROUP BY ct.trade_record_id
                        ORDER BY tr.start_date DESC
                        """,
                    arguments: [siteId, counterpartyName]
                )

                for row in csvRows {
                    if let history = self.parseHistoryRow(row) {
                        results.append(history)
                    }
                }

                return results.sorted { $0.tradeDate > $1.tradeDate }
            }
        } catch {
            print("❌ getP2PCounterpartyHistory failed: \(error)")
            return []
        }
    }

    private func parseHistoryRow(_ row: Row) -> P2PCounterpartyTradeHistory? {
        guard let tradeDate: Date = row["trade_date"],
              let volume: Double = row["volume"],
              let price: Double = row["price"],
              let revenue: Double = row["revenue"],
              let tradeCount: Int = row["trade_count"] else {
            return nil
        }

        let importStart: Date? = row["import_start"]
        let importEnd: Date? = row["import_end"]

        // Direction handling - works for both P2PTradeDirection and LVTradeDirection
        let directionStr: String? = row["direction"]
        let direction: P2PTradeDirection
        if let dirStr = directionStr {
            if dirStr == "Sell" || dirStr == "sell" {
                direction = .sell
            } else if dirStr == "Buy" || dirStr == "buy" {
                direction = .buy
            } else {
                direction = P2PTradeDirection(rawValue: dirStr) ?? .sell
            }
        } else {
            direction = .sell
        }

        return P2PCounterpartyTradeHistory(
            tradeDate: tradeDate,
            volumeKwh: volume,
            priceCents: price,
            revenue: revenue,
            tradeCount: tradeCount,
            importStart: importStart,
            importEnd: importEnd,
            direction: direction
        )
    }
    
    /// Get overall counterparty stats
    func getP2PCounterpartyStats(siteId: Int) -> (totalCounterparties: Int, commercialCount: Int, residentialCount: Int, topBuyerVolume: Double) {
        let leaderboard = getP2PCounterpartyLeaderboard(siteId: siteId, limit: 1000)
        
        let commercialCount = leaderboard.filter { $0.isCommercial }.count
        let residentialCount = leaderboard.count - commercialCount
        let topBuyerVolume = leaderboard.first?.totalVolumeKwh ?? 0
        
        return (leaderboard.count, commercialCount, residentialCount, topBuyerVolume)
    }
    
    /// Get counterparties who pay premium prices (above threshold)
    func getPremiumCounterparties(siteId: Int, minAvgPriceCents: Double = 25.0) -> [P2PCounterpartySummary] {
        let leaderboard = getP2PCounterpartyLeaderboard(siteId: siteId, limit: 1000)
        return leaderboard.filter { $0.avgPriceCents >= minAvgPriceCents }
            .sorted { $0.totalVolumeKwh > $1.totalVolumeKwh }
    }
    
    /// Get counterparties with consistent buying patterns (multiple trades)
    func getConsistentCounterparties(siteId: Int, minTradeCount: Int = 3) -> [P2PCounterpartySummary] {
        let leaderboard = getP2PCounterpartyLeaderboard(siteId: siteId, limit: 1000)
        return leaderboard.filter { $0.tradeCount >= minTradeCount }
            .sorted { $0.totalVolumeKwh > $1.totalVolumeKwh }
    }

    /// Get counterparty names that have trades in both directions (buy AND sell)
    /// These represent direct negotiation opportunities
    /// Combines both CSV imports and LocalVolts API data
    func getBidirectionalCounterparties(siteId: Int) -> Set<String> {
        guard let db = dbQueue else { return [] }

        do {
            // Check if lv_interval_trades table exists
            let lvTableExists = try db.read { db in
                try db.tableExists("lv_interval_trades")
            }

            let sql: String
            if lvTableExists {
                // UNION both data sources and find counterparties with both directions
                sql = """
                    SELECT counterparty_name
                    FROM (
                        SELECT ct.counterparty_name, tr.direction
                        FROM p2p_counterparty_trades ct
                        INNER JOIN p2p_trade_records tr ON ct.trade_record_id = tr.id
                        WHERE ct.site_id = ?

                        UNION

                        SELECT counterparty_name, direction
                        FROM lv_interval_trades
                        WHERE site_id = ?
                    ) combined
                    GROUP BY counterparty_name
                    HAVING COUNT(DISTINCT direction) > 1
                    """
            } else {
                sql = """
                    SELECT ct.counterparty_name
                    FROM p2p_counterparty_trades ct
                    INNER JOIN p2p_trade_records tr ON ct.trade_record_id = tr.id
                    WHERE ct.site_id = ?
                    GROUP BY ct.counterparty_name
                    HAVING COUNT(DISTINCT tr.direction) > 1
                    """
            }

            let names = try db.read { db in
                if lvTableExists {
                    return try String.fetchAll(db, sql: sql, arguments: [siteId, siteId])
                } else {
                    return try String.fetchAll(db, sql: sql, arguments: [siteId])
                }
            }
            return Set(names)
        } catch {
            print("❌ getBidirectionalCounterparties failed: \(error)")
            return []
        }
    }

    /// Get market demand aggregated by exact price point (1¢ buckets)
    /// Shows actual vs provisional (forecast) volume and revenue at each price
    func getP2PMarketDemandByPrice(siteId: Int) -> [P2PPriceDemand] {
        guard let db = dbQueue else { return [] }

        // Get all trade records to identify provisional ones
        let tradeRecords = getP2PTradeRecords(siteId: siteId)
        let provisionalRecordIds = Set(tradeRecords.filter { $0.isProvisional }.map { $0.id.uuidString })

        do {
            _ = try db.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT
                            ROUND(ct.price_cents) as price_bucket,
                            ct.trade_record_id,
                            SUM(ct.volume_kwh) as volume,
                            COUNT(DISTINCT ct.counterparty_name) as buyer_count
                        FROM p2p_counterparty_trades ct
                        INNER JOIN p2p_trade_records tr ON ct.trade_record_id = tr.id
                        WHERE ct.site_id = ?
                        GROUP BY ROUND(ct.price_cents), ct.trade_record_id
                        ORDER BY price_bucket ASC
                        """,
                    arguments: [siteId]
                )
            }

            // Aggregate by price, separating actual vs provisional
            var demandByPrice: [Int: (actualVolume: Double, provisionalVolume: Double, actualBuyers: Set<String>, provisionalBuyers: Set<String>)] = [:]

            // Need to get buyer names per price per record type
            let allTrades = getP2PCounterpartyTrades(siteId: siteId)

            for trade in allTrades {
                let priceBucket = Int(round(trade.priceCents))
                let isProvisional = provisionalRecordIds.contains(trade.tradeRecordId.uuidString)

                var existing = demandByPrice[priceBucket] ?? (actualVolume: 0, provisionalVolume: 0, actualBuyers: Set(), provisionalBuyers: Set())

                if isProvisional {
                    existing.provisionalVolume += trade.volumeKwh
                    existing.provisionalBuyers.insert(trade.counterpartyName)
                } else {
                    existing.actualVolume += trade.volumeKwh
                    existing.actualBuyers.insert(trade.counterpartyName)
                }

                demandByPrice[priceBucket] = existing
            }

            // Convert to array sorted by price
            return demandByPrice.map { (price, data) in
                let actualRevenue = data.actualVolume * Double(price) / 100.0
                let provisionalRevenue = data.provisionalVolume * Double(price) / 100.0

                return P2PPriceDemand(
                    priceCents: Double(price),
                    actualVolumeKwh: data.actualVolume,
                    provisionalVolumeKwh: data.provisionalVolume,
                    actualRevenue: actualRevenue,
                    provisionalRevenue: provisionalRevenue,
                    actualBuyerCount: data.actualBuyers.count,
                    provisionalBuyerCount: data.provisionalBuyers.count
                )
            }.sorted { $0.priceCents < $1.priceCents }

        } catch {
            print("❌ getP2PMarketDemandByPrice failed: \(error)")
            return []
        }
    }

    // MARK: - iCloud KVS Sync
    
    /// Sync counterparty trades to iCloud KVS
    private func syncCounterpartyTradesToCloud(siteId: Int) {
        let trades = getP2PCounterpartyTrades(siteId: siteId)
        
        guard let data = P2PCounterpartyTrade.encodeForSync(trades) else {
            print("❌ Failed to encode counterparty trades for sync")
            return
        }
        
        let key = "\(kP2PCounterpartyTradesKey)_site\(siteId)"
        NSUbiquitousKeyValueStore.default.set(data, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
        
        print("☁️ Synced \(trades.count) counterparty trades to iCloud for site \(siteId)")
    }
    
    /// Pull counterparty trades from iCloud KVS and merge with local
    /// Only imports trades whose parent trade_record exists locally (prevents orphan restoration)
    @MainActor
    func syncCounterpartyTradesFromCloud(siteId: Int) {
        let key = "\(kP2PCounterpartyTradesKey)_site\(siteId)"

        NSUbiquitousKeyValueStore.default.synchronize()

        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: key) else {
            print("☁️ No counterparty trades in iCloud for site \(siteId)")
            return
        }

        guard let cloudTrades = P2PCounterpartyTrade.decodeFromSync(data) else {
            print("☁️ Failed to decode counterparty trades from iCloud")
            return
        }

        // Get local trade record IDs to verify parent exists
        let tradeRecords = getP2PTradeRecords(siteId: siteId)
        let validTradeRecordIds = Set(tradeRecords.map { $0.id })

        let localTrades = getP2PCounterpartyTrades(siteId: siteId)
        let localIds = Set(localTrades.map { $0.id })

        // Filter: only import trades that are new AND have a valid parent trade record
        let newTrades = cloudTrades.filter { trade in
            !localIds.contains(trade.id) && validTradeRecordIds.contains(trade.tradeRecordId)
        }

        // Count how many were filtered out as orphans
        let orphanedInCloud = cloudTrades.filter { trade in
            !localIds.contains(trade.id) && !validTradeRecordIds.contains(trade.tradeRecordId)
        }.count

        if orphanedInCloud > 0 {
            print("☁️ Skipped \(orphanedInCloud) orphaned trades from iCloud (parent trade record deleted)")
        }

        if newTrades.isEmpty {
            print("☁️ No new valid counterparty trades from iCloud")
            return
        }

        guard let db = dbQueue else { return }

        do {
            try db.write { db in
                for trade in newTrades {
                    try trade.insert(db)
                }
            }
            print("☁️ Merged \(newTrades.count) counterparty trades from iCloud")
        } catch {
            print("❌ Failed to merge counterparty trades from iCloud: \(error)")
        }
    }
    
    /// Register for iCloud KVS change notifications for counterparty trades
    func registerForCounterpartyCloudSync() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] notification in
            guard let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
                return
            }
            
            let counterpartyKeysChanged = changedKeys.filter { $0.hasPrefix(kP2PCounterpartyTradesKey) }
            if !counterpartyKeysChanged.isEmpty {
                print("☁️ Counterparty trades changed externally, syncing...")
                // Capture a weak reference to self outside of any @Sendable child tasks
                weak let weakSelf = self
                for key in counterpartyKeysChanged {
                    if let siteIdStr = key.components(separatedBy: "_site").last,
                       let siteId = Int(siteIdStr) {
                        let capturedSiteId = siteId
                        Task { @MainActor [weak weakSelf, capturedSiteId] in
                            guard let strongSelf = weakSelf else { return }
                            strongSelf.syncCounterpartyTradesFromCloud(siteId: capturedSiteId)
                        }
                    }
                }
            }
        }
        
        NSUbiquitousKeyValueStore.default.synchronize()
    }
    
    // MARK: - Maintenance

    /// Delete orphaned counterparty trades (where parent trade record no longer exists)
    @MainActor
    func cleanupOrphanedCounterpartyTrades(siteId: Int) -> Int {
        guard let db = dbQueue else { return 0 }

        do {
            let deletedCount = try db.write { db -> Int in
                // Find and delete counterparty trades whose parent trade record doesn't exist
                try db.execute(
                    sql: """
                        DELETE FROM p2p_counterparty_trades
                        WHERE site_id = ?
                        AND trade_record_id NOT IN (
                            SELECT id FROM p2p_trade_records WHERE site_id = ?
                        )
                        """,
                    arguments: [siteId, siteId]
                )
                return db.changesCount
            }

            if deletedCount > 0 {
                print("🧹 Cleaned up \(deletedCount) orphaned counterparty trades for site \(siteId)")
                syncCounterpartyTradesToCloud(siteId: siteId)
            }

            return deletedCount
        } catch {
            print("❌ Failed to cleanup orphaned counterparty trades: \(error)")
            return 0
        }
    }

    /// Clear counterparty trades for a site
    @MainActor
    func clearP2PCounterpartyTrades(siteId: Int) {
        guard let db = dbQueue else { return }

        do {
            try db.write { db in
                try db.execute(
                    sql: "DELETE FROM p2p_counterparty_trades WHERE site_id = ?",
                    arguments: [siteId]
                )
            }

            let key = "\(kP2PCounterpartyTradesKey)_site\(siteId)"
            NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
            NSUbiquitousKeyValueStore.default.synchronize()

            print("🗑️ Cleared counterparty trades for site \(siteId)")
        } catch {
            print("❌ Failed to clear counterparty trades: \(error)")
        }
    }

    /// Delete a specific counterparty by name (all their trades from both CSV and LV sources)
    @MainActor
    func deleteCounterparty(siteId: Int, name: String) -> Int {
        guard let db = dbQueue else { return 0 }

        do {
            var totalDeleted = 0

            try db.write { db in
                // Delete from CSV imports table
                try db.execute(
                    sql: "DELETE FROM p2p_counterparty_trades WHERE site_id = ? AND counterparty_name = ?",
                    arguments: [siteId, name]
                )
                totalDeleted += db.changesCount

                // Also delete from LV interval trades table if it exists
                if try db.tableExists("lv_interval_trades") {
                    try db.execute(
                        sql: "DELETE FROM lv_interval_trades WHERE site_id = ? AND counterparty_name = ?",
                        arguments: [siteId, name]
                    )
                    totalDeleted += db.changesCount
                }
            }

            if totalDeleted > 0 {
                print("🗑️ Deleted \(totalDeleted) trades for counterparty '\(name)'")
                syncCounterpartyTradesToCloud(siteId: siteId)
            }

            return totalDeleted
        } catch {
            print("❌ Failed to delete counterparty: \(error)")
            return 0
        }
    }
}

