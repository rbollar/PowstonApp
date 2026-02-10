//
//  DecisionEfficiencyAnalysis.swift
//  Powston
//
//  Decision Efficiency analysis engine
//  Swift port of powston_decision_efficiency.py
//
//  Analyzes historical inverter actions to identify:
//  1. Export efficiency - Did we sell at the best available prices?
//  2. Import efficiency - Did we buy at the cheapest available prices?
//  3. Peak capture rate - Did we export during high-price periods?
//  4. Missed opportunities - High-price periods where we held instead of exported
//  5. Achieved opportunities - High-price exports and cheap imports we captured
//

import Foundation
import Combine

// MARK: - Analysis Engine

@MainActor
class DecisionEfficiencyAnalysis: ObservableObject {
    
    // MARK: - Published State
    
    @Published var isAnalyzing = false
    @Published var progress: String = ""
    @Published var result: DecisionEfficiencyResult?
    @Published var error: String?
    
    // MARK: - Dependencies
    
    private var dataStore: PowstonDataStore { PowstonDataStore.shared }
    private let cacheKey = "decision_efficiency_cache"
    
    // MARK: - Configuration
    
    // Thresholds (can be made user-configurable later)
    static let highSellPrice: Double = 20.0      // Consider this a "good" sell price (cents)
    static let lowBuyPrice: Double = 5.0         // Consider this a "good" buy price (cents)
    static let forecastWindowHours: Int = 4      // Hours to look ahead in forecast
    static let nearBestThreshold: Double = 3.0   // Within this many cents = "near best"
    
    // MARK: - Run Analysis
    
    func analyzeDecisionEfficiency(config: AnalysisConfig, latestCompleteDataDate: Date? = nil) async -> DecisionEfficiencyResult? {
        isAnalyzing = true
        error = nil
        progress = "Loading data..."

        var calendar = Calendar.current
        calendar.timeZone = config.timezone

        // Use latestCompleteDataDate if available, otherwise fall back to yesterday
        let endDate = latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: Date())!
        let startDate = calendar.date(byAdding: .day, value: -config.analysisWindowDays, to: endDate)!
        
        // Fetch all records
        progress = "Fetching records..."
        let allRecords = dataStore.fetchActions(siteId: config.siteId, from: startDate, to: endDate)
        print("📊 Decision Efficiency: loaded \(allRecords.count) records")
        
        guard !allRecords.isEmpty else {
            error = "No data available for analysis"
            isAnalyzing = false
            return nil
        }
        
        // Check forecast data availability
        let recordsWithForecasts = allRecords.filter { $0.hasForecastData }
        print("📊 Records with forecast data: \(recordsWithForecasts.count)")
        
        if let oldest = recordsWithForecasts.map({ $0.intervalTime }).min(),
           let newest = recordsWithForecasts.map({ $0.intervalTime }).max() {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            print("📊 Forecast data range: \(df.string(from: oldest)) to \(df.string(from: newest))")
        }
        
        if recordsWithForecasts.count < 100 {
            error = "Insufficient forecast data. Need to re-sync historical data."
            isAnalyzing = false
            return nil
        }
        
        // Analyze exports
        progress = "Analyzing exports..."
        let exportAnalysis = analyzeExports(records: allRecords, config: config)
        
        // Analyze imports
        progress = "Analyzing imports..."
        let importAnalysis = analyzeImports(records: allRecords, config: config)
        
        // Analyze missed opportunities FIRST (needed for peak performance calculation)
        progress = "Finding missed opportunities..."
        let missedOpportunities = analyzeMissedOpportunities(records: allRecords, config: config)
        
        // Analyze achieved opportunities
        progress = "Finding achieved opportunities..."
        let achievedOpportunities = analyzeAchievedOpportunities(records: allRecords, config: config)
        
        // Analyze peak performance (uses missed opportunities for price capture)
        progress = "Analyzing peak performance..."
        let peakAnalysis = analyzePeakPerformance(records: allRecords, config: config, missedOpportunities: missedOpportunities)
        
        // Calculate overall metrics
        progress = "Calculating summary..."
        
        // === EXPORT PRICE CAPTURE ===
        // Actual earnings vs (actual + missed opportunity value)
        let actualExportValueCents = exportAnalysis.totalEarnings
        let missedExportValueCents = missedOpportunities.missedHighExportValue * 100  // API returns dollars
        let theoreticalExportValueCents = actualExportValueCents + missedExportValueCents
        let exportPriceCapture = theoreticalExportValueCents > 0
            ? (actualExportValueCents / theoreticalExportValueCents) * 100
            : 100
        
        print("📊 Export capture: $\(String(format: "%.2f", actualExportValueCents/100)) actual + $\(String(format: "%.2f", missedExportValueCents/100)) missed = $\(String(format: "%.2f", theoreticalExportValueCents/100)) theoretical")
        print("📊 Export price capture: \(String(format: "%.1f", exportPriceCapture))%")
        
        // === IMPORT EFFICIENCY ===
        // What we spent vs what we would have spent if we'd also captured cheap imports
        // Missed cheap imports = periods where price was ≤5¢ but we didn't import
        // Estimate: if we'd imported during those periods at cheap prices instead of our avg price
        let actualImportCostCents = importAnalysis.totalCosts
        let avgImportPrice = importAnalysis.avgPrice ?? 0
        
