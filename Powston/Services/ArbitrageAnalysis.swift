//
//  ArbitrageAnalysis.swift
//  Powston
//
//  Peak export profitability analysis engine
//  Swift port of peaksell.py
//
//  Analyzes historical export data to determine:
//  1. Profitability by sell price bucket
//  2. Optimal minimum sell price floor
//  3. Replacement cost patterns
//

import Foundation
import Combine

// MARK: - Analysis Engine

@MainActor
class ArbitrageAnalysis: ObservableObject {
    
    // MARK: - Published State
    
    @Published var isAnalyzing = false
    @Published var progress: String = ""
    @Published var result: PeakAnalysisResult?
    @Published var error: String?
    
    // MARK: - Dependencies

    private var dataStore: PowstonDataStore { PowstonDataStore.shared }
    private let cacheKey = "peak_analysis_cache"
    
    // MARK: - Run Analysis
    
    /// Run peak export profitability analysis
    /// Call prepareForAnalysis on dataStore first to ensure data is available
    func analyzePeakExports(config: AnalysisConfig, latestCompleteDataDate: Date? = nil) async -> PeakAnalysisResult? {
        isAnalyzing = true
        error = nil
        progress = "Loading data..."

        var calendar = Calendar.current
        calendar.timeZone = config.timezone

        // Use latestCompleteDataDate if available, otherwise fall back to yesterday
        let endDate = latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: Date())!
        let startDate = calendar.date(byAdding: .day, value: -config.analysisWindowDays, to: endDate)!
        
        // Fetch all records for the analysis window
        progress = "Fetching records..."
        let allRecords = dataStore.fetchActions(siteId: config.siteId, from: startDate, to: endDate)
        print("📊 fetchActions returned \(allRecords.count) records (from SQLite)")
        
        guard !allRecords.isEmpty else {
            error = "No data available for analysis"
            isAnalyzing = false
            return nil
        }
        
        print("📊 Analyzing \(allRecords.count) records from \(config.analysisWindowDays) days")
        
        // Extract peak exports
        progress = "Identifying peak exports..."
        let peakExports = extractPeakExports(
            from: allRecords,
            peakStartHour: config.peakStartHour,
            peakEndHour: config.peakEndHour,
            timezone: config.timezone
        )
        
        guard !peakExports.isEmpty else {
            error = "No peak exports found in data"
            isAnalyzing = false
            return nil
        }
        
        print("📊 Found \(peakExports.count) peak exports")
        
        // Calculate replacement costs
        progress = "Calculating replacement costs..."
        let exportsWithReplacement = calculateReplacementCosts(
            exports: peakExports,
            allRecords: allRecords,
            config: config
        )
        
        // Analyze by price bucket
        progress = "Analyzing price buckets..."
        let bucketAnalysis = analyzePriceBuckets(exports: exportsWithReplacement)
        
        // Find optimal floor
        progress = "Finding optimal floor..."
        let floorAnalysis = analyzeOptimalFloor(exports: exportsWithReplacement)
        
        // Analyze replacement sources
        progress = "Analyzing replacement sources..."
        let sourceBreakdown = analyzeReplacementSources(exports: exportsWithReplacement)
        
        // Build result
        let result = PeakAnalysisResult(
            config: config,
            analysisDate: Date(),
            dateRange: DateInterval(start: startDate, end: endDate),
            totalExports: peakExports.count,
            totalKwh: peakExports.reduce(0) { $0 + $1.energyKwh },
            bucketAnalysis: bucketAnalysis,
            floorAnalysis: floorAnalysis,
            sourceBreakdown: sourceBreakdown,
            profitableKwh: exportsWithReplacement.filter { $0.isProfitable }.reduce(0) { $0 + $1.energyKwh }
        )
        
        self.result = result
        self.progress = "Complete"
        self.isAnalyzing = false
        
        // Cache the result
        cacheResult(result, config: config)
        
