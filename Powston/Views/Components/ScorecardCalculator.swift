//
//  ScorecardCalculator.swift
//  Powston
//
//  Performance scorecard calculation engine
//  Ports analysis logic from Python scripts to Swift
//

import Foundation

// MARK: - Scorecard Models

struct Scorecard: Codable, Identifiable {
    var id: String { "\(siteId)_\(periodStart)_\(periodEnd)" }

    let generatedAt: Date
    let siteId: Int
    let periodStart: Date
    let periodEnd: Date
    let daysAnalyzed: Int

    // Overall
    let overallScore: Double
    let overallGrade: String

    // Cohort position (affects grade floor/ceiling)
    let cohortRank: Int?           // User's rank (1 = first place)
    let cohortSize: Int?           // Total sites in cohort
    let cohortPercentile: Int?     // User's percentile (1 = top 1%)
    let cohortAdjusted: Bool       // True if grade was adjusted by cohort position

    // Components
    let components: [ScoreComponent]

    // Financials
    let totalCost: Double
    let fixedCosts: Double
    let energyCosts: Double
    let earnings: Double
    let netPosition: Double

    // Key metrics
    let metrics: ScorecardMetrics

    // Recommendations
    let recommendations: [Recommendation]

    // Daily breakdown
    let dailyGrades: [DailyGrade]

    // Computed helpers
    var dailyAverage: Double {
        daysAnalyzed > 0 ? netPosition / Double(daysAnalyzed) : 0
    }

    var monthlyProjected: Double {
        dailyAverage * 30
    }

    var cohortPositionText: String? {
        guard let rank = cohortRank, let size = cohortSize, size >= 3 else { return nil }
        return "#\(rank) of \(size) in cohort"
    }
}

struct ScoreComponent: Codable, Identifiable {
    var id: String { name }
    
    let name: String
    let score: Double      // 0-100
    let grade: String      // A/B/C/D/F
    let value: String      // Display value
    let status: String     // ✓/⚠/✗
    let detail: String     // Explanation
}

struct Recommendation: Codable, Identifiable {
    var id: String { "\(priority)_\(category)" }
    
    let priority: Int      // 1=high, 2=medium, 3=low
    let category: String
    let action: String
    let potentialSavings: Double  // $/month
    
    var priorityIcon: String {
        switch priority {
        case 1: return "🔴"
        case 2: return "🟡"
        default: return "🟢"
        }
    }
}

struct DailyGrade: Codable, Identifiable {
    var id: String { date }
    
    let date: String
    let netCost: Double
    let grade: String
    
    var gradeIcon: String {
        switch grade {
        case "A", "B": return "✓"
        case "C": return "⚠"
        default: return "✗"
        }
    }
}

struct ScorecardMetrics: Codable {
    let timing: TimingMetrics
    let overnight: OvernightMetrics
    let opportunities: OpportunityMetrics
    let financials: FinancialMetrics
}

struct TimingMetrics: Codable {
    let timingScore: Double
    let peakAvoidancePct: Double
    let avgBuyRate: Double
    let avgSellRate: Double
    let spreadCaptured: Double
    let totalImportKwh: Double
    let totalExportKwh: Double
    let peakImportKwh: Double
    let peakExportKwh: Double
    // Optimal/benchmark comparison
    let actualImportCost: Double      // What you paid (cents)
    let optimalImportCost: Double     // Best possible (cents) - theoretical or cohort #1
    let actualExportRevenue: Double   // What you earned (cents)
    let optimalExportRevenue: Double  // Best possible (cents)
    let actualNet: Double             // Actual profit (cents)
    let optimalNet: Double            // Best possible profit (cents)
    let efficiencyPct: Double         // actual/optimal as percentage
    // Cohort benchmark info
    let usedCohortBenchmark: Bool     // true if using leaderboard #1, false if theoretical
    let cohortBestEfficiency: Double? // Cohort #1's efficiency (¢/kWh of battery) if available
}

struct OvernightMetrics: Codable {
    let overnightScore: Double
    let nightsAnalyzed: Int
    let nightsWithImports: Int
    let overnightImportKwh: Double
    let overnightCost: Double
    let expensiveImportCost: Double
    let avgOvernightRate: Double
    let morningSurvivalRate: Double
    let morningSurvivals: Int
    let morningFailures: Int
    let avg9pmSoc: Double
    let avg6amSoc: Double
}

// MARK: - Missed Opportunity Tracking

enum OpportunityType: String, Codable {
    case export = "Export"
    case cheapImport = "Import"
    case negativePrice = "Negative"
}

struct MissedOpportunity: Codable, Identifiable {
    var id: String { "\(type.rawValue)_\(timestamp)" }
    
    let timestamp: String       // "5:25 AM" format for display
    let fullTimestamp: Date     // For sorting
    let type: OpportunityType
    let price: Double           // ¢/kWh at that moment
    let soc: Double             // Battery SOC at that moment
    let windowAction: Double    // kWh exported/imported in 15-min window
    
    /// Inferred reason why opportunity was missed
    var inferredReason: String {
        switch type {
        case .export:
            if soc < 20 {
                return "Low SOC (\(Int(soc))%)"
            } else if soc < 30 {
                return "SOC reserve (\(Int(soc))%)"
            } else {
                return "No export (\(Int(soc))% SOC)"
            }
        case .cheapImport, .negativePrice:
            if soc > 95 {
                return "Battery full (\(Int(soc))%)"
            } else if soc > 85 {
                return "Near full (\(Int(soc))%)"
            } else {
                return "No import (\(Int(soc))% SOC)"
            }
        }
    }
}