        // Estimate savings from missed cheap imports
        // Each missed cheap import could have saved (avgPrice - cheapPrice) per kWh
        // Assume ~0.5 kWh per missed 5-min interval, at avg missed price vs our avg
        let missedCheapCount = missedOpportunities.missedCheapImports
        let avgMissedCheapPrice = missedOpportunities.topMissedImports.isEmpty ? Self.lowBuyPrice :
            missedOpportunities.topMissedImports.map { $0.price }.reduce(0, +) / Double(missedOpportunities.topMissedImports.count)
        let estimatedMissedImportKwh = Double(missedCheapCount) * 0.5  // ~0.5 kWh per interval
        let potentialSavingsCents = estimatedMissedImportKwh * (avgImportPrice - avgMissedCheapPrice)
        
        // Efficiency = what we could have spent / what we actually spent
        // If we'd captured cheap imports, we'd have spent less
        let theoreticalImportCostCents = max(actualImportCostCents - potentialSavingsCents, 0)
        let importPriceEfficiency = actualImportCostCents > 0
            ? (theoreticalImportCostCents / actualImportCostCents) * 100
            : 100
        
        print("📊 Import efficiency: $\(String(format: "%.2f", actualImportCostCents/100)) actual, could have been $\(String(format: "%.2f", theoreticalImportCostCents/100))")
        print("📊 Import price efficiency: \(String(format: "%.1f", importPriceEfficiency))%")
        
        // === ARBITRAGE SPREAD ===
        let realizedSpread = (exportAnalysis.avgPrice ?? 0) - (importAnalysis.avgPrice ?? 0)
        
        // Theoretical spread: weighted average including missed opportunities
        let actualExportCount = exportAnalysis.count
        let actualExportAvg = exportAnalysis.avgPrice ?? 0
        let missedExportCount = missedOpportunities.missedHighExports
        let missedExportAvg = missedOpportunities.topMissedExports.isEmpty ? actualExportAvg :
            missedOpportunities.topMissedExports.map { $0.price }.reduce(0, +) / Double(missedOpportunities.topMissedExports.count)
        
        let actualImportCount = importAnalysis.count
        let actualImportAvg = importAnalysis.avgPrice ?? 0
        let missedImportCount = missedOpportunities.missedCheapImports
        let missedImportAvg = missedOpportunities.topMissedImports.isEmpty ? actualImportAvg :
            missedOpportunities.topMissedImports.map { $0.price }.reduce(0, +) / Double(missedOpportunities.topMissedImports.count)
        
        // If we'd captured missed exports, our avg sell price would include those high prices
        let theoreticalExportAvg: Double
        if actualExportCount + missedExportCount > 0 {
            theoreticalExportAvg = (actualExportAvg * Double(actualExportCount) + missedExportAvg * Double(missedExportCount)) / Double(actualExportCount + missedExportCount)
        } else {
            theoreticalExportAvg = actualExportAvg
        }
        
        // If we'd captured missed imports, our avg buy price would include those cheap prices
        let theoreticalImportAvg: Double
        if actualImportCount + missedImportCount > 0 {
            theoreticalImportAvg = (actualImportAvg * Double(actualImportCount) + missedImportAvg * Double(missedImportCount)) / Double(actualImportCount + missedImportCount)
        } else {
            theoreticalImportAvg = actualImportAvg
        }
        
        let theoreticalSpread = theoreticalExportAvg - theoreticalImportAvg
        let spreadEfficiency = theoreticalSpread > 0 ? min((realizedSpread / theoreticalSpread) * 100, 100) : 100
        
        print("📊 Spread: \(String(format: "%.1f", realizedSpread))¢ realized, \(String(format: "%.1f", theoreticalSpread))¢ theoretical = \(String(format: "%.0f", spreadEfficiency))% capture")
        
        // === UPDATE ANALYSIS WITH CALCULATED VALUES ===
        // Create updated versions with price capture/efficiency filled in
        let updatedExportAnalysis = ExportEfficiencyAnalysis(
            count: exportAnalysis.count,
            totalKwh: exportAnalysis.totalKwh,
            totalEarnings: exportAnalysis.totalEarnings,
            avgPrice: exportAnalysis.avgPrice,
            minPrice: exportAnalysis.minPrice,
            maxPrice: exportAnalysis.maxPrice,
            atBestCount: exportAnalysis.atBestCount,
            nearBestCount: exportAnalysis.nearBestCount,
            avgBestAvailable: theoreticalExportAvg,
            priceCapture: exportPriceCapture
        )
        
        let updatedImportAnalysis = ImportEfficiencyAnalysis(
            count: importAnalysis.count,
            totalKwh: importAnalysis.totalKwh,
            totalCosts: importAnalysis.totalCosts,
            avgPrice: importAnalysis.avgPrice,
            minPrice: importAnalysis.minPrice,
            maxPrice: importAnalysis.maxPrice,
            atBestCount: importAnalysis.atBestCount,
            nearBestCount: importAnalysis.nearBestCount,
            avgBestAvailable: theoreticalImportAvg,
            priceEfficiency: importPriceEfficiency
        )
        
        // Build result
        let result = DecisionEfficiencyResult(
            config: config,
            analyzedAt: Date(),
            dateRange: DateInterval(start: startDate, end: endDate),
            
            totalRecords: allRecords.count,
            recordsWithForecasts: recordsWithForecasts.count,
            daysAnalyzed: config.analysisWindowDays,
            
            exportAnalysis: updatedExportAnalysis,
            importAnalysis: updatedImportAnalysis,
            peakAnalysis: peakAnalysis,
            missedOpportunities: missedOpportunities,
            achievedOpportunities: achievedOpportunities,
            
            realizedSpread: realizedSpread,
            theoreticalSpread: theoreticalSpread,
            spreadCaptureEfficiency: spreadEfficiency
        )
        