        return result
    }
    
    /// Check for cached analysis result
    func getCachedResult(config: AnalysisConfig) -> PeakAnalysisResult? {
        let key = "\(cacheKey)_\(config.siteId)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(PeakAnalysisResult.self, from: data) else {
            return nil
        }
        
        // Check if cache is fresh (less than 24 hours old)
        let age = Date().timeIntervalSince(cached.analysisDate)
        guard age < 24 * 3600 else { return nil }
        
        return cached
    }
    
    private func cacheResult(_ result: PeakAnalysisResult, config: AnalysisConfig) {
        let key = "\(cacheKey)_\(config.siteId)"
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    // MARK: - Extract Peak Exports
    
    private func extractPeakExports(
        from records: [ActionRecord],
        peakStartHour: Int,
        peakEndHour: Int,
        timezone: TimeZone
    ) -> [ExportEvent] {
        var calendar = Calendar.current
        calendar.timeZone = timezone
        
        return records.compactMap { record -> ExportEvent? in
            // Must be an export with meaningful energy
            guard record.isExport,
                  let energyExport = record.energyExport,
                  energyExport > 0.1 else {
                return nil
            }
            
            // Must be in peak hours
            let hour = calendar.component(.hour, from: record.intervalTime)
            guard hour >= peakStartHour && hour < peakEndHour else {
                return nil
            }
            
            return ExportEvent(
                timestamp: record.intervalTime,
                sellPrice: record.sellPrice ?? 0,
                energyKwh: energyExport,
                soc: record.batterySoc ?? 0,
                recordIndex: record.id
            )
        }
    }
    
    // MARK: - Calculate Replacement Costs
    
    private func calculateReplacementCosts(
        exports: [ExportEvent],
        allRecords: [ActionRecord],
        config: AnalysisConfig
    ) -> [ExportEvent] {
        // Create index for fast lookup
        let recordsById = Dictionary(uniqueKeysWithValues: allRecords.enumerated().map { ($1.id, $0) })
        
        return exports.map { export in
            var result = export
            
            // Find replacement cost by looking forward
            if let exportIndex = recordsById[export.recordIndex] {
                let (price, source, hours) = findReplacementCost(
                    allRecords: allRecords,
                    exportIndex: exportIndex,
                    exportKwh: export.energyKwh,
                    efficiency: config.batteryEfficiency
                )
                result.replacementPrice = price
                result.replacementSource = source
                result.hoursToReplacement = hours
            }
            
            return result
        }
    }
    
    /// Find replacement cost for an export by looking at subsequent imports
    private func findReplacementCost(
        allRecords: [ActionRecord],
        exportIndex: Int,
        exportKwh: Double,
        efficiency: Double
    ) -> (price: Double, source: ReplacementSource, hours: Double) {
        var kwhToReplace = exportKwh
        var totalCost: Double = 0
        var sources: [ReplacementSource] = []
        var firstReplacementTime: Date?
        
        let exportTime = allRecords[exportIndex].intervalTime
        let maxLookahead = min(exportIndex + 288, allRecords.count)  // Max 24 hours ahead
        
        for i in (exportIndex + 1)..<maxLookahead {
            let record = allRecords[i]
            
            // Check for PV generation (free replacement)
            if let pvPower = record.pvPower, pvPower > 500, !record.isExport {
                // Estimate PV charging this period (5-min interval)
                let pvKwh = min((pvPower / 1000) * (5.0 / 60.0), kwhToReplace)
                if pvKwh > 0.1 {
                    kwhToReplace -= pvKwh
                    sources.append(.pv)
                    if firstReplacementTime == nil {
                        firstReplacementTime = record.intervalTime
                    }
                    if kwhToReplace <= 0 { break }
                }
            }
            
            // Check for grid import
            if record.isImport, let importKwh = record.energyImport, importKwh > 0 {
                let usedKwh = min(importKwh, kwhToReplace)
                let buyPrice = record.buyPrice ?? 0
                totalCost += usedKwh * buyPrice
                kwhToReplace -= usedKwh
                
                if buyPrice <= 5 {
                    sources.append(.cheapGrid)
                } else if buyPrice <= 15 {
                    sources.append(.grid)
                } else {
                    sources.append(.expensiveGrid)
                }
                
                if firstReplacementTime == nil {
                    firstReplacementTime = record.intervalTime
                }
                
                if kwhToReplace <= 0 { break }
            }
        }
        
        // Determine primary source
        guard !sources.isEmpty else {
            return (0, .unknown, 0)
        }
        
        let source: ReplacementSource
        let uniqueSources = Set(sources)
        
        if uniqueSources == [.pv] {
            source = .pv
        } else if uniqueSources.contains(.pv) {
            source = .mixedPv
        } else if uniqueSources == [.cheapGrid] {
            source = .cheapGrid
        } else if uniqueSources.contains(.expensiveGrid) {
            source = .expensiveGrid
        } else if uniqueSources.contains(.grid) {
            source = .grid
        } else {
            source = .cheapGrid
        }
        
        // Calculate weighted average price (adjusted for efficiency)
        let avgPrice = exportKwh > 0 ? (totalCost / exportKwh) / efficiency : 0
        
        let hoursTo = firstReplacementTime.map {
            $0.timeIntervalSince(exportTime) / 3600
        } ?? 0
        
        return (avgPrice, source, hoursTo)
    }
    
    // MARK: - Analyze Price Buckets
    
    private func analyzePriceBuckets(exports: [ExportEvent]) -> [PriceBucketAnalysis] {
        let buckets: [(low: Double, high: Double)] = [
            (0, 2), (2, 4), (4, 6), (6, 8), (8, 10), (10, 12), (12, 14), (14, 16),
            (16, 18), (18, 20), (20, 25), (25, 30), (30, 40), (40, 50), (50, 100),
            (100, 500), (500, 2000)
        ]
        
        var results = buckets.compactMap { bucket -> PriceBucketAnalysis? in
            let bucketExports = exports.filter {
                $0.sellPrice >= bucket.low && $0.sellPrice < bucket.high
            }
            
            guard !bucketExports.isEmpty else { return nil }
            
            let count = bucketExports.count
            let kwh = bucketExports.reduce(0) { $0 + $1.energyKwh }
            let profitableCount = bucketExports.filter { $0.isProfitable }.count
            let avgProfit = bucketExports.map { $0.profit }.average
            let avgReplacement = bucketExports.map { $0.effectiveReplacementCost }.average
            let totalProfit = bucketExports.reduce(0) { $0 + ($1.profit * $1.energyKwh) }
            let pvPercent = Double(bucketExports.filter { $0.replacementSource == .pv || $0.replacementSource == .mixedPv }.count) / Double(count)
            
            return PriceBucketAnalysis(
                lowPrice: bucket.low,
                highPrice: bucket.high,
                count: count,
                totalKwh: kwh,
                profitableCount: profitableCount,
                profitablePercent: Double(profitableCount) / Double(count) * 100,
                avgProfitCents: avgProfit,
                avgReplacementCents: avgReplacement,
                totalProfitCents: totalProfit,
                pvPercent: pvPercent * 100,
                cumulativeProfitCents: 0  // Calculated below
            )
        }
        
        // Calculate cumulative profit (sum from this bucket to highest)
        // Results are ordered low to high, so iterate in reverse
        var cumulative: Double = 0
        for i in results.indices.reversed() {
            cumulative += results[i].totalProfitCents
            results[i].cumulativeProfitCents = cumulative
        }
        
        return results
    }
    
    // MARK: - Analyze Optimal Floor
    
    private func analyzeOptimalFloor(exports: [ExportEvent]) -> FloorAnalysis {
        let thresholds: [Double] = [0, 2, 4, 5, 6, 7, 8, 10, 12, 15, 20, 25, 30]
        
        let baseProfit = exports.reduce(0) { $0 + ($1.profit * $1.energyKwh) }
        
        var floorResults: [FloorResult] = []
        var bestFloor: Double = 0
        var bestProfit: Double = baseProfit
        
        for floor in thresholds {
            let kept = exports.filter { $0.sellPrice >= floor }
            let skipped = exports.filter { $0.sellPrice < floor }
            
            guard !kept.isEmpty else { continue }
            
            let keptKwh = kept.reduce(0) { $0 + $1.energyKwh }
            let keptProfit = kept.reduce(0) { $0 + ($1.profit * $1.energyKwh) }
            let avgProfit = kept.map { $0.profit }.average
            
            let skippedRevenue = skipped.reduce(0) { $0 + ($1.sellPrice * $1.energyKwh) }
            let skippedReplacementSaved = skipped.reduce(0) { $0 + ($1.effectiveReplacementCost * $1.energyKwh) }
            
            // Effective profit = kept profit + savings from not replacing skipped
            let effectiveProfit = keptProfit + (skippedReplacementSaved - skippedRevenue)
            
            if effectiveProfit > bestProfit {
                bestProfit = effectiveProfit
                bestFloor = floor
            }
            
            floorResults.append(FloorResult(
                floorPrice: floor,
                exportCount: kept.count,
                totalKwh: keptKwh,
                totalProfitCents: keptProfit,
                avgProfitCents: avgProfit,
                skippedCount: skipped.count,
                skippedRevenueCents: skippedRevenue,
                isOptimal: false  // Will update below
            ))
        }
        
        // Mark optimal
        floorResults = floorResults.map { result in
            var updated = result
            updated.isOptimal = result.floorPrice == bestFloor
            return updated
        }
        
        UserDefaults.standard.set(bestFloor, forKey: "optimal_floor_price")

        
        return FloorAnalysis(
            optimalFloorPrice: bestFloor,
            optimalProfitCents: bestProfit,
            baseProfitCents: baseProfit,
            improvementCents: bestProfit - baseProfit,
            floorResults: floorResults
        )
    }
    
    // MARK: - Analyze Replacement Sources
    
    private func analyzeReplacementSources(exports: [ExportEvent]) -> [SourceBreakdown] {
        let sourceOrder: [ReplacementSource] = [.pv, .mixedPv, .cheapGrid, .grid, .expensiveGrid, .unknown]
        
        return sourceOrder.compactMap { source -> SourceBreakdown? in
            let sourceExports = exports.filter { $0.replacementSource == source }
            guard !sourceExports.isEmpty else { return nil }
            
            return SourceBreakdown(
                source: source,
                count: sourceExports.count,
                totalKwh: sourceExports.reduce(0) { $0 + $1.energyKwh },
                avgSellPrice: sourceExports.map { $0.sellPrice }.average,
                avgReplacementPrice: sourceExports.map { $0.effectiveReplacementCost }.average,
                avgProfit: sourceExports.map { $0.profit }.average
            )
        }
    }
}