struct OpportunityMetrics: Codable {
    let opportunityScore: Double
    let exportOpportunities: Int
    let exportTaken: Int
    let exportCapturePct: Double
    let importOpportunities: Int
    let importTaken: Int
    let importCapturePct: Double
    let negativePeriods: Int
    let negativeTaken: Int
    let negativeCapturePct: Double
    
    // Detailed missed opportunities for drill-down
    let missedExports: [MissedOpportunity]
    let missedImports: [MissedOpportunity]
    let missedNegatives: [MissedOpportunity]
}

struct FinancialMetrics: Codable {
    let totalCost: Double
    let energyCost: Double
    let fixedCost: Double
    let totalEarnings: Double
    let netPosition: Double
    let arbitrageProfit: Double
}

// MARK: - Period Enum

enum ScorecardPeriod: String, CaseIterable, Identifiable {
    case day = "Yesterday"
    case week = "Week"
    case month = "Month"
    
    var id: String { rawValue }
    
    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }
    
#if !os(tvOS)
/// Map to LeaderboardPeriod for benchmark lookup
var leaderboardPeriod: LeaderboardPeriod {
    switch self {
    case .day: return .yesterday
    case .week: return .week
    case .month: return .month
    }
}
#endif
}

// MARK: - Calculator

class ScorecardCalculator {
    
    // Configuration (passed in)
    private let peakStart: Int
    private let peakEnd: Int
    private let overnightEnd = 6
    
    // Thresholds
    private let spikeSellPrice = 15.0      // ¢/kWh
    private let ultraCheapBuy = 2.0        // ¢/kWh
    private let expensiveImportRate = 10.0 // ¢/kWh
    private let cheapRateThreshold = 5.0   // ¢/kWh - morning survival threshold
    
    // Site timezone (passed in from site configuration)
    private let siteTimezone: TimeZone
    
    // Inverter capacity for optimal calculations (watts)
    private let inverterCapacityWatts: Double
    
    // Cohort benchmark (from leaderboard)
    private let cohortBestEfficiency: Double?  // ¢/kWh of battery - cohort #1's performance
    private let batteryCapacityKWh: Double?    // For calculating benchmark net from efficiency
    private let cohortPercentile: Int?         // User's percentile in cohort (1 = top 1%, 100 = bottom)
    private let cohortRank: Int?               // User's rank in cohort (1 = first place)
    private let cohortSize: Int?               // Total sites in cohort

    init(
        timezone: TimeZone? = nil,
        peakStartHour: Int = 16,
        peakEndHour: Int = 21,
        inverterCapacityWatts: Double = 20000,
        cohortBestEfficiency: Double? = nil,
        batteryCapacityKWh: Double? = nil,
        cohortPercentile: Int? = nil,
        cohortRank: Int? = nil,
        cohortSize: Int? = nil
    ) {
        // Default to Brisbane if not specified
        self.siteTimezone = timezone ?? TimeZone(identifier: "Australia/Brisbane")!
        self.peakStart = peakStartHour
        self.peakEnd = peakEndHour
        self.inverterCapacityWatts = inverterCapacityWatts
        self.cohortBestEfficiency = cohortBestEfficiency
        self.batteryCapacityKWh = batteryCapacityKWh
        self.cohortPercentile = cohortPercentile
        self.cohortRank = cohortRank
        self.cohortSize = cohortSize
    }
    
    // MARK: - Main Entry Point
    