        self.result = result
        self.progress = "Complete"
        self.isAnalyzing = false
        
        // Cache result
        cacheResult(result, config: config)
        
        return result
    }
    
    private func cacheResult(_ result: DecisionEfficiencyResult, config: AnalysisConfig) {
        let key = "\(cacheKey)_\(config.siteId)"
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    // MARK: - Check Cached Result
    func getCachedResult(config: AnalysisConfig) -> DecisionEfficiencyResult? {
        let key = "\(cacheKey)_\(config.siteId)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(DecisionEfficiencyResult.self, from: data) else {
            return nil
        }
        
        // Check if cache is fresh (less than 24 hours old)
        let age = Date().timeIntervalSince(cached.analyzedAt)
        guard age < 24 * 3600 else { return nil }
        
        return cached
    }
    
    // MARK: - Export Analysis

    private func analyzeExports(records: [ActionRecord], config: AnalysisConfig) -> ExportEfficiencyAnalysis {
        let exports = records.filter { $0.isExport && ($0.energyExport ?? 0) > 0.1 }
        
        guard !exports.isEmpty else {
            return ExportEfficiencyAnalysis(
                count: 0, totalKwh: 0, totalEarnings: 0,
                avgPrice: nil, minPrice: nil, maxPrice: nil,
                atBestCount: 0, nearBestCount: 0,
                avgBestAvailable: nil, priceCapture: nil
            )
        }
        
        let prices = exports.compactMap { $0.sellPrice }
        let totalKwh = exports.reduce(0.0) { $0 + ($1.energyExport ?? 0) }
        
        // Calculate actual earnings from price × kWh (cents)
        let totalEarningsCents = exports.reduce(0.0) { total, record in
            let kwh = record.energyExport ?? 0
            let price = record.sellPrice ?? 0
            return total + (kwh * price)
        }
        
        let avgPrice = prices.isEmpty ? nil : prices.average
        
        // Count exports at high prices (≥20¢)
        let highPriceExports = exports.filter { ($0.sellPrice ?? 0) >= Self.highSellPrice }
        let atBestCount = highPriceExports.count
        
        // Within 3¢ of 20¢ threshold (≥17¢)
        let nearBestCount = exports.filter { ($0.sellPrice ?? 0) >= (Self.highSellPrice - Self.nearBestThreshold) }.count
        
        print("📊 Export analysis: \(exports.count) exports, \(String(format: "%.1f", totalKwh)) kWh")
        print("📊 Export earnings: \(String(format: "%.0f", totalEarningsCents))¢ = $\(String(format: "%.2f", totalEarningsCents / 100))")
        print("📊 Export avgPrice: \(String(format: "%.1f", avgPrice ?? 0))¢, highPrice: \(atBestCount), nearBest: \(nearBestCount)")
        
        return ExportEfficiencyAnalysis(
            count: exports.count,
            totalKwh: totalKwh,
            totalEarnings: totalEarningsCents,  // In cents
            avgPrice: avgPrice,
            minPrice: prices.min(),
            maxPrice: prices.max(),
            atBestCount: atBestCount,
            nearBestCount: nearBestCount,
            avgBestAvailable: Self.highSellPrice,  // Benchmark is the "good price" threshold
            priceCapture: nil  // Will be calculated after missed opportunities
        )
    }

    // MARK: - Import Analysis

    private func analyzeImports(records: [ActionRecord], config: AnalysisConfig) -> ImportEfficiencyAnalysis {
        let imports = records.filter { $0.isImport && ($0.energyImport ?? 0) > 0.1 }
        
        guard !imports.isEmpty else {
            return ImportEfficiencyAnalysis(
                count: 0, totalKwh: 0, totalCosts: 0,
                avgPrice: nil, minPrice: nil, maxPrice: nil,
                atBestCount: 0, nearBestCount: 0,
                avgBestAvailable: nil, priceEfficiency: nil
            )
        }
        
        let prices = imports.compactMap { $0.buyPrice }
        let totalKwh = imports.reduce(0.0) { $0 + ($1.energyImport ?? 0) }
        
        // Calculate actual costs from price × kWh (cents)
        let totalCostsCents = imports.reduce(0.0) { total, record in
            let kwh = record.energyImport ?? 0
            let price = record.buyPrice ?? 0
            return total + (kwh * price)
        }
        
        let avgPrice = prices.isEmpty ? nil : prices.average
        
        // Count imports at cheap prices (≤5¢)
        let cheapImports = imports.filter { ($0.buyPrice ?? Double.infinity) <= Self.lowBuyPrice }
        let atBestCount = cheapImports.count
        
        // Within 3¢ of 5¢ threshold (≤8¢)
        let nearBestCount = imports.filter { ($0.buyPrice ?? Double.infinity) <= (Self.lowBuyPrice + Self.nearBestThreshold) }.count
        
        print("📊 Import analysis: \(imports.count) imports, \(String(format: "%.1f", totalKwh)) kWh")
        print("📊 Import costs: \(String(format: "%.0f", totalCostsCents))¢ = $\(String(format: "%.2f", totalCostsCents / 100))")
        print("📊 Import avgPrice: \(String(format: "%.1f", avgPrice ?? 0))¢, cheapImports: \(atBestCount), nearBest: \(nearBestCount)")
        
        return ImportEfficiencyAnalysis(
            count: imports.count,
            totalKwh: totalKwh,
            totalCosts: totalCostsCents,  // In cents
            avgPrice: avgPrice,
            minPrice: prices.min(),
            maxPrice: prices.max(),
            atBestCount: atBestCount,
            nearBestCount: nearBestCount,
            avgBestAvailable: Self.lowBuyPrice,  // Benchmark is the "cheap price" threshold
            priceEfficiency: nil  // Will be calculated after missed opportunities
        )
    }
    
    // MARK: - Peak Performance Analysis
        
    private func analyzePeakPerformance(records: [ActionRecord], config: AnalysisConfig, missedOpportunities: MissedOpportunitiesAnalysis) -> PeakPerformanceAnalysis {
        var calendar = Calendar.current
        calendar.timeZone = config.timezone
        
        let peakRecords = records.filter { record in
            let hour = calendar.component(.hour, from: record.intervalTime)
            return hour >= config.peakStartHour && hour < config.peakEndHour
        }
        
        let peakExports = peakRecords.filter { $0.isExport && ($0.energyExport ?? 0) > 0.1 }
        let highPriceRecords = peakRecords.filter { ($0.sellPrice ?? 0) >= Self.highSellPrice }
        let highPriceExported = highPriceRecords.filter { $0.isExport && ($0.energyExport ?? 0) > 0.1 }
        
        // Calculate peak earnings from price × kWh (cents) - consistent with export analysis
        let peakEarningsCents = peakExports.reduce(0.0) { total, record in
            let kwh = record.energyExport ?? 0
            let price = record.sellPrice ?? 0
            return total + (kwh * price)
        }
        
        let captureRate = highPriceRecords.isEmpty ? 0 : Double(highPriceExported.count) / Double(highPriceRecords.count) * 100
        
        // Filter missed opportunities to only those during peak hours
        let peakMissedExports = missedOpportunities.topMissedExports.filter { opp in
            let hour = calendar.component(.hour, from: opp.timestamp)
            return hour >= config.peakStartHour && hour < config.peakEndHour
        }
        
        // Calculate missed value during peak (estimatedMissedValue is in dollars, convert to cents)
        let peakMissedValueCents = peakMissedExports.reduce(0.0) { $0 + $1.estimatedMissedValue } * 100
        
        // Also account for non-top missed opportunities proportionally
        // topMissedExports is only top 10, but missedHighExports is total count
        let missedExportRatio = missedOpportunities.topMissedExports.isEmpty ? 0 :
            Double(missedOpportunities.missedHighExports) / Double(missedOpportunities.topMissedExports.count)
        let estimatedTotalPeakMissedCents = peakMissedValueCents * min(missedExportRatio, 2.0)  // Cap at 2x to avoid outliers
        
        let theoreticalPeakEarnings = peakEarningsCents + estimatedTotalPeakMissedCents
        let priceCapture = theoreticalPeakEarnings > 0
            ? (peakEarningsCents / theoreticalPeakEarnings) * 100
            : 100
        
        print("📊 Peak analysis: \(peakExports.count) exports during \(config.peakStartHour):00-\(config.peakEndHour):00")
        print("📊 Peak earnings: $\(String(format: "%.2f", peakEarningsCents/100)) actual + $\(String(format: "%.2f", estimatedTotalPeakMissedCents/100)) missed = $\(String(format: "%.2f", theoreticalPeakEarnings/100)) theoretical")
        print("📊 Peak price capture: \(String(format: "%.0f", priceCapture))%")
        
        return PeakPerformanceAnalysis(
            peakRecords: peakRecords.count,
            peakExports: peakExports.count,
            peakExportRate: peakRecords.isEmpty ? 0 : Double(peakExports.count) / Double(peakRecords.count) * 100,
            peakEarnings: peakEarningsCents,
            theoreticalEarnings: theoreticalPeakEarnings,
            priceCapture: priceCapture,
            highPricePeriods: highPriceRecords.count,
            highPriceExported: highPriceExported.count,
            highPriceCaptureRate: captureRate
        )
    }
    
    // MARK: - Missed Opportunities Analysis

    private func analyzeMissedOpportunities(records: [ActionRecord], config: AnalysisConfig) -> MissedOpportunitiesAnalysis {
        var missedHighExports: [DecisionMissedOpportunity] = []
        var missedCheapImports: [DecisionMissedOpportunity] = []
        
        var calendar = Calendar.current
        calendar.timeZone = config.timezone
        
        // Use a default floor if decisionValues isn't available
        let defaultFloor: Double = 20.0
        
        for record in records {
            let dv = record.decisionValues  // May be nil for older records
            
            let hour = calendar.component(.hour, from: record.intervalTime)
            let isOvernight = dv?.isOvernight ?? (hour >= 21 || hour < 6)
            let isPeak = hour >= config.peakStartHour && hour < config.peakEndHour
            
            // Get floor from decisionValues, or use default
            let floor = dv?.activeFloor ?? defaultFloor
            
            // Missed high-price export
            // Had SOC above floor, price was good, but didn't export
            if !record.isExport,
               let sellPrice = record.sellPrice,
               sellPrice >= Self.highSellPrice,
               let soc = record.batterySoc,
               soc > floor + 5,
               !isOvernight {
                let availableKwh = (soc - floor) / 100 * config.batteryCapacityKWh
                if availableKwh > 5 {
                    // Calculate potential export based on inverter capacity minus house load
                    let houseLoadKw = (record.housePower ?? 0) / 1000.0
                    let netExportCapacityKw = max(0, config.inverterExportCapacityKw - houseLoadKw)
                    let potentialExportKwh = min(availableKwh, netExportCapacityKw * (5.0 / 60.0))
                    
                    // Extract decisions JSON from valuesJson (may be nil for older records)
                    let decisionsJson = extractDecisionsJson(from: record.valuesJson)
                    
                    missedHighExports.append(DecisionMissedOpportunity(
                        timestamp: record.intervalTime,
                        price: sellPrice,
                        availableKwh: availableKwh,
                        soc: soc,
                        floor: floor,
                        action: record.action,
                        reason: record.reason,
                        decisionChainJson: decisionsJson,
                        houseLoadKw: houseLoadKw,
                        potentialExportKwh: potentialExportKwh
                    ))
                }
            }
            
            // Missed cheap import
            // Needed charge (deficit > 0), price was good, but didn't import
            // Note: Without decisionValues, we can't know daytimeDeficit, so skip if not available
            if !record.isImport,
               let buyPrice = record.buyPrice,
               buyPrice <= Self.lowBuyPrice,
               let soc = record.batterySoc,
               soc < 90,
               !isPeak {
                
                // Only include if we have deficit info, or if SOC is low enough to reasonably assume we needed charge
                let deficit = dv?.daytimeDeficitKwh
                let shouldInclude = (deficit ?? 0) > 5 || (deficit == nil && soc < 50)
                
                if shouldInclude {
                    let houseLoadKw = (record.housePower ?? 0) / 1000.0
                    let decisionsJson = extractDecisionsJson(from: record.valuesJson)
                    
                    missedCheapImports.append(DecisionMissedOpportunity(
                        timestamp: record.intervalTime,
                        price: buyPrice,
                        availableKwh: deficit ?? (90 - soc) / 100 * config.batteryCapacityKWh,
                        soc: soc,
                        floor: floor,
                        action: record.action,
                        reason: record.reason,
                        decisionChainJson: decisionsJson,
                        houseLoadKw: houseLoadKw,
                        potentialExportKwh: nil
                    ))
                }
            }
        }
        
        // Deduplicate by timestamp (multiple inverters create duplicate entries)
        // Keep the one with highest price for exports, lowest for imports
        let uniqueExports = Dictionary(grouping: missedHighExports, by: { $0.timestamp })
            .mapValues { $0.max(by: { $0.price < $1.price })! }
            .values
            .sorted { $0.price > $1.price }
        
        let uniqueImports = Dictionary(grouping: missedCheapImports, by: { $0.timestamp })
            .mapValues { $0.min(by: { $0.price < $1.price })! }
            .values
            .sorted { $0.price < $1.price }
        
        // Recalculate value with deduplicated list
        let uniqueExportValue = uniqueExports.reduce(0.0) { $0 + $1.estimatedMissedValue }
        
        return MissedOpportunitiesAnalysis(
            missedHighExports: uniqueExports.count,
            missedHighExportValue: uniqueExportValue,
            topMissedExports: Array(uniqueExports.prefix(10)),
            missedCheapImports: uniqueImports.count,
            topMissedImports: Array(uniqueImports.prefix(10))
        )
    }
    
    // MARK: - Achieved Opportunities Analysis
    
    private func analyzeAchievedOpportunities(records: [ActionRecord], config: AnalysisConfig) -> AchievedOpportunitiesAnalysis {
        var achievedHighExports: [DecisionAchievedOpportunity] = []
        var achievedCheapImports: [DecisionAchievedOpportunity] = []
        
        var calendar = Calendar.current
        calendar.timeZone = config.timezone
        
        let defaultFloor: Double = 20.0
        
        for record in records {
            let dv = record.decisionValues
            let floor = dv?.activeFloor ?? defaultFloor
            
            // Achieved high-price export
            // Actually exported at a good price (≥20¢)
            if record.isExport,
               let sellPrice = record.sellPrice,
               sellPrice >= Self.highSellPrice,
               let energyKwh = record.energyExport,
               energyKwh > 0.1 {
                
                let houseLoadKw = (record.housePower ?? 0) / 1000.0
                let decisionsJson = extractDecisionsJson(from: record.valuesJson)
                let earningsDollars = sellPrice * energyKwh / 100.0
                
                achievedHighExports.append(DecisionAchievedOpportunity(
                    timestamp: record.intervalTime,
                    price: sellPrice,
                    energyKwh: energyKwh,
                    soc: record.batterySoc ?? 0,
                    floor: floor,
                    earnings: earningsDollars,
                    action: record.action,
                    reason: record.reason,
                    decisionChainJson: decisionsJson,
                    houseLoadKw: houseLoadKw
                ))
            }
            
            // Achieved cheap import
            // Actually imported at a good price (≤5¢)
            if record.isImport,
               let buyPrice = record.buyPrice,
               buyPrice <= Self.lowBuyPrice,
               let energyKwh = record.energyImport,
               energyKwh > 0.1 {
                
                let houseLoadKw = (record.housePower ?? 0) / 1000.0
                let decisionsJson = extractDecisionsJson(from: record.valuesJson)
                let costDollars = buyPrice * energyKwh / 100.0
                
                achievedCheapImports.append(DecisionAchievedOpportunity(
                    timestamp: record.intervalTime,
                    price: buyPrice,
                    energyKwh: energyKwh,
                    soc: record.batterySoc ?? 0,
                    floor: floor,
                    earnings: costDollars,  // Cost paid (low = good)
                    action: record.action,
                    reason: record.reason,
                    decisionChainJson: decisionsJson,
                    houseLoadKw: houseLoadKw
                ))
            }
        }
        
        // Deduplicate by timestamp (multiple inverters)
        let uniqueExports = Dictionary(grouping: achievedHighExports, by: { $0.timestamp })
            .mapValues { $0.max(by: { $0.price < $1.price })! }
            .values
            .sorted { $0.price > $1.price }
        
        let uniqueImports = Dictionary(grouping: achievedCheapImports, by: { $0.timestamp })
            .mapValues { $0.min(by: { $0.price < $1.price })! }
            .values
            .sorted { $0.price < $1.price }
        
        // Calculate totals
        let totalExportValue = uniqueExports.reduce(0.0) { $0 + $1.earnings }
        let totalImportCost = uniqueImports.reduce(0.0) { $0 + $1.earnings }
        
        return AchievedOpportunitiesAnalysis(
            achievedHighExports: uniqueExports.count,
            achievedHighExportValue: totalExportValue,
            topAchievedExports: Array(uniqueExports.prefix(10)),
            achievedCheapImports: uniqueImports.count,
            achievedCheapImportCost: totalImportCost,
            topAchievedImports: Array(uniqueImports.prefix(10))
        )
    }
    
    /// Extract the "decisions" object JSON from the full valuesJson
    private func extractDecisionsJson(from valuesJson: String?) -> String? {
        guard let json = valuesJson,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDecisions = parsed["decisions"] else {
            return nil
        }
        
        // Case 1: decisions is already a valid JSON container (dictionary or array)
        if JSONSerialization.isValidJSONObject(rawDecisions),
           let decisionsData = try? JSONSerialization.data(withJSONObject: rawDecisions),
           let decisionsString = String(data: decisionsData, encoding: .utf8) {
            return decisionsString
        }
        
        // Case 2: decisions is a String that may itself contain JSON; attempt to parse it
        if let decisionsString = rawDecisions as? String,
           let nestedData = decisionsString.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: nestedData),
           JSONSerialization.isValidJSONObject(nested),
           let nestedDataOut = try? JSONSerialization.data(withJSONObject: nested),
           let nestedStringOut = String(data: nestedDataOut, encoding: .utf8) {
            return nestedStringOut
        }
        
        // Case 3: Not a JSON-serializable structure; ignore to avoid crash
        return nil
    }
}