// MARK: - Export Event

struct ExportEvent: Codable, Sendable {
    let timestamp: Date
    let sellPrice: Double        // cents/kWh
    let energyKwh: Double
    let soc: Double
    let recordIndex: Int
    
    // Replacement tracking (calculated)
    var replacementPrice: Double = 0
    var replacementSource: ReplacementSource = .unknown
    var hoursToReplacement: Double = 0
    
    /// Replacement cost adjusted for efficiency
    var effectiveReplacementCost: Double {
        if replacementSource == .pv {
            return 0
        }
        return replacementPrice
    }
    
    /// Net profit per kWh (cents)
    var profit: Double {
        sellPrice - effectiveReplacementCost
    }
    
    var isProfitable: Bool {
        profit > 0
    }
}

// MARK: - Replacement Source

enum ReplacementSource: String, Codable, CaseIterable, Sendable {
    case pv = "PV"
    case mixedPv = "Mixed (PV+Grid)"
    case cheapGrid = "Cheap Grid"
    case grid = "Grid"                  // Moderate price (5-15¢)
    case expensiveGrid = "Expensive Grid"
    case unknown = "Unknown"
    
    var displayName: String { rawValue }
    
    var color: String {
        switch self {
        case .pv: return "green"
        case .mixedPv: return "mint"
        case .cheapGrid: return "blue"
        case .grid: return "cyan"
        case .expensiveGrid: return "orange"
        case .unknown: return "gray"
        }
    }
}

