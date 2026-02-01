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

// MARK: - Data Store

@MainActor
class PowstonDataStore: ObservableObject {
    
    // MARK: - Published State
    
    @Published var isSyncing = false
    @Published var syncProgress: SyncProgress?
    @Published var lastSyncTime: Date?
    @Published var totalRecordCount: Int = 0
    @Published var error: String?
    
    // MARK: - Dependencies
    
    private var dbQueue: DatabaseQueue?
    private weak var api: PowstonAPI?
    
    // MARK: - Configuration
    
    private let finalizationDays: Int = 7  // Records older than this are immutable
    
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
    
    // MARK: - Singleton
    
    static let shared = PowstonDataStore()
    
    private init() {
        setupDatabase()
    }
    
    // MARK: - Setup
    
    func configure(api: PowstonAPI) {
        self.api = api
    }
    
    private func setupDatabase() {
        do {
            var config = Configuration()
            config.readonly = false
            config.foreignKeysEnabled = true
            
            dbQueue = try DatabaseQueue(path: Self.databasePath, configuration: config)
            try createSchema()
            updateRecordCount()
            print("✅ PowstonDataStore initialized at: \(Self.databasePath)")
        } catch {
            self.error = "Database setup failed: \(error.localizedDescription)"
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
                t.column("battery_soc", .double)
                t.column("pv_power", .double)
                t.column("grid_power", .double)
                t.column("battery_power", .double)
                t.column("house_power", .double)
                t.column("reason", .text)
                t.column("is_finalized", .boolean).defaults(to: false)
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
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
        }
    }
    
    // MARK: - View Adapter Methods (Primary Interface for Views)
    
    /// Fetch actions for a single day, syncing from API if not locally available
    /// Use this from DecisionsView instead of api.fetchInverterActions()
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
        let startOfDay = calendar.startOfDay(for: date)
        
        // Check if we have this date locally
        let existing = fetchActionsLocal(siteId: siteId, date: date)
        
        // Calculate day age for finalization check
        let dayAge = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        let isFinalized = dayAge > finalizationDays
        
        // Use local data if: we have records AND (finalized OR not forcing refresh)
        if !existing.isEmpty && (isFinalized || !forceRefresh) {
            print("📦 Using \(existing.count) cached records for \(formatDate(date))")
            return existing
        }
        
        // Fetch from API
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
        