// MARK: - Result Models

struct DecisionEfficiencyResult: Codable, Sendable {
    let config: AnalysisConfig
    let analyzedAt: Date
    let dateRange: DateInterval
    
    // Data summary
    let totalRecords: Int
    let recordsWithForecasts: Int
    let daysAnalyzed: Int
    
    // Component analyses
    let exportAnalysis: ExportEfficiencyAnalysis
    let importAnalysis: ImportEfficiencyAnalysis
    let peakAnalysis: PeakPerformanceAnalysis
    let missedOpportunities: MissedOpportunitiesAnalysis
    let achievedOpportunities: AchievedOpportunitiesAnalysis?
    
    // Arbitrage metrics
    let realizedSpread: Double      // avg sell - avg buy (cents)
    let theoreticalSpread: Double   // best available spread
    let spreadCaptureEfficiency: Double  // % of theoretical achieved
    
    enum CodingKeys: String, CodingKey {
        case config
        case analyzedAt
        case dateRange
        case totalRecords
        case recordsWithForecasts
        case daysAnalyzed
        case exportAnalysis
        case importAnalysis
        case peakAnalysis
        case missedOpportunities
        case achievedOpportunities
        case realizedSpread
        case theoreticalSpread
        case spreadCaptureEfficiency
    }
    
