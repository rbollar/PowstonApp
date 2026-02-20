//
//  LVSettlementRecord.swift
//  Powston
//
//  Per-interval settlement record from LocalVolts WebSocket API (QtyReport/Identity)
//  Contains the full financial breakdown: spot settlement, network charges,
//  certificates, fees, P2P matched amounts, and emissions.
//

import Foundation
import GRDB

// MARK: - Per-Interval Settlement Record

struct LVSettlementRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lv_settlement_intervals"

    var siteId: Int = 0
    var date: String           // "2026-02-18T00:00:00.000Z"
    var period: Int            // 1-288 for 5-min intervals
    var basis: Int             // 288 = 5-min, 48 = 30-min
    var profile: String        // "Export" or "Import"
    var region: String         // "QLD", "NSW", etc.
    var nmi: String
    var quality: String        // "Exp" (expected), "Act" (actual)
    var tou: String            // "Current", "Peak", "OffPeak", etc.

    // Energy
    var volume: Double         // kWh for this interval

    // AEMO spot settlement (dollars)
    var settle: Double         // Spot energy settlement amount

    // Loss factors
    var dlf: Double            // Distribution Loss Factor
    var mlf: Double            // Marginal Loss Factor

    // Network charges (dollars)
    var networkEnergy: Double  // Network energy charge
    var dailyConnection: Double // Daily connection/access charge

    // Certificates (dollars)
    var amountSTC: Double      // Small-scale Technology Certificates
    var amountESC: Double      // Energy Savings Certificates
    var amountLGC: Double      // Large-scale Generation Certificates
    var amountACT: Double      // ACT certificate scheme
    var certificateAmt: Double // Total certificate amount

    // Fees (dollars)
    var localvoltsFee: Double  // LocalVolts fee

    // P2P (dollars/kWh)
    var matchEnergy: Double    // P2P matched energy (kWh)
    var matchAmount: Double    // P2P matched amount (dollars)

    // Other
    var standing: Double       // Standing charges
    var feedInTopUp: Double    // Feed-in tariff top-up
    var meterCapital: Double   // Metering capital charges
    var meterNonCapital: Double // Metering non-capital charges
    var co2e: Double           // Emissions (kgCO2e)

    var fetchedAt: Date = Date()

    var isExport: Bool { profile == "Export" }
    var isImport: Bool { profile == "Import" }

    // MARK: - GRDB Column Mapping

    enum CodingKeys: String, CodingKey {
        case siteId = "site_id"
        case date, period, basis, profile, region, nmi, quality, tou
        case volume, settle, dlf, mlf
        case networkEnergy = "network_energy"
        case dailyConnection = "daily_connection"
        case amountSTC = "amount_stc"
        case amountESC = "amount_esc"
        case amountLGC = "amount_lgc"
        case amountACT = "amount_act"
        case certificateAmt = "certificate_amt"
        case localvoltsFee = "localvolts_fee"
        case matchEnergy = "match_energy"
        case matchAmount = "match_amount"
        case standing
        case feedInTopUp = "feed_in_top_up"
        case meterCapital = "meter_capital"
        case meterNonCapital = "meter_non_capital"
        case co2e
        case fetchedAt = "fetched_at"
    }
}

// MARK: - Parsing

