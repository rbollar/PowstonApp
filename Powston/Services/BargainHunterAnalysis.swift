//
//  BargainHunterAnalysis.swift
//  Powston
//
//  Bargain Hunter analysis engine
//  Swift port of best_n_import_analysis.py
//
//  Analyzes expensive imports to determine root cause:
//  1. Best-N Logic Failures - Forecast showed cheap, had time, imported anyway
//  2. Deadline Pressure - Forecast showed cheap, but couldn't wait
//  3. Forecast Miss - Forecast didn't show the cheap prices coming
//  4. No Forecast Data - Missing forecast in values
//

import Foundation
import Combine

// MARK: - Analysis Engine

@MainActor
class BargainHunterAnalysis: ObservableObject {
    
    // MARK: - Published State
    
    @Published var isAnalyzing = false
    @Published var progress: String = ""
    @Published var result: BargainHunterResult?
    @Published var error: String?
    
    // MARK: - Dependencies
    
    private var dataStore: PowstonDataStore { PowstonDataStore.shared }
    private let cacheKey = "bargain_hunter_cache"
    
    // MARK: - Configuration
    
    static let expensiveThreshold: Double = 5.0   // Imports above this are "expensive" (cents)
    static let cheapThreshold: Double = 3.0       // Forecast showing ≤this means cheap was available (cents)
    static let chargeRateKw: Double = 20.0        // Assumed charge rate for time calculations
    static let kwhPerPeriod: Double = 10.0        // kWh per 30-min period at 20kW
    
    // MARK: - Run Analysis
    
    func analyzeImports(config: AnalysisConfig) async -> BargainHunterResult? {
        isAnalyzing = true
        error = nil
        progress = "Loading data..."
        
        let calendar = Calendar.current
        let endDate = calendar.date(byAdding: .day, value: -1, to: Date())!
        let startDate = calendar.date(byAdding: .day, value: -config.analysisWindowDays, to: endDate)!
        
        // Fetch all records
        progress = "Fetching records..."
        let allRecords = dataStore.fetchActions(siteId: config.siteId, from: startDate, to: endDate)
        print("🏷️ Bargain Hunter: loaded \(allRecords.count) records")
        
        guard !allRecords.isEmpty else {
            error = "No data available for analysis"
            isAnalyzing = false
            return nil
        }
        
        // Extract imports with forecast context
        progress = "Parsing imports..."
        let imports = extractImports(from: allRecords, config: config)
        print("🏷️ Found \(imports.count) imports")
        
        guard !imports.isEmpty else {
            error = "No imports found in data"
            isAnalyzing = false
            return nil
        }
        
        // Analyze each import
        progress = "Analyzing import timing..."
        let analyzedImports = imports.map { analyzeImport($0, config: config) }
        
        // Categorize
        progress = "Categorizing results..."
        let expensiveImports = analyzedImports.filter { $0.isExpensive }
        let cheapImports = analyzedImports.filter { !$0.isExpensive }
        
        // Build breakdown
        let breakdown = buildBreakdown(expensiveImports: expensiveImports)
        
        // Extract actionable samples (Best-N failures sorted by overpaid)
        let couldHaveWaited = expensiveImports
            .filter { $0.category == .bestNFailure }
            .sorted { $0.overpaidCents > $1.overpaidCents }
            .prefix(10)
            .map { toBargainHunterSample($0) }
        
        // By hour analysis
        let byHour = analyzeByHour(expensiveImports: expensiveImports, config: config)
        
        // By priority analysis
        let byPriority = analyzeByPriority(expensiveImports: expensiveImports)
        
        // Calculate potential savings from fixing Best-N
        let bestNFailures = expensiveImports.filter { $0.category == .bestNFailure }
        let potentialSavingsCents = bestNFailures.reduce(0.0) { $0 + $1.overpaidCents }
        
        // Calculate score/grade
        let (score, grade) = calculateGrade(
            totalImports: imports.count,
            expensiveCount: expensiveImports.count,
            bestNFailures: bestNFailures.count
        )
        
        let result = BargainHunterResult(
            config: config,
            analysisDate: Date(),
            dateRange: DateInterval(start: startDate, end: endDate),
            totalImports: imports.count,
            expensiveImports: expensiveImports.count,
            cheapImports: cheapImports.count,
            totalImportKwh: imports.reduce(0) { $0 + $1.energyKwh },
            totalImportCostCents: imports.reduce(0) { $0 + $1.buyPrice * $1.energyKwh },
            breakdown: breakdown,
            potentialSavingsCents: potentialSavingsCents,
            topCouldHaveWaited: Array(couldHaveWaited),
            byHour: byHour,
            byPriority: byPriority,
            score: score,
            grade: grade
        )
        
        self.result = result
        self.progress = "Complete"
        self.isAnalyzing = false
        
        // Cache the result
        cacheResult(result, config: config)
        
        return result
    }
    
