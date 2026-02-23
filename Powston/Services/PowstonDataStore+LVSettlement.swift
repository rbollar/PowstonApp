//
//  PowstonDataStore+LVSettlement.swift
//  Powston
//
//  GRDB persistence for LocalVolts daily cashflow summaries
//  Stores per-day settlement data from QtyReport/Identity responses
//

import Foundation
import GRDB

extension PowstonDataStore {

    // MARK: - Schema

    func createLVSettlementSchema(_ db: Database) throws {
        guard try !db.tableExists("lv_daily_cashflow") else { return }

        print("🔄 Migration: Creating lv_daily_cashflow table")

        try db.create(table: "lv_daily_cashflow") { t in
            t.column("id", .integer).primaryKey(autoincrement: true)
            t.column("site_id", .integer).notNull()
            t.column("date", .text).notNull()               // "2026-02-17"
            t.column("records", .integer).notNull()

            // Energy (kWh)
            t.column("energy_purchased_kwh", .double).notNull()
            t.column("energy_sold_spot_kwh", .double).notNull()
            t.column("energy_sold_p2p_kwh", .double).notNull()

            // Purchases ex-GST (dollars)
            t.column("spot_energy_cost", .double).notNull()
            t.column("network_energy_cost", .double).notNull()
            t.column("network_access_cost", .double).notNull()
            t.column("certificates_cost", .double).notNull()
            t.column("localvolts_fee", .double).notNull()

            // Sales (dollars, no GST)
            t.column("spot_energy_revenue", .double).notNull()
            t.column("p2p_matched_revenue", .double).notNull()
            t.column("feed_in_top_up", .double).notNull()

            // Other
            t.column("emissions", .double).notNull()
            t.column("fetched_at", .datetime).notNull()

            t.uniqueKey(["site_id", "date"])
        }

        print("✅ Created lv_daily_cashflow table")
    }

    // MARK: - Save