extension LVSettlementRecord {
    static func parse(from dict: [String: Any]) -> LVSettlementRecord? {
        guard let profile = dict["profile"] as? String,
              let period = dict["period"] as? Int else {
            return nil
        }

        return LVSettlementRecord(
            date: dict["date"] as? String ?? "",
            period: period,
            basis: dict["basis"] as? Int ?? 288,
            profile: profile,
            region: dict["region"] as? String ?? "",
            nmi: (dict["NMI"] as? String) ?? String(describing: dict["NMI"] ?? ""),
            quality: dict["quality"] as? String ?? "",
            tou: dict["TOU"] as? String ?? "",
            volume: parseDouble(dict["volume"]) ?? 0,
            settle: parseDouble(dict["settle"]) ?? 0,
            dlf: parseDouble(dict["DLF"]) ?? 1.0,
            mlf: parseDouble(dict["MLF"]) ?? 1.0,
            networkEnergy: parseDouble(dict["networkEnergy"]) ?? 0,
            dailyConnection: parseDouble(dict["dailyConnection"]) ?? 0,
            amountSTC: parseDouble(dict["amountSTC"]) ?? 0,
            amountESC: parseDouble(dict["amountESC"]) ?? 0,
            amountLGC: parseDouble(dict["amountLGC"]) ?? 0,
            amountACT: parseDouble(dict["amountACT"]) ?? 0,
            certificateAmt: parseDouble(dict["certificateAmt"]) ?? 0,
            localvoltsFee: parseDouble(dict["LocalvoltsFee"]) ?? 0,
            matchEnergy: parseDouble(dict["matchEnergy"]) ?? 0,
            matchAmount: parseDouble(dict["matchAmount"]) ?? 0,
            standing: parseDouble(dict["standing"]) ?? 0,
            feedInTopUp: parseDouble(dict["FeedInTopUp"]) ?? 0,
            meterCapital: parseDouble(dict["meterCapital"]) ?? 0,
            meterNonCapital: parseDouble(dict["meterNonCapital"]) ?? 0,
            co2e: parseDouble(dict["CO2e"]) ?? 0
        )
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - Cashflow Summary (aggregated from settlement records)

struct LVCashflowSummary {

    let date: String
    let records: Int

    // Energy quantities
    let energyPurchasedKwh: Double      // Total import volume
    let energySoldSpotKwh: Double       // Spot export volume
    let energySoldP2PKwh: Double        // P2P matched export volume

    // Purchases breakdown (ex-GST dollars from QtyReport settlement data)
    // Computed properties below apply ×1.1 GST for purchase-side costs
    let spotEnergyCostExGST: Double     // AEMO spot settlement for imports (ex-GST)
    let networkEnergyCostExGST: Double  // Network energy charges (ex-GST)
    let networkAccessCostExGST: Double  // Daily connection + standing + metering (ex-GST)
    let certificatesCostExGST: Double   // STC + ESC + LGC + ACT (ex-GST)
    let localvoltsFeeExGST: Double      // LV fee on imports (ex-GST)

    // Sales breakdown (dollars)
    let spotEnergyRevenue: Double       // AEMO spot settlement for exports
    let p2pMatchedRevenue: Double       // P2P matched amount

    // Other
    let feedInTopUp: Double
    let emissions: Double               // kgCO2e

    // Purchase amounts (QtyReport data is ex-GST, add 10% GST to match LV portal)
    // Sales (export revenue) do NOT get GST — residential prosumers aren't GST-registered
    var spotEnergyCost: Double { spotEnergyCostExGST * 1.1 }
    var networkEnergyCost: Double { networkEnergyCostExGST * 1.1 }
    var networkAccessCost: Double { networkAccessCostExGST * 1.1 }
    var certificatesCost: Double { certificatesCostExGST * 1.1 }
    var localvoltsFee: Double { localvoltsFeeExGST * 1.1 }

    var totalPurchases: Double {
        spotEnergyCost + networkEnergyCost + networkAccessCost + certificatesCost + localvoltsFee
    }

    var totalSales: Double {
        spotEnergyRevenue + p2pMatchedRevenue + feedInTopUp
    }

    var netCosts: Double {
        totalPurchases - totalSales
    }

    var energySoldTotalKwh: Double {
        energySoldSpotKwh + energySoldP2PKwh
    }

}

// MARK: - DailySummary Conversion

extension LVCashflowSummary {
    /// Convert to DailySummary for use in HistoryView charts
    func toDailySummary() -> DailySummary? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        guard let parsedDate = formatter.date(from: String(date.prefix(10))) else { return nil }

        return DailySummary(
            date: parsedDate,
            totalImport: energyPurchasedKwh,
            totalExport: energySoldTotalKwh,
            totalEarnings: totalSales,
            totalCosts: spotEnergyCost + networkEnergyCost + certificatesCost,
            avgSoc: 0,
            recordCount: records,
            netProfit: -netCosts  // Negative netCosts = profit
        )
    }

    /// Aggregate daily cashflow summaries into monthly DailySummary entries for year view charts
    /// Groups by month, sums values, returns one DailySummary per month with date = 1st of month
    static func monthlyAggregates(from dailySummaries: [LVCashflowSummary], year: Int) -> [DailySummary] {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")

        // Group by month number
        let byMonth = Dictionary(grouping: dailySummaries) { summary -> Int in
            guard let date = formatter.date(from: String(summary.date.prefix(10))) else { return 0 }
            return calendar.component(.month, from: date)
        }

        return byMonth.compactMap { (month, summaries) -> DailySummary? in
            guard month > 0,
                  let monthDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return nil }

            let agg = summaries.aggregated()
            return DailySummary(
                date: monthDate,
                totalImport: agg.energyPurchasedKwh,
                totalExport: agg.energySoldTotalKwh,
                totalEarnings: agg.totalSales,
                totalCosts: agg.spotEnergyCost + agg.networkEnergyCost + agg.certificatesCost,
                avgSoc: 0,
                recordCount: agg.records,
                netProfit: -agg.netCosts
            )
        }.sorted { $0.date < $1.date }
    }
}