    // MARK: - Cache Management
    
    func getCachedResult(config: AnalysisConfig) -> BargainHunterResult? {
        let key = "\(cacheKey)_\(config.siteId)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(BargainHunterResult.self, from: data) else {
            return nil
        }
        
        // Check if cache is fresh (less than 24 hours old)
        let age = Date().timeIntervalSince(cached.analysisDate)
        guard age < 24 * 3600 else { return nil }
        
        return cached
    }
    
    private func cacheResult(_ result: BargainHunterResult, config: AnalysisConfig) {
        let key = "\(cacheKey)_\(config.siteId)"
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    // MARK: - Extract Imports
    
    private func extractImports(from records: [ActionRecord], config: AnalysisConfig) -> [ImportContext] {
        var calendar = Calendar.current
        calendar.timeZone = config.timezone
        
        return records.compactMap { record -> ImportContext? in
            // Must be an import with meaningful energy
            guard record.isImport,
                  let energyImport = record.energyImport,
                  energyImport > 0.01,
                  let buyPrice = record.buyPrice,
                  buyPrice > 0 else {
                return nil
            }
            
            // Parse values JSON for forecast and decision context
            var buyForecast: [Double] = []
            var activeFloor: Double = 0
            var priority: Int = 0
            var reason: String? = nil
            var soc: Double = record.batterySoc ?? 0
            
            if let valuesJson = record.valuesJson,
               let data = valuesJson.data(using: .utf8),
               let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                // Buy forecast (24 hourly values)
                if let forecast = values["buy_forecast"] as? [Double] {
                    buyForecast = forecast
                }
                
                // Battery SOC from values if not in record
                if soc == 0, let valueSoc = values["battery_soc"] as? Double {
                    soc = valueSoc
                }
                
                // Parse decisions for active floor and priority
                if let decisions = values["decisions"] as? [String: Any],
                   let decisionList = decisions["decisions"] as? [[String: Any]] {
                    for decision in decisionList {
                        if decision["applied"] as? Bool == true {
                            priority = decision["priority"] as? Int ?? 0
                            reason = decision["reason"] as? String
                            if let decisionValues = decision["values"] as? [String: Any] {
                                activeFloor = decisionValues["active_floor"] as? Double ?? 0
                                if soc == 0, let decisionSoc = decisionValues["soc"] as? Double {
                                    soc = decisionSoc
                                }
                            }
                            break
                        }
                    }
                }
            }
            
            return ImportContext(
                timestamp: record.intervalTime,
                buyPrice: buyPrice,
                energyKwh: energyImport,
                soc: soc,
                activeFloor: activeFloor,
                priority: priority,
                reason: reason,
                buyForecast: buyForecast,
                batteryCapacityKwh: config.batteryCapacityKWh,
                deadlineHour: config.peakStartHour
            )
        }
    }
    
    // MARK: - Analyze Single Import
    
    private func analyzeImport(_ context: ImportContext, config: AnalysisConfig) -> AnalyzedImport {
        var result = AnalyzedImport(context: context)
        
        // Check if expensive
        result.isExpensive = context.buyPrice > Self.expensiveThreshold
        
        guard result.isExpensive else {
            result.category = .cheap
            return result
        }
        
        // No forecast = can't analyze
        guard !context.buyForecast.isEmpty else {
            result.category = .noForecast
            return result
        }
        
        // Find cheapest in forecast
        result.cheapestInForecast = context.buyForecast.min() ?? 999
        
        // Find periods until cheap price
        for (i, price) in context.buyForecast.enumerated() {
            if price <= Self.cheapThreshold {
                result.periodsUntilCheap = i
                break
            }
        }
        
        // Calculate hours until deadline
        var calendar = Calendar.current
        calendar.timeZone = config.timezone
        
        let hour = calendar.component(.hour, from: context.timestamp)
        var hoursUntilDeadline = Double(context.deadlineHour - hour)
        if hoursUntilDeadline <= 0 {
            hoursUntilDeadline += 24 // Past deadline, use next day
        }
        result.hoursUntilDeadline = hoursUntilDeadline
        
        // Categorize
        if result.cheapestInForecast > Self.cheapThreshold {
            // Forecast didn't show anything cheap
            if result.cheapestInForecast >= context.buyPrice {
                result.category = .forecastMiss
            } else {
                // Forecast showed something cheaper, but not "cheap"
                result.category = .forecastMiss
            }
        } else if let periodsUntil = result.periodsUntilCheap {
            // Forecast showed cheap prices - could we have waited?
            let hoursToWait = Double(periodsUntil) * 0.5  // 30-min periods
            let hoursToCharge = Double(context.periodsNeeded) * 0.5
            let totalHoursNeeded = hoursToWait + hoursToCharge
            
            if totalHoursNeeded < hoursUntilDeadline {
                // Had time to wait - this is a Best-N failure
                result.category = .bestNFailure
                result.couldHaveWaited = true
                result.overpaidCents = (context.buyPrice - result.cheapestInForecast) * context.energyKwh
            } else {
                // Couldn't wait - deadline pressure
                result.category = .deadlinePressure
            }
        } else {
            result.category = .forecastMiss
        }
        
        return result
    }
    
    // MARK: - Build Breakdown
    
    private func buildBreakdown(expensiveImports: [AnalyzedImport]) -> BargainHunterBreakdown {
        var bestN = CategoryStats()
        var deadline = CategoryStats()
        var forecastMiss = CategoryStats()
        var noForecast = CategoryStats()
        
        for imp in expensiveImports {
            let kwh = imp.context.energyKwh
            let cost = imp.context.buyPrice * kwh
            
            switch imp.category {
            case .bestNFailure:
                bestN.count += 1
                bestN.totalKwh += kwh
                bestN.totalCostCents += cost
                bestN.overpaidCents += imp.overpaidCents
            case .deadlinePressure:
                deadline.count += 1
                deadline.totalKwh += kwh
                deadline.totalCostCents += cost
            case .forecastMiss:
                forecastMiss.count += 1
                forecastMiss.totalKwh += kwh
                forecastMiss.totalCostCents += cost
            case .noForecast:
                noForecast.count += 1
                noForecast.totalKwh += kwh
                noForecast.totalCostCents += cost
            case .cheap:
                break // Not in expensive list
            }
        }
        
        return BargainHunterBreakdown(
            bestNFailures: bestN,
            deadlinePressure: deadline,
            forecastMiss: forecastMiss,
            noForecast: noForecast
        )
    }
    
    // MARK: - By Hour Analysis
    
    private func analyzeByHour(expensiveImports: [AnalyzedImport], config: AnalysisConfig) -> [HourStats] {
        var calendar = Calendar.current
        calendar.timeZone = config.timezone
        
        var byHour: [Int: (count: Int, totalPrice: Double, forecastHadCheap: Int, couldWait: Int)] = [:]
        
        for imp in expensiveImports {
            let hour = calendar.component(.hour, from: imp.context.timestamp)
            var stats = byHour[hour] ?? (0, 0, 0, 0)
            stats.count += 1
            stats.totalPrice += imp.context.buyPrice
            if imp.cheapestInForecast <= Self.cheapThreshold {
                stats.forecastHadCheap += 1
            }
            if imp.couldHaveWaited {
                stats.couldWait += 1
            }
            byHour[hour] = stats
        }
        
        return byHour.map { hour, stats in
            HourStats(
                hour: hour,
                count: stats.count,
                avgPrice: stats.count > 0 ? stats.totalPrice / Double(stats.count) : 0,
                forecastHadCheap: stats.forecastHadCheap,
                couldWait: stats.couldWait
            )
        }.sorted { $0.hour < $1.hour }
    }
    
    // MARK: - By Priority Analysis
    
    private func analyzeByPriority(expensiveImports: [AnalyzedImport]) -> [PriorityStats] {
        var byPriority: [Int: (count: Int, totalPrice: Double, totalSoc: Double, reasons: [String: Int])] = [:]
        
        for imp in expensiveImports {
            let priority = imp.context.priority
            var stats = byPriority[priority] ?? (0, 0, 0, [:])
            stats.count += 1
            stats.totalPrice += imp.context.buyPrice
            stats.totalSoc += imp.context.soc
            if let reason = imp.context.reason {
                stats.reasons[reason, default: 0] += 1
            }
            byPriority[priority] = stats
        }
        
        return byPriority.map { priority, stats in
            // Find most common reason for this priority
            let topReason = stats.reasons.max { $0.value < $1.value }?.key
            
            return PriorityStats(
                priority: priority,
                count: stats.count,
                avgPrice: stats.count > 0 ? stats.totalPrice / Double(stats.count) : 0,
                avgSoc: stats.count > 0 ? stats.totalSoc / Double(stats.count) : 0,
                topReason: topReason
            )
        }.sorted { $0.priority > $1.priority }
    }
    
    // MARK: - Grade Calculation
    
    private func calculateGrade(totalImports: Int, expensiveCount: Int, bestNFailures: Int) -> (Int, String) {
        guard totalImports > 0 else { return (100, "A") }
        
        // Score based on:
        // - % of imports that were cheap (higher = better)
        // - % of expensive that were Best-N failures (lower = better)
        
        let cheapPercent = Double(totalImports - expensiveCount) / Double(totalImports) * 100
        let bestNFailureRate = expensiveCount > 0 ? Double(bestNFailures) / Double(expensiveCount) * 100 : 0
        
        // Weight: 60% cheap rate, 40% inverse of Best-N failure rate
        let score = Int(cheapPercent * 0.6 + (100 - bestNFailureRate) * 0.4)
        
        let grade: String
        switch score {
        case 90...100: grade = "A"
        case 80..<90: grade = "B+"
        case 70..<80: grade = "B"
        case 60..<70: grade = "C+"
        case 50..<60: grade = "C"
        default: grade = "D"
        }
        
        return (score, grade)
    }
    
    // MARK: - Convert to Sample
    
    private func toBargainHunterSample(_ analyzed: AnalyzedImport) -> BargainHunterSample {
        BargainHunterSample(
            timestamp: analyzed.context.timestamp,
            buyPrice: analyzed.context.buyPrice,
            cheapestInForecast: analyzed.cheapestInForecast,
            periodsUntilCheap: analyzed.periodsUntilCheap,
            soc: analyzed.context.soc,
            priority: analyzed.context.priority,
            reason: analyzed.context.reason,
            energyKwh: analyzed.context.energyKwh,
            overpaidCents: analyzed.overpaidCents,
            hoursUntilDeadline: analyzed.hoursUntilDeadline
        )
    }
}