// MARK: - Analysis Results

struct PeakAnalysisResult: Codable, Sendable {
    let config: AnalysisConfig
    let analysisDate: Date
    let dateRange: DateInterval
    let totalExports: Int
    let totalKwh: Double
    let bucketAnalysis: [PriceBucketAnalysis]
    let floorAnalysis: FloorAnalysis
    let sourceBreakdown: [SourceBreakdown]
    let profitableKwh: Double
    
    var profitablePercent: Double {
        guard totalKwh > 0 else { return 0 }
        return (profitableKwh / totalKwh) * 100
    }
    
    var totalProfitDollars: Double {
        floorAnalysis.baseProfitCents / 100.0
    }
    
    var optimizedProfitDollars: Double {
        floorAnalysis.optimalProfitCents / 100.0
    }
    
    var improvementDollars: Double {
        floorAnalysis.improvementCents / 100.0
    }
}

struct PriceBucketAnalysis: Codable, Identifiable, Sendable {
    var id: String { "\(lowPrice)-\(highPrice)" }
    
    let lowPrice: Double
    let highPrice: Double
    let count: Int
    let totalKwh: Double
    let profitableCount: Int
    let profitablePercent: Double
    let avgProfitCents: Double
    let avgReplacementCents: Double
    let totalProfitCents: Double
    let pvPercent: Double
    var cumulativeProfitCents: Double  // Profit if floor set at lowPrice
    