    func calculate(records: [MeterRecord], siteId: Int, from: Date, to: Date) -> Scorecard {
        let byDateHour = groupByDateHour(records)
        
        let timing = analyzeTiming(records: records, byDateHour: byDateHour)
        let overnight = analyzeOvernight(records: records, byDateHour: byDateHour)
        let opportunities = analyzeOpportunities(records: records)
        let financials = analyzeFinancials(records: records, byDateHour: byDateHour)
        
        let components = buildComponents(timing: timing, overnight: overnight, opportunities: opportunities)
        
        // Weighted overall score
        let weights: [String: Double] = [
            "Timing Efficiency": 0.20,
            "Peak Avoidance": 0.25,
            "Overnight Efficiency": 0.20,
            "Morning Survival": 0.15,
            "Opportunity Capture": 0.20
        ]

        var overallScore = components.reduce(0.0) { sum, component in
            sum + component.score * (weights[component.name] ?? 0.2)
        }

        // Apply cohort-based floor/ceiling
        // If you're #1 in your cohort, you get an A regardless of absolute metrics
        // If you're in the bottom, your grade is capped
        let rawScore = overallScore
        var cohortAdjusted = false

        if let rank = cohortRank, let size = cohortSize, size >= 3 {
            if rank == 1 {
                // #1 in cohort = minimum A grade (90)
                let newScore = max(overallScore, 90)
                if newScore > overallScore {
                    cohortAdjusted = true
                    print("📊 Cohort bonus: #1 of \(size) → score floor 90 (was \(rawScore.rounded(to: 1)))")
                }
                overallScore = newScore
            } else if rank == 2 && size >= 5 {
                // #2 in decent-sized cohort = minimum B+ (80)
                let newScore = max(overallScore, 80)
                if newScore > overallScore { cohortAdjusted = true }
                overallScore = newScore
            } else if rank == 3 && size >= 10 {
                // #3 in large cohort = minimum B (70)
                let newScore = max(overallScore, 70)
                if newScore > overallScore { cohortAdjusted = true }
                overallScore = newScore
            }

            // Bottom 20% of cohort = ceiling at C (69)
            let bottomThreshold = max(1, Int(Double(size) * 0.8))
            if rank > bottomThreshold && size >= 5 {
                let newScore = min(overallScore, 69)
                if newScore < overallScore {
                    cohortAdjusted = true
                    print("📊 Cohort ceiling: #\(rank) of \(size) (bottom 20%) → score ceiling 69")
                }
                overallScore = newScore
            }
        } else if let percentile = cohortPercentile {
            // Fallback to percentile if rank not available
            if percentile <= 5 {
                let newScore = max(overallScore, 90)
                if newScore > overallScore { cohortAdjusted = true }
                overallScore = newScore
            } else if percentile <= 15 {
                let newScore = max(overallScore, 80)
                if newScore > overallScore { cohortAdjusted = true }
                overallScore = newScore
            } else if percentile <= 25 {
                let newScore = max(overallScore, 70)
                if newScore > overallScore { cohortAdjusted = true }
                overallScore = newScore
            } else if percentile >= 80 {
                let newScore = min(overallScore, 69)
                if newScore < overallScore { cohortAdjusted = true }
                overallScore = newScore
            }
        }
        
        let recommendations = generateRecommendations(timing: timing, overnight: overnight, opportunities: opportunities, financials: financials)
        
        let dailyGrades = buildDailyGrades(financials: financials)
        
        let metrics = ScorecardMetrics(
            timing: timing,
            overnight: overnight,
            opportunities: opportunities,
            financials: financials
        )
        
        return Scorecard(
            generatedAt: Date(),
            siteId: siteId,
            periodStart: from,
            periodEnd: to,
            daysAnalyzed: byDateHour.count,
            overallScore: overallScore.rounded(to: 1),
            overallGrade: scoreToGrade(overallScore),
            cohortRank: cohortRank,
            cohortSize: cohortSize,
            cohortPercentile: cohortPercentile,
            cohortAdjusted: cohortAdjusted,
            components: components,
            totalCost: financials.totalCost,
            fixedCosts: financials.fixedCost,
            energyCosts: financials.energyCost,
            earnings: financials.totalEarnings,
            netPosition: financials.netPosition,
            metrics: metrics,
            recommendations: recommendations,
            dailyGrades: dailyGrades
        )
    }
    
    // MARK: - Grouping
    
    private func groupByDateHour(_ records: [MeterRecord]) -> [String: [Int: [MeterRecord]]] {
        var result: [String: [Int: [MeterRecord]]] = [:]
        
        // Configure formatters and calendar for Brisbane timezone
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = siteTimezone
        
        var calendar = Calendar.current
        calendar.timeZone = siteTimezone
        
        for record in records {
            guard let utcDate = record.date else { continue }
            
            // Let the formatter/calendar handle timezone conversion - don't manually add hours
            let dateKey = dateFormatter.string(from: utcDate)
            let hour = calendar.component(.hour, from: utcDate)
            
            if result[dateKey] == nil {
                result[dateKey] = [:]
            }
            if result[dateKey]![hour] == nil {
                result[dateKey]![hour] = []
            }
            result[dateKey]![hour]!.append(record)
        }
        
        return result
    }
    
    // MARK: - Timing Analysis
    