// MARK: - Supporting Types

private struct ImportContext {
    let timestamp: Date
    let buyPrice: Double
    let energyKwh: Double
    let soc: Double
    let activeFloor: Double
    let priority: Int
    let reason: String?
    let buyForecast: [Double]
    let batteryCapacityKwh: Double
    let deadlineHour: Int
    
    var kwhNeeded: Double {
        let targetSoc = 95.0
        return max(0, (targetSoc - soc) / 100 * batteryCapacityKwh)
    }
    
    var periodsNeeded: Int {
        max(1, Int(kwhNeeded / BargainHunterAnalysis.kwhPerPeriod) + 1)
    }
}

private struct AnalyzedImport {
    let context: ImportContext
    var isExpensive: Bool = false
    var category: ImportCategory = .cheap
    var cheapestInForecast: Double = 999
    var periodsUntilCheap: Int? = nil
    var hoursUntilDeadline: Double = 0
    var couldHaveWaited: Bool = false
    var overpaidCents: Double = 0
}

enum ImportCategory: String, Codable, Sendable {
    case cheap = "cheap"
    case bestNFailure = "best_n_failure"
    case deadlinePressure = "deadline_pressure"
    case forecastMiss = "forecast_miss"
    case noForecast = "no_forecast"
    
    var displayName: String {
        switch self {
        case .cheap: return "Cheap Import"
        case .bestNFailure: return "Could Have Waited"
        case .deadlinePressure: return "Deadline Pressure"
        case .forecastMiss: return "Forecast Miss"
        case .noForecast: return "No Forecast"
        }
    }
    
