//
//  PowstonDataStore.swift
//  Powston
//
//  Local SQLite persistence for historical data and analysis
//  Uses GRDB.swift for database operations
//
//  Architecture:
//  - Primary source for historical views (HistoryView, DecisionsView)
//  - Cache-through layer: reads from SQLite first, fetches from API only if missing
//  - Lazy sync: fetches data on-demand, not proactively
//  - Shared via App Group for Widget/Watch access
//

import Foundation
import GRDB
import SwiftUI
import Combine

// MARK: - Sync Progress

struct SyncProgress: Equatable, Sendable {
    let currentDay: Int
    let totalDays: Int
    let recordsFetched: Int
    let status: String
    
    var percentComplete: Double {
        guard totalDays > 0 else { return 0 }
        return Double(currentDay) / Double(totalDays)
    }
    
    var isComplete: Bool {
        currentDay >= totalDays
    }
    
    var displayText: String {
        if isComplete {
            return "Complete - \(recordsFetched.formatted()) records"
        }
        return "\(status) (\(currentDay)/\(totalDays))"
    }
}

// MARK: - Sync Result

struct SyncResult: Equatable, Sendable {
    let daysRequested: Int
    let daysFetched: Int
    let recordsFetched: Int
    let consecutiveFailuresAtEnd: Int
    let stoppedEarly: Bool
    let gapDates: [Date]  // Missing days between oldest success and newest
    
    var hasGaps: Bool { !gapDates.isEmpty }
    var sufficientData: Bool { daysFetched >= 60 }
    
    static let empty = SyncResult(
        daysRequested: 0,
        daysFetched: 0,
        recordsFetched: 0,
        consecutiveFailuresAtEnd: 0,
        stoppedEarly: false,
        gapDates: []
    )
}

// MARK: - Data Store
@MainActor
class PowstonDataStore: ObservableObject {
    
    // MARK: - Published State (must be accessed on MainActor)
    
    @MainActor @Published var isSyncing = false
    @MainActor @Published var syncProgress: SyncProgress?
    @MainActor @Published var lastSyncTime: Date?
    @MainActor @Published var totalRecordCount: Int = 0
    @MainActor @Published var error: String?
    
    // MARK: - Dependencies
    
    internal var dbQueue: DatabaseQueue?
    private weak var api: PowstonAPI?
    
    // MARK: - Configuration
    
    internal let finalizationDays: Int = 7  // Records older than this are immutable
    
    // MARK: - Refresh Tracking (in-memory, resets on app restart)
    private var lastDeltaFetch: [Int: Date] = [:]  // siteId → timestamp
    private let deltaThreshold: TimeInterval = 300  // 5 minutes
    
    // MARK: - Database Path (App Group Container)
    
    private static var databasePath: String {
        // Use App Group container for sharing with Widget/Watch
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            // Fallback to Application Support if App Group unavailable
            print("⚠️ App Group container not available, using Application Support")
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbFolder = appSupport.appendingPathComponent("Powston", isDirectory: true)
            try? FileManager.default.createDirectory(at: dbFolder, withIntermediateDirectories: true)
            return dbFolder.appendingPathComponent("powston_data.sqlite").path
        }
        