    private func analyzeTiming(records: [MeterRecord], byDateHour: [String: [Int: [MeterRecord]]]) -> TimingMetrics {
        var totalImport: Double = 0
        var totalExport: Double = 0
        var totalImportCost: Double = 0  // Total cost including fixed/network
        var totalEarnings: Double = 0
        var peakImport: Double = 0
        var peakExport: Double = 0
        
        // For optimal calculation - collect all intervals with their rates and capacities
        var intervals: [IntervalData] = []
        let intervalHours = 5.0 / 60.0  // 5-minute intervals
        let maxImportPerInterval = (inverterCapacityWatts / 1000.0) * intervalHours
        
        for (_, hours) in byDateHour {
            for (hour, hourRecords) in hours {
                for r in hourRecords {
                    let importKwh = r.energyImport ?? 0
                    let exportKwh = r.energyExport ?? 0
                    // Use energy costs only (not total costs) - excludes network/supply fees
                    // This scores only the controllable timing decisions, not fixed fees
                    let importCost = r.energyCosts ?? 0
                    let exportRevenue = r.earnings ?? 0

                    totalImport += importKwh
                    totalExport += exportKwh
                    totalImportCost += importCost
                    totalEarnings += exportRevenue

                    if hour >= peakStart && hour < peakEnd {
                        peakImport += importKwh
                        peakExport += exportKwh
                    }

                    // Calculate rates for this interval (energy costs only)
                    let importRate = importKwh > 0.001 ? importCost / importKwh : 0
                    let exportRate = exportKwh > 0.001 ? exportRevenue / exportKwh : 0
                    
                    // Max export capacity = inverter + solar - house (can't export more than available)
                    let solarKw = (r.ppvGeneration ?? 0) / 1000.0
                    let houseKw = (r.houseConsumption ?? 0) / 1000.0
                    let maxExportKw = max(0, (inverterCapacityWatts / 1000.0) + solarKw - houseKw)
                    let maxExportPerInterval = maxExportKw * intervalHours
                    
                    // Only include intervals where we have rate data
                    if importRate > 0 || exportRate > 0 {
                        intervals.append(IntervalData(
                            importRate: importRate,
                            exportRate: exportRate,
                            maxImportKwh: maxImportPerInterval,
                            maxExportKwh: maxExportPerInterval
                        ))
                    }
                }
            }
        }
        
        // Determine benchmark: use cohort best if available, otherwise theoretical optimal
        let usedCohortBenchmark: Bool
        let benchmarkOptimalImportCost: Double
        let benchmarkOptimalExportRevenue: Double
        let benchmarkOptimalNet: Double
        
        if let cohortEff = cohortBestEfficiency, let batteryKWh = batteryCapacityKWh, batteryKWh > 0 {
            // Use cohort benchmark: scale cohort's efficiency by our battery size
            // Cohort efficiency is ¢/kWh of battery capacity
            // Our benchmark net = cohortEff * our battery size * days in period
            let benchmarkNet = cohortEff * batteryKWh  // cents per day, already aggregated by period
            
            // We don't know the breakdown of import/export for cohort, so estimate
            // The key metric is the net profit, so we'll set optimal values such that net matches
            benchmarkOptimalNet = benchmarkNet
            // Estimate: cohort achieved this by being ~80% more efficient on imports and ~20% better on exports
            benchmarkOptimalImportCost = totalImportCost * 0.15  // Best case: pay 15% of actual
            benchmarkOptimalExportRevenue = benchmarkOptimalNet + benchmarkOptimalImportCost
            usedCohortBenchmark = true
            print("📊 Using cohort benchmark: \(cohortEff)¢/kWh × \(batteryKWh)kWh = $\(benchmarkNet/100)")
        } else {
            // Fall back to theoretical optimal
            benchmarkOptimalImportCost = calculateOptimalImport(intervals: intervals, totalNeeded: totalImport)
            benchmarkOptimalExportRevenue = calculateOptimalExport(intervals: intervals, totalToSell: totalExport)
            benchmarkOptimalNet = benchmarkOptimalExportRevenue - benchmarkOptimalImportCost
            usedCohortBenchmark = false
        }
        
        // Calculate efficiency
        let actualNet = totalEarnings - totalImportCost  // Actual profit (cents)
        
        // Efficiency as percentage of benchmark captured
        let efficiencyPct: Double
        if benchmarkOptimalNet > 0 {
            efficiencyPct = min(100, max(0, (actualNet / benchmarkOptimalNet) * 100))
        } else if actualNet >= 0 && benchmarkOptimalNet <= 0 {
            efficiencyPct = 100
        } else {
            efficiencyPct = benchmarkOptimalNet < 0 ? min(100, max(0, (benchmarkOptimalNet / actualNet) * 100)) : 0
        }
        
        // Scoring: Profitable = passing grade (50+), losses scale down from 50
        // If profitable: base 50 + up to 50 bonus based on efficiency
        // If loss: scale from 0-50 based on how close to breakeven
        let timingScore: Double
        if actualNet >= 0 {
            // Profitable: guaranteed passing grade
            // 50 base + bonus scaled so 100% efficiency = 100 points
            let bonus = min(50, efficiencyPct / 2)  // 100% eff = 50 bonus = 100 total
            timingScore = 50 + bonus
        } else {
            // Loss: score 0-50 based on how bad the loss is relative to benchmark
            if benchmarkOptimalNet > 0 {
                let lossRatio = abs(actualNet) / benchmarkOptimalNet
                timingScore = max(0, 50 - (lossRatio * 50))
            } else {
                timingScore = 25
            }
        }
        
        let peakAvoidance = totalImport > 0 ? 100 * (1 - peakImport / totalImport) : 100
        let avgBuyRate = totalImport > 0 ? totalImportCost / totalImport : 0
        let avgSellRate = totalExport > 0 ? totalEarnings / totalExport : 0
        let spreadCaptured = avgSellRate - avgBuyRate
        
        return TimingMetrics(
            timingScore: timingScore.rounded(to: 1),
            peakAvoidancePct: peakAvoidance.rounded(to: 1),
            avgBuyRate: avgBuyRate.rounded(to: 2),
            avgSellRate: avgSellRate.rounded(to: 2),
            spreadCaptured: spreadCaptured.rounded(to: 2),
            totalImportKwh: totalImport.rounded(to: 1),
            totalExportKwh: totalExport.rounded(to: 1),
            peakImportKwh: peakImport.rounded(to: 1),
            peakExportKwh: peakExport.rounded(to: 1),
            actualImportCost: totalImportCost.rounded(to: 2),
            optimalImportCost: benchmarkOptimalImportCost.rounded(to: 2),
            actualExportRevenue: totalEarnings.rounded(to: 2),
            optimalExportRevenue: benchmarkOptimalExportRevenue.rounded(to: 2),
            actualNet: actualNet.rounded(to: 2),
            optimalNet: benchmarkOptimalNet.rounded(to: 2),
            efficiencyPct: efficiencyPct.rounded(to: 1),
            usedCohortBenchmark: usedCohortBenchmark,
            cohortBestEfficiency: cohortBestEfficiency
        )
    }
    
    // MARK: - Optimal Calculation Helpers
    
    private struct IntervalData {
        let importRate: Double      // ¢/kWh
        let exportRate: Double      // ¢/kWh
        let maxImportKwh: Double    // Max import this interval
        let maxExportKwh: Double    // Max export this interval (considering solar/house)
    }
    