    var icon: String {
        switch self {
        case .cheap: return "checkmark.circle.fill"
        case .bestNFailure: return "exclamationmark.triangle.fill"
        case .deadlinePressure: return "clock.badge.exclamationmark"
        case .forecastMiss: return "cloud.bolt.fill"
        case .noForecast: return "questionmark.circle.fill"
        }
    }
    
    var color: String {
        switch self {
        case .cheap: return "green"
        case .bestNFailure: return "red"
        case .deadlinePressure: return "orange"
        case .forecastMiss: return "purple"
        case .noForecast: return "gray"
        }
    }
}

// MARK: - Result Types

struct BargainHunterResult: Codable, Sendable {
    let config: AnalysisConfig
    let analysisDate: Date
    let dateRange: DateInterval
    
    let totalImports: Int
    let expensiveImports: Int
    let cheapImports: Int
    let totalImportKwh: Double
    let totalImportCostCents: Double
    
    let breakdown: BargainHunterBreakdown
    let potentialSavingsCents: Double
    let topCouldHaveWaited: [BargainHunterSample]
    let byHour: [HourStats]
    let byPriority: [PriorityStats]
    
    let score: Int
    let grade: String
    
    var potentialSavingsDollars: Double {
        potentialSavingsCents / 100.0
    }
    
