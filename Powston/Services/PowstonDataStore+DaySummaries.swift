//
//  PowstonDataStore+DaySummaries.swift
//  Powston
//
//  Day summary persistence - data range info and helper methods
//  Note: Main cache-through logic is in PowstonAPI_DayRates.swift

import Foundation
import GRDB

extension PowstonDataStore {
    
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
    
    // MARK: - Finalization
    
    /// Finalize old day summaries (called periodically)
    func finalizeDaySummaries(siteId: Int) {
        guard let db = dbQueue else { return }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let cutoffDate = calendar.date(byAdding: .day, value: -finalizationDays, to: Date())!
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        let cutoffStr = dateFormatter.string(from: cutoffDate)
        
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
    
    // MARK: - Maintenance
    
    /// Clear day summary cache for a site
    @MainActor
    func clearDaySummaryData(siteId: Int) {
        guard let db = dbQueue else { return }
        
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM day_summaries WHERE site_id = ?", arguments: [siteId])
            }
            print("🗑️ Cleared day summary data for site \(siteId)")
        } catch {
            print("❌ Failed to clear day summary data: \(error)")
        }
    }
}
