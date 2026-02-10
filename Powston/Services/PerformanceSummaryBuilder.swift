//
//  PerformanceSummaryBuilder.swift
//  Powston
//
//  Builds structured input for Foundation Models to generate natural language
//  summaries of historical performance (retrospective analysis)
//

import Foundation

// MARK: - Input Structure for Foundation Models

struct PerformanceSummaryInput: Codable {
    // Core outcome
    let period: String                    // "Yesterday", "Week", "Month"
    let periodDays: Int
    let grade: String
    let score: Int
    let netPositionDollars: Double
    let wasProfit: Bool
    
    // What went well (components with score >= 80)
    let strengths: [ComponentSummary]
    
    // What dragged score down (components with score < 60)
    let weaknesses: [ComponentSummary]
    
    // Financial context
    let totalCostDollars: Double
    let totalEarningsDollars: Double
    let avgBuyRateCents: Double
    let avgSellRateCents: Double
    let spreadCents: Double               // sell - buy (positive = good arbitrage)
    
    // Import/Export volumes
    let importKwh: Double
    let exportKwh: Double
    let peakImportKwh: Double
    
    // Missed opportunity rollup
    let missedExportCount: Int
    let missedExportPrices: [Double]      // For calculating potential revenue
    let missedImportCount: Int
    let missedNegativeCount: Int
    let topMissedReasons: [String: Int]   // Reason -> count
    let worstMissedExportPrice: Double?   // Highest price we didn't capture
    let bestMissedImportPrice: Double?    // Lowest/most negative price we didn't capture
    
    // Overnight metrics
    let avg9pmSoc: Double
    let avg6amSoc: Double
    let nightsWithImports: Int
    let nightsAnalyzed: Int
    let morningSurvivalRate: Double
    
    // Cross-period context (nil if not available)
    let weekNetPositionDollars: Double?
    let monthNetPositionDollars: Double?
    let weekGrade: String?
    let monthGrade: String?
    let trendDirection: String?           // "improving", "declining", "stable"
    
    // Cohort context (from leaderboard)
    let cohortPercentile: Int?
    let cohortRankingMode: String?
    let cohortSiteCount: Int?
    let cohortTopEfficiencyCents: Double? // Best performer's ¢/kWh
    let myEfficiencyCents: Double?        // My ¢/kWh
    
    // Anomalies detected
    let anomalies: [AnomalyInfo]
    
    // Recommendations from scorecard
    let recommendations: [RecommendationInfo]
    
    // System context
    let batteryCapacityKWh: Double?
    let inverterCapacityKw: Double?
}

struct ComponentSummary: Codable {
    let name: String
    let value: String
    let score: Int
}

struct AnomalyInfo: Codable {
    let severity: String      // "info", "warning", "critical"
    let category: String
    let description: String
}

struct RecommendationInfo: Codable {
    let priority: Int
    let category: String
    let action: String
}

// MARK: - Builder

class PerformanceSummaryBuilder {
    
    private let scorecard: Scorecard
    private let period: ScorecardPeriod
    private let batteryCapacityKWh: Double?
    private let inverterCapacityKw: Double?
    
    // Optional cross-period scorecards
    private var weekScorecard: Scorecard?
    private var monthScorecard: Scorecard?
    
    // Optional leaderboard context
    #if !os(tvOS)
    private var leaderboardState: LeaderboardState?
    #endif
    
    init(
        scorecard: Scorecard,
        period: ScorecardPeriod,
        batteryCapacityKWh: Double? = nil,
        inverterCapacityKw: Double? = nil
    ) {
        self.scorecard = scorecard
        self.period = period
        self.batteryCapacityKWh = batteryCapacityKWh
        self.inverterCapacityKw = inverterCapacityKw
    }
    
    func withCrossPeriodContext(week: Scorecard?, month: Scorecard?) -> Self {
        self.weekScorecard = week
        self.monthScorecard = month
        return self
    }
    
    #if !os(tvOS)
    func withLeaderboard(_ state: LeaderboardState) -> Self {
        self.leaderboardState = state
        return self
    }
    #endif
    
    // MARK: - Build
    
