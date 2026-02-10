//
//  RetailerComparisonAnalysis.swift
//  Powston
//
//  Analysis engine comparing LocalVolts vs Flowpower costs
//  using actual meter data to simulate what Flowpower would have cost
//

import Foundation
import SwiftUI
import Combine
import GRDB

// MARK: - Analysis Engine

@MainActor
class RetailerComparisonAnalysis: ObservableObject {
    @Published var result: RetailerComparisonResult?
    @Published var isAnalyzing = false
    @Published var progress: String = ""
    @Published var error: String?

    private let cacheKey = "retailer_comparison_cache"

    // MARK: - Run Analysis

    func runAnalysis(api: PowstonAPI, config: AnalysisConfig, flowpowerConfig: FlowpowerConfig) async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        error = nil
        progress = "Checking cached data..."

        defer { isAnalyzing = false }

        // Use Powston timezone for date calculations
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        // End = last complete day
        let todayStart = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let latestComplete = api.latestCompleteDataDate ?? yesterday
        let endDate = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: latestComplete) ?? latestComplete)

        // Start = 60 days before
        guard let startDate = calendar.date(byAdding: .day, value: -60, to: endDate) else {
            error = "Failed to calculate date range"
            return
        }

        print("📅 RetailerComparison date range: \(startDate) to \(endDate)")

        let siteId = config.siteId
        let dataStore = PowstonDataStore.shared

        // Check how much data we have cached
        let cachedRecords = dataStore.getMeterRecordsLocal(siteId: siteId, from: startDate, to: endDate)
        let targetIntervals = 60 * 288  // 60 days worth
        let cachedCompleteness = Double(cachedRecords.count) / Double(targetIntervals)

        let records: [MeterRecord]

        if cachedCompleteness >= 0.8 {
            // We have enough cached data
            progress = "Loading from cache..."
            records = cachedRecords.map { $0.toMeterRecord() }
            print("📦 RetailerComparison: Using \(cachedRecords.count) cached records (\(Int(cachedCompleteness * 100))%)")
        } else {
            // Need to fetch more data - fetch the full 60 days
            progress = "Fetching 60 days of data..."
            print("📡 RetailerComparison: Fetching data from \(startDate) to \(endDate)")

            _ = await api.fetchMeterRecords(siteId: siteId, fromDate: startDate, toDate: endDate, forceRefresh: false)

            let freshRecords = dataStore.getMeterRecordsLocal(siteId: siteId, from: startDate, to: endDate)
            records = freshRecords.map { $0.toMeterRecord() }
            print("📦 RetailerComparison: After fetch, have \(freshRecords.count) records")
        }

        guard !records.isEmpty else {
            error = "No meter records available"
            return
        }

        // Check data completeness
        let periodDays = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 60
        let expectedIntervals = periodDays * 288  // 288 5-min intervals per day
        let completeness = Double(records.count) / Double(expectedIntervals) * 100

        print("📊 RetailerComparison: \(records.count) records, \(periodDays) days, \(Int(completeness))% coverage")

        // Require at least 1 day of data (288 intervals) to produce meaningful results
        guard records.count >= 288 else {
            let hours = records.count * 5 / 60  // Each record is 5 minutes
            error = "Need at least 1 day of data (have ~\(hours) hours)"
            return
        }

        progress = "Calculating LocalVolts costs..."

        // Calculate LocalVolts actual costs
        let localVoltsCost = calculateLocalVoltsCost(records: records)

        progress = "Simulating Flowpower costs..."

        // Calculate Flowpower simulated costs
        let flowpowerCost = calculateFlowpowerCost(
            records: records,
            config: flowpowerConfig,
            periodDays: periodDays
        )

        progress = "Comparing retailers..."

        // Calculate comparison metrics
        let difference = flowpowerCost.netCost - localVoltsCost.netCost  // Positive = LV cheaper
        let cheaperRetailer: Retailer = difference >= 0 ? .localVolts : .flowpower
        let dailyDifference = abs(difference) / Double(periodDays)
        let annualizedDifference = dailyDifference * 365

        // Count missing RRP intervals
        let missingRrp = records.filter { $0.rrp == nil }.count

        // Energy totals
        let totalImport = records.reduce(0.0) { $0 + $1.effectiveImport }
        let totalExport = records.reduce(0.0) { $0 + $1.effectiveExport }

        progress = "Complete"

        result = RetailerComparisonResult(
            analysisDate: Date(),
            periodDays: periodDays,
            totalImportKwh: totalImport,
            totalExportKwh: totalExport,
            localVoltsActual: localVoltsCost,
            flowpowerSimulated: flowpowerCost,
            difference: difference,
            cheaperRetailer: cheaperRetailer,
            dailyDifference: dailyDifference,
            annualizedDifference: annualizedDifference,
            dataCompleteness: completeness,
            missingRrpIntervals: missingRrp
        )

        cacheResult(result!, config: config, flowpowerConfig: flowpowerConfig)
    }

    // MARK: - LocalVolts Cost Calculation

    private func calculateLocalVoltsCost(records: [MeterRecord]) -> LocalVoltsCost {
        var totalImportCost: Double = 0       // cents
        var totalExportRevenue: Double = 0    // cents
        var totalDailyCharges: Double = 0     // cents
        var totalImportKwh: Double = 0
        var totalExportKwh: Double = 0

        for record in records {
            let importKwh = record.effectiveImport
            let exportKwh = record.effectiveExport

            totalImportKwh += importKwh
            totalExportKwh += exportKwh

            // Costs and earnings are already in cents from the API
            if let costs = record.costs {
                totalImportCost += costs
            }

            if let earnings = record.earnings {
                totalExportRevenue += earnings
            }

            // Fixed costs are daily supply charges (in cents)
            if let fixed = record.fixedCosts {
                totalDailyCharges += fixed
            }
        }

        // Convert cents to dollars
        let importCostDollars = totalImportCost / 100.0
        let exportRevenueDollars = totalExportRevenue / 100.0
        let dailyChargesDollars = totalDailyCharges / 100.0

        // P2P revenue is included in earnings - we can estimate it as the premium above spot
        // For now, we'll approximate it as 10% of export revenue (typical P2P premium)
        // In a real implementation, we'd track P2P trades separately
        let estimatedP2PRevenue = exportRevenueDollars * 0.10

        let netCost = importCostDollars - exportRevenueDollars + dailyChargesDollars

        let avgImportPrice = totalImportKwh > 0 ? totalImportCost / totalImportKwh : 0
        let avgExportPrice = totalExportKwh > 0 ? totalExportRevenue / totalExportKwh : 0

        return LocalVoltsCost(
            importCost: importCostDollars,
            exportRevenue: exportRevenueDollars,
            dailyCharges: dailyChargesDollars,
            p2pRevenue: estimatedP2PRevenue,
            netCost: netCost,
            avgImportPrice: avgImportPrice,
            avgExportPrice: avgExportPrice
        )
    }

    // MARK: - Flowpower Cost Calculation

    private func calculateFlowpowerCost(
        records: [MeterRecord],
        config: FlowpowerConfig,
        periodDays: Int
    ) -> FlowpowerCost {
        // PEA Calculation: volume-weighted average wholesale price during imports
        var peaSum: Double = 0           // Sum of (RRP * import kWh)
        var totalImportKwh: Double = 0
        var peakExportKwh: Double = 0
        var offPeakExportKwh: Double = 0

        for record in records {
            let importKwh = record.effectiveImport
            let exportKwh = record.effectiveExport

            // PEA calculation: sum of wholesale price * import for each interval
            if importKwh > 0 {
                let rrp = record.rrp ?? 0  // Use 0 if missing (conservative)
                peaSum += rrp * importKwh
                totalImportKwh += importKwh
            }

            // Export window check
            if exportKwh > 0, let date = record.date {
                if config.isInExportWindow(date: date) {
                    peakExportKwh += exportKwh
                } else {
                    offPeakExportKwh += exportKwh
                }
            }
        }

        // PEA = volume-weighted average wholesale price during imports
        let pea = totalImportKwh > 0 ? peaSum / totalImportKwh : 0

        // Effective import rate = base rate - PEA (but not below 0)
        let effectiveRate = max(0, config.baseImportRate - pea)

        // Import cost in dollars
        let importCost = (totalImportKwh * effectiveRate) / 100.0

        // Export revenue: only peak window exports earn 45c
        let exportRevenue = (peakExportKwh * config.peakExportRate) / 100.0

        // Daily charges
        let totalDailyCharges = config.dailyCharge * Double(periodDays)

        // Net cost
        let netCost = importCost - exportRevenue + totalDailyCharges

        // PEA timing grade based on how low the average wholesale price is
        let grade = calculatePEAGrade(pea: pea)

        let peaDetails = PEADetails(
            totalWholesaleValue: peaSum,
            totalImportKwh: totalImportKwh,
            volumeWeightedAvgPrice: pea,
            importTimingGrade: grade
        )

        return FlowpowerCost(
            baseImportRate: config.baseImportRate,
            peaAdjustment: pea,
            effectiveImportRate: effectiveRate,
            importCost: importCost,
            peakExportKwh: peakExportKwh,
            offPeakExportKwh: offPeakExportKwh,
            exportRevenue: exportRevenue,
            dailyCharge: config.dailyCharge,
            totalDailyCharges: totalDailyCharges,
            netCost: netCost,
            peaDetails: peaDetails
        )
    }

    private func calculatePEAGrade(pea: Double) -> String {
        // Grade based on how low the PEA is (lower = better import timing)
        // These thresholds are based on typical AEMO spot prices
        switch pea {
        case ..<5:
            return "A"   // Excellent - importing at very low prices
        case 5..<10:
            return "B"   // Good
        case 10..<15:
            return "C"   // Average
        default:
            return "D"   // Poor - importing at peak prices
        }
    }

    // MARK: - Caching

    func getCachedResult(config: AnalysisConfig, flowpowerConfig: FlowpowerConfig) -> RetailerComparisonResult? {
        let key = "\(cacheKey)_\(config.siteId)_\(flowpowerConfig.networkRegion.rawValue)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(RetailerComparisonResult.self, from: data) else {
            return nil
        }

        // Cache valid for 24 hours
        let age = Date().timeIntervalSince(cached.analysisDate)
        guard age < 24 * 3600 else { return nil }

        return cached
    }

    private func cacheResult(_ result: RetailerComparisonResult, config: AnalysisConfig, flowpowerConfig: FlowpowerConfig) {
        let key = "\(cacheKey)_\(config.siteId)_\(flowpowerConfig.networkRegion.rawValue)"
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func clearCache(config: AnalysisConfig, flowpowerConfig: FlowpowerConfig) {
        let key = "\(cacheKey)_\(config.siteId)_\(flowpowerConfig.networkRegion.rawValue)"
        UserDefaults.standard.removeObject(forKey: key)
    }
}