    var priceRange: String {
        // Format as dollars for prices >= $1
        if lowPrice >= 100 {
            let lowDollars = Int(lowPrice / 100)
            let highDollars = Int(highPrice / 100)
            return "$\(lowDollars)-$\(highDollars)"
        }
        return "\(Int(lowPrice))-\(Int(highPrice))¢"
    }
    
    var isProfitable: Bool {
        avgProfitCents > 0
    }
    
    var cumulativeProfitDollars: Double {
        cumulativeProfitCents / 100.0
    }
}

struct FloorAnalysis: Codable, Sendable {
    let optimalFloorPrice: Double
    let optimalProfitCents: Double
    let baseProfitCents: Double
    let improvementCents: Double
    let floorResults: [FloorResult]
    
    var improvementPercent: Double {
        guard baseProfitCents != 0 else { return 0 }
        return (improvementCents / abs(baseProfitCents)) * 100
    }
}

struct FloorResult: Codable, Identifiable, Sendable {
    var id: Double { floorPrice }
    
    let floorPrice: Double
    let exportCount: Int
    let totalKwh: Double
    let totalProfitCents: Double
    let avgProfitCents: Double
    let skippedCount: Int
    let skippedRevenueCents: Double
    var isOptimal: Bool
    
    var totalProfitDollars: Double {
        totalProfitCents / 100.0
    }
}

struct SourceBreakdown: Codable, Identifiable, Sendable {
    var id: String { source.rawValue }
    
    let source: ReplacementSource
    let count: Int
    let totalKwh: Double
    let avgSellPrice: Double
    let avgReplacementPrice: Double
    let avgProfit: Double
}

// MARK: - Array Extension

extension Array where Element == Double {
    var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}

// MARK: - Formatted Output Extension

extension PeakAnalysisResult {
    