    func build() -> PerformanceSummaryInput {
        let timing = scorecard.metrics.timing
        let overnight = scorecard.metrics.overnight
        let opportunities = scorecard.metrics.opportunities
        
        return PerformanceSummaryInput(
            period: period.rawValue,
            periodDays: scorecard.daysAnalyzed,
            grade: scorecard.overallGrade,
            score: Int(scorecard.overallScore),
            netPositionDollars: scorecard.netPosition,
            wasProfit: scorecard.netPosition <= 0,  // Negative = credit = profit
            
            strengths: extractStrengths(),
            weaknesses: extractWeaknesses(),
            
            totalCostDollars: scorecard.totalCost,
            totalEarningsDollars: scorecard.earnings,
            avgBuyRateCents: timing.avgBuyRate,
            avgSellRateCents: timing.avgSellRate,
            spreadCents: timing.spreadCaptured,
            
            importKwh: timing.totalImportKwh,
            exportKwh: timing.totalExportKwh,
            peakImportKwh: timing.peakImportKwh,
            
            missedExportCount: opportunities.missedExports.count,
            missedExportPrices: opportunities.missedExports.map { $0.price },
            missedImportCount: opportunities.missedImports.count,
            missedNegativeCount: opportunities.missedNegatives.count,
            topMissedReasons: aggregateMissedReasons(opportunities),
            worstMissedExportPrice: opportunities.missedExports.map { $0.price }.max(),
            bestMissedImportPrice: (opportunities.missedImports + opportunities.missedNegatives).map { $0.price }.min(),
            
            avg9pmSoc: overnight.avg9pmSoc,
            avg6amSoc: overnight.avg6amSoc,
            nightsWithImports: overnight.nightsWithImports,
            nightsAnalyzed: overnight.nightsAnalyzed,
            morningSurvivalRate: overnight.morningSurvivalRate,
            
            weekNetPositionDollars: weekScorecard?.netPosition,
            monthNetPositionDollars: monthScorecard?.netPosition,
            weekGrade: weekScorecard?.overallGrade,
            monthGrade: monthScorecard?.overallGrade,
            trendDirection: calculateTrend()?.rawValue,
            
            cohortPercentile: extractCohortPercentile(),
            cohortRankingMode: extractCohortRankingMode(),
            cohortSiteCount: extractCohortSiteCount(),
            cohortTopEfficiencyCents: extractCohortTopEfficiency(),
            myEfficiencyCents: extractMyEfficiency(),
            
            anomalies: detectAnomalies(),
            
            recommendations: scorecard.recommendations.map {
                RecommendationInfo(priority: $0.priority, category: $0.category, action: $0.action)
            },
            
            batteryCapacityKWh: batteryCapacityKWh,
            inverterCapacityKw: inverterCapacityKw
        )
    }
    
    // MARK: - Extraction Helpers
    
    private func extractStrengths() -> [ComponentSummary] {
        scorecard.components
            .filter { $0.score >= 80 }
            .sorted { $0.score > $1.score }
            .map { ComponentSummary(name: $0.name, value: $0.value, score: Int($0.score)) }
    }
    
    private func extractWeaknesses() -> [ComponentSummary] {
        scorecard.components
            .filter { $0.score < 60 }
            .sorted { $0.score < $1.score }
            .map { ComponentSummary(name: $0.name, value: $0.value, score: Int($0.score)) }
    }
    
    private func aggregateMissedReasons(_ opp: OpportunityMetrics) -> [String: Int] {
        var reasons: [String: Int] = [:]
        
        for missed in opp.missedExports {
            reasons[missed.inferredReason, default: 0] += 1
        }
        for missed in opp.missedImports {
            reasons[missed.inferredReason, default: 0] += 1
        }
        for missed in opp.missedNegatives {
            reasons[missed.inferredReason, default: 0] += 1
        }
        
        return reasons
    }
    
    private enum TrendDirection: String {
        case improving, declining, stable
    }
    
    private func calculateTrend() -> TrendDirection? {
        guard let week = weekScorecard else { return nil }
        
        let dayAvg = scorecard.netPosition / Double(max(1, scorecard.daysAnalyzed))
        let weekAvg = week.netPosition / Double(max(1, week.daysAnalyzed))
        
        let diff = dayAvg - weekAvg
        let threshold = 0.50  // $0.50/day threshold for trend
        
        if diff < -threshold {
            return .improving  // Lower net position = better (credit)
        } else if diff > threshold {
            return .declining
        } else {
            return .stable
        }
    }
    
    // MARK: - Leaderboard Extraction
    
    private func extractCohortPercentile() -> Int? {
        #if !os(tvOS)
        return leaderboardState?.calculatePercentile(forMode: .efficiency)
        #else
        return nil
        #endif
    }
    
    private func extractCohortRankingMode() -> String? {
        #if !os(tvOS)
        return leaderboardState != nil ? "efficiency" : nil
        #else
        return nil
        #endif
    }
    
    private func extractCohortSiteCount() -> Int? {
        #if !os(tvOS)
        return leaderboardState?.totalSites
        #else
        return nil
        #endif
    }
    
    private func extractCohortTopEfficiency() -> Double? {
        #if !os(tvOS)
        return leaderboardState?.topEfficiency(for: period.leaderboardPeriod)
        #else
        return nil
        #endif
    }
    
    private func extractMyEfficiency() -> Double? {
        #if !os(tvOS)
        return leaderboardState?.myEfficiency(for: period.leaderboardPeriod)
        #else
        return nil
        #endif
    }
    
    // MARK: - Anomaly Detection
    