    private func calculateOptimalImport(intervals: [IntervalData], totalNeeded: Double) -> Double {
        // Filter to intervals with valid import rates and sort by rate ascending (cheapest first)
        let importOptions = intervals
            .filter { $0.importRate > 0 && $0.maxImportKwh > 0 }
            .sorted { $0.importRate < $1.importRate }
        
        // Fill import needs from cheapest slots
        var remaining = totalNeeded
        var totalCost: Double = 0
        
        for option in importOptions {
            if remaining <= 0 { break }
            let take = min(remaining, option.maxImportKwh)
            totalCost += take * option.importRate
            remaining -= take
        }
        
        return totalCost
    }
    
    private func calculateOptimalExport(intervals: [IntervalData], totalToSell: Double) -> Double {
        // Filter to intervals with valid export rates and sort by rate descending (highest paying first)
        let exportOptions = intervals
            .filter { $0.exportRate > 0 && $0.maxExportKwh > 0 }
            .sorted { $0.exportRate > $1.exportRate }
        
        // Fill export volume from highest-paying slots
        var remaining = totalToSell
        var totalRevenue: Double = 0
        
        for option in exportOptions {
            if remaining <= 0 { break }
            let take = min(remaining, option.maxExportKwh)
            totalRevenue += take * option.exportRate
            remaining -= take
        }
        
        return totalRevenue
    }
    
    // MARK: - Overnight Analysis
    
    private func analyzeOvernight(records: [MeterRecord], byDateHour: [String: [Int: [MeterRecord]]]) -> OvernightMetrics {
        let dates = byDateHour.keys.sorted()
        
        var overnightImports: Double = 0
        var overnightCosts: Double = 0
        var nightsWithImports = 0
        var nightsAnalyzed = 0
        var expensiveImportCost: Double = 0
        
        var morningSurvivals = 0
        var morningFailures = 0
        
        var socsAt9pm: [Double] = []
        var socsAt6am: [Double] = []
        
        // Threshold for "cheap rates have arrived" (¢/kWh)
        let cheapRateThreshold = 5.0
        
        // Handle single-day case (Yesterday view)
        // For one day, we analyze: evening (9 PM - midnight) AND morning (midnight - 6 AM) of that same calendar day
        if dates.count == 1 {
            let date = dates[0]
            nightsAnalyzed = 1
            
            var nightImport: Double = 0
            var nightCost: Double = 0
            
            // Evening hours (9 PM - midnight) of this date
            for hour in peakEnd..<24 {
                if let hourRecords = byDateHour[date]?[hour] {
                    for r in hourRecords {
                        nightImport += r.energyImport ?? 0
                        nightCost += r.energyCosts ?? 0
                        
                        if hour == peakEnd, let soc = r.startBatterySoc {
                            socsAt9pm.append(soc)
                        }
                    }
                }
            }
            
            // Morning hours (midnight - 6 AM) of this date
            for hour in 0..<overnightEnd {
                if let hourRecords = byDateHour[date]?[hour] {
                    for r in hourRecords {
                        nightImport += r.energyImport ?? 0
                        nightCost += r.energyCosts ?? 0
                    }
                }
            }
            
            // 6 AM SOC from this date
            if let hourRecords = byDateHour[date]?[overnightEnd],
               let first = hourRecords.first,
               let soc = first.startBatterySoc {
                socsAt6am.append(soc)
            }
            
            overnightImports = nightImport
            overnightCosts = nightCost
            
            if nightImport > 2 {
                nightsWithImports = 1
            }
            
            if nightCost > 0 && nightImport > 0.5 {
                let rate = nightCost / nightImport
                if rate > expensiveImportRate {
                    expensiveImportCost = nightCost
                }
            }
            
            // Morning survival check for this date
            var morningImport: Double = 0
            morningLoop: for hour in overnightEnd..<14 {
                if let hourRecords = byDateHour[date]?[hour] {
                    for r in hourRecords {
                        let pvWatts = r.ppvGeneration ?? 0
                        if pvWatts >= 2000 {
                            break morningLoop
                        }
                        
                        let importKwh = r.energyImport ?? 0
                        
                        if importKwh > 0.01 {
                            let importRate = (r.energyCosts ?? 0) / importKwh
                            if importRate < cheapRateThreshold {
                                break morningLoop
                            }
                        } else if (r.rrp ?? 100) / 10 < cheapRateThreshold - 3 {
                            break morningLoop
                        }
                        
                        morningImport += importKwh
                    }
                }
            }
            
            if morningImport < 2 {
                morningSurvivals = 1
            } else {
                morningFailures = 1
            }
            
        } else {
            // Multi-day case: analyze transitions between consecutive dates
            for i in 0..<(dates.count - 1) {
                let date = dates[i]
                let nextDate = dates[i + 1]
                nightsAnalyzed += 1
                
                var nightImport: Double = 0
                var nightCost: Double = 0
                
                // Evening (9 PM - midnight)
                for hour in peakEnd..<24 {
                    if let hourRecords = byDateHour[date]?[hour] {
                        for r in hourRecords {
                            nightImport += r.energyImport ?? 0
                            nightCost += r.energyCosts ?? 0
                            
                            if hour == peakEnd, let soc = r.startBatterySoc {
                                socsAt9pm.append(soc)
                            }
                        }
                    }
                }
                
                // Morning (midnight - 6 AM)
                for hour in 0..<overnightEnd {
                    if let hourRecords = byDateHour[nextDate]?[hour] {
                        for r in hourRecords {
                            nightImport += r.energyImport ?? 0
                            nightCost += r.energyCosts ?? 0
                        }
                    }
                }
                
                // 6 AM SOC
                if let hourRecords = byDateHour[nextDate]?[overnightEnd],
                   let first = hourRecords.first,
                   let soc = first.startBatterySoc {
                    socsAt6am.append(soc)
                }
                
                overnightImports += nightImport
                overnightCosts += nightCost
                
                if nightImport > 2 {
                    nightsWithImports += 1
                }
                
                if nightCost > 0 && nightImport > 0.5 {
                    let rate = nightCost / nightImport
                    if rate > expensiveImportRate {
                        expensiveImportCost += nightCost
                    }
                }
                
                // Morning survival: 6 AM until solar kicks in or cheap rates arrive
                var morningImport: Double = 0
                
                morningLoop: for hour in overnightEnd..<14 {
                    if let hourRecords = byDateHour[nextDate]?[hour] {
                        for r in hourRecords {
                            let pvWatts = r.ppvGeneration ?? 0
                            if pvWatts >= 2000 {
                                break morningLoop
                            }
                            
                            let importKwh = r.energyImport ?? 0
                            
                            if importKwh > 0.01 {
                                let importRate = (r.energyCosts ?? 0) / importKwh
                                if importRate < cheapRateThreshold {
                                    break morningLoop
                                }
                            } else if (r.rrp ?? 100) / 10 < cheapRateThreshold - 3 {
                                break morningLoop
                            }
                            
                            morningImport += importKwh
                        }
                    }
                }
                
                if morningImport < 2 {
                    morningSurvivals += 1
                } else {
                    morningFailures += 1
                }
            }
        }
        
        let avg9pmSoc = socsAt9pm.isEmpty ? 0 : socsAt9pm.reduce(0, +) / Double(socsAt9pm.count)
        let avg6amSoc = socsAt6am.isEmpty ? 0 : socsAt6am.reduce(0, +) / Double(socsAt6am.count)
        
        let importFrequency = nightsAnalyzed > 0 ? Double(nightsWithImports) / Double(nightsAnalyzed) : 0
        let overnightScore = 100 * (1 - importFrequency)
        
        let totalMornings = morningSurvivals + morningFailures
        let survivalRate = totalMornings > 0 ? Double(morningSurvivals) / Double(totalMornings) * 100 : 100
        
        let avgOvernightRate = overnightImports > 0.5 ? overnightCosts / overnightImports : 0
        
        return OvernightMetrics(
            overnightScore: overnightScore.rounded(to: 1),
            nightsAnalyzed: nightsAnalyzed,
            nightsWithImports: nightsWithImports,
            overnightImportKwh: overnightImports.rounded(to: 1),
            overnightCost: (overnightCosts / 100).rounded(to: 2),
            expensiveImportCost: (expensiveImportCost / 100).rounded(to: 2),
            avgOvernightRate: avgOvernightRate.rounded(to: 1),
            morningSurvivalRate: survivalRate.rounded(to: 1),
            morningSurvivals: morningSurvivals,
            morningFailures: morningFailures,
            avg9pmSoc: avg9pmSoc.rounded(to: 1),
            avg6amSoc: avg6amSoc.rounded(to: 1)
        )
    }
    