    var expensivePercent: Double {
        guard totalImports > 0 else { return 0 }
        return Double(expensiveImports) / Double(totalImports) * 100
    }
    
    var avgImportPrice: Double {
        guard totalImportKwh > 0 else { return 0 }
        return totalImportCostCents / totalImportKwh
    }
}

struct BargainHunterBreakdown: Codable, Sendable {
    let bestNFailures: CategoryStats
    let deadlinePressure: CategoryStats
    let forecastMiss: CategoryStats
    let noForecast: CategoryStats
    
    var total: Int {
        bestNFailures.count + deadlinePressure.count + forecastMiss.count + noForecast.count
    }
}

struct CategoryStats: Codable, Sendable {
    var count: Int = 0
    var totalKwh: Double = 0
    var totalCostCents: Double = 0
    var overpaidCents: Double = 0
    
    var percent: Double {
        0 // Calculated in view with total
    }
}

struct BargainHunterSample: Codable, Sendable, Identifiable {
    var id: Date { timestamp }
    
    let timestamp: Date
    let buyPrice: Double
    let cheapestInForecast: Double
    let periodsUntilCheap: Int?
    let soc: Double
    let priority: Int
    let reason: String?
    let energyKwh: Double
    let overpaidCents: Double
    let hoursUntilDeadline: Double
    
    var overpaidDollars: Double {
        overpaidCents / 100.0
    }
    
    var hoursToWait: Double? {
        guard let periods = periodsUntilCheap else { return nil }
        return Double(periods) * 0.5
    }
}

struct HourStats: Codable, Sendable, Identifiable {
    var id: Int { hour }
    
    let hour: Int
    let count: Int
    let avgPrice: Double
    let forecastHadCheap: Int
    let couldWait: Int
    
    var forecastHadCheapPercent: Double {
        guard count > 0 else { return 0 }
        return Double(forecastHadCheap) / Double(count) * 100
    }
}

struct PriorityStats: Codable, Sendable, Identifiable {
    var id: Int { priority }
    
    let priority: Int
    let count: Int
    let avgPrice: Double
    let avgSoc: Double
    let topReason: String?
}

// MARK: - Formatted Report

extension BargainHunterResult {
    
