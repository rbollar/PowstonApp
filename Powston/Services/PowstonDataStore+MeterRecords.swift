//
//  PowstonDataStore+MeterRecords.swift
//  Powston
//
//  Meter record persistence - query and save methods
//  Cache-through logic is in PowstonAPI+MeterRecords.swift
//

import Foundation
import GRDB

extension PowstonDataStore {
    
    // MARK: - Local Query Operations
    
    /// Fetch meter records from local SQLite for a date range
    func getMeterRecordsLocal(siteId: Int, from startDate: Date, to endDate: Date) -> [MeterRecordDB] {
        guard let db = dbQueue else { return [] }
        
        do {
            return try db.read { db in
                try MeterRecordDB.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM meter_records
                        WHERE site_id = ?
                        AND interval_time >= ?
                        AND interval_time <= ?
                        ORDER BY interval_time ASC
                        """,
                    arguments: [siteId, startDate, endDate]
                )
            }
        } catch {
            print("❌ getMeterRecordsLocal failed: \(error)")
            return []
        }
    }
    
    /// Check if we have complete data for a date (288 records = full day of 5-min intervals)
    func hasMeterRecordsForDate(siteId: Int, date: Date) -> Bool {
        guard let db = dbQueue else { return false }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!.addingTimeInterval(-1)
        
        do {
            let count = try db.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM meter_records
                        WHERE site_id = ? AND interval_time >= ? AND interval_time <= ?
                        """,
                    arguments: [siteId, startOfDay, endOfDay]
                )
            } ?? 0
            
            // Consider complete if we have at least 280 records (allowing for minor gaps)
            return count >= 280
        } catch {
            return false
        }
    }
    
    /// Check if records for a date are finalized
    func areMeterRecordsFinalized(siteId: Int, date: Date) -> Bool {
        guard let db = dbQueue else { return false }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!.addingTimeInterval(-1)
        
        do {
            // Check if ALL records for this day are finalized
            let unfinalizedCount = try db.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM meter_records
                        WHERE site_id = ? AND interval_time >= ? AND interval_time <= ?
                        AND is_finalized = 0
                        """,
                    arguments: [siteId, startOfDay, endOfDay]
                )
            } ?? 0
            
            return unfinalizedCount == 0 && hasMeterRecordsForDate(siteId: siteId, date: date)
        } catch {
            return false
        }
    }
    
    /// Get the most recent meter record date for a site
    func getMostRecentMeterRecordDate(siteId: Int) -> Date? {
        guard let db = dbQueue else { return nil }
        
        do {
            return try db.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT MAX(interval_time) as latest FROM meter_records WHERE site_id = ?",
                    arguments: [siteId]
                )
                return row?["latest"] as? Date
            }
        } catch {
            print("❌ getMostRecentMeterRecordDate failed: \(error)")
            return nil
        }
    }
    
    // MARK: - Save Operations
    
    /// Save meter records to SQLite
    func saveMeterRecords(_ records: [MeterRecord], siteId: Int) {
        guard let db = dbQueue, !records.isEmpty else { return }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let today = Date()
        
        do {
            try db.write { db in
                for record in records {
                    guard let recordDate = record.date else { continue }
                    
                    // Calculate if this record should be finalized
                    let dayAge = calendar.dateComponents([.day], from: recordDate, to: today).day ?? 0
                    let isFinalized = dayAge > finalizationDays
                    
                    let dbRecord = MeterRecordDB(from: record, siteId: siteId, isFinalized: isFinalized)
                    try dbRecord.save(db, onConflict: .replace)
                }
            }
            print("💾 Saved \(records.count) meter records for site \(siteId)")
        } catch {
            print("❌ saveMeterRecords failed: \(error)")
        }
    }
    
    // MARK: - Finalization
    
    /// Finalize old meter records (called periodically)
    func finalizeMeterRecords(siteId: Int) {
        guard let db = dbQueue else { return }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let cutoffDate = calendar.date(byAdding: .day, value: -finalizationDays, to: Date())!
        
        do {
            let updated = try db.write { db in
                try db.execute(
                    sql: """
                        UPDATE meter_records 
                        SET is_finalized = 1
                        WHERE site_id = ? AND interval_time < ? AND is_finalized = 0
                        """,
                    arguments: [siteId, cutoffDate]
                )
                return db.changesCount
            }
            if updated > 0 {
                print("✅ Finalized \(updated) meter records for site \(siteId)")
            }
        } catch {
            print("❌ finalizeMeterRecords failed: \(error)")
        }
    }
    
    // MARK: - Data Range Info
    
    /// Get the date range of cached meter records for a site
    func getMeterRecordDataRange(siteId: Int) -> (earliest: Date?, latest: Date?, count: Int) {
        guard let db = dbQueue else { return (nil, nil, 0) }
        
        do {
            return try db.read { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM meter_records WHERE site_id = ?",
                    arguments: [siteId]
                ) ?? 0
                
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT MIN(interval_time) as earliest, MAX(interval_time) as latest
                        FROM meter_records WHERE site_id = ?
                        """,
                    arguments: [siteId]
                )
                
                let earliest = row?["earliest"] as? Date
                let latest = row?["latest"] as? Date
                
                return (earliest, latest, count)
            }
        } catch {
            print("❌ getMeterRecordDataRange failed: \(error)")
            return (nil, nil, 0)
        }
    }
    
    /// Check if we have meter record data for a site
    func hasMeterRecordData(siteId: Int) -> Bool {
        let range = getMeterRecordDataRange(siteId: siteId)
        return range.count > 0
    }
    
    /// Get description of cached meter record range for UI display
    func getMeterRecordRangeDescription(siteId: Int) -> String? {
        let range = getMeterRecordDataRange(siteId: siteId)
        guard let earliest = range.earliest, let latest = range.latest else {
            return nil
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.timeZone = powstonTimezone()
        
        return "\(formatter.string(from: earliest)) – \(formatter.string(from: latest)) (\(range.count) records)"
    }
    
    // MARK: - Maintenance
    
    /// Clear meter record cache for a site
    @MainActor
    func clearMeterRecordData(siteId: Int) {
        guard let db = dbQueue else { return }
        
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM meter_records WHERE site_id = ?", arguments: [siteId])
            }
            print("🗑️ Cleared meter record data for site \(siteId)")
        } catch {
            print("❌ Failed to clear meter record data: \(error)")
        }
    }
}
