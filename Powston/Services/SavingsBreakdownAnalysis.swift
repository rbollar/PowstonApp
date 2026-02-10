//
//  SavingsBreakdownAnalysis.swift
//  Powston
//
//  Analysis engine for savings breakdown with battery expansion modeling
//
//  UPDATED: Now uses API-sourced actual cost for accuracy, removed fake Powston simulation
//

import Foundation
import SwiftUI
import Combine
import GRDB

// MARK: - Comparison Mode

enum PaybackComparisonMode: String, CaseIterable {
    case flatRate = "Flat Rate"
    case tou = "Time of Use"
}

// MARK: - Result Types

struct SavingsBreakdownResult: Codable {
    let analysisDate: Date
    let periodDays: Int
    
    // Core savings (three tiers: grid → solar → battery, plus actual)
    let gridOnlyCost: Double
    let solarOnlyCost: Double
    let dumbBatteryCost: Double
    let actualCost: Double
    let supplyCost: Double
    
    // Flat rate comparison
    let flatRateCost: Double
    let flatBuyRate: Double
    let flatSellRate: Double
    
    // Energy totals
    let totalImportKwh: Double
    let totalExportKwh: Double
    let totalPvGenerationKwh: Double
    let totalConsumptionKwh: Double
    
    // Derived metrics
    let selfConsumptionPercent: Double
    let batteryUtilizationPercent: Double
    let avgExportPrice: Double
    let avgImportPrice: Double
    
    // Battery expansion analysis
    let expansionAnalysis: [BatteryExpansionPoint]
    
    // Current config
    let currentBatteryCapacity: Double
    
    // Data quality
    let usedDerivedData: Bool
    
    // Exceptional days outside analysis window
    let exceptionalDaysTotal: Double
    let exceptionalDaysCount: Int

    // Computed savings (each tier measures incremental value)
    var solarSavings: Double { gridOnlyCost - solarOnlyCost }
    var batterySavings: Double { solarOnlyCost - dumbBatteryCost }
    var powstonSavings: Double { dumbBatteryCost - actualCost }  // Value of smart scheduling
    var totalSavings: Double { gridOnlyCost - actualCost }
    var flatRateSavings: Double { flatRateCost - actualCost }
    
    var dailyAvgSavings: Double { periodDays > 0 ? totalSavings / Double(periodDays) : 0 }
    var dailyAvgPowstonValue: Double { periodDays > 0 ? powstonSavings / Double(periodDays) : 0 }
}

struct BatteryExpansionPoint: Identifiable, Codable {
    var id: String { "\(capacityKwh)" }
    
    let capacityKwh: Double
    let dailyCost: Double          // Dumb battery daily cost at this capacity
    let powstonDailyCost: Double   // Projected Powston daily cost (using actual benefit ratio)
    let totalCost: Double          // Dumb battery period cost
    let marginalSavings: Double
    let savingsPerAddedKwh: Double
    let isCurrentCapacity: Bool
    
    // TOU baseline payback (vs solar-only on TOU)
    let paybackYears: Double?
    let tenYearROI: Double?
    let powstonPaybackYears: Double?
    let powstonTenYearROI: Double?
    let powstonPaybackWithSpikesYears: Double?
    
    // Flat rate baseline payback (vs solar-only on flat rate)
    let paybackYearsFlatRate: Double?
    let powstonPaybackYearsFlatRate: Double?
    let powstonPaybackWithSpikesYearsFlatRate: Double?
    
    enum CodingKeys: String, CodingKey {
        case capacityKwh
        case dailyCost
        case powstonDailyCost
        case totalCost
        case marginalSavings
        case savingsPerAddedKwh
        case isCurrentCapacity
        case paybackYears
        case tenYearROI
        case powstonPaybackYears
        case powstonTenYearROI
        case powstonPaybackWithSpikesYears
        case paybackYearsFlatRate
        case powstonPaybackYearsFlatRate
        case powstonPaybackWithSpikesYearsFlatRate
    }
}

// MARK: - Analysis Engine

@MainActor
class SavingsBreakdownAnalysis: ObservableObject {
    @Published var result: SavingsBreakdownResult?
    @Published var isAnalyzing = false
    @Published var progress: String = ""
    @Published var error: String?
    
    private let cacheKey = "savings_breakdown_cache"
    
