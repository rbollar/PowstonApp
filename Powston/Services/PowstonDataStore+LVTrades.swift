//
//  PowstonDataStore+LVTrades.swift
//  Powston
//
//  GRDB persistence extension for LocalVolts interval trades
//

import Foundation
import GRDB

extension PowstonDataStore {

    // MARK: - Schema Creation (called from performMigrations)

    func createLVTradesSchema(_ db: Database) throws {
        guard try !db.tableExists("lv_interval_trades") else {
            return
        }

        print("🔄 Migration: Creating lv_interval_trades table")

        try db.create(table: "lv_interval_trades") { t in
            t.column("id", .text).primaryKey()
            t.column("site_id", .integer).notNull()
            t.column("period_start", .datetime).notNull()
            t.column("counterparty_name", .text).notNull()
            t.column("cp_facility", .text)
            t.column("cp_region", .text)
            t.column("direction", .text).notNull()
            t.column("volume_kwh", .double).notNull()
            t.column("sell_price_cents", .double)
            t.column("buy_price_cents", .double)
            t.column("category", .text)
            t.column("fetched_at", .datetime).notNull()
        }

        try db.create(
            index: "idx_lv_trades_site_period",
            on: "lv_interval_trades",
            columns: ["site_id", "period_start"]
        )

        try db.create(
            index: "idx_lv_trades_counterparty",
            on: "lv_interval_trades",
            columns: ["site_id", "counterparty_name"]
        )

        print("✅ Migration complete: lv_interval_trades table created")
    }

    // MARK: - Save Operations

    /// Save LV interval trades, replacing existing records for the same period
    /// Uses minute-level precision for deduplication to avoid floating-point issues
    func saveLVIntervalTrades(_ trades: [LVIntervalTrade]) throws {
        guard let db = dbQueue, !trades.isEmpty else { return }

        try db.write { db in
            for trade in trades {
                // Delete any existing trade for same site/period/counterparty/direction
                // Use strftime to round to minute precision to avoid floating-point timestamp issues
                try db.execute(
                    sql: """
                        DELETE FROM lv_interval_trades
                        WHERE site_id = ?
                        AND strftime('%Y-%m-%d %H:%M', period_start) = strftime('%Y-%m-%d %H:%M', ?)
                        AND counterparty_name = ?
                        AND direction = ?
                        """,
                    arguments: [
                        trade.siteId,
                        trade.periodStart,
                        trade.counterpartyName,
                        trade.direction.rawValue
                    ]
                )

                try trade.save(db)
            }
        }

        print("💾 Saved \(trades.count) LV interval trades")
    }

    /// Save LV interval trades in batch (more efficient for large imports)
    func saveLVIntervalTradesBatch(_ trades: [LVIntervalTrade], siteId: Int, from: Date, to: Date) throws {
        guard let db = dbQueue, !trades.isEmpty else { return }

        try db.write { db in
            // Delete existing trades in the date range first
            try db.execute(
                sql: """
                    DELETE FROM lv_interval_trades
                    WHERE site_id = ? AND period_start >= ? AND period_start <= ?
                    """,
                arguments: [siteId, from, to]
            )

            // Insert all new trades
            for trade in trades {
                try trade.save(db)
            }
        }

        print("💾 Batch saved \(trades.count) LV interval trades for \(formatDateRange(from: from, to: to))")
    }

    // MARK: - Query Operations