        let dbFolder = containerURL.appendingPathComponent("Database", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbFolder, withIntermediateDirectories: true)
        return dbFolder.appendingPathComponent("powston_data.sqlite").path
    }
    
    // MARK: - Shared Instance
    
    static let shared = PowstonDataStore()
    
    private init() {
        setupDatabase()
    }
    
    // MARK: - Setup
    
    @MainActor
    func configure(api: PowstonAPI) {
        self.api = api
    }
    
    private func setupDatabase() {
        do {
            var config = Configuration()
            config.readonly = false
            config.foreignKeysEnabled = true
            
            let path = Self.databasePath
            print("🗄️ Database path: \(path)")
            
            dbQueue = try DatabaseQueue(path: path, configuration: config)
            try createSchema()
            try performMigrations()
            
            // Update record count on main actor
            Task { @MainActor in
                self.updateRecordCount()
            }
            
            print("✅ PowstonDataStore initialized at: \(Self.databasePath)")
        } catch {
            Task { @MainActor in
                self.error = "Database setup failed: \(error.localizedDescription)"
            }
            print("❌ Database setup failed: \(error)")
        }
    }
    
    // MARK: - Schema Creation
    
    private func createSchema() throws {
        guard let db = dbQueue else { return }
        
        try db.write { db in
            // Action records table
            try db.create(table: "action_records", ifNotExists: true) { t in
                t.column("id", .integer).notNull()
                t.column("inverter_id", .integer).notNull()
                t.column("site_id", .integer).notNull()
                t.column("interval_time", .datetime).notNull()
                t.column("action", .text).notNull()
                t.column("buy_price", .double)
                t.column("sell_price", .double)
                t.column("energy_import", .double)
                t.column("energy_export", .double)
                t.column("earnings", .double)
                t.column("costs", .double)
                t.column("battery_soc", .double)
                t.column("pv_power", .double)
                t.column("grid_power", .double)
                t.column("battery_power", .double)
                t.column("house_power", .double)
                t.column("reason", .text)
                t.column("is_finalized", .boolean).defaults(to: false)
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("values_json", .text)
                t.uniqueKey(["id", "inverter_id"])
            }
            
            // Indexes for action_records
            try db.create(
                index: "idx_actions_site_time",
                on: "action_records",
                columns: ["site_id", "interval_time"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_actions_inverter_time",
                on: "action_records",
                columns: ["inverter_id", "interval_time"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_actions_action",
                on: "action_records",
                columns: ["action", "interval_time"],
                ifNotExists: true
            )
            
            // Day summaries table
            try db.create(table: "day_summaries", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("site_id", .integer).notNull()
                t.column("date", .text).notNull()
                t.column("expected_bill", .double)
                t.column("total_costs", .double)
                t.column("total_earnings", .double)
                t.column("rate_costs", .double)
                t.column("rate_earnings", .double)
                t.column("daily_costs", .double)
                t.column("energy_imported", .double)
                t.column("energy_exported", .double)
                t.column("battery_kwh", .double)
                t.column("buy_rate", .double)
                t.column("sell_rate", .double)
                t.column("record_count", .integer)
                t.column("is_finalized", .boolean).defaults(to: false)
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.uniqueKey(["site_id", "date"])
            }
            
            try db.create(
                index: "idx_summaries_site_date",
                on: "day_summaries",
                columns: ["site_id", "date"],
                ifNotExists: true
            )
            
            // Sync metadata table
            try db.create(table: "sync_metadata", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("entity_type", .text).notNull()
                t.column("site_id", .integer).notNull()
                t.column("inverter_id", .integer)
                t.column("last_sync_time", .datetime)
                t.column("last_record_time", .datetime)
                t.column("record_count", .integer).defaults(to: 0)
                t.uniqueKey(["entity_type", "site_id", "inverter_id"])
            }
            
            // Analysis cache table
            try db.create(table: "analysis_cache", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("site_id", .integer).notNull()
                t.column("analysis_type", .text).notNull()
                t.column("parameters_hash", .text).notNull()
                t.column("result_json", .text).notNull()
                t.column("computed_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("valid_until", .datetime)
                t.uniqueKey(["site_id", "analysis_type", "parameters_hash"])
            }
            
            // Meter records table
            try db.create(table: "meter_records", ifNotExists: true) { t in
                t.column("site_id", .integer).notNull()
                t.column("interval_time", .datetime).notNull()
                t.column("energy_import", .double)
                t.column("energy_export", .double)
                t.column("general_kwh", .double)
                t.column("feed_in_kwh", .double)
                t.column("start_battery_soc", .double)
                t.column("end_battery_soc", .double)
                t.column("ppv_generation", .double)
                t.column("house_consumption", .double)
                t.column("rrp", .double)
                t.column("earnings", .double)
                t.column("costs", .double)
                t.column("energy_costs", .double)
                t.column("fixed_costs", .double)
                t.column("is_finalized", .boolean).defaults(to: false)
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.primaryKey(["site_id", "interval_time"])
            }
            
            // Index for date-based queries on meter_records
            try db.create(
                index: "idx_meter_records_site_date",
                on: "meter_records",
                columns: ["site_id", "interval_time"],
                ifNotExists: true
            )
        }
    }
    
    // MARK: - Schema Migrations
    
    private func performMigrations() throws {
        guard let db = dbQueue else { return }
        
        try db.write { db in
            // Get existing columns
            let columns = try db.columns(in: "action_records")
            let columnNames = Set(columns.map { $0.name })
            
            // Migration 1: Add values_json column
            if !columnNames.contains("values_json") {
                print("🔄 Migration: Adding values_json column to action_records")
                try db.execute(sql: "ALTER TABLE action_records ADD COLUMN values_json TEXT")
                print("✅ Migration complete: values_json column added")
            }
            
            // Migration 2: Add earnings column
            if !columnNames.contains("earnings") {
                print("🔄 Migration: Adding earnings column to action_records")
                try db.execute(sql: "ALTER TABLE action_records ADD COLUMN earnings DOUBLE")
                print("✅ Migration complete: earnings column added")
            }
            
            // Migration 3: Add costs column
            if !columnNames.contains("costs") {
                print("🔄 Migration: Adding costs column to action_records")
                try db.execute(sql: "ALTER TABLE action_records ADD COLUMN costs DOUBLE")
                print("✅ Migration complete: costs column added")
            }
            
            // Migration 4: Add energy_costs/fixed_costs to meter_records
            if try db.tableExists("meter_records") {
                let meterColumns = try db.columns(in: "meter_records")
                let meterColumnNames = Set(meterColumns.map { $0.name })
                
                if !meterColumnNames.contains("energy_costs") {
                    print("🔄 Migration: Adding energy_costs column to meter_records")
                    try db.execute(sql: "ALTER TABLE meter_records ADD COLUMN energy_costs DOUBLE")
                    print("✅ Migration complete: energy_costs column added")
                }
                
                if !meterColumnNames.contains("fixed_costs") {
                    print("🔄 Migration: Adding fixed_costs column to meter_records")
                    try db.execute(sql: "ALTER TABLE meter_records ADD COLUMN fixed_costs DOUBLE")
                    print("✅ Migration complete: fixed_costs column added")
                }
            }
            
            // Migration 5: Create p2p_trade_records table
            if try !db.tableExists("p2p_trade_records") {
                print("🔄 Migration: Creating p2p_trade_records table")
                try db.create(table: "p2p_trade_records") { t in
                    t.column("id", .text).primaryKey()
                    t.column("site_id", .integer).notNull()
                    t.column("start_date", .datetime).notNull()
                    t.column("end_date", .datetime).notNull()
                    t.column("p2p_kwh", .double).notNull()
                    t.column("p2p_revenue", .double).notNull()
                    t.column("counterparty_count", .integer).notNull()
                    t.column("imported_at", .datetime).notNull()
                    t.column("source", .text).notNull()
                }
                
                try db.create(
                    index: "idx_p2p_trades_site_date",
                    on: "p2p_trade_records",
                    columns: ["site_id", "start_date", "end_date"]
                )
                print("✅ Migration complete: p2p_trade_records table created")
            }
            // Migration 6: Create p2p_contracts table
            try createP2PContractSchema(db)
            
            // Migration 7: Create p2p_counterparty_trades table
            try createP2PCounterpartySchema(db)

            // Migration 8: Add is_provisional column to p2p_trade_records
            if try db.tableExists("p2p_trade_records") {
                let columns = try db.columns(in: "p2p_trade_records").map { $0.name }
                if !columns.contains("is_provisional") {
                    print("🔄 Migration: Adding is_provisional column to p2p_trade_records")
                    try db.execute(sql: "ALTER TABLE p2p_trade_records ADD COLUMN is_provisional INTEGER DEFAULT 0")
                    print("✅ Migration complete: is_provisional column added")
                }
            }

            // Migration 9: Create p2p_counterparty_locations table
            try createLocationsTables(db)

            // Migration 10: Add direction column to p2p_contracts
            if try db.tableExists("p2p_contracts") {
                let columns = try db.columns(in: "p2p_contracts").map { $0.name }
                if !columns.contains("direction") {
                    print("🔄 Migration: Adding direction column to p2p_contracts")
                    try db.execute(sql: "ALTER TABLE p2p_contracts ADD COLUMN direction TEXT DEFAULT 'Sell'")
                    print("✅ Migration complete: direction column added")
                }
            }

            // Migration 11: Add direction column to p2p_trade_records and p2p_counterparty_trades
            if try db.tableExists("p2p_trade_records") {
                let columns = try db.columns(in: "p2p_trade_records").map { $0.name }
                if !columns.contains("direction") {
                    print("🔄 Migration: Adding direction column to p2p_trade_records")
                    try db.execute(sql: "ALTER TABLE p2p_trade_records ADD COLUMN direction TEXT DEFAULT 'Sell'")
                    print("✅ Migration complete: direction column added to p2p_trade_records")
                }
            }

            if try db.tableExists("p2p_counterparty_trades") {
                let columns = try db.columns(in: "p2p_counterparty_trades").map { $0.name }
                if !columns.contains("direction") {
                    print("🔄 Migration: Adding direction column to p2p_counterparty_trades")
                    try db.execute(sql: "ALTER TABLE p2p_counterparty_trades ADD COLUMN direction TEXT DEFAULT 'Sell'")
                    print("✅ Migration complete: direction column added to p2p_counterparty_trades")
                }
            }

            // Migration 12: Add last_data_date column to sync_metadata for tracking what data date we've synced to
            if try db.tableExists("sync_metadata") {
                let columns = try db.columns(in: "sync_metadata").map { $0.name }
                if !columns.contains("last_data_date") {
                    print("🔄 Migration: Adding last_data_date column to sync_metadata")
                    try db.execute(sql: "ALTER TABLE sync_metadata ADD COLUMN last_data_date DATETIME")
                    print("✅ Migration complete: last_data_date column added to sync_metadata")
                }
            }

            // Migration 13: Create lv_interval_trades table for LocalVolts WebSocket data
            try createLVTradesSchema(db)

            // Migration 14: Create lv_market_contracts table for LocalVolts ContractTable data
            try createLVMarketContractsSchema(db)

            // Migration 15: Create lv_orders table for LocalVolts TradeList orders/contracts
            try createLVOrdersSchema(db)

            // Migration 16: Create contract snapshot tables for subscription tracking
            try createContractSnapshotTables(in: db)

            // Migration 17: Create lv_daily_cashflow table for LV settlement data
            try createLVSettlementSchema(db)

            // Migration 18: Create lv_settlement_intervals table for per-interval settlement data
            try createLVSettlementIntervalsSchema(db)
        }
    }
    
    // MARK: - Delta Fetch (Smart Refresh)

    /// Get 2nd-to-last interval time so we re-fetch last 2 potentially incomplete records
    private func getSecondToLastIntervalTime(siteId: Int) -> Date? {
        guard let db = dbQueue else { return nil }
        
        return try? db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT interval_time FROM action_records 
                    WHERE site_id = ? 
                    ORDER BY interval_time DESC 
                    LIMIT 1 OFFSET 1
                    """,
                arguments: [siteId]
            )
            return row?["interval_time"] as? Date
        }
    }

    /// Delta fetch: get records from 2nd-to-last cached interval to now
    /// Fast path for view refresh - minimal API load
    @MainActor
    func fetchActionsDelta(
        siteId: Int,
        inverterIds: [Int]
    ) async -> [ActionRecord] {
        // Check if we fetched recently
        if let lastFetch = lastDeltaFetch[siteId],
           Date().timeIntervalSince(lastFetch) < deltaThreshold {
            let secondsAgo = Int(Date().timeIntervalSince(lastFetch))
            print("📦 Delta fetch skipped - last fetch \(secondsAgo)s ago")
            return fetchActionsLocal(siteId: siteId, date: Date())
        }
        
        guard let api = api else {
            return fetchActionsLocal(siteId: siteId, date: Date())
        }
        
        // Find 2nd-to-last interval time (re-fetch last 2 potentially incomplete records)
        let fetchFrom = getSecondToLastIntervalTime(siteId: siteId)
                        ?? Calendar.current.date(byAdding: .hour, value: -1, to: Date())!
        
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = powstonTimezone()
        print("🔄 Delta fetch from \(formatter.string(from: fetchFrom)) to now")
        
        // Fetch today's data for each inverter
        for inverterId in inverterIds {
            let actions = await api.fetchInverterActions(inverterId: inverterId, date: Date())
            
            if !actions.isEmpty {
                do {
                    try saveActions(actions, siteId: siteId)
                    print("💾 Delta saved \(actions.count) records for inverter \(inverterId)")
                } catch {
                    print("❌ Delta save failed: \(error)")
                }
            }
        }
        
        lastDeltaFetch[siteId] = Date()
        return fetchActionsLocal(siteId: siteId, date: Date())
    }

    /// Force reset of delta fetch throttle (e.g., after pull-to-refresh)
    @MainActor
    func resetDeltaThrottle(siteId: Int) {
        lastDeltaFetch.removeValue(forKey: siteId)
    }

    // MARK: - Background Sync

    /// Get last full sync date from sync_metadata
    func getLastFullSyncDate(siteId: Int) -> Date? {
        guard let db = dbQueue else { return nil }
        
        return try? db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT last_sync_time FROM sync_metadata 
                    WHERE entity_type = 'actions_full' AND site_id = ?
                    """,
                arguments: [siteId]
            )
            return row?["last_sync_time"] as? Date
        }
    }

    /// Set last full sync date
    private func setLastFullSyncDate(siteId: Int) {
        guard let db = dbQueue else { return }
        
        do {
            try db.write { db in
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO sync_metadata 
                        (entity_type, site_id, inverter_id, last_sync_time, record_count)
                        VALUES ('actions_full', ?, NULL, ?, 0)
                        """,
                    arguments: [siteId, Date()]
                )
            }
            print("📝 Updated last full sync date for site \(siteId)")
        } catch {
            print("❌ Failed to update sync date: \(error)")
        }
    }

    /// Check if background sync needed and queue it (non-blocking)
    /// Uses day_rates endpoint as a "canary" to detect when new finalized data is available
    @MainActor
    func scheduleBackgroundSyncIfNeeded(siteId: Int, inverterIds: [Int]) {
        // Only sync after 8am Brisbane time (when API has updated)
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let hour = calendar.component(.hour, from: Date())
        guard hour >= 8 else {
            print("📦 Background sync skipped - before 8am")
            return
        }

        guard !isSyncing else {
            print("📦 Background sync skipped - already syncing")
            return
        }

        // Quick check: if we synced within the last 30 minutes, skip the API check
        let lastSync = getLastFullSyncDate(siteId: siteId)
        if let lastSync = lastSync, Date().timeIntervalSince(lastSync) < 1800 {
            print("📦 Background sync skipped - synced recently")
            return
        }

        Task.detached(priority: .background) { [weak self] in
            await self?.performBackgroundSyncWithDataCheck(siteId: siteId, inverterIds: inverterIds)
        }
    }

    /// Check data availability and perform sync if new data exists
    @MainActor
    private func performBackgroundSyncWithDataCheck(siteId: Int, inverterIds: [Int]) async {
        guard let api = api else {
            print("📦 Background sync skipped - no API reference")
            return
        }

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        // Use day_rates as a reliable canary to check if yesterday's data is finalized
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let yesterdayFinalized = await api.isDayDataFinalized(date: yesterday)

        if !yesterdayFinalized {
            print("📦 Background sync skipped - yesterday's data not yet finalized")
            return
        }

        // Refresh latestCompleteDataDate to get the most recent available
        await api.refreshLatestCompleteDataDate()

        guard let latestAvailable = api.latestCompleteDataDate else {
            print("📦 Background sync skipped - could not determine latest data date")
            return
        }

        // Check if we have new data to sync
        let lastSyncedDate = getLastSyncedDataDate(siteId: siteId)
        let latestAvailableDay = calendar.startOfDay(for: latestAvailable)

        if let lastSynced = lastSyncedDate {
            let lastSyncedDay = calendar.startOfDay(for: lastSynced)
            if latestAvailableDay <= lastSyncedDay {
                print("📦 Background sync not needed - already synced up to \(formatDate(latestAvailable))")
                return
            }
        }

        print("🔄 New data available up to \(formatDate(latestAvailable)) - starting background sync")
        await performBackgroundSync(siteId: siteId, inverterIds: inverterIds)

        // Record what date we synced up to
        setLastSyncedDataDate(siteId: siteId, date: latestAvailable)
    }

    /// Get the last data date we successfully synced (not the sync timestamp)
    func getLastSyncedDataDate(siteId: Int) -> Date? {
        guard let db = dbQueue else { return nil }

        return try? db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT last_data_date FROM sync_metadata
                    WHERE entity_type = 'actions_full' AND site_id = ?
                    """,
                arguments: [siteId]
            )
            return row?["last_data_date"] as? Date
        }
    }

    /// Set the last data date we successfully synced (also updates sync time)
    private func setLastSyncedDataDate(siteId: Int, date: Date) {
        guard let db = dbQueue else { return }

        do {
            try db.write { db in
                // Use INSERT OR REPLACE to handle both new and existing records
                try db.execute(
                    sql: """
                        INSERT INTO sync_metadata
                        (entity_type, site_id, inverter_id, last_sync_time, record_count, last_data_date)
                        VALUES ('actions_full', ?, NULL, ?, 0, ?)
                        ON CONFLICT(entity_type, site_id, inverter_id)
                        DO UPDATE SET last_sync_time = excluded.last_sync_time, last_data_date = excluded.last_data_date
                        """,
                    arguments: [siteId, Date(), date]
                )
            }
            print("📝 Updated last synced data date to \(formatDate(date)) for site \(siteId)")
        } catch {
            print("❌ Failed to update last synced data date: \(error)")
        }
    }

    /// Perform background sync of last 7 days (non-blocking)
    /// Only runs after 8am Brisbane time, skips days already complete in cache
    @MainActor
    private func performBackgroundSync(siteId: Int, inverterIds: [Int]) async {
        // Only sync after 8am Brisbane time (when API has updated)
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let hour = calendar.component(.hour, from: Date())
        guard hour >= 8 else {
            print("📦 Background sync skipped - before 8am")
            return
        }
        
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -finalizationDays, to: endDate) else {
            return
        }
        
        // Find days that actually need syncing:
        // 1. Missing days (no data at all)
        // 2. Incomplete days (< 280 records) - but NOT today, which is expected to be incomplete
        let missingDays = findMissingDays(siteId: siteId, from: startDate, to: endDate)
        
        let incompleteDays = (1..<finalizationDays).compactMap { offset -> Date? in
            // Start from 1, not 0 - skip today (day 0) since it's naturally incomplete
            guard let day = calendar.date(byAdding: .day, value: -offset, to: endDate) else { return nil }
            let count = countActionsForDay(siteId: siteId, date: day)
            // Consider incomplete if < 280 records (allowing small gaps)
            // Full day = 288 records per inverter, but we store by site
            let expectedMinimum = 280 * inverterIds.count
            if count < expectedMinimum {
                print("📊 Day \(formatDate(day)) incomplete: \(count)/\(expectedMinimum) records")
                return day
            }
            return nil
        }
        
        let daysToSync = Array(Set(missingDays + incompleteDays)).sorted(by: >)

        guard let api = api, !daysToSync.isEmpty else {
            print("📦 Background sync: all days complete")
            return
        }

        print("🔄 Background sync: \(daysToSync.count) days need updating")

        _ = await syncDays(
            daysToSync,
            siteId: siteId,
            inverterIds: inverterIds,
            api: api,
            minimumDaysRequired: 1,
            timeout: 10,
            progressHandler: nil
        )

        print("✅ Background sync complete")
    }
    
    // MARK: - Backfill Missing Values JSON
    
    /// Check how many records are missing valuesJson
    func countRecordsMissingValuesJson(siteId: Int) -> Int {
        guard let db = dbQueue else { return 0 }
        
        return (try? db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM action_records WHERE site_id = ? AND values_json IS NULL",
                arguments: [siteId]
            )
        }) ?? 0
    }
    
    /// One-time backfill for records missing valuesJson
    /// Runs asynchronously in background, doesn't block UI
    /// Throttled to once per day to avoid repeated API calls if data unavailable
    func backfillMissingValuesJsonIfNeeded(siteId: Int, inverterIds: [Int]) {
        // Only attempt backfill once per day
        let key = "valuesJson_backfill_last_attempt_\(siteId)"
        if let lastAttempt = UserDefaults.standard.object(forKey: key) as? Date,
           Calendar.current.isDateInToday(lastAttempt) {
            print("📦 valuesJson backfill already attempted today")
            return
        }
        
        let missingCount = countRecordsMissingValuesJson(siteId: siteId)
        
        guard missingCount > 0 else {
            print("✅ All records have valuesJson")
            return
        }
        
        print("🔄 Starting async backfill: \(missingCount) records missing valuesJson")
        
        // Mark attempt immediately to prevent re-triggering
        UserDefaults.standard.set(Date(), forKey: key)
        
        Task.detached(priority: .utility) { [weak self] in
            await self?.performValuesJsonBackfill(siteId: siteId, inverterIds: inverterIds)
        }
    }
    
    /// Perform the actual backfill (runs on background thread)
    /// Perform the actual backfill (runs on background thread)
    private func performValuesJsonBackfill(siteId: Int, inverterIds: [Int]) async {
        guard let api = await MainActor.run(body: { self.api }),
              let db = dbQueue else { return }
        
        // Capture timezone on main actor
        let tz = await MainActor.run { powstonTimezone() }
        
        // Create formatter for this function
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"
        dateFormatter.timeZone = tz
        
        // Find dates with records missing valuesJson
        let datesNeedingBackfill: [Date] = await (try? db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT DATE(interval_time) as date_str
                    FROM action_records
                    WHERE site_id = ?
                    AND values_json IS NULL
                    ORDER BY interval_time DESC
                    """,
                arguments: [siteId]
            )
            
            let parseFormatter = DateFormatter()
            parseFormatter.dateFormat = "yyyy-MM-dd"
            parseFormatter.timeZone = tz
            
            return rows.compactMap { row -> Date? in
                guard let dateStr = row["date_str"] as? String else { return nil }
                return parseFormatter.date(from: dateStr)
            }
        }) ?? []
        
        guard !datesNeedingBackfill.isEmpty else { return }
        
        print("🔄 Backfill: \(datesNeedingBackfill.count) days need valuesJson")
        
        var recordsUpdated = 0
        var totalFetched = 0
        var totalWithValues = 0
        var consecutiveFailures = 0
        let maxFailures = 5
        
        for (index, date) in datesNeedingBackfill.enumerated() {
            if index % 10 == 0 {
                print("🔄 Backfill progress: \(index)/\(datesNeedingBackfill.count) days, \(recordsUpdated) records updated")
            }
            
            var daySuccess = false
            
            for inverterId in inverterIds {
                let actions = await api.fetchInverterActions(
                    inverterId: inverterId,
                    date: date,
                    timeout: 15
                )
                
                totalFetched += actions.count
                
                // Debug: check what we're getting
                let withValues = actions.filter { $0.valuesJSON != nil && !$0.valuesJSON!.isEmpty }
                let withNilValues = actions.filter { $0.valuesJSON == nil }
                let withEmptyValues = actions.filter { $0.valuesJSON != nil && $0.valuesJSON!.isEmpty }
                
                totalWithValues += withValues.count
                
                if index < 3 {  // Detailed logging for first 3 days
                    print("🔍 Backfill \(dateFormatter.string(from: date)) inv \(inverterId): \(actions.count) fetched, \(withValues.count) with values, \(withNilValues.count) nil, \(withEmptyValues.count) empty")
                    
                    // Sample one action to see the raw data
                    if let sample = actions.first {
                        print("🔍 Sample action valuesJSON: \(sample.valuesJSON ?? "nil")")
                    }
                }
                
                if !withValues.isEmpty {
                    do {
                        try saveActions(withValues, siteId: siteId)
                        recordsUpdated += withValues.count
                        daySuccess = true
                    } catch {
                        print("❌ Backfill save failed for \(dateFormatter.string(from: date)): \(error)")
                    }
                }
            }
            
            if daySuccess {
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                if consecutiveFailures >= maxFailures {
                    print("⚠️ Backfill stopping after \(maxFailures) consecutive days without valuesJson")
                    break
                }
            }
            
            // Small delay to avoid hammering API
            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
        }
        // At the end of performValuesJsonBackfill, add:
        let stillMissing = countRecordsMissingValuesJson(siteId: siteId)
        print("📊 Backfill complete: \(stillMissing) records STILL missing valuesJson")
        print("✅ Backfill complete: \(recordsUpdated) records updated")
        print("📊 Backfill stats: \(totalFetched) fetched, \(totalWithValues) had valuesJson (\(totalFetched > 0 ? Int(Double(totalWithValues) / Double(totalFetched) * 100) : 0)%)")
        
        // Invalidate analysis cache since we have new data
        invalidateAnalysisCache(siteId: siteId)
    }
    
    // MARK: - View Adapter Methods (Primary Interface for Views)
    
    /// Fetch actions for a single day with smart refresh strategy:
    /// - Finalized (>7 days): serve from cache
    /// - Today: delta fetch (last 2 intervals + new)
    /// - Recent (1-7 days): serve cache, background sync handles refresh
    @MainActor
    func fetchActionsForDay(
        siteId: Int,
        inverterId: Int,
        date: Date,
        forceRefresh: Bool = false
    ) async -> [ActionRecord] {
        guard let api = api else {
            return fetchActionsLocal(siteId: siteId, date: date)
        }
        
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(date)
        let dayAge = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        let isFinalized = dayAge > finalizationDays
        
        // Finalized data (>7 days): always serve from cache
        if isFinalized {
            let existing = fetchActionsLocal(siteId: siteId, date: date)
            if !existing.isEmpty {
                print("📦 Using \(existing.count) finalized records for \(formatDate(date))")
                return existing
            }
            // Cache empty for finalized day - fetch once
            print("🌐 Fetching finalized day \(formatDate(date)) - cache empty")
        }
        
        // Today: use delta fetch (re-fetches last 2 intervals + new)
        if isToday {
            let inverterIds = api.inverters.filter { $0.siteId == siteId }.map { $0.id }
            if !inverterIds.isEmpty {
                // Force refresh resets throttle
                if forceRefresh {
                    resetDeltaThrottle(siteId: siteId)
                }
                return await fetchActionsDelta(siteId: siteId, inverterIds: inverterIds)
            }
        }
        
        // Recent but not today (1-7 days): serve cache if available
        // Background sync will refresh these periodically
        let existing = fetchActionsLocal(siteId: siteId, date: date)
        if !existing.isEmpty && !forceRefresh {
            print("📦 Using \(existing.count) cached records for \(formatDate(date))")
            return existing
        }
        
        // Cache miss or force refresh: full day fetch
        print("🌐 Fetching from API for \(formatDate(date))")
        let actions = await api.fetchInverterActions(inverterId: inverterId, date: date)
        
        if !actions.isEmpty {
            do {
                try saveActions(actions, siteId: siteId)
                print("💾 Saved \(actions.count) records for \(formatDate(date))")
            } catch {
                print("❌ Failed to save actions: \(error)")
            }
        }
        
        return fetchActionsLocal(siteId: siteId, date: date)
    }
    
    /// Fetch SOC history for chart display - cache-first, single inverter
    /// Does NOT trigger delta fetch - uses cached data if available
    @MainActor
    func fetchSOCHistory(siteId: Int, inverterId: Int, date: Date) async -> [ActionSOCPoint] {
        // Query cache for this specific inverter (fast path)
        let cached = fetchActionsForInverter(siteId: siteId, inverterId: inverterId, date: date)
        
        if !cached.isEmpty {
            print("📊 Chart using \(cached.count) cached records for inverter \(inverterId)")
            return cached.compactMap { record -> ActionSOCPoint? in
                guard record.batterySoc != nil else { return nil }
                return ActionSOCPoint(from: record)
            }
        }
        
        // Cache empty - fetch from API (single inverter only, no delta)
        guard let api = api else { return [] }
        
        print("📊 Chart cache miss - fetching inverter \(inverterId) from API")
        let actions = await api.fetchInverterActions(inverterId: inverterId, date: date)
        if !actions.isEmpty {
            try? saveActions(actions, siteId: siteId)
        }
        
        let records = fetchActionsForInverter(siteId: siteId, inverterId: inverterId, date: date)
        return records.compactMap { record -> ActionSOCPoint? in
            guard record.batterySoc != nil else { return nil }
            return ActionSOCPoint(from: record)
        }
    }

    /// Fetch SOC history for last 24 hours (rolling window, not midnight-to-midnight)
    @MainActor
    func fetchSOCHistoryLast24Hours(siteId: Int, inverterId: Int) async -> [ActionSOCPoint] {
        let now = Date()
        let twentyFourHoursAgo = now.addingTimeInterval(-24 * 60 * 60)

        // Query cache for rolling 24h window
        let cached = fetchActionsForInverter(siteId: siteId, inverterId: inverterId, from: twentyFourHoursAgo, to: now)

        if !cached.isEmpty {
            print("📊 Chart using \(cached.count) cached records for last 24h")
            return cached.compactMap { record -> ActionSOCPoint? in
                guard record.batterySoc != nil else { return nil }
                return ActionSOCPoint(from: record)
            }
        }

        // Cache empty or insufficient - fetch today and yesterday from API
        guard let api = api else { return [] }

        let calendar = Calendar.current
        let today = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        print("📊 Chart cache miss - fetching last 24h from API")

        // Fetch both days in parallel
        async let todayActions = api.fetchInverterActions(inverterId: inverterId, date: today)
        async let yesterdayActions = api.fetchInverterActions(inverterId: inverterId, date: yesterday)

        let allActions = await todayActions + yesterdayActions
        if !allActions.isEmpty {
            try? saveActions(allActions, siteId: siteId)
        }

        // Query again with the date range
        let records = fetchActionsForInverter(siteId: siteId, inverterId: inverterId, from: twentyFourHoursAgo, to: now)
        return records.compactMap { record -> ActionSOCPoint? in
            guard record.batterySoc != nil else { return nil }
            return ActionSOCPoint(from: record)
        }
    }

    /// Fetch actions for a specific inverter from cache (private helper)
    private func fetchActionsForInverter(siteId: Int, inverterId: Int, date: Date) -> [ActionRecord] {
        guard dbQueue != nil else { return [] }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!.addingTimeInterval(-1)

        return fetchActionsForInverter(siteId: siteId, inverterId: inverterId, from: startOfDay, to: endOfDay)
    }

    /// Fetch actions for a specific inverter within a date range (private helper)
    private func fetchActionsForInverter(siteId: Int, inverterId: Int, from startDate: Date, to endDate: Date) -> [ActionRecord] {
        guard let db = dbQueue else { return [] }

        do {
            return try db.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, inverter_id, site_id, interval_time, action,
                               buy_price, sell_price, energy_import, energy_export,
                               earnings, costs,
                               battery_soc, pv_power, grid_power, battery_power, house_power,
                               reason, is_finalized, created_at, values_json
                        FROM action_records
                        WHERE site_id = ? AND inverter_id = ? AND interval_time >= ? AND interval_time <= ?
                        ORDER BY interval_time ASC
                        """,
                    arguments: [siteId, inverterId, startDate, endDate]
                )
                
                return rows.map { row in
                    ActionRecord(
                        id: row["id"],
                        inverterId: row["inverter_id"],
                        siteId: row["site_id"],
                        intervalTime: row["interval_time"],
                        action: row["action"],
                        buyPrice: row["buy_price"],
                        sellPrice: row["sell_price"],
                        energyImport: row["energy_import"],
                        energyExport: row["energy_export"],
                        earnings: row["earnings"],
                        costs: row["costs"],
                        batterySoc: row["battery_soc"],
                        pvPower: row["pv_power"],
                        gridPower: row["grid_power"],
                        batteryPower: row["battery_power"],
                        housePower: row["house_power"],
                        reason: row["reason"],
                        isFinalized: row["is_finalized"] ?? false,
                        createdAt: row["created_at"] ?? Date(),
                        valuesJson: row["values_json"]
                    )
                }
            }
        } catch {
            print("❌ fetchActionsForInverter failed: \(error)")
            return []
        }
    }
    
    /// Fetch actions for a date range, syncing missing days from API
    /// Use this from HistoryView for multi-day views
    @MainActor
    func fetchActionsForRange(
        siteId: Int,
        inverterIds: [Int],
        from startDate: Date,
        to endDate: Date,
        progressHandler: ((SyncProgress) -> Void)? = nil
    ) async -> [ActionRecord] {
        guard let api = api else {
            return fetchActions(siteId: siteId, from: startDate, to: endDate)
        }
        
        // Find missing days
        let missingDays = findMissingDays(siteId: siteId, from: startDate, to: endDate)
        
        if missingDays.isEmpty {
            print("📦 All data available locally for range")
            return fetchActions(siteId: siteId, from: startDate, to: endDate)
        }
        
        print("🌐 Need to fetch \(missingDays.count) missing days")
        
        // Sync missing days
        await syncDays(
            missingDays,
            siteId: siteId,
            inverterIds: inverterIds,
            api: api,
            progressHandler: progressHandler
        )
        
        // Return complete data
        return fetchActions(siteId: siteId, from: startDate, to: endDate)
    }
    
    /// Check if data exists for a date range (for UI indicators)
    func hasDataForRange(siteId: Int, from startDate: Date, to endDate: Date) -> Bool {
        let missingDays = findMissingDays(siteId: siteId, from: startDate, to: endDate)
        return missingDays.isEmpty
    }
    
    /// Get count of missing days for a range (for progress estimation)
    func missingDayCount(siteId: Int, from startDate: Date, to endDate: Date) -> Int {
        return findMissingDays(siteId: siteId, from: startDate, to: endDate).count
    }

    /// Count total records in a date range
    func countRecords(siteId: Int, from startDate: Date, to endDate: Date) -> Int {
        guard let db = dbQueue else { return 0 }

        return (try? db.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM action_records
                    WHERE site_id = ?
                    AND interval_time >= ?
                    AND interval_time <= ?
                    """,
                arguments: [siteId, startDate, endDate]
            )
        }) ?? 0
    }

    // MARK: - Gap Detection

    /// Find days within a range that have no local data
    func findMissingDays(siteId: Int, from startDate: Date, to endDate: Date) -> [Date] {
        guard let db = dbQueue else { return [] }
        
        let calendar = Calendar.current
        var missingDays: [Date] = []
        
        // Get all dates that have data
        let datesWithData: Set<String> = (try? db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT DATE(interval_time) as date_str
                    FROM action_records
                    WHERE site_id = ?
                    AND interval_time >= ?
                    AND interval_time <= ?
                    """,
                arguments: [siteId, startDate, endDate]
            )
            return Set(rows.compactMap { $0["date_str"] as? String })
        }) ?? []
        
        // Check each day in range
        var currentDate = calendar.startOfDay(for: startDate)
        let endDateNormalized = calendar.startOfDay(for: endDate)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        
        while currentDate <= endDateNormalized {
            let dateStr = dateFormatter.string(from: currentDate)
            
            // Missing if no data and not a future date
            if !datesWithData.contains(dateStr) && currentDate < Date() {
                missingDays.append(currentDate)
            }
            
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        return missingDays
    }
    
    /// Count action records for a specific day
    func countActionsForDay(siteId: Int, date: Date) -> Int {
        guard let db = dbQueue else { return 0 }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        do {
            return try db.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM action_records
                        WHERE site_id = ? AND interval_time >= ? AND interval_time < ?
                        """,
                    arguments: [siteId, startOfDay, endOfDay]
                ) ?? 0
            }
        } catch {
            print("❌ countActionsForDay failed: \(error)")
            return 0
        }
    }
    
    // MARK: - Sync Operations
    
    /// Sync specific days from API (newest-first with graceful failure handling)
    @MainActor
    @discardableResult
    private func syncDays(
        _ days: [Date],
        siteId: Int,
        inverterIds: [Int],
        api: PowstonAPI,
        minimumDaysRequired: Int = 60,
        timeout: TimeInterval = 12,
        progressHandler: ((SyncProgress) -> Void)?
    ) async -> SyncResult {
        isSyncing = true
        
        // Sort newest-first so we get recent data before potentially failing on old data
        let sortedDays = days.sorted(by: >)
        
        let totalDays = sortedDays.count
        var recordsFetched = 0
        var daysFetched = 0
        var consecutiveFailures = 0
        var failedDates: [Date] = []
        var stoppedEarly = false
        let maxConsecutiveFailures = 3
        
        for (index, date) in sortedDays.enumerated() {
            let progress = SyncProgress(
                currentDay: index + 1,
                totalDays: totalDays,
                recordsFetched: recordsFetched,
                status: "Fetching \(formatDate(date))..."
            )
            syncProgress = progress
            progressHandler?(progress)
            
            var daySuccess = false
            var dayRecords = 0
            
            for inverterId in inverterIds {
                let actions = await api.fetchInverterActions(
                    inverterId: inverterId,
                    date: date,
                    timeout: timeout
                )
                
                if !actions.isEmpty {
                    do {
                        try saveActions(actions, siteId: siteId)
                        dayRecords += actions.count
                        daySuccess = true
                    } catch {
                        print("❌ Failed to save actions for \(formatDate(date)): \(error)")
                    }
                }
            }
            
            if daySuccess {
                recordsFetched += dayRecords
                daysFetched += 1
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                failedDates.append(date)
                print("⚠️ Day \(formatDate(date)) failed (consecutive: \(consecutiveFailures))")
            }
            
            // Check stop conditions
            if consecutiveFailures >= maxConsecutiveFailures {
                // Check if we have enough data to proceed
                let totalDaysAvailable = countUniqueDays(siteId: siteId)
                
                if totalDaysAvailable >= minimumDaysRequired {
                    print("⏹️ Stopping after \(consecutiveFailures) consecutive failures - have \(totalDaysAvailable) days (≥\(minimumDaysRequired) required)")
                    stoppedEarly = true
                    break
                } else {
                    print("⚠️ \(consecutiveFailures) consecutive failures but only \(totalDaysAvailable) days available, continuing...")
                    // Reset counter to try a few more
                    consecutiveFailures = 1
                }
            }
            
            // Yield to prevent UI blocking
            await Task.yield()
        }
        
        // Finalize old records
        finalizeOldRecords(siteId: siteId)
        
        // Update counts
        updateRecordCount()
        lastSyncTime = Date()
        
        // Detect gaps: failed dates that are BETWEEN successful fetches (not at the old end)
        let gapDates = detectGaps(failedDates: failedDates, siteId: siteId)
        
        let finalProgress = SyncProgress(
            currentDay: totalDays,
            totalDays: totalDays,
            recordsFetched: recordsFetched,
            status: stoppedEarly ? "Partial sync complete" : "Complete"
        )
        syncProgress = finalProgress
        progressHandler?(finalProgress)
        
        print("✅ Synced \(daysFetched)/\(totalDays) days, \(recordsFetched) records, gaps: \(gapDates.count)")
        
        isSyncing = false
        
        return SyncResult(
            daysRequested: totalDays,
            daysFetched: daysFetched,
            recordsFetched: recordsFetched,
            consecutiveFailuresAtEnd: stoppedEarly ? consecutiveFailures : 0,
            stoppedEarly: stoppedEarly,
            gapDates: gapDates
        )
    }

    /// Count unique days with data for a site
    func countUniqueDays(siteId: Int) -> Int {
        guard let db = dbQueue else { return 0 }
        
        return (try? db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(DISTINCT DATE(interval_time)) FROM action_records WHERE site_id = ?",
                arguments: [siteId]
            )
        }) ?? 0
    }

    /// Detect gaps: failed dates that fall between our oldest and newest successful data
    private func detectGaps(failedDates: [Date], siteId: Int) -> [Date] {
        guard !failedDates.isEmpty else { return [] }
        
        let range = getDataRange(siteId: siteId)
        guard let earliest = range.earliest, let latest = range.latest else {
            return [] // No data at all, so no "gaps"
        }
        
        let calendar = Calendar.current
        let earliestDay = calendar.startOfDay(for: earliest)
        let latestDay = calendar.startOfDay(for: latest)
        
        // A gap is a failed date that's between our data range (not older than our oldest data)
        return failedDates.filter { failedDate in
            let failedDay = calendar.startOfDay(for: failedDate)
            return failedDay > earliestDay && failedDay < latestDay
        }.sorted(by: >)
    }
    
    /// Full sync for analysis preparation
    /// Call this before running analysis to ensure we have enough data
    /// Returns SyncResult with information about what was fetched and any gaps
    @MainActor
    func prepareForAnalysis(
        config: AnalysisConfig,
        inverterIds: [Int],
        progressHandler: @escaping (SyncProgress) -> Void
    ) async -> SyncResult {
        guard let api = api else {
            progressHandler(SyncProgress(currentDay: 0, totalDays: 0, recordsFetched: 0, status: "No API configured"))
            return .empty
        }
        
        let calendar = Calendar.current
        let endDate = calendar.date(byAdding: .day, value: -1, to: Date())!
        let startDate = calendar.date(byAdding: .day, value: -config.analysisWindowDays, to: endDate)!
        
        // Find gaps
        let missingDays = findMissingDays(siteId: config.siteId, from: startDate, to: endDate)
        
        if missingDays.isEmpty {
            let existingDays = countUniqueDays(siteId: config.siteId)
            progressHandler(SyncProgress(
                currentDay: 1,
                totalDays: 1,
                recordsFetched: 0,
                status: "Data ready - \(existingDays) days available"
            ))
            return SyncResult(
                daysRequested: 0,
                daysFetched: 0,
                recordsFetched: 0,
                consecutiveFailuresAtEnd: 0,
                stoppedEarly: false,
                gapDates: []
            )
        }
        
        print("📊 Analysis prep: need to fetch \(missingDays.count) of \(config.analysisWindowDays) days")
        
        let result = await syncDays(
            missingDays,
            siteId: config.siteId,
            inverterIds: inverterIds,
            api: api,
            minimumDaysRequired: config.analysisWindowDays,
            timeout: 12,  // Shorter timeout for bulk historical fetches
            progressHandler: progressHandler
        )
        
        // Invalidate stale analysis cache since we have new data
        if result.recordsFetched > 0 {
            invalidateAnalysisCache(siteId: config.siteId)
        }
        
        return result
    }
    
    // MARK: - Save Operations
    
    private func saveActions(_ actions: [InverterAction], siteId: Int) throws {
        guard let db = dbQueue else {
            print("❌ saveActions: dbQueue is nil")
            return
        }
        
        print("💾 saveActions: attempting to save \(actions.count) actions for site \(siteId)")
        
        do {
            try db.write { db in
                for action in actions {
                    let record = ActionRecord(from: action, siteId: siteId)
                    
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO action_records (
                                id, inverter_id, site_id, interval_time, action,
                                buy_price, sell_price, energy_import, energy_export,
                                earnings, costs,
                                battery_soc, pv_power, grid_power, battery_power, house_power,
                                reason, is_finalized, created_at, values_json
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            record.id,
                            record.inverterId,
                            record.siteId,
                            record.intervalTime,
                            record.action,
                            record.buyPrice,
                            record.sellPrice,
                            record.energyImport,
                            record.energyExport,
                            record.earnings,
                            record.costs,
                            record.batterySoc,
                            record.pvPower,
                            record.gridPower,
                            record.batteryPower,
                            record.housePower,
                            record.reason,
                            record.isFinalized,
                            record.createdAt,
                            record.valuesJson
                        ]
                    )
                }
            }
            print("✅ saveActions: saved \(actions.count) records")
            
            // Verify immediately
            let verifyCount = try? db.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM action_records WHERE site_id = ?", arguments: [siteId])
            }
            print("🔍 Verify after save: \(verifyCount ?? -1) records for site \(siteId)")
            
        } catch {
            print("❌ saveActions failed: \(error)")
            throw error
        }
    }
    
    func saveDaySummary(_ summary: DayRateSummary, date: String) throws {
        guard let db = dbQueue else { return }
        
        try db.write { db in
            let record = DaySummaryRecord(from: summary, date: date)
            try record.save(db, onConflict: .replace)
        }
    }
    
    // MARK: - Finalization
    
    private func finalizeOldRecords(siteId: Int) {
        guard let db = dbQueue else { return }
        
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -finalizationDays, to: Date()) ?? Date()
        
        do {
            try db.write { db in
                try db.execute(
                    sql: """
                        UPDATE action_records 
                        SET is_finalized = 1 
                        WHERE site_id = ? AND interval_time < ? AND is_finalized = 0
                        """,
                    arguments: [siteId, cutoffDate]
                )
            }
        } catch {
            print("❌ Finalization failed: \(error)")
        }
    }
    
    // MARK: - Record Count
    
    @MainActor
    private func updateRecordCount() {
        guard let db = dbQueue else { return }
        
        totalRecordCount = (try? db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM action_records")
        }) ?? 0
    }
    
    // MARK: - Local Query Operations
    
    /// Fetch actions for a single day from local database only
    private func fetchActionsLocal(siteId: Int, date: Date) -> [ActionRecord] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!.addingTimeInterval(-1)
        return fetchActions(siteId: siteId, from: startOfDay, to: endOfDay)
    }
    
    /// Fetch action records for a site within a date range (local only)
    func fetchActions(
        siteId: Int,
        from startDate: Date,
        to endDate: Date,
        action: String? = nil
    ) -> [ActionRecord] {
        guard let db = dbQueue else { return [] }
        
        do {
            return try db.read { db in
                var sql = """
                    SELECT id, inverter_id, site_id, interval_time, action,
                           buy_price, sell_price, energy_import, energy_export,
                           earnings, costs,
                           battery_soc, pv_power, grid_power, battery_power, house_power,
                           reason, is_finalized, created_at, values_json
                    FROM action_records
                    WHERE site_id = ? AND interval_time >= ? AND interval_time <= ?
                    """
                var arguments: [DatabaseValueConvertible] = [siteId, startDate, endDate]
                
                if let action = action {
                    sql += " AND action LIKE ?"
                    arguments.append("%\(action)%")
                }
                
                sql += " ORDER BY interval_time ASC"
                
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                
                return rows.map { row in
                    ActionRecord(
                        id: row["id"],
                        inverterId: row["inverter_id"],
                        siteId: row["site_id"],
                        intervalTime: row["interval_time"],
                        action: row["action"],
                        buyPrice: row["buy_price"],
                        sellPrice: row["sell_price"],
                        energyImport: row["energy_import"],
                        energyExport: row["energy_export"],
                        earnings: row["earnings"],
                        costs: row["costs"],
                        batterySoc: row["battery_soc"],
                        pvPower: row["pv_power"],
                        gridPower: row["grid_power"],
                        batteryPower: row["battery_power"],
                        housePower: row["house_power"],
                        reason: row["reason"],
                        isFinalized: row["is_finalized"] ?? false,
                        createdAt: row["created_at"] ?? Date(),
                        valuesJson: row["values_json"]
                    )
                }
            }
        } catch {
            print("❌ Query failed: \(error)")
            return []
        }
    }
    
    /// Fetch export records for analysis (local only)
    func fetchExports(siteId: Int, from startDate: Date, to endDate: Date) -> [ActionRecord] {
        guard let db = dbQueue else { return [] }
        
        do {
            return try db.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, inverter_id, site_id, interval_time, action,
                               buy_price, sell_price, energy_import, energy_export,
                               earnings, costs,
                               battery_soc, pv_power, grid_power, battery_power, house_power,
                               reason, is_finalized, created_at, values_json
                        FROM action_records
                        WHERE site_id = ? 
                        AND interval_time >= ? 
                        AND interval_time <= ?
                        AND action LIKE '%export%'
                        AND energy_export > 0.1
                        ORDER BY interval_time ASC
                        """,
                    arguments: [siteId, startDate, endDate]
                )
                
                return rows.map { row in
                    ActionRecord(
                        id: row["id"],
                        inverterId: row["inverter_id"],
                        siteId: row["site_id"],
                        intervalTime: row["interval_time"],
                        action: row["action"],
                        buyPrice: row["buy_price"],
                        sellPrice: row["sell_price"],
                        energyImport: row["energy_import"],
                        energyExport: row["energy_export"],
                        earnings: row["earnings"],
                        costs: row["costs"],
                        batterySoc: row["battery_soc"],
                        pvPower: row["pv_power"],
                        gridPower: row["grid_power"],
                        batteryPower: row["battery_power"],
                        housePower: row["house_power"],
                        reason: row["reason"],
                        isFinalized: row["is_finalized"] ?? false,
                        createdAt: row["created_at"] ?? Date(),
                        valuesJson: row["values_json"]
                    )
                }
            }
        } catch {
            print("❌ Export query failed: \(error)")
            return []
        }
    }
    
    /// Fetch records for peak hours only
    func fetchPeakExports(
        siteId: Int,
        from startDate: Date,
        to endDate: Date,
        peakStartHour: Int,
        peakEndHour: Int,
        timezone: TimeZone
    ) -> [ActionRecord] {
        let allExports = fetchExports(siteId: siteId, from: startDate, to: endDate)
        
        var calendar = Calendar.current
        calendar.timeZone = timezone
        
        return allExports.filter { record in
            let hour = calendar.component(.hour, from: record.intervalTime)
            return hour >= peakStartHour && hour < peakEndHour
        }
    }
    
    /// Get data availability info for a site
    func getDataRange(siteId: Int) -> (earliest: Date?, latest: Date?, count: Int) {
        guard let db = dbQueue else {
            print("⚠️ getDataRange: dbQueue is nil")
            return (nil, nil, 0)
        }
        
        do {
            return try db.read { db in
                // Get count directly
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM action_records WHERE site_id = ?",
                    arguments: [siteId]
                ) ?? 0
                
                // Get date range
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT MIN(interval_time) as earliest, MAX(interval_time) as latest
                        FROM action_records
                        WHERE site_id = ?
                        """,
                    arguments: [siteId]
                )
                
                let earliest = row?["earliest"] as? Date
                let latest = row?["latest"] as? Date
                
                print("📊 getDataRange(site \(siteId)): count=\(count), earliest=\(earliest?.description ?? "nil"), latest=\(latest?.description ?? "nil")")
                
                return (earliest, latest, count)
            }
        } catch {
            print("❌ getDataRange failed: \(error)")
            return (nil, nil, 0)
        }
    }
    
    /// Get record count per day for a date range (for UI indicators)
    func getRecordCountsByDay(siteId: Int, from startDate: Date, to endDate: Date) -> [String: Int] {
        guard let db = dbQueue else { return [:] }
        
        do {
            return try db.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT DATE(interval_time) as date_str, COUNT(*) as count
                        FROM action_records
                        WHERE site_id = ?
                        AND interval_time >= ?
                        AND interval_time <= ?
                        GROUP BY DATE(interval_time)
                        """,
                    arguments: [siteId, startDate, endDate]
                )
                
                var result: [String: Int] = [:]
                for row in rows {
                    if let dateStr = row["date_str"] as? String,
                       let count = row["count"] as? Int {
                        result[dateStr] = count
                    }
                }
                return result
            }
        } catch {
            return [:]
        }
    }
    
    // MARK: - Analysis Cache
    
    func getCachedAnalysis<T: Codable>(siteId: Int, type: String, hash: String) -> T? {
        guard let db = dbQueue else { return nil }
        
        do {
            return try db.read { db in
                guard let entry = try AnalysisCacheEntry.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM analysis_cache
                        WHERE site_id = ? AND analysis_type = ? AND parameters_hash = ?
                        """,
                    arguments: [siteId, type, hash]
                ), entry.isValid else {
                    return nil
                }
                
                guard let data = entry.resultJson.data(using: .utf8) else { return nil }
                return try JSONDecoder().decode(T.self, from: data)
            }
        } catch {
            return nil
        }
    }
    
    func cacheAnalysis<T: Codable>(_ result: T, siteId: Int, type: String, hash: String, validFor: TimeInterval? = nil) {
        guard let db = dbQueue else { return }
        
        do {
            let json = try JSONEncoder().encode(result)
            let jsonString = String(data: json, encoding: .utf8) ?? ""
            
            try db.write { db in
                let entry = AnalysisCacheEntry(
                    siteId: siteId,
                    analysisType: type,
                    parametersHash: hash,
                    resultJson: jsonString,
                    computedAt: Date(),
                    validUntil: validFor.map { Date().addingTimeInterval($0) }
                )
                try entry.save(db, onConflict: .replace)
            }
            print("💾 Cached analysis: \(type)")
        } catch {
            print("❌ Failed to cache analysis: \(error)")
        }
    }
    
    func invalidateAnalysisCache(siteId: Int) {
        guard let db = dbQueue else { return }
        
        do {
            try db.write { db in
                try db.execute(
                    sql: "DELETE FROM analysis_cache WHERE site_id = ?",
                    arguments: [siteId]
                )
            }
            print("🗑️ Invalidated analysis cache for site \(siteId)")
        } catch {
            print("❌ Failed to invalidate cache: \(error)")
        }
    }
    
    // MARK: - Maintenance
    
    /// Clear all data for a site
    @MainActor
    func clearSiteData(siteId: Int) {
        guard let db = dbQueue else { return }
        
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM action_records WHERE site_id = ?", arguments: [siteId])
                try db.execute(sql: "DELETE FROM day_summaries WHERE site_id = ?", arguments: [siteId])
                try db.execute(sql: "DELETE FROM sync_metadata WHERE site_id = ?", arguments: [siteId])
                try db.execute(sql: "DELETE FROM analysis_cache WHERE site_id = ?", arguments: [siteId])
                try db.execute(sql: "DELETE FROM meter_records WHERE site_id = ?", arguments: [siteId])
            }
            updateRecordCount()
            print("🗑️ Cleared all data for site \(siteId)")
        } catch {
            print("❌ Failed to clear site data: \(error)")
        }
    }
    
    /// Clear entire database
    @MainActor
    func clearAllData() {
        guard let db = dbQueue else { return }
        
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM action_records")
                try db.execute(sql: "DELETE FROM day_summaries")
                try db.execute(sql: "DELETE FROM sync_metadata")
                try db.execute(sql: "DELETE FROM analysis_cache")
                try db.execute(sql: "DELETE FROM meter_records")
                try db.execute(sql: "DELETE FROM p2p_trade_records")
            }
            updateRecordCount()
            lastSyncTime = nil
            print("🗑️ Cleared all database data")
        } catch {
            print("❌ Failed to clear database: \(error)")
        }
    }
    
    /// Get database size
    func getDatabaseSize() -> String {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: Self.databasePath),
              let size = attributes[.size] as? Int64 else {
            return "Unknown"
        }
        
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    /// Get database path for debugging
    func getDatabasePath() -> String {
        return Self.databasePath
    }
    
    // MARK: - Helpers
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
}

// MARK: - Convenience Extensions

extension PowstonDataStore {
    
    /// Quick check if we have any data for a site
    func hasSiteData(siteId: Int) -> Bool {
        let range = getDataRange(siteId: siteId)
        return range.count > 0
    }
    
    /// Get the date range we have data for (for UI display)
    func getDataRangeDescription(siteId: Int) -> String? {
        let range = getDataRange(siteId: siteId)
        guard let earliest = range.earliest, let latest = range.latest else {
            return nil
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.timeZone = powstonTimezone()
        
        return "\(formatter.string(from: earliest)) – \(formatter.string(from: latest))"
    }
}
