//
//  PowstonDataStore+DaySummaries.swift
//  Powston
//
//  Day summary persistence with cache-through pattern
//  Uses cumulative subtraction to work around day_rates API 2-day minimum bug
//

import Foundation
import GRDB

extension PowstonDataStore {
    
    // MARK: - Day Summary Fetch (Cache-Through)
    
    /// Fetch a single day's summary, syncing from API if not locally available
    /// Returns nil if no data available from either source
    @MainActor
    func fetchDaySummary(
        siteId: Int,
        date: Date,
        forceRefresh: Bool = false
    ) async -> DaySummaryRecord? {
        let dateStr = formatDateString(date)
        
        // Check local first
        if let existing = getDaySummaryLocal(siteId: siteId, date: dateStr) {
            let dayAge = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
            let isFinalized = dayAge > finalizationDays
            
            // Use cached if finalized or not forcing refresh
            if isFinalized || !forceRefresh {
                print("📦 Using cached day summary for \(dateStr)")
                return existing
            }
        }
        
        // Fetch from API
        guard let api = api else { return getDaySummaryLocal(siteId: siteId, date: dateStr) }
        
        print("🌐 Fetching day summary from API for \(dateStr)")
        
        // Use cumulative method for accurate single-day values
        if let record = await fetchSingleDayFromCumulative(api: api, siteId: siteId, date: date) {
            do {
                try saveDaySummaryRecord(record)
                print("💾 Saved day summary for \(dateStr)")
            } catch {
                print("❌ Failed to save day summary: \(error)")
            }
        }
        
        return getDaySummaryLocal(siteId: siteId, date: dateStr)
    }
    
    /// Fetch day summaries for a date range, syncing missing days from API
    /// Use this from HistoryView for week/month charts
    @MainActor
    func fetchDaySummariesForRange(
        siteId: Int,
        from startDate: Date,
        to endDate: Date,
        forceRefresh: Bool = false,
        progressHandler: ((Int, Int) -> Void)? = nil
    ) async -> [DaySummaryRecord] {
        guard let api = api else {
            return getDaySummariesLocal(siteId: siteId, from: startDate, to: endDate)
        }
        
        // Find missing days
        let missingDates = findMissingDaySummaryDates(siteId: siteId, from: startDate, to: endDate)
        
        if missingDates.isEmpty && !forceRefresh {
            print("📦 All day summaries available locally for range")
            return getDaySummariesLocal(siteId: siteId, from: startDate, to: endDate)
        }
        
        let datesToFetch = forceRefresh ? generateDateRange(from: startDate, to: endDate) : missingDates
        print("🌐 Fetching \(datesToFetch.count) day summaries from API")
        
        // Fetch missing days
        for (index, date) in datesToFetch.enumerated() {
            progressHandler?(index + 1, datesToFetch.count)
            
            // Use cumulative method for accurate single-day values
            if let record = await fetchSingleDayFromCumulative(api: api, siteId: siteId, date: date) {
                do {
                    try saveDaySummaryRecord(record)
                } catch {
                    print("❌ Failed to save day summary for \(record.date): \(error)")
                }
            }
            
            // Yield to prevent UI blocking
            await Task.yield()
        }
        
        // Finalize old summaries
        finalizeDaySummaries(siteId: siteId)
        
        return getDaySummariesLocal(siteId: siteId, from: startDate, to: endDate)
    }
    
    /// Fetch a single day's data using cumulative subtraction method
    /// Workaround for day_rates API bug that returns 2+ days for single-day queries
    private func fetchSingleDayFromCumulative(
        api: PowstonAPI,
        siteId: Int,
        date: Date
    ) async -> DaySummaryRecord? {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let dateStr = formatDateString(date)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: date)!
        let epochStart = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        
        // Fetch cumulative to end of target day
        guard let cumulativeToDate = await api.fetchDayRateSummary(
            startDate: epochStart,
            endDate: date
        ) else { return nil }
        
        // Fetch cumulative to end of previous day
        guard let cumulativeToPrevious = await api.fetchDayRateSummary(
            startDate: epochStart,
            endDate: previousDay
        ) else {
            // First day of data - use as-is
            return DaySummaryRecord(from: cumulativeToDate, date: dateStr)
        }
        
        // Subtract to get single day values
        return DaySummaryRecord(
            siteId: siteId,
            date: dateStr,
            expectedBill: cumulativeToDate.expectedBill - cumulativeToPrevious.expectedBill,
            totalCosts: cumulativeToDate.totalCosts - cumulativeToPrevious.totalCosts,
            totalEarnings: cumulativeToDate.totalEarnings - cumulativeToPrevious.totalEarnings,
            rateCosts: cumulativeToDate.rateCosts - cumulativeToPrevious.rateCosts,
            rateEarnings: cumulativeToDate.rateEarnings - cumulativeToPrevious.rateEarnings,
            dailyCosts: cumulativeToDate.dailyCosts - cumulativeToPrevious.dailyCosts,
            energyImported: cumulativeToDate.totalEnergyImported - cumulativeToPrevious.totalEnergyImported,
            energyExported: cumulativeToDate.totalEnergyExported - cumulativeToPrevious.totalEnergyExported,
            batteryKwh: cumulativeToDate.totalBatteryKwh - cumulativeToPrevious.totalBatteryKwh,
            buyRate: cumulativeToDate.buyRate,  // Use current day's rate
            sellRate: cumulativeToDate.sellRate,
            recordCount: cumulativeToDate.recordCount - cumulativeToPrevious.recordCount,
            isFinalized: false,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
    
    // MARK: - Local Database Operations
    
    private func getDaySummaryLocal(siteId: Int, date: String) -> DaySummaryRecord? {
        guard let db = dbQueue else { return nil }
        
        do {
            return try db.read { db in
                try DaySummaryRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM day_summaries WHERE site_id = ? AND date = ?",
                    arguments: [siteId, date]
                )
            }
        } catch {
            print("❌ getDaySummaryLocal failed: \(error)")
            return nil
        }
    }
    