    // MARK: - Computed Metrics
    
    /// Overall efficiency score (0-100)
    var overallScore: Int {
        var score: Double = 0
        var weights: Double = 0
        
        // Export price capture (40% weight)
        if let capture = exportAnalysis.priceCapture {
            score += min(capture, 100) * 0.4
            weights += 0.4
        }
        
        // Import efficiency (20% weight)
        if let efficiency = importAnalysis.priceEfficiency {
            score += min(efficiency, 100) * 0.2
            weights += 0.2
        }
        
        // Peak capture (25% weight)
        score += min(peakAnalysis.priceCapture, 100) * 0.25
        weights += 0.25
        
        // Spread efficiency (15% weight)
        score += min(spreadCaptureEfficiency, 100) * 0.15
        weights += 0.15
        
        return weights > 0 ? Int(score / weights) : 0
    }
    
    /// Letter grade based on overall score
    var grade: String {
        switch overallScore {
        case 90...100: return "A"
        case 80..<90: return "B+"
        case 70..<80: return "B"
        case 60..<70: return "C+"
        case 50..<60: return "C"
        default: return "D"
        }
    }
    
    /// Net earnings (exports - imports) in cents
    var netEarnings: Double {
        exportAnalysis.totalEarnings - importAnalysis.totalCosts
    }
}

