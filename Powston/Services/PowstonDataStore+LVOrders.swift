//
//  PowstonDataStore+LVOrders.swift
//  Powston
//
//  GRDB persistence for LocalVolts orders/contracts
//

import Foundation
import GRDB

extension PowstonDataStore {

    // MARK: - Schema Creation

    func createLVOrdersSchema(_ db: Database) throws {
        guard try !db.tableExists("lv_orders") else {
            return
        }

        print("🔄 Migration: Creating lv_orders table")

        try db.create(table: "lv_orders") { t in
            t.column("id", .text).primaryKey()  // orderId from API
            t.column("site_id", .integer).notNull()
            t.column("customer_id", .text).notNull()
            t.column("direction", .text).notNull()
            t.column("nmi", .text)
            t.column("date_from", .datetime).notNull()
            t.column("date_to", .datetime).notNull()
            t.column("volume_kwh", .double).notNull()
            t.column("price_cents", .double)  // NULL for market orders
            t.column("trade_date", .datetime).notNull()
            t.column("status", .text)
            t.column("fetched_at", .datetime).notNull()
            t.column("start_hour", .integer)
            t.column("end_hour", .integer)
        }

        try db.create(
            index: "idx_lv_orders_site_direction",
            on: "lv_orders",
            columns: ["site_id", "direction"]
        )

        try db.create(
            index: "idx_lv_orders_dates",
            on: "lv_orders",
            columns: ["site_id", "date_from", "date_to"]
        )

        print("✅ Migration complete: lv_orders table created")
    }

    // MARK: - Save Operations

    /// Save LV orders, replacing existing by orderId
    func saveLVOrders(_ orders: [LVOrder]) throws {
        guard let db = dbQueue, !orders.isEmpty else { return }

        try db.write { db in
            for order in orders {
                // Use INSERT OR REPLACE since orderId is primary key
                try order.save(db)
            }
        }

        print("💾 Saved \(orders.count) LV orders")
    }

    /// Update order status from TradeDetail
    func updateLVOrderStatus(orderId: String, status: String) {
        guard let db = dbQueue else { return }

        do {
            try db.write { db in
                try db.execute(
                    sql: "UPDATE lv_orders SET status = ? WHERE id = ?",
                    arguments: [status, orderId]
                )
            }
        } catch {
            print("❌ updateLVOrderStatus failed: \(error)")
        }
    }

    // MARK: - Query Operations