    /// Get LV interval trades for a site within a date range
    func getLVIntervalTrades(siteId: Int, from: Date, to: Date) -> [LVIntervalTrade] {
        guard let db = dbQueue else { return [] }

        do {
            return try db.read { db in
                try LVIntervalTrade.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM lv_interval_trades
                        WHERE site_id = ? AND period_start >= ? AND period_start <= ?
                        ORDER BY period_start ASC
                        """,
                    arguments: [siteId, from, to]
                )
            }
        } catch {
            print("❌ getLVIntervalTrades failed: \(error)")
            return []
        }
    }

    /// Get LV interval trades for a specific counterparty
    /// - Parameters:
    ///   - siteId: The site ID
    ///   - counterparty: Name of the counterparty
    ///   - from: Optional start date filter
    ///   - to: Optional end date filter
    ///   - includeContracts: If false, only shows actual executed trades (period_start <= now)
    func getLVIntervalTrades(siteId: Int, counterparty: String, from: Date? = nil, to: Date? = nil, includeContracts: Bool = false) -> [LVIntervalTrade] {
        guard let db = dbQueue else { return [] }

        do {
            return try db.read { db in
                var sql = """
                    SELECT * FROM lv_interval_trades
                    WHERE site_id = ? AND counterparty_name = ?
                    """
                var args: [DatabaseValueConvertible] = [siteId, counterparty]

                // Filter to only actual executed trades (not future contracts)
                if !includeContracts {
                    sql += " AND period_start <= datetime('now')"
                }

                if let from = from {
                    sql += " AND period_start >= ?"
                    args.append(from)
                }
                if let to = to {
                    sql += " AND period_start <= ?"
                    args.append(to)
                }

                sql += " ORDER BY period_start DESC"

                return try LVIntervalTrade.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            print("❌ getLVIntervalTrades for counterparty failed: \(error)")
            return []
        }
    }

    /// Get aggregated counterparty summary from LV trades
    func getLVCounterpartySummary(siteId: Int, from: Date, to: Date) -> [P2PCounterpartySummary] {
        let trades = getLVIntervalTrades(siteId: siteId, from: from, to: to)
        let lvSummaries = trades.summarizeByCounterparty()

        // Convert to P2PCounterpartySummary for compatibility with existing views
        return lvSummaries.map { summary in
            let lower = summary.counterpartyName.lowercased()
            let isCommercial = lower.contains("pty ltd") ||
                               lower.contains("pty. ltd") ||
                               lower.contains(" ltd") ||
                               lower.contains("holdings") ||
                               lower.contains("group") ||
                               lower.contains("services") ||
                               lower.contains("cafe") ||
                               lower.contains("restaurant")

            return P2PCounterpartySummary(
                counterpartyName: summary.counterpartyName,
                totalVolumeKwh: summary.totalVolumeKwh,
                totalRevenue: summary.totalRevenue,
                tradeCount: summary.tradeCount,
                avgPriceCents: summary.avgPriceCents,
                minPriceCents: summary.avgPriceCents,  // LV doesn't provide min/max
                maxPriceCents: summary.avgPriceCents,
                firstTradeDate: summary.firstTrade,
                lastTradeDate: summary.lastTrade,
                isCommercial: isCommercial
            )
        }
    }

    /// Get the date range of LV trades we have
    func getLVTradesDateRange(siteId: Int) -> (earliest: Date?, latest: Date?) {
        guard let db = dbQueue else { return (nil, nil) }

        do {
            return try db.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT MIN(period_start) as earliest, MAX(period_start) as latest
                        FROM lv_interval_trades
                        WHERE site_id = ?
                        """,
                    arguments: [siteId]
                )

                return (
                    row?["earliest"] as? Date,
                    row?["latest"] as? Date
                )
            }
        } catch {
            print("❌ getLVTradesDateRange failed: \(error)")
            return (nil, nil)
        }
    }

    /// Count LV trades for a site
    func countLVTrades(siteId: Int) -> Int {
        guard let db = dbQueue else { return 0 }

        return (try? db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM lv_interval_trades WHERE site_id = ?",
                arguments: [siteId]
            )
        }) ?? 0
    }

    /// Get unique counterparty names from LV trades
    func getLVCounterpartyNames(siteId: Int) -> [String] {
        guard let db = dbQueue else { return [] }

        do {
            return try db.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT counterparty_name
                        FROM lv_interval_trades
                        WHERE site_id = ?
                        ORDER BY counterparty_name
                        """,
                    arguments: [siteId]
                )
            }
        } catch {
            print("❌ getLVCounterpartyNames failed: \(error)")
            return []
        }
    }

    // MARK: - Sync Metadata

    /// Get last LV sync time for a site
    func getLastLVSyncTime(siteId: Int) -> Date? {
        guard let db = dbQueue else { return nil }

        return try? db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT last_sync_time FROM sync_metadata
                    WHERE entity_type = 'lv_trades' AND site_id = ?
                    """,
                arguments: [siteId]
            )
            return row?["last_sync_time"] as? Date
        }
    }

    /// Set last LV sync time for a site
    func setLastLVSyncTime(siteId: Int, date: Date = Date()) {
        guard let db = dbQueue else { return }

        do {
            try db.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sync_metadata
                        (entity_type, site_id, inverter_id, last_sync_time, record_count)
                        VALUES ('lv_trades', ?, NULL, ?, 0)
                        ON CONFLICT(entity_type, site_id, inverter_id)
                        DO UPDATE SET last_sync_time = excluded.last_sync_time
                        """,
                    arguments: [siteId, date]
                )
            }
        } catch {
            print("❌ setLastLVSyncTime failed: \(error)")
        }
    }

    // MARK: - Diagnostics

    /// Count actual trades and sum volume for a counterparty (for debugging)
    func getLVTradeStats(siteId: Int, counterparty: String) -> (count: Int, totalVolumeKwh: Double, duplicates: Int) {
        guard let db = dbQueue else { return (0, 0, 0) }

        do {
            return try db.read { db in
                // Get total count and volume
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) as count, COALESCE(SUM(volume_kwh), 0) as total_volume
                        FROM lv_interval_trades
                        WHERE site_id = ? AND counterparty_name = ?
                        """,
                    arguments: [siteId, counterparty]
                )

                let count = row?["count"] as? Int ?? 0
                let totalVolume = row?["total_volume"] as? Double ?? 0

                // Check for duplicates (same period_start, counterparty, direction)
                // Round to nearest minute to catch floating-point precision issues
                let dupCount = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) - COUNT(DISTINCT
                            site_id || '|' ||
                            strftime('%Y-%m-%d %H:%M', period_start) || '|' ||
                            counterparty_name || '|' ||
                            direction
                        ) as duplicates
                        FROM lv_interval_trades
                        WHERE site_id = ? AND counterparty_name = ?
                        """,
                    arguments: [siteId, counterparty]
                ) ?? 0

                return (count, totalVolume, dupCount)
            }
        } catch {
            print("❌ getLVTradeStats failed: \(error)")
            return (0, 0, 0)
        }
    }

    /// Remove duplicate LV trades (keeps one per period/counterparty/direction, rounded to minute)
    @discardableResult
    func deduplicateLVTrades(siteId: Int) -> Int {
        guard let db = dbQueue else { return 0 }

        do {
            return try db.write { db -> Int in  
                // Keep only the most recent record for each period/counterparty/direction combo
                // Group by period rounded to minute to handle floating-point timestamp differences
                _ = try db.execute(
                    sql: """
                        DELETE FROM lv_interval_trades
                        WHERE id NOT IN (
                            SELECT MIN(id) as keep_id
                            FROM lv_interval_trades
                            WHERE site_id = ?
                            GROUP BY
                                strftime('%Y-%m-%d %H:%M', period_start),
                                counterparty_name,
                                direction
                        )
                        AND site_id = ?
                        """,
                    arguments: [siteId, siteId]
                )
                let count = db.changesCount
                if count > 0 {
                    print("🧹 Removed \(count) duplicate LV trades for site \(siteId)")
                }
                return count
            }
        } catch {
            print("❌ deduplicateLVTrades failed: \(error)")
            return 0
        }
    }

    // MARK: - Cleanup

    /// Delete all LV trades for a site
    func clearLVTrades(siteId: Int) {
        guard let db = dbQueue else { return }

        do {
            try db.write { db in
                try db.execute(
                    sql: "DELETE FROM lv_interval_trades WHERE site_id = ?",
                    arguments: [siteId]
                )
            }
            print("🗑️ Cleared LV trades for site \(siteId)")
        } catch {
            print("❌ clearLVTrades failed: \(error)")
        }
    }

    /// Delete LV trades for a specific date
    func deleteLVTrades(siteId: Int, for date: Date) -> Int {
        guard let db = dbQueue else { return 0 }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = powstonTimezone()
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        do {
            return try db.write { db -> Int in
                try db.execute(
                    sql: """
                        DELETE FROM lv_interval_trades
                        WHERE site_id = ? AND period_start >= ? AND period_start < ?
                        """,
                    arguments: [siteId, dayStart, dayEnd]
                )
                let deleted = db.changesCount
                if deleted > 0 {
                    print("🗑️ Deleted \(deleted) LV trades for \(formatDateRange(from: dayStart, to: dayStart))")
                }
                return deleted
            }
        } catch {
            print("❌ deleteLVTrades failed: \(error)")
            return 0
        }
    }

    // MARK: - Helpers

    private func formatDateRange(from: Date, to: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.timeZone = powstonTimezone()
        return "\(formatter.string(from: from)) - \(formatter.string(from: to))"
    }
}
