//
//  SavingsBreakdownResult.swift
//  Powston
//
//  Created by Rick Bollar on 1/24/26.
//


//
//  SavingsBreakdownAnalysis.swift
//  Powston
//
//  Analysis engine for savings breakdown with battery expansion modeling
//

import Foundation
import SwiftUI

// MARK: - Result Types

struct SavingsBreakdownResult: Codable {
    let analysisDate: Date
    let periodDays: Int
    
    // Core savings
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
    
    // Computed
    var solarSavings: Double { gridOnlyCost - solarOnlyCost }
    var batterySavings: Double { solarOnlyCost - dumbBatteryCost }
    var powstonSavings: Double { dumbBatteryCost - actualCost }
    var totalSavings: Double { gridOnlyCost - actualCost }
    var flatRateSavings: Double { flatRateCost - actualCost }
    
    var dailyAvgSavings: Double { periodDays > 0 ? totalSavings / Double(periodDays) : 0 }
    var dailyAvgPowstonValue: Double { periodDays > 0 ? powstonSavings / Double(periodDays) : 0 }
}

struct BatteryExpansionPoint: Codable, Identifiable {
    var id: Double { capacityKwh }
    let capacityKwh: Double
    let dailyCost: Double
    let totalCost: Double
    let marginalSavings: Double      // vs previous tier
    let savingsPerAddedKwh: Double   // $/kWh/day for this increment
    let isCurrentCapacity: Bool
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
        progress = "Loading meter records..."
        
        defer { isAnalyzing = false }
        
        // Get 60 days of data
        let calendar = Calendar.current
        let endDate = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        guard let startDate = calendar.date(byAdding: .day, value: -60, to: endDate) else {
            error = "Failed to calculate date range"
            return
        }
        
        // Fetch records
        let records = await api.fetchMeterRecords(fromDate: startDate, toDate: endDate)
        
        guard !records.isEmpty else {
            error = "No meter records available"
            return
        }
        
        progress = "Analyzing \(records.count) intervals..."
        
        // Get flat rates from settings
        let flatBuyRate = UserDefaults.standard.double(forKey: "comparison_buy_rate")
        let flatSellRate = UserDefaults.standard.double(forKey: "comparison_sell_rate")
        let buyRate = flatBuyRate > 0 ? flatBuyRate : 33.0
        let sellRate = flatSellRate > 0 ? flatSellRate : 5.0
        
        // Calculate supply cost for period
        let supplyCostPerDay = config.supplyCostCentsPerDay / 100.0
        let periodDays = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 60
        let totalSupplyCost = supplyCostPerDay * Double(periodDays)
        
        // Run core analysis
        let calculator = SavingsAnalysisCalculator()
        guard let baseAnalysis = calculator.calculate(
            records: records,
            batteryCapacityKwh: config.batteryCapacityKwh,
            supplyCost: totalSupplyCost,
            flatBuyRate: buyRate,
            flatSellRate: sellRate
        ) else {
            error = "Insufficient data for analysis (need 90%+ coverage)"
            return
        }
        
        progress = "Running expansion analysis..."
        
        // Calculate energy totals and metrics
        let energyMetrics = calculateEnergyMetrics(records: records, batteryCapacity: config.batteryCapacityKwh)
        
        // Run battery expansion analysis
        let expansionPoints = runExpansionAnalysis(
            records: records,
            currentCapacity: config.batteryCapacityKwh,
            supplyCost: totalSupplyCost,
            flatBuyRate: buyRate,
            flatSellRate: sellRate
        )
        
        progress = "Complete"
        
        result = SavingsBreakdownResult(
            analysisDate: Date(),
            periodDays: periodDays,
            gridOnlyCost: baseAnalysis.gridOnlyCost,
            solarOnlyCost: baseAnalysis.solarOnlyCost,
            dumbBatteryCost: baseAnalysis.dumbBatteryCost,
            actualCost: baseAnalysis.actualCost,
            supplyCost: totalSupplyCost,
            flatRateCost: baseAnalysis.flatRateCost,
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
            currentBatteryCapacity: config.batteryCapacityKwh
        )
        