    /// Get all orders for a site
    func getLVOrders(siteId: Int) -> [LVOrder] {
        guard let db = dbQueue else { return [] }

        do {
            return try db.read { db in
                try LVOrder.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM lv_orders
                        WHERE site_id = ?
                        ORDER BY date_from DESC
                        """,
                    arguments: [siteId]
                )
            }
        } catch {
            print("❌ getLVOrders failed: \(error)")
            return []
        }
    }

    /// Get orders by direction
    func getLVOrders(siteId: Int, direction: String) -> [LVOrder] {
        guard let db = dbQueue else { return [] }

        do {
            return try db.read { db in
                try LVOrder.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM lv_orders
                        WHERE site_id = ? AND direction = ?
                        ORDER BY date_from DESC
                        """,
                    arguments: [siteId, direction]
                )
            }
        } catch {
            print("❌ getLVOrders(direction) failed: \(error)")
            return []
        }
    }

    /// Get active orders (dateTo >= today, not cancelled)
    func getActiveLVOrders(siteId: Int, direction: String? = nil) -> [LVOrder] {
        guard let db = dbQueue else { return [] }

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        let today = calendar.startOfDay(for: Date())

        do {
            return try db.read { db in
                var sql = """
                    SELECT * FROM lv_orders
                    WHERE site_id = ?
                    AND date_to >= ?
                    AND (status IS NULL OR status != 'Cancelled')
                    """
                var args: [DatabaseValueConvertible] = [siteId, today]

                if let dir = direction {
                    sql += " AND direction = ?"
                    args.append(dir)
                }

                sql += " ORDER BY date_from ASC"

                return try LVOrder.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            print("❌ getActiveLVOrders failed: \(error)")
            return []
        }
    }

    /// Get order by ID
    func getLVOrder(orderId: String) -> LVOrder? {
        guard let db = dbQueue else { return nil }

        do {
            return try db.read { db in
                try LVOrder.fetchOne(
                    db,
                    sql: "SELECT * FROM lv_orders WHERE id = ?",
                    arguments: [orderId]
                )
            }
        } catch {
            print("❌ getLVOrder failed: \(error)")
            return nil
        }
    }

    /// Check if any orders exist for a site
    func hasLVOrders(siteId: Int) -> Bool {
        guard let db = dbQueue else { return false }

        do {
            return try db.read { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM lv_orders WHERE site_id = ?",
                    arguments: [siteId]
                )
                return (count ?? 0) > 0
            }
        } catch {
            print("❌ hasLVOrders failed: \(error)")
            return false
        }
    }

    /// Get orders overlapping a date range
    func getLVOrders(siteId: Int, from: Date, to: Date, direction: String? = nil) -> [LVOrder] {
        guard let db = dbQueue else { return [] }

        do {
            return try db.read { db in
                var sql = """
                    SELECT * FROM lv_orders
                    WHERE site_id = ?
                    AND date_from <= ?
                    AND date_to >= ?
                    """
                var args: [DatabaseValueConvertible] = [siteId, to, from]

                if let dir = direction {
                    sql += " AND direction = ?"
                    args.append(dir)
                }

                sql += " ORDER BY date_from ASC"

                return try LVOrder.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            print("❌ getLVOrders(range) failed: \(error)")
            return []
        }
    }

    // MARK: - Sync Metadata

    /// Get last LV orders sync time
    func getLastLVOrdersSyncTime(siteId: Int) -> Date? {
        guard let db = dbQueue else { return nil }

        return try? db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT last_sync_time FROM sync_metadata
                    WHERE entity_type = 'lv_orders' AND site_id = ?
                    """,
                arguments: [siteId]
            )
            return row?["last_sync_time"] as? Date
        }
    }

    /// Set last LV orders sync time
    func setLastLVOrdersSyncTime(siteId: Int, date: Date = Date()) {
        guard let db = dbQueue else { return }

        do {
            try db.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sync_metadata
                        (entity_type, site_id, inverter_id, last_sync_time, record_count)
                        VALUES ('lv_orders', ?, NULL, ?, 0)
                        ON CONFLICT(entity_type, site_id, inverter_id)
                        DO UPDATE SET last_sync_time = excluded.last_sync_time
                        """,
                    arguments: [siteId, date]
                )
            }
        } catch {
            print("❌ setLastLVOrdersSyncTime failed: \(error)")
        }
    }

    // MARK: - Cleanup

    /// Delete old/expired orders (older than 90 days past dateTo)
    func cleanupOldLVOrders(siteId: Int) -> Int {
        guard let db = dbQueue else { return 0 }

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        let cutoff = calendar.date(byAdding: .day, value: -90, to: Date()) ?? Date()

        do {
            return try db.write { db -> Int in
                try db.execute(
                    sql: """
                        DELETE FROM lv_orders
                        WHERE site_id = ? AND date_to < ?
                        """,
                    arguments: [siteId, cutoff]
                )
                return db.changesCount
            }
        } catch {
            print("❌ cleanupOldLVOrders failed: \(error)")
            return 0
        }
    }

    /// Clear all LV orders for a site
    func clearLVOrders(siteId: Int) {
        guard let db = dbQueue else { return }

        do {
            try db.write { db in
                try db.execute(
                    sql: "DELETE FROM lv_orders WHERE site_id = ?",
                    arguments: [siteId]
                )
            }
            print("🗑️ Cleared LV orders for site \(siteId)")
        } catch {
            print("❌ clearLVOrders failed: \(error)")
        }
    }

    // MARK: - Performance Tracking

    /// Get performance for an LV order by converting to P2PContract
    /// This allows using the existing performance tracking infrastructure
    @MainActor
    func getLVOrderPerformance(_ order: LVOrder) -> P2PContractPerformance {
        let contract = order.toP2PContract()
        return getP2PContractPerformance(contract)
    }

    /// Get performance for multiple LV orders
    @MainActor
    func getLVOrderPerformances(_ orders: [LVOrder]) -> [String: P2PContractPerformance] {
        var performances: [String: P2PContractPerformance] = [:]
        for order in orders {
            performances[order.id] = getLVOrderPerformance(order)
        }
        return performances
    }

    /// Get performance for an LV order group (multiple orders merged into one contract)
    /// The group is converted to a multi-tier P2PContract for performance tracking
    @MainActor
    func getLVOrderGroupPerformance(_ group: LVOrderGroup) -> P2PContractPerformance {
        let contract = group.toP2PContract()
        return getP2PContractPerformance(contract)
    }

    /// Get performance for multiple LV order groups
    @MainActor
    func getLVOrderGroupPerformances(_ groups: [LVOrderGroup]) -> [UUID: P2PContractPerformance] {
        var performances: [UUID: P2PContractPerformance] = [:]
        for group in groups {
            performances[group.id] = getLVOrderGroupPerformance(group)
        }
        return performances
    }
}