    func formattedReport() -> String {
        var lines: [String] = []
        
        lines.append(String(repeating: "=", count: 70))
        lines.append("BARGAIN HUNTER ANALYSIS")
        lines.append(String(repeating: "=", count: 70))
        lines.append("")
        
        lines.append("📊 SUMMARY")
        lines.append("   Analysis period: \(config.analysisWindowDays) days")
        lines.append("   Total imports: \(totalImports)")
        lines.append("   Cheap (≤5¢): \(cheapImports) (\(String(format: "%.0f", 100 - expensivePercent))%)")
        lines.append("   Expensive (>5¢): \(expensiveImports) (\(String(format: "%.0f", expensivePercent))%)")
        lines.append("   Avg import price: \(String(format: "%.1f", avgImportPrice))¢")
        lines.append("")
        
        lines.append("🎯 SCORE: \(score)% (\(grade))")
        lines.append("")
        
        // Breakdown
        lines.append(String(repeating: "-", count: 70))
        lines.append("EXPENSIVE IMPORT BREAKDOWN")
        lines.append(String(repeating: "-", count: 70))
        
        let total = breakdown.total
        if total > 0 {
            let bestNPct = Double(breakdown.bestNFailures.count) / Double(total) * 100
            let deadlinePct = Double(breakdown.deadlinePressure.count) / Double(total) * 100
            let forecastPct = Double(breakdown.forecastMiss.count) / Double(total) * 100
            let noForecastPct = Double(breakdown.noForecast.count) / Double(total) * 100
            
            lines.append("   Could Have Waited: \(breakdown.bestNFailures.count) (\(String(format: "%.0f", bestNPct))%)")
            lines.append("   Deadline Pressure: \(breakdown.deadlinePressure.count) (\(String(format: "%.0f", deadlinePct))%)")
            lines.append("   Forecast Miss: \(breakdown.forecastMiss.count) (\(String(format: "%.0f", forecastPct))%)")
            lines.append("   No Forecast Data: \(breakdown.noForecast.count) (\(String(format: "%.0f", noForecastPct))%)")
        }
        lines.append("")
        
        // Potential savings
        lines.append("💰 POTENTIAL SAVINGS")
        lines.append("   From fixing Best-N logic: $\(String(format: "%.2f", potentialSavingsDollars))")
        lines.append("")
        
        // Top samples
        if !topCouldHaveWaited.isEmpty {
            lines.append(String(repeating: "-", count: 70))
            lines.append("TOP 'COULD HAVE WAITED' IMPORTS")
            lines.append(String(repeating: "-", count: 70))
            lines.append("")
            lines.append("  Time              Paid    Best   Away   SOC    Priority")
            lines.append("  ----------------  ------  -----  -----  -----  --------")
            
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            df.timeZone = config.timezone
            
            for sample in topCouldHaveWaited {
                let time = df.string(from: sample.timestamp)
                let paid = String(format: "%.1f¢", sample.buyPrice)
                let best = String(format: "%.1f¢", sample.cheapestInForecast)
                let away = sample.hoursToWait.map { String(format: "%.1fh", $0) } ?? "?"
                let soc = String(format: "%.0f%%", sample.soc)
                let priority = "P\(sample.priority)"
                
                lines.append("  \(time)  \(paid.padding(toLength: 6, withPad: " ", startingAt: 0))  \(best.padding(toLength: 5, withPad: " ", startingAt: 0))  \(away.padding(toLength: 5, withPad: " ", startingAt: 0))  \(soc.padding(toLength: 5, withPad: " ", startingAt: 0))  \(priority)")
            }
        }
        lines.append("")
        
        // By priority
        if !byPriority.isEmpty {
            lines.append(String(repeating: "-", count: 70))
            lines.append("BY PRIORITY")
            lines.append(String(repeating: "-", count: 70))
            lines.append("")
            lines.append("  Priority  Count   Avg Price  Avg SOC  Reason")
            lines.append("  --------  ------  ---------  -------  ------")
            
            for stat in byPriority {
                let priority = "P\(stat.priority)".padding(toLength: 8, withPad: " ", startingAt: 0)
                let count = String(stat.count).padding(toLength: 6, withPad: " ", startingAt: 0)
                let avgPrice = String(format: "%.1f¢", stat.avgPrice).padding(toLength: 9, withPad: " ", startingAt: 0)
                let avgSoc = String(format: "%.0f%%", stat.avgSoc).padding(toLength: 7, withPad: " ", startingAt: 0)
                let reason = stat.topReason ?? "Unknown"
                
                lines.append("  \(priority)  \(count)  \(avgPrice)  \(avgSoc)  \(reason)")
            }
        }
        
        return lines.joined(separator: "\n")
    }
}