// MARK: - Component Analysis Models

struct ExportEfficiencyAnalysis: Codable, Sendable {
    let count: Int
    let totalKwh: Double
    let totalEarnings: Double  // In cents
    let avgPrice: Double?
    let minPrice: Double?
    let maxPrice: Double?
    let atBestCount: Int
    let nearBestCount: Int
    let avgBestAvailable: Double?
    let priceCapture: Double?  // % of best price achieved
    
    enum CodingKeys: String, CodingKey {
        case count
        case totalKwh
        case totalEarnings
        case avgPrice
        case minPrice
        case maxPrice
        case atBestCount
        case nearBestCount
        case avgBestAvailable
        case priceCapture
    }
    
    var atBestPercent: Double {
        count > 0 ? Double(atBestCount) / Double(count) * 100 : 0
    }
    
    var nearBestPercent: Double {
        count > 0 ? Double(nearBestCount) / Double(count) * 100 : 0
    }
}

struct ImportEfficiencyAnalysis: Codable, Sendable {
    let count: Int
    let totalKwh: Double
    let totalCosts: Double  // In cents
    let avgPrice: Double?
    let minPrice: Double?
    let maxPrice: Double?
    let atBestCount: Int
    let nearBestCount: Int
    let avgBestAvailable: Double?
    let priceEfficiency: Double?  // % (best/actual, higher = better)
    