// MARK: - Multi-Day Aggregation (from stored daily summaries)

extension Array where Element == LVCashflowSummary {
    /// Aggregate multiple daily cashflow summaries into a single period summary
    func aggregated() -> LVCashflowSummary {
        LVCashflowSummary(
            date: self.first?.date ?? "",
            records: self.reduce(0) { $0 + $1.records },
            energyPurchasedKwh: self.reduce(0.0) { $0 + $1.energyPurchasedKwh },
            energySoldSpotKwh: self.reduce(0.0) { $0 + $1.energySoldSpotKwh },
            energySoldP2PKwh: self.reduce(0.0) { $0 + $1.energySoldP2PKwh },
            spotEnergyCostExGST: self.reduce(0.0) { $0 + $1.spotEnergyCostExGST },
            networkEnergyCostExGST: self.reduce(0.0) { $0 + $1.networkEnergyCostExGST },
            networkAccessCostExGST: self.reduce(0.0) { $0 + $1.networkAccessCostExGST },
            certificatesCostExGST: self.reduce(0.0) { $0 + $1.certificatesCostExGST },
            localvoltsFeeExGST: self.reduce(0.0) { $0 + $1.localvoltsFeeExGST },
            spotEnergyRevenue: self.reduce(0.0) { $0 + $1.spotEnergyRevenue },
            p2pMatchedRevenue: self.reduce(0.0) { $0 + $1.p2pMatchedRevenue },
            feedInTopUp: self.reduce(0.0) { $0 + $1.feedInTopUp },
            emissions: self.reduce(0.0) { $0 + $1.emissions }
        )
    }
}

// MARK: - Per-Interval Aggregation (from raw settlement records)

extension Array where Element == LVSettlementRecord {
    /// Calculate cashflow summary matching the LV dashboard Cashflow Breakdown
    func cashflowSummary() -> LVCashflowSummary {
        let imports = self.filter { $0.isImport }
        let exports = self.filter { $0.isExport }

        // Energy quantities
        let energyPurchased = imports.reduce(0.0) { $0 + $1.volume }
        let energySoldSpot = exports.reduce(0.0) { $0 + ($1.volume - $1.matchEnergy) }
        let energySoldP2P = exports.reduce(0.0) { $0 + $1.matchEnergy }

        // Import costs (purchases)
        let spotCost = imports.reduce(0.0) { $0 + $1.settle + $1.matchAmount }
        let networkEnergy = imports.reduce(0.0) { $0 + $1.networkEnergy }
        let certificates = imports.reduce(0.0) { $0 + $1.certificateAmt }
        let lvFee = imports.reduce(0.0) { $0 + $1.localvoltsFee }

        // Network access: dailyConnection is unreliable in QtyReport (inflated 5-27× at any resolution).
        // Use raw value when reasonable, otherwise estimate from LV fee (which is always correct).
        // Portal shows access=70.29c/day, LV fee=$1.10/day → ratio 0.6364 ex-GST.
        let rawNetworkAccess = imports.reduce(0.0) { $0 + $1.dailyConnection + $1.standing + $1.meterCapital + $1.meterNonCapital }
        let networkAccess = rawNetworkAccess <= lvFee ? rawNetworkAccess : lvFee * 0.6364

        // Export revenue (sales)
        let spotRevenue = exports.reduce(0.0) { $0 + $1.settle }
        let p2pRevenue = exports.reduce(0.0) { $0 + $1.matchAmount }
        let fitTopUp = (imports + exports).reduce(0.0) { $0 + $1.feedInTopUp }

        // Emissions
        let co2e = (imports + exports).reduce(0.0) { $0 + $1.co2e }

        let dateStr = self.first?.date ?? ""

        return LVCashflowSummary(
            date: dateStr,
            records: self.count,
            energyPurchasedKwh: energyPurchased,
            energySoldSpotKwh: energySoldSpot,
            energySoldP2PKwh: energySoldP2P,
            spotEnergyCostExGST: spotCost,
            networkEnergyCostExGST: networkEnergy,
            networkAccessCostExGST: networkAccess,
            certificatesCostExGST: certificates,
            localvoltsFeeExGST: lvFee,
            spotEnergyRevenue: spotRevenue,
            p2pMatchedRevenue: p2pRevenue,
            feedInTopUp: fitTopUp,
            emissions: co2e
        )
    }
}