    private func getDaySummariesLocal(siteId: Int, from startDate: Date, to endDate: Date) -> [DaySummaryRecord] {
        guard let db = dbQueue else { return [] }
        
        let startStr = formatDateString(startDate)
        let endStr = formatDateString(endDate)
        
        do {
            return try db.read { db in
                try DaySummaryRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM day_summaries 
                        WHERE site_id = ? AND date >= ? AND date <= ?
                        ORDER BY date ASC
                        """,
                    arguments: [siteId, startStr, endStr]
                )
            }
        } catch {
            print("❌ getDaySummariesLocal failed: \(error)")
            return []
        }
    }
    
    private func saveDaySummaryRecord(_ record: DaySummaryRecord) throws {
        guard let db = dbQueue else { return }
        
        var mutableRecord = record
        mutableRecord.updatedAt = Date()
        
        try db.write { db in
            try mutableRecord.save(db, onConflict: .replace)
        }
    }
    
    private func finalizeDaySummaries(siteId: Int) {
        guard let db = dbQueue else { return }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let cutoffDate = calendar.date(byAdding: .day, value: -finalizationDays, to: Date())!
        let cutoffStr = formatDateString(cutoffDate)
        
        do {
            try db.write { db in
                try db.execute(
                    sql: """
                        UPDATE day_summaries 
                        SET is_finalized = 1, updated_at = CURRENT_TIMESTAMP
                        WHERE site_id = ? AND date < ? AND is_finalized = 0
                        """,
                    arguments: [siteId, cutoffStr]
                )
            }
        } catch {
            print("❌ finalizeDaySummaries failed: \(error)")
        }
    }
    
    // MARK: - Gap Detection
    
    private func findMissingDaySummaryDates(siteId: Int, from startDate: Date, to endDate: Date) -> [Date] {
        guard let db = dbQueue else { return generateDateRange(from: startDate, to: endDate) }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        // Get existing dates
        let existingDates: Set<String> = (try? db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT date FROM day_summaries 
                    WHERE site_id = ? AND date >= ? AND date <= ?
                    """,
                arguments: [siteId, formatDateString(startDate), formatDateString(endDate)]
            )
            return Set(rows.compactMap { $0["date"] as? String })
        }) ?? []
        
        // Find missing
        var missingDates: [Date] = []
        var currentDate = calendar.startOfDay(for: startDate)
        let endDateNormalized = calendar.startOfDay(for: endDate)
        
        while currentDate <= endDateNormalized {
            let dateStr = formatDateString(currentDate)
            if !existingDates.contains(dateStr) && currentDate < Date() {
                missingDates.append(currentDate)
            }
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        return missingDates
    }
    
    private func generateDateRange(from startDate: Date, to endDate: Date) -> [Date] {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        var dates: [Date] = []
        var currentDate = calendar.startOfDay(for: startDate)
        let endDateNormalized = calendar.startOfDay(for: endDate)
        
        while currentDate <= endDateNormalized {
            if currentDate < Date() {
                dates.append(currentDate)
            }
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        return dates
    }
    
    // MARK: - Data Range Info
    
    /// Get the date range of cached day summaries for a site
    func getDaySummaryDataRange(siteId: Int) -> (earliest: String?, latest: String?, count: Int) {
        guard let db = dbQueue else { return (nil, nil, 0) }
        
        do {
            return try db.read { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM day_summaries WHERE site_id = ?",
                    arguments: [siteId]
                ) ?? 0
                
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT MIN(date) as earliest, MAX(date) as latest
                        FROM day_summaries WHERE site_id = ?
                        """,
                    arguments: [siteId]
                )
                
                let earliest = row?["earliest"] as? String
                let latest = row?["latest"] as? String
                
                return (earliest, latest, count)
            }
        } catch {
            print("❌ getDaySummaryDataRange failed: \(error)")
            return (nil, nil, 0)
        }
    }
    
    /// Check if we have day summary data for a site
    func hasDaySummaryData(siteId: Int) -> Bool {
        let range = getDaySummaryDataRange(siteId: siteId)
        return range.count > 0
    }
    
    /// Get description of cached day summary range for UI display
    func getDaySummaryRangeDescription(siteId: Int) -> String? {
        let range = getDaySummaryDataRange(siteId: siteId)
        guard let earliest = range.earliest, let latest = range.latest else {
            return nil
        }
        return "\(earliest) – \(latest) (\(range.count) days)"
    }
    
    // MARK: - Helpers
    
    private func formatDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
}