        // Return fresh data from database
        return fetchActionsLocal(siteId: siteId, date: date)
    }
    
    /// Fetch actions for a date range, syncing missing days from API
    /// Use this from HistoryView for multi-day views
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
    
    // MARK: - Gap Detection
    
    /// Find days within a range that have no local data
    private func findMissingDays(siteId: Int, from startDate: Date, to endDate: Date) -> [Date] {
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
    
    // MARK: - Sync Operations
    
    /// Sync specific days from API
    private func syncDays(
        _ days: [Date],
        siteId: Int,
        inverterIds: [Int],
        api: PowstonAPI,
        progressHandler: ((SyncProgress) -> Void)?
    ) async {
        isSyncing = true
        
        let totalDays = days.count
        var recordsFetched = 0
        
        for (index, date) in days.enumerated() {
            let progress = SyncProgress(
                currentDay: index + 1,
                totalDays: totalDays,
                recordsFetched: recordsFetched,
                status: "Fetching \(formatDate(date))..."
            )
            syncProgress = progress
            progressHandler?(progress)
            
            for inverterId in inverterIds {
                let actions = await api.fetchInverterActions(inverterId: inverterId, date: date)
                
                if !actions.isEmpty {
                    do {
                        try saveActions(actions, siteId: siteId)
                        recordsFetched += actions.count
                    } catch {
                        print("❌ Failed to save actions for \(formatDate(date)): \(error)")
                    }
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
        
        let finalProgress = SyncProgress(
            currentDay: totalDays,
            totalDays: totalDays,
            recordsFetched: recordsFetched,
            status: "Complete"
        )
        syncProgress = finalProgress
        progressHandler?(finalProgress)
        
        print("✅ Synced \(totalDays) days, \(recordsFetched) records")
        
        isSyncing = false
    }
    
    /// Full sync for analysis preparation
    /// Call this before running analysis to ensure we have enough data
    func prepareForAnalysis(
        config: AnalysisConfig,
        inverterIds: [Int],
        progressHandler: @escaping (SyncProgress) -> Void
    ) async {
        guard let api = api else {
            progressHandler(SyncProgress(currentDay: 0, totalDays: 0, recordsFetched: 0, status: "No API configured"))
            return
        }
        
        let calendar = Calendar.current
        let endDate = calendar.date(byAdding: .day, value: -1, to: Date())!
        let startDate = calendar.date(byAdding: .day, value: -config.analysisWindowDays, to: endDate)!
        
        // Find gaps
        let missingDays = findMissingDays(siteId: config.siteId, from: startDate, to: endDate)
        
        if missingDays.isEmpty {
            progressHandler(SyncProgress(
                currentDay: 1,
                totalDays: 1,
                recordsFetched: 0,
                status: "Data ready - \(config.analysisWindowDays) days available"
            ))
            return
        }
        
        print("📊 Analysis prep: need to fetch \(missingDays.count) of \(config.analysisWindowDays) days")
        
        await syncDays(
            missingDays,
            siteId: config.siteId,
            inverterIds: inverterIds,
            api: api,
            progressHandler: progressHandler
        )
        
        // Invalidate stale analysis cache since we have new data
        invalidateAnalysisCache(siteId: config.siteId)
    }
    
    // MARK: - Save Operations
    
    private func saveActions(_ actions: [InverterAction], siteId: Int) throws {
        guard let db = dbQueue else { return }
        
        try db.write { db in
            for action in actions {
                let record = ActionRecord(from: action, siteId: siteId)
                try record.save(db, onConflict: .replace)
            }
        }
    }
    
    func saveDaySummary(_ summary: DayRateSummary, date: String) throws {
        guard let db = dbQueue else { return }
        
        try db.write { db in
            var record = DaySummaryRecord(from: summary, date: date)
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
                    SELECT * FROM action_records
                    WHERE site_id = ? AND interval_time >= ? AND interval_time <= ?
                    """
                var arguments: [DatabaseValueConvertible] = [siteId, startDate, endDate]
                
                if let action = action {
                    sql += " AND action LIKE ?"
                    arguments.append("%\(action)%")
                }
                
                sql += " ORDER BY interval_time ASC"
                
                return try ActionRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
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
                try ActionRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM action_records
                        WHERE site_id = ? 
                        AND interval_time >= ? 
                        AND interval_time <= ?
                        AND action LIKE '%export%'
                        AND energy_export > 0.1
                        ORDER BY interval_time ASC
                        """,
                    arguments: [siteId, startDate, endDate]
                )
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
        guard let db = dbQueue else { return (nil, nil, 0) }
        
        do {
            return try db.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT MIN(interval_time) as earliest, MAX(interval_time) as latest, COUNT(*) as count
                        FROM action_records
                        WHERE site_id = ?
                        """,
                    arguments: [siteId]
                )
                
                return (
                    row?["earliest"] as? Date,
                    row?["latest"] as? Date,
                    row?["count"] as? Int ?? 0
                )
            }
        } catch {
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
                var entry = AnalysisCacheEntry(
                    id: nil,
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
    func clearSiteData(siteId: Int) {
        guard let db = dbQueue else { return }
        
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM action_records WHERE site_id = ?", arguments: [siteId])
                try db.execute(sql: "DELETE FROM day_summaries WHERE site_id = ?", arguments: [siteId])
                try db.execute(sql: "DELETE FROM sync_metadata WHERE site_id = ?", arguments: [siteId])
                try db.execute(sql: "DELETE FROM analysis_cache WHERE site_id = ?", arguments: [siteId])
            }
            updateRecordCount()
            print("🗑️ Cleared all data for site \(siteId)")
        } catch {
            print("❌ Failed to clear site data: \(error)")
        }
    }
    
    /// Clear entire database
    func clearAllData() {
        guard let db = dbQueue else { return }
        
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM action_records")
                try db.execute(sql: "DELETE FROM day_summaries")
                try db.execute(sql: "DELETE FROM sync_metadata")
                try db.execute(sql: "DELETE FROM analysis_cache")
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

// MARK: - Sync Progress

struct SyncProgress: Equatable {
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