    enum CodingKeys: String, CodingKey {
        case count
        case totalKwh
        case totalCosts
        case avgPrice
        case minPrice
        case maxPrice
        case atBestCount
        case nearBestCount
        case avgBestAvailable
        case priceEfficiency
    }
    
    var atBestPercent: Double {
        count > 0 ? Double(atBestCount) / Double(count) * 100 : 0
    }
    
    var nearBestPercent: Double {
        count > 0 ? Double(nearBestCount) / Double(count) * 100 : 0
    }
}

struct PeakPerformanceAnalysis: Codable, Sendable {
    let peakRecords: Int
    let peakExports: Int
    let peakExportRate: Double
    let peakEarnings: Double
    let theoreticalEarnings: Double
    let priceCapture: Double
    let highPricePeriods: Int
    let highPriceExported: Int
    let highPriceCaptureRate: Double
    
    enum CodingKeys: String, CodingKey {
        case peakRecords
        case peakExports
        case peakExportRate
        case peakEarnings
        case theoreticalEarnings
        case priceCapture
        case highPricePeriods
        case highPriceExported
        case highPriceCaptureRate
    }
}

struct MissedOpportunitiesAnalysis: Codable, Sendable {
    let missedHighExports: Int
    let missedHighExportValue: Double
    let topMissedExports: [DecisionMissedOpportunity]
    let missedCheapImports: Int
    let topMissedImports: [DecisionMissedOpportunity]
    
    enum CodingKeys: String, CodingKey {
        case missedHighExports
        case missedHighExportValue
        case topMissedExports
        case missedCheapImports
        case topMissedImports
    }
}

struct AchievedOpportunitiesAnalysis: Codable, Sendable {
    let achievedHighExports: Int
    let achievedHighExportValue: Double  // Total earnings in dollars
    let topAchievedExports: [DecisionAchievedOpportunity]
    let achievedCheapImports: Int
    let achievedCheapImportCost: Double  // Total cost in dollars (low = good)
    let topAchievedImports: [DecisionAchievedOpportunity]
    
    enum CodingKeys: String, CodingKey {
        case achievedHighExports
        case achievedHighExportValue
        case topAchievedExports
        case achievedCheapImports
        case achievedCheapImportCost
        case topAchievedImports
    }
}

struct DecisionMissedOpportunity: Codable, Sendable, Identifiable {
    var id: Date { timestamp }
    
    let timestamp: Date
    let price: Double
    let availableKwh: Double
    let soc: Double
    let floor: Double?
    let action: String
    let reason: String?
    
    // Enhanced data for decision chain display
    let decisionChainJson: String?    // Raw JSON of "decisions" object for UI parsing
    let houseLoadKw: Double?          // House power at that interval (kW)
    let potentialExportKwh: Double?   // (exportCapacity - houseLoad) × (5/60), capped
    
    enum CodingKeys: String, CodingKey {
        case timestamp
        case price
        case availableKwh
        case soc
        case floor
        case action
        case reason
        case decisionChainJson
        case houseLoadKw
        case potentialExportKwh
    }
    
    /// Parse decision chain from JSON for display
    var parsedDecisionChain: [[String: Any]]? {
        guard let json = decisionChainJson,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decisions = parsed["decisions"] as? [[String: Any]] else {
            return nil
        }
        return decisions
    }
    
    /// Get the final action and priority from decision chain
    var finalDecision: (action: String, priority: Int)? {
        guard let json = decisionChainJson,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = parsed["current_action"] as? String,
              let priority = parsed["current_priority"] as? Int else {
            return nil
        }
        return (action, priority)
    }
    
    /// Estimated missed value in dollars
    var estimatedMissedValue: Double {
        let exportKwh = potentialExportKwh ?? min(availableKwh, 1.67)
        return price * exportKwh / 100.0
    }
}

struct DecisionAchievedOpportunity: Codable, Sendable, Identifiable {
    var id: Date { timestamp }
    
    let timestamp: Date
    let price: Double
    let energyKwh: Double
    let soc: Double
    let floor: Double?
    let earnings: Double  // Value in dollars
    let action: String
    let reason: String?
    
    let decisionChainJson: String?
    let houseLoadKw: Double?
    
    enum CodingKeys: String, CodingKey {
        case timestamp
        case price
        case energyKwh
        case soc
        case floor
        case earnings
        case action
        case reason
        case decisionChainJson
        case houseLoadKw
    }
    
    /// Parse decision chain from JSON for display
    var parsedDecisionChain: [[String: Any]]? {
        guard let json = decisionChainJson,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decisions = parsed["decisions"] as? [[String: Any]] else {
            return nil
        }
        return decisions
    }
    
    /// Get the final action and priority from decision chain
    var finalDecision: (action: String, priority: Int)? {
        guard let json = decisionChainJson,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = parsed["current_action"] as? String,
              let priority = parsed["current_priority"] as? Int else {
            return nil
        }
        return (action, priority)
    }
}

// MARK: - Formatted Report

extension DecisionEfficiencyResult {
    