        // Cache result
        cacheResult(result!, config: config)
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
        avgImportPrice: Double
    ) {
        var totalImport: Double = 0
        var totalExport: Double = 0
        var totalPv: Double = 0
        var totalConsumption: Double = 0
        var totalExportEarnings: Double = 0
        var totalImportCosts: Double = 0
        var maxSoc: Double = 0
        var minSoc: Double = 100
        
        let intervalHours = 5.0 / 60.0
        
        for record in records {
            totalImport += record.effectiveImport
            totalExport += record.effectiveExport
            
            if let pv = record.ppvGeneration {
                totalPv += (pv / 1000.0) * intervalHours
            }
            if let consumption = record.houseConsumption {
                totalConsumption += (consumption / 1000.0) * intervalHours
            }
            
            totalExportEarnings += record.earnings ?? 0
            totalImportCosts += record.costs ?? 0
            
            if let soc = record.startBatterySoc {
                maxSoc = max(maxSoc, soc)
                minSoc = min(minSoc, soc)
            }
        }
        
        let selfConsumption = totalPv > 0 ? ((totalPv - totalExport) / totalPv) * 100 : 0
        let batterySwing = maxSoc - minSoc
        let batteryUtilization = batteryCapacity > 0 ? (batterySwing / 100.0) * 100 : 0
        
        let avgExportPrice = totalExport > 0 ? totalExportEarnings / totalExport : 0
        let avgImportPrice = totalImport > 0 ? totalImportCosts / totalImport : 0
        
        return (
            totalImport,
            totalExport,
            totalPv,
            totalConsumption,
            min(100, selfConsumption),
            min(100, batteryUtilization),
            avgExportPrice,
            avgImportPrice
        )
    }
    
    // MARK: - Expansion Analysis
    
    private func runExpansionAnalysis(
        records: [MeterRecord],
        currentCapacity: Double,
        supplyCost: Double,
        flatBuyRate: Double,
        flatSellRate: Double
    ) -> [BatteryExpansionPoint] {
        let calculator = SavingsAnalysisCalculator()
        
        // Test capacities from 25 kWh to 250 kWh in 25 kWh increments
        let capacities = stride(from: 25.0, through: 250.0, by: 25.0).map { $0 }
        
        var points: [BatteryExpansionPoint] = []
        var previousCost: Double?
        
        for capacity in capacities {
            guard let analysis = calculator.calculate(
                records: records,
                batteryCapacityKwh: capacity,
                supplyCost: supplyCost,
                flatBuyRate: flatBuyRate,
                flatSellRate: flatSellRate
            ) else { continue }
            
            let totalCost = analysis.dumbBatteryCost
            let marginalSavings = previousCost.map { $0 - totalCost } ?? 0
            let savingsPerKwh = marginalSavings / 25.0  // Per kWh added in this increment
            
            let isCurrentCapacity = abs(capacity - currentCapacity) < 12.5  // Within half a step
            
            points.append(BatteryExpansionPoint(
                capacityKwh: capacity,
                dailyCost: totalCost / 60.0,  // 60-day period to daily
                totalCost: totalCost,
                marginalSavings: marginalSavings,
                savingsPerAddedKwh: savingsPerKwh / 60.0,  // Daily per kWh
                isCurrentCapacity: isCurrentCapacity
            ))
            
            previousCost = totalCost
        }
        
        return points
    }
    
    // MARK: - Caching
    
    func getCachedResult(config: AnalysisConfig) -> SavingsBreakdownResult? {
        let key = "\(cacheKey)_\(config.siteId)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(SavingsBreakdownResult.self, from: data) else {
            return nil
        }
        
        // Check if cache is fresh (less than 24 hours old)
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