    // MARK: - Run Analysis
    
    func runAnalysis(api: PowstonAPI, config: AnalysisConfig) async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        error = nil
        progress = "Checking cached data..."
        
        defer { isAnalyzing = false }
        
        // Use Powston timezone for date calculations (same as HistoryView)
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        // End = last complete day (either from API or yesterday)
        // This ensures we don't include partial data from today
        let todayStart = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let latestComplete = api.latestCompleteDataDate ?? yesterday
        let endDate = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: latestComplete) ?? latestComplete)
        
        // Start = 60 days before at midnight
        guard let startDate = calendar.date(byAdding: .day, value: -60, to: endDate) else {
            error = "Failed to calculate date range"
            return
        }
        
        print("📅 SavingsBreakdown date range: \(startDate) to \(endDate) (latestComplete: \(latestComplete))")
        
        let siteId = api.selectedSite?.id ?? 0
        let dataStore = PowstonDataStore.shared
        
        // Check if we have the latest complete day's data
        let hasLatestData = dataStore.hasMeterRecordsForDate(siteId: siteId, date: latestComplete)
        
        let records: [MeterRecord]
        
        if hasLatestData {
            // We have recent data - just load from cache, no API call
            progress = "Loading from cache..."
            let cached = dataStore.getMeterRecordsLocal(siteId: siteId, from: startDate, to: endDate)
            records = cached.map { $0.toMeterRecord() }
            print("📦 SavingsBreakdown: Using \(cached.count) cached records (have yesterday)")
        } else {
            // Need to fetch the gap - find most recent cached date
            progress = "Fetching recent data..."
            
            let mostRecentCached = dataStore.getMostRecentMeterRecordDate(siteId: siteId)
            
            let fetchFrom: Date
            if let mostRecent = mostRecentCached, mostRecent > startDate {
                fetchFrom = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: mostRecent)) ?? startDate
                print("📡 SavingsBreakdown: Fetching gap from \(fetchFrom) to \(endDate)")
            } else {
                fetchFrom = startDate
                print("📡 SavingsBreakdown: Fetching full range")
            }
            
            // Fetch only the missing portion
            _ = await api.fetchMeterRecords(fromDate: fetchFrom, toDate: endDate)
            
            // Now load full 60 days from cache
            let cached = dataStore.getMeterRecordsLocal(siteId: siteId, from: startDate, to: endDate)
            records = cached.map { $0.toMeterRecord() }
            print("📦 SavingsBreakdown: Loaded \(cached.count) records after gap fill")
        }
        
        guard !records.isEmpty else {
            error = "No meter records available"
            return
        }
        
        progress = "Loading price data..."
        
        // Fetch action records to get buy/sell prices per interval
        let actions = PowstonDataStore.shared.fetchActions(siteId: siteId, from: startDate, to: endDate)
        
        // Build price lookup by interval time
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var pricesByInterval: [String: (buy: Double, sell: Double)] = [:]
        for action in actions {
            let key = isoFormatter.string(from: action.intervalTime)
            if let buy = action.buyPrice, let sell = action.sellPrice {
                pricesByInterval[key] = (buy: buy, sell: sell)
            }
        }

        if let firstKey = pricesByInterval.keys.first {
            print("DEBUG: Sample pricesByInterval key = \(firstKey)")
        }
        
        // Get flat rates from settings
        let flatBuyRate = UserDefaults.standard.double(forKey: "comparison_buy_rate")
        let flatSellRate = UserDefaults.standard.double(forKey: "comparison_sell_rate")
        let buyRate = flatBuyRate > 0 ? flatBuyRate : 33.0
        let sellRate = flatSellRate > 0 ? flatSellRate : 5.0
        
        // Calculate supply cost
        let periodDays = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 60
        let totalFixedCosts = records.compactMap { $0.fixedCosts }.reduce(0, +)
        let totalSupplyCost: Double
        if totalFixedCosts > 1.0 {
            totalSupplyCost = totalFixedCosts / 100.0
        } else {
            totalSupplyCost = 1.0 * Double(periodDays)
        }
        
        let inverterLimitKw = Double(api.selectedSite?.inverterPower ?? 10000) / 1000.0
        
        // =====================================================
        // FETCH AUTHORITATIVE ACTUAL FROM API
        // This ensures we use the same "actual" as Powston web
        // =====================================================
        progress = "Fetching actual performance data..."
        
        let actualNetFromAPI: Double?
                let apiImportKwh: Double?
                let apiExportKwh: Double?
                if let summary = await api.fetchCustomRangeSummary(startDate: startDate, endDate: endDate) {
                    actualNetFromAPI = summary.netProfitDollars
                    apiImportKwh = summary.totalEnergyImported
                    apiExportKwh = summary.totalEnergyExported
                    print("📊 SavingsBreakdown: Actual net from API = $\(String(format: "%.2f", summary.netProfitDollars)), import=\(summary.totalEnergyImported) kWh, export=\(summary.totalEnergyExported) kWh")
                } else {
                    actualNetFromAPI = nil
                    apiImportKwh = nil
                    apiExportKwh = nil
                    print("⚠️ SavingsBreakdown: Could not fetch API summary, using meterrecords")
                }
        
        // Calculate energy metrics (used for fallback and other metrics)
                let energyMetrics = calculateEnergyMetrics(records: records, batteryCapacity: config.batteryCapacityKWh)
                
                // Use API values if available, otherwise fall back to meter record calculations
                let totalImportKwh = apiImportKwh ?? energyMetrics.importKwh
                let totalExportKwh = apiExportKwh ?? energyMetrics.exportKwh
                
                progress = "Analyzing \(records.count) intervals (\(pricesByInterval.count) with prices)..."
        
        // Run core analysis
        let calculator = SavingsAnalysisCalculator()
        let baseAnalysis: SavingsAnalysis?
        
        if let actualNet = actualNetFromAPI {
            // Use API actual for accuracy (includes all fees, reconciled data)
            baseAnalysis = calculator.calculateForPeriod(
                            records: records,
                            pricesByInterval: pricesByInterval,
                            batteryCapacityKwh: config.batteryCapacityKWh,
                            supplyCost: totalSupplyCost,
                            totalImportKwh: totalImportKwh,
                            totalExportKwh: totalExportKwh,
                            actualNetFromAPI: actualNet,
                            flatBuyRate: buyRate,
                            flatSellRate: sellRate,
                            inverterLimitKw: inverterLimitKw
                        )
        } else {
            // Fallback to meterrecords-derived actual
            baseAnalysis = calculator.calculate(
                            records: records,
                            pricesByInterval: pricesByInterval,
                            batteryCapacityKwh: config.batteryCapacityKWh,
                            supplyCost: totalSupplyCost,
                            totalImportKwh: totalImportKwh,
                            totalExportKwh: totalExportKwh,
                            flatBuyRate: buyRate,
                            flatSellRate: sellRate,
                            inverterLimitKw: inverterLimitKw
                        )
        }
        
        guard let analysis = baseAnalysis else {
            error = "Insufficient data for analysis (need 90%+ coverage)"
            return
        }
        
        progress = "Finding exceptional days..."
        
        // Find exceptional days outside the 60-day window
        let exceptionalDays = await findExceptionalDays(
            api: api,
            siteId: siteId,
            excludeStart: startDate,
            excludeEnd: endDate
        )
        
        progress = "Running expansion analysis..."

        let storedFloorPrice = UserDefaults.standard.double(forKey: "optimal_floor_price")
        let floorPrice = storedFloorPrice > 0 ? storedFloorPrice : 7.0

        let expansionPoints = runExpansionAnalysis(
                    records: records,
                    pricesByInterval: pricesByInterval,
                    currentCapacity: config.batteryCapacityKWh,
                    supplyCost: totalSupplyCost,
                    totalImportKwh: totalImportKwh,
                    totalExportKwh: totalExportKwh,
                    flatBuyRate: buyRate,
                    flatSellRate: sellRate,
                    inverterLimitKw: inverterLimitKw,
                    floorPrice: floorPrice,
                    actualCost: analysis.actualCost,
                    exceptionalDaysTotal: exceptionalDays.total
                )
        
        progress = "Complete"

        let usedDerivedData = analysis.usedDerivedData || energyMetrics.usedDerivedData

        result = SavingsBreakdownResult(
            analysisDate: Date(),
            periodDays: periodDays,
            gridOnlyCost: analysis.gridOnlyCost,
            solarOnlyCost: analysis.solarOnlyCost,
            dumbBatteryCost: analysis.dumbBatteryCost,
            actualCost: analysis.actualCost,
            supplyCost: totalSupplyCost,
            flatRateCost: analysis.flatRateCost,
            flatBuyRate: buyRate,
            flatSellRate: sellRate,
            totalImportKwh: energyMetrics.importKwh,
            totalExportKwh: energyMetrics.exportKwh,
            totalPvGenerationKwh: energyMetrics.pvKwh,
            totalConsumptionKwh: energyMetrics.consumptionKwh,
            selfConsumptionPercent: energyMetrics.selfConsumptionPercent,
            batteryUtilizationPercent: energyMetrics.batteryUtilization,
            avgExportPrice: energyMetrics.avgExportPrice,
            avgImportPrice: energyMetrics.avgImportPrice,
            expansionAnalysis: expansionPoints,
            currentBatteryCapacity: config.batteryCapacityKWh,
            usedDerivedData: usedDerivedData,
            exceptionalDaysTotal: exceptionalDays.total,
            exceptionalDaysCount: exceptionalDays.count
        )
        
        cacheResult(result!, config: config)
    }
    
    // MARK: - Find Exceptional Days
    
    private func findExceptionalDays(
        api: PowstonAPI,
        siteId: Int,
        excludeStart: Date,
        excludeEnd: Date
    ) async -> (total: Double, count: Int) {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = powstonTimezone()
        
        let excludeStartStr = dayFormatter.string(from: excludeStart)
        
        let db = await MainActor.run { PowstonDataStore.shared.dbQueue }
        guard let db = db else { return (0, 0) }
        
        do {
            let results: [(date: String, netProfit: Double)] = try await db.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT date, total_earnings, total_costs
                        FROM day_summaries
                        WHERE site_id = ?
                        AND date < ?
                        ORDER BY date DESC
                        """,
                    arguments: [siteId, excludeStartStr]
                )
                
                return rows.map { row in
                    let earnings = (row["total_earnings"] as? Double ?? 0) / 100.0
                    let costs = (row["total_costs"] as? Double ?? 0) / 100.0
                    let netProfit = earnings - costs
                    let dateStr = row["date"] as? String ?? "?"
                    return (date: dateStr, netProfit: netProfit)
                }
            }
            
            let threshold = 100.0
            var exceptionalTotal = 0.0
            var exceptionalCount = 0
            
            for result in results {
                if result.netProfit > threshold {
                    exceptionalTotal += result.netProfit
                    exceptionalCount += 1
                    print("DEBUG: Exceptional day \(result.date): $\(String(format: "%.2f", result.netProfit))")
                }
            }
            
            return (exceptionalTotal, exceptionalCount)
        } catch {
            print("❌ findExceptionalDays failed: \(error)")
            return (0, 0)
        }
    }
    
    // MARK: - Energy Metrics
    
    private func calculateEnergyMetrics(records: [MeterRecord], batteryCapacity: Double) -> (
        importKwh: Double,
        exportKwh: Double,
        pvKwh: Double,
        consumptionKwh: Double,
        selfConsumptionPercent: Double,
        batteryUtilization: Double,
        avgExportPrice: Double,
        avgImportPrice: Double,
        usedDerivedData: Bool
    ) {
        var totalImport: Double = 0
        var totalExport: Double = 0
        var totalPv: Double = 0
        var totalConsumption: Double = 0
        var totalSelfConsumed: Double = 0
        var totalExportEarnings: Double = 0
        var totalImportCosts: Double = 0
        var maxSoc: Double = 0
        var minSoc: Double = 100
        
        let intervalHours = 5.0 / 60.0
        
        let hasValidInverterData = records.contains { record in
            if let pv = record.ppvGeneration, pv > 0,
               let consumption = record.houseConsumption, consumption > 0 {
                return true
            }
            return false
        }
        
        for record in records {
            totalImport += record.effectiveImport
            totalExport += record.effectiveExport
            
            let importKwh = record.effectiveImport
            let exportKwh = record.effectiveExport
            
            if hasValidInverterData {
                if let pv = record.ppvGeneration, pv > 0 {
                    let pvKwh = (pv / 1000.0) * intervalHours
                    totalPv += pvKwh
                    
                    if let consumption = record.houseConsumption, consumption > 0 {
                        let consumptionKwh = (consumption / 1000.0) * intervalHours
                        totalConsumption += consumptionKwh
                        totalSelfConsumed += min(pvKwh, consumptionKwh)
                    }
                } else {
                    if let consumption = record.houseConsumption, consumption > 0 {
                        totalConsumption += (consumption / 1000.0) * intervalHours
                    }
                }
            } else if importKwh > 0.001 || exportKwh > 0.001 {
                let estimatedSelfConsumptionRatio = 0.3
                
                if exportKwh > 0.001 {
                    let estimatedPvGeneration = exportKwh / (1.0 - estimatedSelfConsumptionRatio)
                    let estimatedPvConsumed = estimatedPvGeneration * estimatedSelfConsumptionRatio
                    totalPv += estimatedPvGeneration
                    totalConsumption += importKwh + estimatedPvConsumed
                    totalSelfConsumed += estimatedPvConsumed
                } else {
                    totalConsumption += importKwh
                }
            }
            
            totalExportEarnings += record.earnings ?? 0
            totalImportCosts += record.costs ?? 0
            
            if let soc = record.startBatterySoc {
                maxSoc = max(maxSoc, soc)
                minSoc = min(minSoc, soc)
            }
        }
        
        let selfConsumption = totalPv > 0 ? (totalSelfConsumed / totalPv) * 100 : 0
        let batterySwing = maxSoc - minSoc
        let batteryUtilization = batteryCapacity > 0 ? (batterySwing / 100.0) * 100 : 0
        let avgExportPrice = totalExport > 0 ? totalExportEarnings / totalExport : 0
        let avgImportPrice = totalImport > 0 ? totalImportCosts / totalImport : 0
        
        return (
            totalImport,
            totalExport,
            totalPv,
            totalConsumption,
            min(100, max(0, selfConsumption)),
            min(100, batteryUtilization),
            avgExportPrice,
            avgImportPrice,
            !hasValidInverterData
        )
    }
    
    // MARK: - Expansion Analysis
    
    private func runExpansionAnalysis(
            records: [MeterRecord],
            pricesByInterval: [String: (buy: Double, sell: Double)],
            currentCapacity: Double,
            supplyCost: Double,
            totalImportKwh: Double,
            totalExportKwh: Double,
            flatBuyRate: Double,
            flatSellRate: Double,
            inverterLimitKw: Double,
            floorPrice: Double,
            actualCost: Double,
            exceptionalDaysTotal: Double
        ) -> [BatteryExpansionPoint] {
        let calculator = SavingsAnalysisCalculator()
        let periodDays = 60.0
        let intervalHours = 5.0 / 60.0
        
        // === Calculate true solar-only energy profile ===
        // This simulates what would happen with solar but NO battery
        var solarOnlyImportKwh: Double = 0
        var solarOnlyExportKwh: Double = 0
        var solarOnlyTouCost: Double = 0  // Import cost - export earnings at TOU rates
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        
        for record in records {
            // Get solar and load for this interval
            let solarW = record.ppvGeneration ?? 0
            let loadW = record.houseConsumption ?? 0
            
            let solarKwh = (solarW / 1000.0) * intervalHours
            let loadKwh = (loadW / 1000.0) * intervalHours
            
            // Get TOU prices for this interval - intervalTime is already a String
            let key = record.intervalTime
            let prices = pricesByInterval[key]
            let buyPrice = prices?.buy ?? 30.0  // Default if missing
            let sellPrice = prices?.sell ?? 5.0
            
            if loadKwh > solarKwh {
                // Solar can't meet load - must import the shortfall
                let shortfall = loadKwh - solarKwh
                solarOnlyImportKwh += shortfall
                solarOnlyTouCost += shortfall * buyPrice  // Cost in cents
            } else {
                // Excess solar - export the surplus
                let surplus = solarKwh - loadKwh
                solarOnlyExportKwh += surplus
                solarOnlyTouCost -= surplus * sellPrice  // Earnings in cents (negative cost)
            }
        }
        
        // Convert TOU cost from cents to dollars and add supply
        let solarOnlyTouCostDollars = solarOnlyTouCost / 100.0 + supplyCost
        
        // Flat rate solar-only: same energy profile, flat prices
        let solarOnlyFlatCostDollars = (solarOnlyImportKwh * flatBuyRate - solarOnlyExportKwh * flatSellRate) / 100.0 + supplyCost
        
        print("DEBUG: Solar-only profile - Import: \(String(format: "%.1f", solarOnlyImportKwh)) kWh, Export: \(String(format: "%.1f", solarOnlyExportKwh)) kWh")
        print("DEBUG: Solar-only costs - TOU: $\(String(format: "%.2f", solarOnlyTouCostDollars)), Flat: $\(String(format: "%.2f", solarOnlyFlatCostDollars))")
        
        // ROI assumptions
        let storedCostPerKwh = UserDefaults.standard.double(forKey: "battery_cost_per_kwh")
        let costPerKwh = storedCostPerKwh > 0 ? storedCostPerKwh : 800.0

        let storedDiscountRate = UserDefaults.standard.double(forKey: "battery_discount_rate")
        let discountRate = storedDiscountRate > 0 ? storedDiscountRate : 0.05

        let lifespanYears = 10.0
        
        // Get claimed rebate settings
        let claimedRebate = UserDefaults.standard.bool(forKey: "stc_rebate_claimed")
        let claimedKwh = UserDefaults.standard.double(forKey: "stc_rebate_kwh")
        let claimedYear = UserDefaults.standard.integer(forKey: "stc_rebate_year")

        print("DEBUG: Rebate settings - claimed=\(claimedRebate), kwh=\(claimedKwh), year=\(claimedYear)")
        
        // Calculate the rebate amount if claimed
        let claimedRebateAmount: Double
        let effectiveYear = claimedYear >= 2025 ? claimedYear : 2025
        if claimedRebate && claimedKwh > 0 {
            let stcFactor = stcFactorForYear(effectiveYear)
            claimedRebateAmount = claimedKwh * stcFactor * 40.0
            print("DEBUG: STC rebate claimed: \(claimedKwh) kWh in \(effectiveYear), factor=\(stcFactor), amount=$\(claimedRebateAmount)")
        } else {
            claimedRebateAmount = 0
        }
        
        // Rebate band: from (currentCapacity - claimedKwh) to currentCapacity
        let rebateBandStart = max(0, currentCapacity - claimedKwh)
        let rebateBandEnd = currentCapacity
        
        // Get dumb battery cost at current capacity for Powston benefit calculation
            guard let currentAnalysis = calculator.calculate(
                        records: records,
                        pricesByInterval: pricesByInterval,
                        batteryCapacityKwh: currentCapacity,
                        supplyCost: supplyCost,
                        totalImportKwh: totalImportKwh,
                        totalExportKwh: totalExportKwh,
                        flatBuyRate: flatBuyRate,
                        flatSellRate: flatSellRate,
                        inverterLimitKw: inverterLimitKw
                    ) else { return [] }
        
        let dumbCostAtCurrent = currentAnalysis.dumbBatteryCost
        
        // === Anchor to actual Powston performance ===
        // This is the key insight: we use REAL actual cost, not simulated
        let actualDailyCost = actualCost / periodDays
        let dumbDailyCostAtCurrent = dumbCostAtCurrent / periodDays
        let powstonBenefitPerDay = dumbDailyCostAtCurrent - actualDailyCost
        
        print("DEBUG: Powston benefit = $\(String(format: "%.2f", powstonBenefitPerDay))/day (dumb: $\(String(format: "%.2f", dumbDailyCostAtCurrent)) - actual: $\(String(format: "%.2f", actualDailyCost)))")
        
        // Test capacities
        let maxCapacity = max(150.0, currentCapacity + 50.0)
        let capacities: [Double]
        if currentCapacity <= 30 {
            capacities = stride(from: 10.0, through: maxCapacity, by: 10.0).map { $0 }
        } else {
            capacities = stride(from: 25.0, through: maxCapacity, by: 25.0).map { $0 }
        }
        
        var points: [BatteryExpansionPoint] = []
        
        for capacity in capacities {
            guard let analysis = calculator.calculate(
                            records: records,
                            pricesByInterval: pricesByInterval,
                            batteryCapacityKwh: capacity,
                            supplyCost: supplyCost,
                            totalImportKwh: totalImportKwh,
                            totalExportKwh: totalExportKwh,
                            flatBuyRate: flatBuyRate,
                            flatSellRate: flatSellRate,
                            inverterLimitKw: inverterLimitKw
                        ) else { continue }
            
            let dumbBatteryCost = analysis.dumbBatteryCost
            let dumbDailyCost = dumbBatteryCost / periodDays
            let isCurrentCapacity = abs(capacity - currentCapacity) < 12.5
            
            // === Calculate battery cost with rebate ===
            var batteryCost = capacity * costPerKwh
            
            if claimedRebateAmount > 0 {
                let overlapStart = max(rebateBandStart, 0)
                let overlapEnd = min(rebateBandEnd, capacity)
                let rebateableKwh = max(0, overlapEnd - overlapStart)
                
                if rebateableKwh > 0 && claimedKwh > 0 {
                    let rebatePerKwh = claimedRebateAmount / claimedKwh
                    let applicableRebate = rebateableKwh * rebatePerKwh
                    batteryCost = max(0, batteryCost - applicableRebate)
                }
            }
            
            // === Powston benefit projection ===
            // Scale the actual observed benefit to other capacities
            let powstonBenefit: Double
            if capacity <= currentCapacity {
                // Smaller battery: benefit scales linearly down
                powstonBenefit = powstonBenefitPerDay * (capacity / currentCapacity)
            } else {
                // Larger battery: diminishing returns on extra capacity
                let baselineBenefit = powstonBenefitPerDay
                let extraCapacity = capacity - currentCapacity
                let extraBenefitFactor = log(1 + extraCapacity / currentCapacity) / log(2)
                let extraBenefit = powstonBenefitPerDay * 0.3 * extraBenefitFactor
                powstonBenefit = baselineBenefit + extraBenefit
            }
            
            let powstonDailyCost = max(0, dumbDailyCost - powstonBenefit)
            let powstonTotalCost = powstonDailyCost * periodDays
            
            // ============================================
            // TOU BASELINE CALCULATIONS (vs solar-only on TOU)
            // ============================================
            
            // Dumb Battery (TOU)
            let dumbCumulativeSavingsTOU = solarOnlyTouCostDollars - dumbBatteryCost
            let dumbAnnualSavingsTOU = dumbCumulativeSavingsTOU * (365.0 / periodDays)

            let dumbPaybackYears: Double?
            let dumbTenYearROI: Double?

            if dumbAnnualSavingsTOU > 0 && batteryCost > 0 {
                dumbPaybackYears = batteryCost / dumbAnnualSavingsTOU
                
                var npvSavings = 0.0
                for year in 1...Int(lifespanYears) {
                    npvSavings += dumbAnnualSavingsTOU / pow(1 + discountRate, Double(year))
                }
                dumbTenYearROI = ((npvSavings - batteryCost) / batteryCost) * 100
            } else {
                dumbPaybackYears = nil
                dumbTenYearROI = nil
            }

            // Powston (TOU)
            let powstonCumulativeSavingsTOU = solarOnlyTouCostDollars - powstonTotalCost
            let powstonAnnualSavingsTOU = powstonCumulativeSavingsTOU * (365.0 / periodDays)

            let powstonPaybackYears: Double?
            let powstonTenYearROI: Double?

            if powstonAnnualSavingsTOU > 0 && batteryCost > 0 {
                powstonPaybackYears = batteryCost / powstonAnnualSavingsTOU
                
                var npvSavings = 0.0
                for year in 1...Int(lifespanYears) {
                    npvSavings += powstonAnnualSavingsTOU / pow(1 + discountRate, Double(year))
                }
                powstonTenYearROI = ((npvSavings - batteryCost) / batteryCost) * 100
            } else {
                powstonPaybackYears = nil
                powstonTenYearROI = nil
            }
            
            // Powston with Spikes (TOU)
            let powstonPaybackWithSpikesYears: Double?
            if powstonAnnualSavingsTOU > 0 && batteryCost > 0 && exceptionalDaysTotal > 0 {
                let adjustedAnnualSavings = powstonAnnualSavingsTOU + exceptionalDaysTotal
                powstonPaybackWithSpikesYears = batteryCost / adjustedAnnualSavings
            } else {
                powstonPaybackWithSpikesYears = powstonPaybackYears
            }

            // ============================================
            // FLAT RATE BASELINE CALCULATIONS (vs solar-only on flat rate)
            // ============================================
            
            // Dumb Battery (Flat Rate)
            let dumbCumulativeSavingsFlatRate = solarOnlyFlatCostDollars - dumbBatteryCost
            let dumbAnnualSavingsFlatRate = dumbCumulativeSavingsFlatRate * (365.0 / periodDays)

            let dumbPaybackYearsFlatRate: Double?
            if dumbAnnualSavingsFlatRate > 0 && batteryCost > 0 {
                dumbPaybackYearsFlatRate = batteryCost / dumbAnnualSavingsFlatRate
            } else {
                dumbPaybackYearsFlatRate = nil
            }

            // Powston (Flat Rate)
            let powstonCumulativeSavingsFlatRate = solarOnlyFlatCostDollars - powstonTotalCost
            let powstonAnnualSavingsFlatRate = powstonCumulativeSavingsFlatRate * (365.0 / periodDays)

            let powstonPaybackYearsFlatRate: Double?
            if powstonAnnualSavingsFlatRate > 0 && batteryCost > 0 {
                powstonPaybackYearsFlatRate = batteryCost / powstonAnnualSavingsFlatRate
            } else {
                powstonPaybackYearsFlatRate = nil
            }

            // Powston with Spikes (Flat Rate) - Note: spikes not capturable on flat rate
            // but we include for consistency, user would need to switch to TOU to capture
            let powstonPaybackWithSpikesYearsFlatRate: Double?
            if powstonAnnualSavingsFlatRate > 0 && batteryCost > 0 && exceptionalDaysTotal > 0 {
                let adjustedAnnualSavingsFlatRate = powstonAnnualSavingsFlatRate + exceptionalDaysTotal
                powstonPaybackWithSpikesYearsFlatRate = batteryCost / adjustedAnnualSavingsFlatRate
            } else {
                powstonPaybackWithSpikesYearsFlatRate = powstonPaybackYearsFlatRate
            }
            
            // Marginal savings (using TOU baseline for consistency)
            let marginalSavings = points.last.map { solarOnlyTouCostDollars - dumbBatteryCost - (solarOnlyTouCostDollars - $0.totalCost) } ?? (solarOnlyTouCostDollars - dumbBatteryCost)
            
            points.append(BatteryExpansionPoint(
                capacityKwh: capacity,
                dailyCost: dumbDailyCost,
                powstonDailyCost: powstonDailyCost,
                totalCost: dumbBatteryCost,
                marginalSavings: marginalSavings,
                savingsPerAddedKwh: marginalSavings / 25.0 / periodDays,
                isCurrentCapacity: isCurrentCapacity,
                paybackYears: dumbPaybackYears,
                tenYearROI: dumbTenYearROI,
                powstonPaybackYears: powstonPaybackYears,
                powstonTenYearROI: powstonTenYearROI,
                powstonPaybackWithSpikesYears: powstonPaybackWithSpikesYears,
                paybackYearsFlatRate: dumbPaybackYearsFlatRate,
                powstonPaybackYearsFlatRate: powstonPaybackYearsFlatRate,
                powstonPaybackWithSpikesYearsFlatRate: powstonPaybackWithSpikesYearsFlatRate
            ))
        }
        
        return points
    }
    
    // MARK: - STC Factor Lookup
    
    private func stcFactorForYear(_ year: Int) -> Double {
        switch year {
        case 2025: return 9.3
        case 2026: return 8.4
        case 2027: return 7.4
        case 2028: return 6.5
        case 2029: return 5.6
        case 2030: return 4.7
        default: return 0
        }
    }
  
    // MARK: - Caching
    
    func getCachedResult(config: AnalysisConfig) -> SavingsBreakdownResult? {
        let key = "\(cacheKey)_\(config.siteId)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(SavingsBreakdownResult.self, from: data) else {
            return nil
        }
        
        let age = Date().timeIntervalSince(cached.analysisDate)
        guard age < 24 * 3600 else { return nil }
        
        return cached
    }
    
    private func cacheResult(_ result: SavingsBreakdownResult, config: AnalysisConfig) {
        let key = "\(cacheKey)_\(config.siteId)"
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    func clearCache(config: AnalysisConfig) {
        let key = "\(cacheKey)_\(config.siteId)"
        UserDefaults.standard.removeObject(forKey: key)
    }
}