    func formattedReport() -> String {
        var lines: [String] = []
        
        lines.append(String(repeating: "=", count: 70))
        lines.append("DECISION EFFICIENCY ANALYSIS")
        lines.append(String(repeating: "=", count: 70))
        lines.append("")
        
        lines.append("📊 DATA SUMMARY")
        lines.append("   Analysis period: \(daysAnalyzed) days")
        lines.append("   Total records: \(totalRecords.formatted())")
        lines.append("   Records with forecasts: \(recordsWithForecasts.formatted())")
        lines.append("")
        
        lines.append("🎯 OVERALL SCORE: \(overallScore)% (\(grade))")
        lines.append("")
        
        // Export efficiency
        lines.append(String(repeating: "-", count: 70))
        lines.append("⬆️  EXPORT EFFICIENCY")
        lines.append(String(repeating: "-", count: 70))
        lines.append("   Export actions: \(exportAnalysis.count)")
        lines.append("   Total exported: \(String(format: "%.1f", exportAnalysis.totalKwh)) kWh")
        lines.append("   Total earnings: $\(String(format: "%.2f", exportAnalysis.totalEarnings / 100))")
        if let avg = exportAnalysis.avgPrice {
            lines.append("   Avg sell price: \(String(format: "%.1f", avg))¢")
        }
        if let capture = exportAnalysis.priceCapture {
            lines.append("   Price capture: \(String(format: "%.1f", capture))%")
        }
        lines.append("   At best price: \(exportAnalysis.atBestCount) (\(String(format: "%.1f", exportAnalysis.atBestPercent))%)")
        lines.append("   Within 3¢ of best: \(exportAnalysis.nearBestCount) (\(String(format: "%.1f", exportAnalysis.nearBestPercent))%)")
        lines.append("")
        
        // Import efficiency
        lines.append(String(repeating: "-", count: 70))
        lines.append("⬇️  IMPORT EFFICIENCY")
        lines.append(String(repeating: "-", count: 70))
        lines.append("   Import actions: \(importAnalysis.count)")
        lines.append("   Total imported: \(String(format: "%.1f", importAnalysis.totalKwh)) kWh")
        lines.append("   Total costs: $\(String(format: "%.2f", importAnalysis.totalCosts / 100))")
        if let avg = importAnalysis.avgPrice {
            lines.append("   Avg buy price: \(String(format: "%.1f", avg))¢")
        }
        if let efficiency = importAnalysis.priceEfficiency {
            lines.append("   Price efficiency: \(String(format: "%.1f", efficiency))%")
        }
        lines.append("")
        
        // Peak performance
        lines.append(String(repeating: "-", count: 70))
        lines.append("🔥 PEAK PERFORMANCE")
        lines.append(String(repeating: "-", count: 70))
        lines.append("   Peak period records: \(peakAnalysis.peakRecords)")
        lines.append("   Peak exports: \(peakAnalysis.peakExports)")
        lines.append("   Peak earnings: $\(String(format: "%.2f", peakAnalysis.peakEarnings / 100))")
        lines.append("   Theoretical earnings: $\(String(format: "%.2f", peakAnalysis.theoreticalEarnings / 100))")
        lines.append("   Price capture: \(String(format: "%.1f", peakAnalysis.priceCapture))%")
        lines.append("   High-price periods (≥20¢): \(peakAnalysis.highPricePeriods)")
        lines.append("   High-price capture rate: \(String(format: "%.1f", peakAnalysis.highPriceCaptureRate))%")
        lines.append("")
        
        // Arbitrage spread
        lines.append(String(repeating: "-", count: 70))
        lines.append("💰 ARBITRAGE SPREAD")
        lines.append(String(repeating: "-", count: 70))
        lines.append("   Realized spread: \(String(format: "%.1f", realizedSpread))¢/kWh")
        lines.append("   Theoretical best: \(String(format: "%.1f", theoreticalSpread))¢/kWh")
        lines.append("   Spread capture: \(String(format: "%.1f", spreadCaptureEfficiency))%")
        lines.append("")
        
        // Achieved opportunities
        if let achieved = achievedOpportunities {
            lines.append(String(repeating: "-", count: 70))
            lines.append("✅ ACHIEVED OPPORTUNITIES")
            lines.append(String(repeating: "-", count: 70))
            lines.append("   High-price exports (≥20¢): \(achieved.achievedHighExports)")
            lines.append("   Export earnings: $\(String(format: "%.2f", achieved.achievedHighExportValue))")
            lines.append("   Cheap imports (≤5¢): \(achieved.achievedCheapImports)")
            lines.append("   Import cost: $\(String(format: "%.2f", achieved.achievedCheapImportCost))")
            lines.append("")
        }
        
        // Missed opportunities
        lines.append(String(repeating: "-", count: 70))
        lines.append("❌ MISSED OPPORTUNITIES")
        lines.append(String(repeating: "-", count: 70))
        lines.append("   Missed high-price exports: \(missedOpportunities.missedHighExports)")
        lines.append("   Estimated lost value: $\(String(format: "%.2f", missedOpportunities.missedHighExportValue))")
        lines.append("   Missed cheap imports: \(missedOpportunities.missedCheapImports)")
        lines.append("")
        
        // Summary
        lines.append(String(repeating: "=", count: 70))
        lines.append("📋 SUMMARY")
        lines.append(String(repeating: "=", count: 70))
        lines.append("   Net earnings: $\(String(format: "%.2f", netEarnings / 100))")
        lines.append("   Overall efficiency: \(overallScore)% (\(grade))")
        
        return lines.joined(separator: "\n")
    }
}