    /// Generate formatted text report (similar to Python output)
    func formattedReport() -> String {
        var lines: [String] = []
        
        lines.append(String(repeating: "=", count: 70))
        lines.append("PEAK EXPORT PROFITABILITY ANALYSIS (\(config.peakStartHour):00-\(config.peakEndHour):00)")
        lines.append(String(repeating: "=", count: 70))
        lines.append("")
        
        lines.append("Analysis Period: \(config.analysisWindowDays) days")
        lines.append("Total Peak Exports: \(totalExports)")
        lines.append("Total Energy: \(String(format: "%.1f", totalKwh)) kWh")
        lines.append("Profitable: \(String(format: "%.1f", profitableKwh)) kWh (\(String(format: "%.0f", profitablePercent))%)")
        lines.append("")
        
        // Bucket Analysis
        lines.append(String(repeating: "-", count: 70))
        lines.append("PROFITABILITY BY SELL PRICE")
        lines.append(String(repeating: "-", count: 70))
        lines.append("")
        
        lines.append("  Price       N       kWh      Profit%   Avg Profit  Avg Repl")
        lines.append("  ----------  ------  -------  --------  ----------  --------")
        
        for bucket in bucketAnalysis {
            let status = bucket.isProfitable ? "✅" : "❌"
            let priceRange = "\(Int(bucket.lowPrice))-\(Int(bucket.highPrice))¢".padding(toLength: 10, withPad: " ", startingAt: 0)
            let count = String(bucket.count).padding(toLength: 6, withPad: " ", startingAt: 0)
            let kwh = String(format: "%.0f", bucket.totalKwh).padding(toLength: 7, withPad: " ", startingAt: 0)
            let profPct = String(format: "%.0f%%", bucket.profitablePercent).padding(toLength: 6, withPad: " ", startingAt: 0)
            let avgProfit = String(format: "%+.1f¢", bucket.avgProfitCents).padding(toLength: 10, withPad: " ", startingAt: 0)
            let avgRepl = String(format: "%.1f¢", bucket.avgReplacementCents).padding(toLength: 8, withPad: " ", startingAt: 0)
            
            lines.append("  \(priceRange)  \(count)  \(kwh)  \(profPct) \(status)  \(avgProfit)  \(avgRepl)")
        }
        
        // Floor Analysis
        lines.append("")
        lines.append(String(repeating: "-", count: 70))
        lines.append("OPTIMAL SELL FLOOR")
        lines.append(String(repeating: "-", count: 70))
        lines.append("")
        
        lines.append("  Floor     Exports   kWh       Total Profit   Avg Profit")
        lines.append("  --------  --------  --------  -------------  ----------")
        
        for floor in floorAnalysis.floorResults {
            let marker = floor.isOptimal ? "⭐" : "  "
            let floorPrice = "\(Int(floor.floorPrice))¢ \(marker)".padding(toLength: 8, withPad: " ", startingAt: 0)
            let exports = String(floor.exportCount).padding(toLength: 8, withPad: " ", startingAt: 0)
            let kwh = String(format: "%.0f", floor.totalKwh).padding(toLength: 8, withPad: " ", startingAt: 0)
            let totalProfit = String(format: "$%.2f", floor.totalProfitDollars).padding(toLength: 13, withPad: " ", startingAt: 0)
            let avgProfit = String(format: "%+.1f¢", floor.avgProfitCents).padding(toLength: 10, withPad: " ", startingAt: 0)
            
            lines.append("  \(floorPrice)  \(exports)  \(kwh)  \(totalProfit)  \(avgProfit)")
        }
        
        lines.append("")
        lines.append("  ⭐ OPTIMAL FLOOR: \(Int(floorAnalysis.optimalFloorPrice))¢")
        lines.append(String(format: "     Total profit at optimal: $%.2f", optimizedProfitDollars))
        lines.append(String(format: "     vs no floor: $%.2f", totalProfitDollars))
        lines.append(String(format: "     Improvement: $%.2f", improvementDollars))
        
        // Source Breakdown
        lines.append("")
        lines.append(String(repeating: "-", count: 70))
        lines.append("REPLACEMENT SOURCE BREAKDOWN")
        lines.append(String(repeating: "-", count: 70))
        lines.append("")
        
        lines.append("  Source              Count    kWh      Avg Sell   Avg Repl   Profit")
        lines.append("  ------------------  -------  -------  ---------  ---------  -------")
        
        for source in sourceBreakdown {
            let name = source.source.displayName.padding(toLength: 18, withPad: " ", startingAt: 0)
            let count = String(source.count).padding(toLength: 7, withPad: " ", startingAt: 0)
            let kwh = String(format: "%.0f", source.totalKwh).padding(toLength: 7, withPad: " ", startingAt: 0)
            let avgSell = String(format: "%.1f¢", source.avgSellPrice).padding(toLength: 9, withPad: " ", startingAt: 0)
            let avgRepl = String(format: "%.1f¢", source.avgReplacementPrice).padding(toLength: 9, withPad: " ", startingAt: 0)
            let profit = String(format: "%+.1f¢", source.avgProfit).padding(toLength: 7, withPad: " ", startingAt: 0)
            
            lines.append("  \(name)  \(count)  \(kwh)  \(avgSell)  \(avgRepl)  \(profit)")
        }
        
        // Recommendation
        lines.append("")
        lines.append(String(repeating: "=", count: 70))
        lines.append("RECOMMENDATION")
        lines.append(String(repeating: "=", count: 70))
        lines.append("")
        
        lines.append("  Set PEAK_MIN_SELL_PRICE = \(Int(floorAnalysis.optimalFloorPrice)).0")
        lines.append(String(format: "  Expected improvement: $%.2f over %d days", improvementDollars, config.analysisWindowDays))
        
        if config.analysisWindowDays > 0 {
            let dailyImprovement = improvementDollars / Double(config.analysisWindowDays)
            let monthlyImprovement = dailyImprovement * 30
            let yearlyImprovement = dailyImprovement * 365
            lines.append(String(format: "  Projected monthly: $%.2f", monthlyImprovement))
            lines.append(String(format: "  Projected yearly: $%.2f", yearlyImprovement))
        }
        
        return lines.joined(separator: "\n")
    }
}