    // MARK: - Opportunity Analysis
    
    private func analyzeOpportunities(records: [MeterRecord]) -> OpportunityMetrics {
        let sortedRecords = records.sorted { ($0.intervalTime) < ($1.intervalTime) }
        
        var exportOpportunities = 0
        var exportTaken = 0
        var importOpportunities = 0
        var importTaken = 0
        var negativePeriods = 0
        var negativeTaken = 0
        
        // Track missed opportunities
        var missedExports: [MissedOpportunity] = []
        var missedImports: [MissedOpportunity] = []
        var missedNegatives: [MissedOpportunity] = []
        
        var counted: Set<String> = []
        
        // Time formatter for display
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "h:mm a"
        displayFormatter.timeZone = siteTimezone
        
        for i in 0..<sortedRecords.count {
            let rec = sortedRecords[i]
            guard let utcDate = rec.date else { continue }
            
            // Use calendar with Brisbane timezone - don't manually add hours
            var calendar = Calendar.current
            calendar.timeZone = siteTimezone
            let hour = calendar.component(.hour, from: utcDate)
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            dateFormatter.timeZone = siteTimezone
            let timestamp = dateFormatter.string(from: utcDate)
            
            let soc = rec.endBatterySoc ?? rec.startBatterySoc ?? 0
            let exportKwh = rec.energyExport ?? 0
            let importKwh = rec.energyImport ?? 0
            
            // Rolling window (15 min = 3 periods)
            var windowExport = exportKwh
            var windowImport = importKwh
            for j in 1..<3 {
                if i + j < sortedRecords.count {
                    let nextRec = sortedRecords[i + j]
                    windowExport += nextRec.energyExport ?? 0
                    windowImport += nextRec.energyImport ?? 0
                }
            }
            
            let rrp = rec.rrp ?? 0
            let rrpCkwh = rrp / 10
            
            // Sell price
            var sellPrice: Double
            if exportKwh > 0.1, let earnings = rec.earnings {
                sellPrice = earnings / exportKwh
            } else {
                sellPrice = max(0, rrpCkwh)
            }
            
            // Buy price estimate
            var actualBuyEstimate: Double
            if importKwh < 0.1 {
                actualBuyEstimate = rrpCkwh + 8.0
            } else if let costs = rec.energyCosts, importKwh > 0 {
                actualBuyEstimate = costs / importKwh
            } else {
                actualBuyEstimate = rrpCkwh + 8.0
            }
            
            // Export opportunity
            if sellPrice >= spikeSellPrice && soc > 15 {
                let oppKey = "export_\(String(timestamp.prefix(14)))"
                if !counted.contains(oppKey) {
                    counted.insert(oppKey)
                    exportOpportunities += 1
                    if windowExport >= 1.0 {
                        exportTaken += 1
                    } else {
                        // Missed export opportunity
                        missedExports.append(MissedOpportunity(
                            timestamp: displayFormatter.string(from: utcDate),
                            fullTimestamp: utcDate,
                            type: .export,
                            price: sellPrice,
                            soc: soc,
                            windowAction: windowExport
                        ))
                    }
                }
            }
            
            // Import opportunity (skip peak)
            let isPeak = hour >= peakStart && hour < peakEnd
            if !isPeak {
                if actualBuyEstimate < 0 {
                    let oppKey = "neg_\(String(timestamp.prefix(14)))"
                    if !counted.contains(oppKey) {
                        counted.insert(oppKey)
                        negativePeriods += 1
                        importOpportunities += 1
                        if windowImport >= 1.0 {
                            importTaken += 1
                            negativeTaken += 1
                        } else {
                            // Missed negative price opportunity
                            missedNegatives.append(MissedOpportunity(
                                timestamp: displayFormatter.string(from: utcDate),
                                fullTimestamp: utcDate,
                                type: .negativePrice,
                                price: actualBuyEstimate,
                                soc: soc,
                                windowAction: windowImport
                            ))
                        }
                    }
                } else if actualBuyEstimate < ultraCheapBuy && soc < 95 {
                    let oppKey = "cheap_\(String(timestamp.prefix(14)))"
                    if !counted.contains(oppKey) {
                        counted.insert(oppKey)
                        importOpportunities += 1
                        if windowImport >= 1.0 {
                            importTaken += 1
                        } else {
                            // Missed cheap import opportunity
                            missedImports.append(MissedOpportunity(
                                timestamp: displayFormatter.string(from: utcDate),
                                fullTimestamp: utcDate,
                                type: .cheapImport,
                                price: actualBuyEstimate,
                                soc: soc,
                                windowAction: windowImport
                            ))
                        }
                    }
                }
            }
        }
        
        let exportCapture = exportOpportunities > 0 ? Double(exportTaken) / Double(exportOpportunities) * 100 : 100
        let importCapture = importOpportunities > 0 ? Double(importTaken) / Double(importOpportunities) * 100 : 100
        let negativeCapture = negativePeriods > 0 ? Double(negativeTaken) / Double(negativePeriods) * 100 : 100
        
        let totalOpportunities = exportOpportunities + importOpportunities
        let totalTaken = exportTaken + importTaken
        let overallCapture = totalOpportunities > 0 ? Double(totalTaken) / Double(totalOpportunities) * 100 : 100
        
        return OpportunityMetrics(
            opportunityScore: overallCapture.rounded(to: 1),
            exportOpportunities: exportOpportunities,
            exportTaken: exportTaken,
            exportCapturePct: exportCapture.rounded(to: 1),
            importOpportunities: importOpportunities,
            importTaken: importTaken,
            importCapturePct: importCapture.rounded(to: 1),
            negativePeriods: negativePeriods,
            negativeTaken: negativeTaken,
            negativeCapturePct: negativeCapture.rounded(to: 1),
            missedExports: missedExports.sorted { $0.fullTimestamp < $1.fullTimestamp },
            missedImports: missedImports.sorted { $0.fullTimestamp < $1.fullTimestamp },
            missedNegatives: missedNegatives.sorted { $0.fullTimestamp < $1.fullTimestamp }
        )
    }
    