    /// Save cashflow summaries from LV settlement data (upsert by site+date)
    /// Protects higher-resolution data: won't overwrite if existing record has more intervals
    func saveLVCashflowSummaries(_ summaries: [LVCashflowSummary], siteId: Int) {
        guard let db = dbQueue, !summaries.isEmpty else { return }

        do {
            var saved = 0
            var skipped = 0
            try db.write { db in
                for summary in summaries {
                    let dateStr = String(summary.date.prefix(10))
                    guard !dateStr.isEmpty else { continue }

                    // Check existing record count — don't overwrite higher-resolution data
                    let existingRecords = try Int.fetchOne(
                        db,
                        sql: "SELECT records FROM lv_daily_cashflow WHERE site_id = ? AND date = ?",
                        arguments: [siteId, dateStr]
                    ) ?? 0

                    if existingRecords > summary.records {
                        skipped += 1
                        continue
                    }

                    try db.execute(
                        sql: "DELETE FROM lv_daily_cashflow WHERE site_id = ? AND date = ?",
                        arguments: [siteId, dateStr]
                    )

                    try db.execute(
                        sql: """
                            INSERT INTO lv_daily_cashflow (
                                site_id, date, records,
                                energy_purchased_kwh, energy_sold_spot_kwh, energy_sold_p2p_kwh,
                                spot_energy_cost, network_energy_cost, network_access_cost,
                                certificates_cost, localvolts_fee,
                                spot_energy_revenue, p2p_matched_revenue, feed_in_top_up,
                                emissions, fetched_at
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            siteId, dateStr, summary.records,
                            summary.energyPurchasedKwh, summary.energySoldSpotKwh, summary.energySoldP2PKwh,
                            summary.spotEnergyCostExGST, summary.networkEnergyCostExGST, summary.networkAccessCostExGST,
                            summary.certificatesCostExGST, summary.localvoltsFeeExGST,
                            summary.spotEnergyRevenue, summary.p2pMatchedRevenue, summary.feedInTopUp,
                            summary.emissions, Date()
                        ]
                    )
                    saved += 1
                }
            }
            if skipped > 0 {
                print("💾 Saved \(saved) LV cashflow summaries (skipped \(skipped) lower-resolution)")
            } else {
                print("💾 Saved \(saved) LV cashflow summaries")
            }
        } catch {
            print("❌ Failed to save LV cashflow summaries: \(error)")
        }
    }

    // MARK: - Retrieve

    /// Get LV cashflow summary for a specific date
    func getLVCashflowSummary(siteId: Int, date: Date) -> LVCashflowSummary? {
        guard let db = dbQueue else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        let dateStr = formatter.string(from: date)

        return try? db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM lv_daily_cashflow WHERE site_id = ? AND date = ?",
                arguments: [siteId, dateStr]
            ) else { return nil }

            return LVCashflowSummary(
                date: row["date"],
                records: row["records"],
                energyPurchasedKwh: row["energy_purchased_kwh"],
                energySoldSpotKwh: row["energy_sold_spot_kwh"],
                energySoldP2PKwh: row["energy_sold_p2p_kwh"],
                spotEnergyCostExGST: row["spot_energy_cost"],
                networkEnergyCostExGST: row["network_energy_cost"],
                networkAccessCostExGST: row["network_access_cost"],
                certificatesCostExGST: row["certificates_cost"],
                localvoltsFeeExGST: row["localvolts_fee"],
                spotEnergyRevenue: row["spot_energy_revenue"],
                p2pMatchedRevenue: row["p2p_matched_revenue"],
                feedInTopUp: row["feed_in_top_up"],
                emissions: row["emissions"]
            )
        }
    }

    /// Clear all settlement data for a site (used by schema migrations to force re-fetch)
    func clearAllSettlementData(siteId: Int) {
        guard let db = dbQueue else { return }
        do {
            try db.write { db in
                try db.execute(
                    sql: "DELETE FROM lv_daily_cashflow WHERE site_id = ?",
                    arguments: [siteId]
                )
                print("🧹 Cleared settlement data for site \(siteId)")
            }
        } catch {
            print("❌ Failed to clear settlement data: \(error)")
        }
    }

    /// Delete forecast settlement data (dates after today) that shouldn't have been stored
    func purgeFutureSettlementData(siteId: Int) {
        guard let db = dbQueue else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        let todayStr = formatter.string(from: Date())
        do {
            try db.write { db in
                _ = try db.execute(
                    sql: "DELETE FROM lv_daily_cashflow WHERE site_id = ? AND date > ?",
                    arguments: [siteId, todayStr]
                )
                print("🧹 Purged future settlement data for site \(siteId) (after \(todayStr))")
            }
        } catch {
            print("❌ Failed to purge future settlement data: \(error)")
        }
    }

    /// Get the set of date strings that have settlement data for a site
    func getSettlementDates(siteId: Int) -> Set<String> {
        guard let db = dbQueue else { return [] }
        return (try? db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT date FROM lv_daily_cashflow WHERE site_id = ?",
                arguments: [siteId]
            )
            return Set(rows.map { $0["date"] as String })
        }) ?? []
    }

    /// Get the earliest settlement date for a site
    func getEarliestSettlementDate(siteId: Int) -> String? {
        guard let db = dbQueue else { return nil }
        return try? db.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT MIN(date) FROM lv_daily_cashflow WHERE site_id = ?",
                arguments: [siteId]
            )
        }
    }

    /// Get LV cashflow summaries for a year, grouped by month
    /// Returns one LVCashflowSummary per month that has data
    /// Optional maxDate caps the query to exclude unfinalized days
    func getLVMonthlySummaries(siteId: Int, year: Int, maxDate: Date? = nil) -> [LVCashflowSummary] {
        guard let db = dbQueue else { return [] }

        let fromStr = String(format: "%04d-01-01", year)
        let toStr: String
        if let maxDate = maxDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
            toStr = formatter.string(from: maxDate)
        } else {
            toStr = String(format: "%04d-12-31", year)
        }

        return (try? db.read { db in
            // Get all daily records for the year, then group in Swift for flexibility
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM lv_daily_cashflow WHERE site_id = ? AND date >= ? AND date <= ? ORDER BY date",
                arguments: [siteId, fromStr, toStr]
            )

            let dailySummaries: [LVCashflowSummary] = rows.map { row in
                LVCashflowSummary(
                    date: row["date"],
                    records: row["records"],
                    energyPurchasedKwh: row["energy_purchased_kwh"],
                    energySoldSpotKwh: row["energy_sold_spot_kwh"],
                    energySoldP2PKwh: row["energy_sold_p2p_kwh"],
                    spotEnergyCostExGST: row["spot_energy_cost"],
                    networkEnergyCostExGST: row["network_energy_cost"],
                    networkAccessCostExGST: row["network_access_cost"],
                    certificatesCostExGST: row["certificates_cost"],
                    localvoltsFeeExGST: row["localvolts_fee"],
                    spotEnergyRevenue: row["spot_energy_revenue"],
                    p2pMatchedRevenue: row["p2p_matched_revenue"],
                    feedInTopUp: row["feed_in_top_up"],
                    emissions: row["emissions"]
                )
            }

            // Group by month
            let byMonth = Dictionary(grouping: dailySummaries) { summary -> String in
                String(summary.date.prefix(7))  // "2025-11"
            }

            return byMonth.map { (_, summaries) in
                summaries.aggregated()
            }.sorted { $0.date < $1.date }
        }) ?? []
    }

    /// Get LV cashflow summaries for a date range
    func getLVCashflowSummaries(siteId: Int, from: Date, to: Date) -> [LVCashflowSummary] {
        guard let db = dbQueue else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        let fromStr = formatter.string(from: from)
        let toStr = formatter.string(from: to)

        return (try? db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM lv_daily_cashflow WHERE site_id = ? AND date >= ? AND date <= ? ORDER BY date",
                arguments: [siteId, fromStr, toStr]
            )

            return rows.map { row in
                LVCashflowSummary(
                    date: row["date"],
                    records: row["records"],
                    energyPurchasedKwh: row["energy_purchased_kwh"],
                    energySoldSpotKwh: row["energy_sold_spot_kwh"],
                    energySoldP2PKwh: row["energy_sold_p2p_kwh"],
                    spotEnergyCostExGST: row["spot_energy_cost"],
                    networkEnergyCostExGST: row["network_energy_cost"],
                    networkAccessCostExGST: row["network_access_cost"],
                    certificatesCostExGST: row["certificates_cost"],
                    localvoltsFeeExGST: row["localvolts_fee"],
                    spotEnergyRevenue: row["spot_energy_revenue"],
                    p2pMatchedRevenue: row["p2p_matched_revenue"],
                    feedInTopUp: row["feed_in_top_up"],
                    emissions: row["emissions"]
                )
            }
        }) ?? []
    }

    // MARK: - Per-Interval Settlement Records (lv_settlement_intervals)

    /// Create lv_settlement_intervals table for per-interval settlement data
    func createLVSettlementIntervalsSchema(_ db: Database) throws {
        guard try !db.tableExists("lv_settlement_intervals") else { return }

        print("🔄 Migration: Creating lv_settlement_intervals table")

        try db.create(table: "lv_settlement_intervals") { t in
            t.column("site_id", .integer).notNull()
            t.column("date", .text).notNull()
            t.column("period", .integer).notNull()
            t.column("basis", .integer).notNull()
            t.column("profile", .text).notNull()
            t.column("region", .text).notNull()
            t.column("nmi", .text).notNull()
            t.column("quality", .text).notNull()
            t.column("tou", .text).notNull()
            t.column("volume", .double)
            t.column("settle", .double)
            t.column("dlf", .double)
            t.column("mlf", .double)
            t.column("network_energy", .double)
            t.column("daily_connection", .double)
            t.column("amount_stc", .double)
            t.column("amount_esc", .double)
            t.column("amount_lgc", .double)
            t.column("amount_act", .double)
            t.column("certificate_amt", .double)
            t.column("localvolts_fee", .double)
            t.column("match_energy", .double)
            t.column("match_amount", .double)
            t.column("standing", .double)
            t.column("feed_in_top_up", .double)
            t.column("meter_capital", .double)
            t.column("meter_non_capital", .double)
            t.column("co2e", .double)
            t.column("fetched_at", .datetime).notNull()
            t.primaryKey(["site_id", "date", "period", "profile"])
        }

        try db.create(
            index: "idx_lv_settlement_site_date",
            on: "lv_settlement_intervals",
            columns: ["site_id", "date"]
        )

        print("✅ Created lv_settlement_intervals table")
    }

    /// Save per-interval settlement records (upsert via composite PK)
    func saveLVSettlementIntervals(_ records: [LVSettlementRecord], siteId: Int) {
        guard let db = dbQueue, !records.isEmpty else { return }

        do {
            try db.write { db in
                for var record in records {
                    record.siteId = siteId
                    record.date = String(record.date.prefix(10))
                    record.fetchedAt = Date()
                    try record.save(db, onConflict: .replace)
                }
            }
            print("💾 Saved \(records.count) LV settlement interval records for site \(siteId)")
        } catch {
            print("❌ Failed to save LV settlement intervals: \(error)")
        }
    }

    /// Check if we have per-interval settlement data for a specific date
    func hasSettlementIntervals(siteId: Int, date: String) -> Bool {
        guard let db = dbQueue else { return false }
        return (try? db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM lv_settlement_intervals WHERE site_id = ? AND date = ?",
                arguments: [siteId, String(date.prefix(10))]
            )
        }).flatMap { $0 > 0 } ?? false
    }

    /// Get all per-interval settlement records for a specific date
    func getSettlementIntervals(siteId: Int, date: String) -> [LVSettlementRecord] {
        guard let db = dbQueue else { return [] }
        return (try? db.read { db in
            try LVSettlementRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM lv_settlement_intervals
                    WHERE site_id = ? AND date = ?
                    ORDER BY period, profile
                    """,
                arguments: [siteId, String(date.prefix(10))]
            )
        }) ?? []
    }

    /// Delete future settlement interval data (parallel to purgeFutureSettlementData)
    func purgeFutureSettlementIntervals(siteId: Int) {
        guard let db = dbQueue else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        let todayStr = formatter.string(from: Date())
        do {
            try db.write { db in
                try db.execute(
                    sql: "DELETE FROM lv_settlement_intervals WHERE site_id = ? AND date > ?",
                    arguments: [siteId, todayStr]
                )
            }
            print("🧹 Purged future settlement intervals for site \(siteId) (after \(todayStr))")
        } catch {
            print("❌ Failed to purge future settlement intervals: \(error)")
        }
    }
}