    private func detectAnomalies() -> [AnomalyInfo] {
        var anomalies: [AnomalyInfo] = []
        let overnight = scorecard.metrics.overnight
        let timing = scorecard.metrics.timing
        
        // SOC anomalies
        if let capacity = batteryCapacityKWh, capacity > 20 {
            // Large battery should rarely be at 0%
            if overnight.avg9pmSoc < 5 {
                anomalies.append(AnomalyInfo(
                    severity: "warning",
                    category: "Battery SOC",
                    description: "9 PM SOC averaged only \(Int(overnight.avg9pmSoc))% — unusual for a \(Int(capacity)) kWh system"
                ))
            }
            if overnight.avg6amSoc < 5 {
                anomalies.append(AnomalyInfo(
                    severity: "warning",
                    category: "Battery SOC",
                    description: "6 AM SOC averaged only \(Int(overnight.avg6amSoc))% — check overnight consumption estimates"
                ))
            }
        }
        
        // Data completeness
        if scorecard.daysAnalyzed == 0 {
            anomalies.append(AnomalyInfo(
                severity: "critical",
                category: "Data",
                description: "No complete days of data found for this period"
            ))
        }
        
        // Extreme rates
        if timing.avgBuyRate > 40 {
            anomalies.append(AnomalyInfo(
                severity: "warning",
                category: "Pricing",
                description: "Average buy rate was \(String(format: "%.1f", timing.avgBuyRate))¢/kWh — unusually high"
            ))
        }
        
        if timing.avgSellRate < 5 && timing.totalExportKwh > 10 {
            anomalies.append(AnomalyInfo(
                severity: "info",
                category: "Pricing",
                description: "Average sell rate was only \(String(format: "%.1f", timing.avgSellRate))¢/kWh — poor export conditions"
            ))
        }
        
        // Negative spread (paying more than earning per kWh)
        if timing.spreadCaptured < -5 {
            anomalies.append(AnomalyInfo(
                severity: "warning",
                category: "Arbitrage",
                description: "Negative spread of \(String(format: "%.1f", timing.spreadCaptured))¢ — buying high, selling low"
            ))
        }
        
        // High peak import despite good overnight
        if timing.peakImportKwh > 5 && overnight.morningSurvivalRate > 80 {
            anomalies.append(AnomalyInfo(
                severity: "info",
                category: "Peak",
                description: "Imported \(String(format: "%.1f", timing.peakImportKwh)) kWh during peak despite good morning survival — check afternoon consumption"
            ))
        }
        
        // Missed negative prices (critical - you get paid to charge!)
        let missedNegatives = scorecard.metrics.opportunities.missedNegatives
        if !missedNegatives.isEmpty {
            let worstPrice = missedNegatives.map { $0.price }.min() ?? 0
            anomalies.append(AnomalyInfo(
                severity: "critical",
                category: "Missed Opportunity",
                description: "Missed \(missedNegatives.count) negative price period(s) — you get PAID to import at \(String(format: "%.1f", worstPrice))¢/kWh"
            ))
        }
        
        return anomalies
    }
}

// MARK: - Convenience Extensions

extension PerformanceSummaryInput {
    
    /// Estimated revenue lost from missed export opportunities
    var estimatedMissedExportRevenue: Double {
        // Assume average export of 1.5 kWh per 15-min opportunity window
        let avgExportPerWindow = 1.5
        return missedExportPrices.reduce(0) { $0 + ($1 * avgExportPerWindow / 100) }
    }
    
    /// Most common reason for missed opportunities
    var primaryMissedReason: String? {
        topMissedReasons.max(by: { $0.value < $1.value })?.key
    }
    
    /// Whether this was a "defensive win" (good overnight/peak, poor timing)
    var isDefensivePattern: Bool {
        let hasStrengthInDefense = strengths.contains {
            $0.name == "Peak Avoidance" || $0.name == "Morning Survival" || $0.name == "Overnight Efficiency"
        }
        let hasWeaknessInOffense = weaknesses.contains {
            $0.name == "Timing Efficiency" || $0.name == "Opportunity Capture"
        }
        return hasStrengthInDefense && hasWeaknessInOffense
    }
    
    /// Quick summary of cross-period standing
    var crossPeriodContext: String? {
        if let weekNet = weekNetPositionDollars {
            let weekStatus = weekNet <= 0 ? "ahead" : "behind"
            return "Week: \(weekStatus) $\(String(format: "%.2f", abs(weekNet)))"
        }
        return nil
    }
    
    /// Human-readable summary of what went well
    var strengthsSummary: String {
        if strengths.isEmpty { return "No standout areas" }
        return strengths.map { "\($0.name) (\($0.score))" }.joined(separator: ", ")
    }
    
    /// Human-readable summary of improvement areas
    var weaknessesSummary: String {
        if weaknesses.isEmpty { return "All areas performing well" }
        return weaknesses.map { "\($0.name) (\($0.score))" }.joined(separator: ", ")
    }
}