    // MARK: - Financial Analysis
    
    private func analyzeFinancials(records: [MeterRecord], byDateHour: [String: [Int: [MeterRecord]]]) -> FinancialMetrics {
        var totalCost: Double = 0
        var totalEnergyCost: Double = 0
        var totalFixedCost: Double = 0
        var totalEarnings: Double = 0
        
        for (_, hours) in byDateHour {
            for (_, hourRecords) in hours {
                for r in hourRecords {
                    totalCost += r.costs ?? 0
                    totalEnergyCost += r.energyCosts ?? 0
                    totalFixedCost += r.fixedCosts ?? 0
                    totalEarnings += r.earnings ?? 0
                }
            }
        }
        
        let arbitrage = (totalEarnings - totalEnergyCost) / 100
        
        return FinancialMetrics(
            totalCost: (totalCost / 100).rounded(to: 2),
            energyCost: (totalEnergyCost / 100).rounded(to: 2),
            fixedCost: (totalFixedCost / 100).rounded(to: 2),
            totalEarnings: (totalEarnings / 100).rounded(to: 2),
            netPosition: ((totalCost - totalEarnings) / 100).rounded(to: 2),
            arbitrageProfit: arbitrage.rounded(to: 2)
        )
    }
    
    // MARK: - Build Components
    
    private func buildComponents(timing: TimingMetrics, overnight: OvernightMetrics, opportunities: OpportunityMetrics) -> [ScoreComponent] {
        var components: [ScoreComponent] = []
        
        // Timing Efficiency
        components.append(ScoreComponent(
            name: "Timing Efficiency",
            score: timing.timingScore,
            grade: scoreToGrade(timing.timingScore),
            value: String(format: "%.0f%% of optimal", timing.efficiencyPct),
            status: scoreToStatus(timing.timingScore),
            detail: String(format: "Actual $%.2f vs Optimal $%.2f", timing.actualNet / 100, timing.optimalNet / 100)
        ))
        
        // Peak Avoidance
        components.append(ScoreComponent(
            name: "Peak Avoidance",
            score: timing.peakAvoidancePct,
            grade: scoreToGrade(timing.peakAvoidancePct),
            value: String(format: "%.1f%%", timing.peakAvoidancePct),
            status: scoreToStatus(timing.peakAvoidancePct),
            detail: String(format: "%.1f kWh imported during peak", timing.peakImportKwh)
        ))
        
        // Overnight Efficiency
        components.append(ScoreComponent(
            name: "Overnight Efficiency",
            score: overnight.overnightScore,
            grade: scoreToGrade(overnight.overnightScore),
            value: "\(overnight.nightsWithImports)/\(overnight.nightsAnalyzed) nights",
            status: scoreToStatus(overnight.overnightScore),
            detail: String(format: "$%.2f total overnight imports", overnight.overnightCost)
        ))
        
        // Morning Survival
        components.append(ScoreComponent(
            name: "Morning Survival",
            score: overnight.morningSurvivalRate,
            grade: scoreToGrade(overnight.morningSurvivalRate),
            value: String(format: "%.0f%%", overnight.morningSurvivalRate),
            status: scoreToStatus(overnight.morningSurvivalRate),
            detail: "\(overnight.morningSurvivals)/\(overnight.morningSurvivals + overnight.morningFailures) mornings survived to cheap rates"
        ))
        
        // Opportunity Capture
        components.append(ScoreComponent(
            name: "Opportunity Capture",
            score: opportunities.opportunityScore,
            grade: scoreToGrade(opportunities.opportunityScore),
            value: String(format: "%.0f%%", opportunities.opportunityScore),
            status: scoreToStatus(opportunities.opportunityScore),
            detail: String(format: "Export: %.0f%%, Import: %.0f%%, Negative: %.0f%%",
                          opportunities.exportCapturePct, opportunities.importCapturePct, opportunities.negativeCapturePct)
        ))
        
        return components
    }
    
    // MARK: - Recommendations
    
    private func generateRecommendations(timing: TimingMetrics, overnight: OvernightMetrics, opportunities: OpportunityMetrics, financials: FinancialMetrics) -> [Recommendation] {
        var recs: [Recommendation] = []
        
        // Overnight floor recommendation
        if overnight.nightsWithImports > overnight.nightsAnalyzed / 2 {
            recs.append(Recommendation(
                priority: 1,
                category: "Overnight Strategy",
                action: String(format: "Raise overnight floor by 5%% to retain more charge (avg 6 AM SOC: %.0f%%)", overnight.avg6amSoc),
                potentialSavings: overnight.expensiveImportCost
            ))
        }
        
        // Morning survival
        if overnight.morningSurvivalRate < 50 {
            recs.append(Recommendation(
                priority: 1,
                category: "Morning Buffer",
                action: String(format: "Increase overnight consumption estimate by ~300 Wh/hr to improve morning survival rate (%.0f%% → target 80%%+)", overnight.morningSurvivalRate),
                potentialSavings: Double(overnight.morningFailures) * 0.50
            ))
        }
        
        // Negative price capture
        if opportunities.negativePeriods > 0 && opportunities.negativeCapturePct < 80 {
            let missed = opportunities.negativePeriods - opportunities.negativeTaken
            recs.append(Recommendation(
                priority: 2,
                category: "Opportunity Capture",
                action: "Improve negative price response — missed \(missed) of \(opportunities.negativePeriods) opportunities",
                potentialSavings: Double(missed) * 0.50
            ))
        }
        
        // Peak avoidance
        if timing.peakAvoidancePct < 95 {
            let peakImportCost = timing.peakImportKwh * 0.25
            recs.append(Recommendation(
                priority: 1,
                category: "Peak Avoidance",
                action: String(format: "Reduce peak imports (%.1f kWh at ~25¢/kWh)", timing.peakImportKwh),
                potentialSavings: peakImportCost
            ))
        }
        
        // Spread optimization
        if timing.spreadCaptured < 2.0 {
            recs.append(Recommendation(
                priority: 3,
                category: "Arbitrage Spread",
                action: String(format: "Current spread %.1f¢ — consider adjusting export timing for better rates", timing.spreadCaptured),
                potentialSavings: timing.totalExportKwh * 0.01
            ))
        }
        
        return recs.sorted { $0.priority < $1.priority }
    }
    
    // MARK: - Daily Grades
    
    private func buildDailyGrades(financials: FinancialMetrics) -> [DailyGrade] {
        // This would need daily breakdown from the analysis
        // For now, return empty - we'll populate this when we have daily data
        return []
    }
    
    // MARK: - Helpers
    
    private func scoreToGrade(_ score: Double) -> String {
        if score >= 90 { return "A" }
        if score >= 80 { return "B+" }
        if score >= 70 { return "B" }
        if score >= 60 { return "C+" }
        if score >= 50 { return "C" }
        if score >= 40 { return "D" }
        return "F"
    }
    
    private func scoreToStatus(_ score: Double) -> String {
        if score >= 80 { return "✓" }
        if score >= 50 { return "⚠" }
        return "✗"
    }
}

// MARK: - Double Extension

extension Double {
    func rounded(to places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
