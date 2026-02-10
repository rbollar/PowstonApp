//
//  IntelligentSummaryService.swift
//  Powston
//
//  Generates natural language summaries for energy system performance and forecasts.
//  Uses Foundation Models on iOS 26+ with deterministic fallback for earlier versions.
//

import Foundation
import SwiftUI
import Combine
import FoundationModels

// MARK: - Output Structures

/// Generated summary for historical performance (retrospective)
struct PerformanceSummaryOutput {
    let headline: String
    let explanation: String
    let missedOpportunityNote: String?
    let contextNote: String?
    let investigationHint: String?
    let actionableAdvice: String?
}

/// Generated explanation for current state and upcoming opportunities
struct ForecastExplanationOutput {
    let currentStateHeadline: String
    let currentStateDetail: String
    let upcomingOpportunity: String?
    let recommendation: String?
    let alertEnhancement: String?
}

// MARK: - Generable Output Types (iOS 26+)

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GenerablePerformanceSummary {
    /// A punchy one-line headline about today's outcome, e.g. "Strong B+ day with $12 profit" or "Tough day — $3 net cost despite good defense"
    let headline: String
    /// 2-3 sentences explaining strengths and weaknesses. Focus on component scores and spread.
    let explanation: String
    /// ONLY about missed price opportunities (exports at high prices, imports at negative prices). Leave nil if no missed opportunities. Never mention peak periods here.
    let missedOpportunityNote: String?
    /// Cross-period comparison (week/month totals) or cohort ranking. Leave nil if no cross-period data available.
    let contextNote: String?
    /// Flag unusual data that needs investigation (e.g. "0% SOC readings seem wrong"). Leave nil if no anomalies.
    let investigationHint: String?
    /// The single most important recommendation. Should not duplicate investigationHint.
    let actionableAdvice: String?
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GenerableForecastExplanation {
    /// What's happening right now, e.g. "Exporting at 27¢/kWh"
    let currentStateHeadline: String
    /// Power flow summary, e.g. "5.2kW solar, 2.1kW load, exporting 3.1kW"
    let currentStateDetail: String
    /// Next significant price event, e.g. "Spike at 5:30 PM — 45¢/kWh"
    let upcomingOpportunity: String?
    /// What action to take or confirmation auto is correct
    let recommendation: String?
    /// Enhanced notification text if this is for a push alert
    let alertEnhancement: String?
}

// MARK: - Service

@MainActor
class IntelligentSummaryService: ObservableObject {
    
    @Published var isAvailable = false
    @Published var lastError: String?
    
    private let systemInstructions = """
    You are an energy advisor for home battery systems participating in electricity arbitrage.
    Your role is to explain performance and opportunities in plain, direct language.
    
    CRITICAL PRICING FACTS:
    - Peak periods (typically 4-9 PM) are EXPENSIVE — you pay MORE to import, not less
    - Negative prices (below 0¢) are when you get PAID to charge — this is rare and valuable
    - Good arbitrage = buy cheap, sell expensive = positive spread
    
    Guidelines:
    - Be direct and specific. Use actual numbers with $ and ¢ symbols.
    - If they lost money, say so clearly but constructively.
    - Headlines: ~15 words. Explanations: 3-4 sentences with specifics.
    - Use Australian English spelling.
    - Set optional fields to null when data isn't available — don't invent content.
    - Don't repeat the same point across multiple fields.
    """
    
    init() {
        checkAvailability()
    }
    
    // MARK: - Availability Check
    
    func checkAvailability() {
        if #available(iOS 26.0, macOS 26.0, *) {
            Task {
                await checkFoundationModelsAvailability()
            }
        } else {
            isAvailable = false
        }
    }
    
    @available(iOS 26.0, macOS 26.0, *)
    private func checkFoundationModelsAvailability() async {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            isAvailable = true
        case .unavailable:
            isAvailable = false
        @unknown default:
            isAvailable = false
        }
    }
    
    // MARK: - Performance Summary Generation
    
    func generatePerformanceSummary(from input: PerformanceSummaryInput) async -> PerformanceSummaryOutput {
        if #available(iOS 26.0, macOS 26.0, *), isAvailable {
            do {
                return try await generateWithFoundationModels(input: input)
            } catch {
                lastError = error.localizedDescription
                return buildDeterministicPerformanceSummary(from: input)
            }
        } else {
            return buildDeterministicPerformanceSummary(from: input)
        }
    }
    
    @available(iOS 26.0, macOS 26.0, *)
    private func generateWithFoundationModels(input: PerformanceSummaryInput) async throws -> PerformanceSummaryOutput {
        let session = LanguageModelSession(instructions: systemInstructions)
        let prompt = buildPerformancePrompt(from: input)
        
        let response = try await session.respond(
            to: prompt,
            generating: GenerablePerformanceSummary.self
        )
        
        let generated = response.content
        
        return PerformanceSummaryOutput(
            headline: generated.headline,
            explanation: generated.explanation,
            missedOpportunityNote: generated.missedOpportunityNote.nilIfEmpty,
            contextNote: generated.contextNote.nilIfEmpty,
            investigationHint: generated.investigationHint.nilIfEmpty,
            actionableAdvice: generated.actionableAdvice.nilIfEmpty
        )
    }
    
    private func buildPerformancePrompt(from input: PerformanceSummaryInput) -> String {
        // Period-aware label
        let periodLabel: String
        switch input.period.lowercased() {
        case "yesterday": periodLabel = "day"
        case "week": periodLabel = "week"
        case "month": periodLabel = "month"
        default: periodLabel = input.periodDays == 1 ? "day" : "period"
        }
        
        // Grade-appropriate adjective
        let adjective: String
        switch input.grade.prefix(1) {
        case "A": adjective = "Excellent"
        case "B": adjective = "Solid"
        case "C": adjective = "Mixed"
        case "D": adjective = "Challenging"
        default: adjective = "Tough"
        }
        
        var prompt = """
        Generate a BRIEF performance summary. Bullet points show details — your text should ADD INSIGHT, not repeat data.
        
        - headline: "\(adjective) \(periodLabel)" — only add $ if >$5
        - explanation: MAX 2 sentences. What drove the result + one insight. NO dollar amounts, NO percentages.
          IMPORTANT: Only blame things listed in Weaknesses. Don't say "peak was costly" if Peak Avoidance is a Strength.
        - missedOpportunityNote: Only if missed opportunities exist. Otherwise null.
        - contextNote: Only if cohort/week data exists. Otherwise null.
        - investigationHint: Only if anomalies exist. Otherwise null.
        - actionableAdvice: One recommendation, or null.
        
        === DATA ===
        Grade: \(input.grade) (\(input.score)/100) | Net: $\(String(format: "%.2f", input.netPositionDollars)) (\(input.wasProfit ? "profit" : "cost"))
        Spread: \(String(format: "%.1f", input.spreadCents))¢ | Peak imports: \(String(format: "%.1f", input.peakImportKwh)) kWh
        Strengths (performed well): \(input.strengthsSummary)
        Weaknesses (needs work): \(input.weaknessesSummary)
        """
        
        if input.missedExportCount > 0 || input.missedNegativeCount > 0 {
            prompt += "\n\nMISSED OPPORTUNITIES (for missedOpportunityNote field):"
            if input.missedExportCount > 0 {
                prompt += "\n- Missed \(input.missedExportCount) export opportunities"
                if let worstPrice = input.worstMissedExportPrice {
                    prompt += " (prices up to \(String(format: "%.0f", worstPrice))¢)"
                }
            }
            if input.missedNegativeCount > 0 {
                prompt += "\n- Missed \(input.missedNegativeCount) NEGATIVE price periods (you get PAID to import!)"
            }
            if input.estimatedMissedExportRevenue > 0.5 {
                prompt += "\n- Estimated missed revenue: $\(String(format: "%.2f", input.estimatedMissedExportRevenue)) (dollars, not cents)"
            }
        } else {
            prompt += "\n\nNo missed opportunities — set missedOpportunityNote to null."
        }
        
        if !input.anomalies.isEmpty {
            prompt += "\n\nANOMALIES (for investigationHint field):"
            for anomaly in input.anomalies {
                prompt += "\n- [\(anomaly.severity.uppercased())] \(anomaly.description)"
            }
        } else {
            prompt += "\n\nNo anomalies — set investigationHint to null."
        }
        
        // Cross-period and cohort data - keep brief, don't repeat in explanation
        var hasContext = false
        if let weekNet = input.weekNetPositionDollars {
            let status = weekNet <= 0 ? "ahead" : "behind"
            prompt += "\n\nCONTEXT (for contextNote only, NOT explanation):"
            prompt += "\n- Week: \(status) $\(String(format: "%.2f", abs(weekNet)))"
            hasContext = true
        }
        if let percentile = input.cohortPercentile {
            if !hasContext {
                prompt += "\n\nCONTEXT (for contextNote only, NOT explanation):"
            }
            prompt += "\n- Cohort: Top \(percentile)%"
            // Only show gap if reasonable (1-50¢/kWh/day) - hide outliers
            if let topEff = input.cohortTopEfficiencyCents, let myEff = input.myEfficiencyCents {
                let rawGap = topEff - myEff
                let dailyGap = input.periodDays > 1 ? rawGap / Double(input.periodDays) : rawGap
                if dailyGap > 1 && dailyGap < 50 {
                    prompt += " (gap: \(String(format: "%.1f", dailyGap))¢/kWh/day)"
                }
            }
            hasContext = true
        }
        if !hasContext {
            prompt += "\n\nNo context data — set contextNote to null."
        }
        
        if !input.recommendations.isEmpty {
            prompt += "\n\nRECOMMENDATION (pick ONE for actionableAdvice):"
            prompt += "\n- \(input.recommendations.first!.action)"
        }
        
        return prompt
    }
    
    // MARK: - Forecast Explanation Generation
    
    func generateForecastExplanation(from input: ForecastAdvisorInput) async -> ForecastExplanationOutput {
        if #available(iOS 26.0, macOS 26.0, *), isAvailable {
            do {
                return try await generateForecastWithFoundationModels(input: input)
            } catch {
                lastError = error.localizedDescription
                return buildDeterministicForecastExplanation(from: input)
            }
        } else {
            return buildDeterministicForecastExplanation(from: input)
        }
    }
    
    @available(iOS 26.0, macOS 26.0, *)
    private func generateForecastWithFoundationModels(input: ForecastAdvisorInput) async throws -> ForecastExplanationOutput {
        let session = LanguageModelSession(instructions: systemInstructions)
        let prompt = buildForecastPrompt(from: input)
        
        let response = try await session.respond(
            to: prompt,
            generating: GenerableForecastExplanation.self
        )
        
        let generated = response.content
        
        return ForecastExplanationOutput(
            currentStateHeadline: generated.currentStateHeadline,
            currentStateDetail: generated.currentStateDetail,
            upcomingOpportunity: generated.upcomingOpportunity.nilIfEmpty,
            recommendation: generated.recommendation.nilIfEmpty,
            alertEnhancement: generated.alertEnhancement.nilIfEmpty
        )
    }
    
    private func buildForecastPrompt(from input: ForecastAdvisorInput) -> String {
        var prompt = """
        Explain the current state and upcoming opportunities for this energy system:
        
        Current State:
        - SOC: \(Int(input.currentSoc))% of \(String(format: "%.0f", input.batteryCapacityKWh)) kWh
        - Action: \(input.currentAction)
        - Buy price: \(String(format: "%.1f", input.currentBuyPrice))¢/kWh
        - Sell price: \(String(format: "%.1f", input.currentSellPrice))¢/kWh
        
        Power Flow:
        - Solar: \(String(format: "%.1f", input.solarKw)) kW
        - House: \(String(format: "%.1f", input.houseKw)) kW
        - Grid: \(String(format: "%.1f", input.gridKw)) kW (\(input.gridKw > 0 ? "importing" : "exporting"))
        - Battery: \(String(format: "%.1f", input.batteryKw)) kW (\(input.batteryKw > 0 ? "discharging" : "charging"))
        
        Available capacity:
        - Export available: \(String(format: "%.1f", input.availableExportKwh)) kWh above floor
        - Import available: \(String(format: "%.1f", input.availableImportKwh)) kWh to full
        
        Time context:
        - Current hour: \(input.currentHour):00
        - Peak period: \(input.peakStartHour):00 - \(input.peakEndHour):00
        - In peak now: \(input.isInPeakPeriod ? "YES" : "no")
        """
        
        if !input.upcomingSpikes.isEmpty {
            prompt += "\n\nUpcoming price spikes:"
            for spike in input.upcomingSpikes.prefix(3) {
                prompt += "\n- \(spike.expectedTime): \(String(format: "%.0f", spike.forecastPrice))¢/kWh"
                prompt += " (potential: $\(String(format: "%.2f", spike.potentialRevenueDollars)))"
                if spike.currentSocGap > 5 {
                    prompt += " — need \(Int(spike.currentSocGap))% more SOC"
                }
            }
        }
        
        if !input.upcomingNegativePeriods.isEmpty {
            prompt += "\n\nUPCOMING NEGATIVE PRICES (you get paid to charge!):"
            for neg in input.upcomingNegativePeriods {
                prompt += "\n- \(neg.expectedTime): \(String(format: "%.1f", neg.forecastPrice))¢/kWh"
                prompt += " (earn ~$\(String(format: "%.2f", neg.potentialEarningsDollars)))"
            }
        }
        
        if !input.upcomingCheapPeriods.isEmpty {
            prompt += "\n\nUpcoming cheap periods:"
            for cheap in input.upcomingCheapPeriods.prefix(2) {
                prompt += "\n- \(cheap.startTime)-\(cheap.endTime): ~\(String(format: "%.1f", cheap.forecastPrice))¢/kWh"
            }
        }
        
        if let alertType = input.alertType {
            prompt += "\n\nThis is for a push notification triggered by: \(alertType)"
            if let threshold = input.alertThreshold {
                prompt += " (threshold: \(String(format: "%.1f", threshold))¢)"
            }
            prompt += "\nGenerate a concise, actionable alert message."
        }
        
        if let reason = input.currentReason {
            prompt += "\n\nController reason: \(reason)"
        }
        
        return prompt
    }
    
    // MARK: - Enhanced Push Notification
    
    func generateEnhancedNotification(
        alertType: String,
        threshold: Double,
        currentPrice: Double,
        inverterResponse: InverterResponse,
        site: Site?
    ) async -> String {
        
        let input = ForecastAdvisorBuilder(
            inverterResponse: inverterResponse,
            site: site
        )
        .withAlert(type: alertType, threshold: threshold)
        .build()
        
        let output = await generateForecastExplanation(from: input)
        
        if let enhancement = output.alertEnhancement {
            return enhancement
        }
        
        return buildFallbackNotificationText(alertType: alertType, currentPrice: currentPrice, input: input)
    }
    
    // MARK: - Deterministic Fallback Generation
    
    private func buildDeterministicPerformanceSummary(from input: PerformanceSummaryInput) -> PerformanceSummaryOutput {
        let headline = buildHeadline(from: input)
        let explanation = buildExplanation(from: input)
        let missedNote = buildMissedOpportunityNote(from: input)
        let contextNote = buildContextNote(from: input)
        let investigationHint = buildInvestigationHint(from: input)
        let actionableAdvice = input.recommendations.first?.action
        
        return PerformanceSummaryOutput(
            headline: headline,
            explanation: explanation,
            missedOpportunityNote: missedNote,
            contextNote: contextNote,
            investigationHint: investigationHint,
            actionableAdvice: actionableAdvice
        )
    }
    
    private func buildHeadline(from input: PerformanceSummaryInput) -> String {
        // Period-aware label
        let periodLabel: String
        switch input.period.lowercased() {
        case "yesterday": periodLabel = "day"
        case "week": periodLabel = "week"
        case "month": periodLabel = "month"
        default: periodLabel = input.periodDays == 1 ? "day" : "period"
        }
        
        // Grade-appropriate adjective (not "Solid C" - that's an oxymoron)
        let adjective: String
        switch input.grade.prefix(1) {
        case "A": adjective = "Excellent"
        case "B": adjective = "Solid"
        case "C": adjective = "Mixed"
        case "D": adjective = "Challenging"
        default: adjective = "Tough"
        }
        
        // Only show $ for significant amounts (>$5)
        if abs(input.netPositionDollars) >= 5.0 {
            let verb = input.wasProfit ? "earned" : "cost"
            return "\(adjective) \(input.grade) \(periodLabel) — $\(String(format: "%.2f", abs(input.netPositionDollars))) \(verb)"
        }
        
        return "\(adjective) \(input.grade) \(periodLabel)"
    }
    
    private func buildExplanation(from input: PerformanceSummaryInput) -> String {
        // Keep it SHORT - 2 sentences max. Don't repeat what's in bullet points.
        var sentences: [String] = []
        
        // Check what's actually a weakness vs strength
        let peakIsWeakness = input.weaknesses.contains { $0.name == "Peak Avoidance" }
        let timingIsWeakness = input.weaknesses.contains { $0.name == "Timing Efficiency" }
        let overnightIsWeakness = input.weaknesses.contains { $0.name == "Overnight Efficiency" || $0.name == "Morning Survival" }
        
        // One sentence about what drove the outcome
        if input.wasProfit {
            if input.spreadCents > 10 {
                sentences.append("Good market spread enabled profitable arbitrage.")
            } else if input.exportKwh > input.importKwh * 2 {
                sentences.append("Strong export volume drove the result.")
            } else {
                sentences.append("Efficient operation kept costs below earnings.")
            }
        } else {
            // Only blame peak if it's actually a weakness
            if input.spreadCents < 0 {
                sentences.append("Negative spread made profitable trading difficult.")
            } else if peakIsWeakness && input.peakImportKwh > 5 {
                sentences.append("Peak imports drove costs up.")
            } else if overnightIsWeakness {
                sentences.append("Overnight grid draws added to costs.")
            } else if timingIsWeakness {
                sentences.append("Buy/sell timing missed optimal windows.")
            } else {
                sentences.append("Tight spread limited arbitrage opportunities.")
            }
        }
        
        // One sentence about the main strength OR weakness (not both)
        if let topStrength = input.strengths.first, input.score >= 60 {
            switch topStrength.name {
            case "Peak Avoidance":
                sentences.append("Strong peak avoidance kept demand charges low.")
            case "Morning Survival":
                sentences.append("Battery lasted until solar kicked in.")
            case "Overnight Efficiency":
                sentences.append("Efficient overnight operation minimized grid draws.")
            case "Timing Efficiency":
                sentences.append("Good buy/sell timing captured value.")
            case "Opportunity Capture":
                sentences.append("Captured price spikes when they occurred.")
            default:
                break
            }
        } else if let topWeakness = input.weaknesses.first {
            switch topWeakness.name {
            case "Overnight Efficiency", "Morning Survival":
                sentences.append("Overnight efficiency needs attention.")
            case "Timing Efficiency":
                sentences.append("Buy/sell timing could be sharper.")
            case "Opportunity Capture":
                sentences.append("Some price opportunities were missed.")
            case "Peak Avoidance":
                sentences.append("Peak period imports added unnecessary cost.")
            default:
                break
            }
        }
        
        return sentences.joined(separator: " ")
    }
    
    private func buildMissedOpportunityNote(from input: PerformanceSummaryInput) -> String? {
        var parts: [String] = []
        
        if input.missedExportCount > 0 {
            var note = "Missed \(input.missedExportCount) export\(input.missedExportCount > 1 ? "s" : "")"
            if let worst = input.worstMissedExportPrice {
                note += " (up to \(String(format: "%.0f", worst))¢)"
            }
            parts.append(note)
        }
        if input.missedNegativeCount > 0 {
            parts.append("Missed \(input.missedNegativeCount) negative price period\(input.missedNegativeCount > 1 ? "s" : "") — you get PAID to charge!")
        }
        
        guard !parts.isEmpty else { return nil }
        
        if input.estimatedMissedExportRevenue > 0.50 {
            parts.append("Est. impact: ~$\(String(format: "%.2f", input.estimatedMissedExportRevenue))")
        }
        if let reason = input.primaryMissedReason {
            parts.append("Cause: \(reason)")
        }
        
        return parts.joined(separator: ". ")
    }
    
    private func buildContextNote(from input: PerformanceSummaryInput) -> String? {
        var parts: [String] = []
        
        // Week comparison
        if let weekNet = input.weekNetPositionDollars {
            let status = weekNet <= 0 ? "ahead" : "behind"
            parts.append("\(status.capitalized) $\(String(format: "%.2f", abs(weekNet))) for the week")
        }
        
        // Cohort ranking with normalized gap
        if let percentile = input.cohortPercentile, let siteCount = input.cohortSiteCount {
            var cohortText = "Top \(percentile)% of \(siteCount) similar systems"
            
            // Only show gap if reasonable (1-50¢/kWh/day) - hide outliers
            if let topEff = input.cohortTopEfficiencyCents, let myEff = input.myEfficiencyCents {
                let rawGap = topEff - myEff
                let dailyGap = input.periodDays > 1 ? rawGap / Double(input.periodDays) : rawGap
                if dailyGap > 1 && dailyGap < 50 {
                    cohortText += " (gap: \(String(format: "%.1f", dailyGap))¢/kWh/day)"
                }
            }
            parts.append(cohortText)
        }
        
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
    
    private func buildInvestigationHint(from input: PerformanceSummaryInput) -> String? {
        if let critical = input.anomalies.first(where: { $0.severity == "critical" }) {
            return "⚠️ \(critical.description)"
        }
        if let warning = input.anomalies.first(where: { $0.severity == "warning" }) {
            return "Note: \(warning.description)"
        }
        return nil
    }
    
    private func buildDeterministicForecastExplanation(from input: ForecastAdvisorInput) -> ForecastExplanationOutput {
        let headline = input.simpleActionExplanation
        let detail = input.powerFlowSummary
        
        var opportunity: String?
        if let neg = input.upcomingNegativePeriods.first {
            opportunity = "🎉 Negative price at \(neg.expectedTime) — get paid \(String(format: "%.1f", abs(neg.forecastPrice)))¢/kWh"
        } else if let spike = input.upcomingSpikes.first {
            var text = "Spike at \(spike.expectedTime): \(String(format: "%.0f", spike.forecastPrice))¢/kWh"
            if spike.potentialRevenueDollars > 1.0 {
                text += " (~$\(String(format: "%.2f", spike.potentialRevenueDollars)))"
            }
            if spike.currentSocGap > 10 {
                text += " — need \(Int(spike.currentSocGap))% more SOC"
            }
            opportunity = text
        } else if let cheap = input.upcomingCheapPeriods.first, cheap.hoursFromNow <= 4 {
            opportunity = "Cheap at \(cheap.startTime): \(String(format: "%.1f", cheap.forecastPrice))¢/kWh"
        } else if let min = input.minutesToPeakStart, min <= 60 && min > 0 {
            opportunity = "Peak starts in \(min) minutes"
        }
        
        let alertEnhancement = buildAlertEnhancement(from: input)
        
        return ForecastExplanationOutput(
            currentStateHeadline: headline,
            currentStateDetail: detail,
            upcomingOpportunity: opportunity,
            recommendation: input.urgentActionHint,
            alertEnhancement: alertEnhancement
        )
    }
    
    private func buildAlertEnhancement(from input: ForecastAdvisorInput) -> String? {
        guard let alertType = input.alertType else { return nil }
        
        switch alertType {
        case "highSell":
            var text = "Export: \(String(format: "%.1f", input.currentSellPrice))¢/kWh"
            if input.availableExportKwh > 5 {
                let revenue = input.availableExportKwh * input.currentSellPrice / 100
                text += ". \(String(format: "%.0f", input.availableExportKwh)) kWh available (~$\(String(format: "%.2f", revenue)))"
            }
            return text
        case "lowBuy":
            return "Cheap: \(String(format: "%.1f", input.currentBuyPrice))¢/kWh. \(String(format: "%.0f", input.availableImportKwh)) kWh capacity."
        case "negative":
            return "🎉 NEGATIVE: Get paid \(String(format: "%.1f", abs(input.currentBuyPrice)))¢/kWh to charge!"
        case "spike":
            if let spike = input.bestUpcomingSpike {
                return "Spike: \(String(format: "%.0f", spike.forecastPrice))¢/kWh at \(spike.expectedTime). ~$\(String(format: "%.2f", spike.potentialRevenueDollars))"
            }
            return nil
        case "peakStarting":
            return "Peak starting. SOC: \(Int(input.currentSoc))%. Avoid imports until \(input.peakEndHour):00."
        default:
            return nil
        }
    }
    
    private func buildFallbackNotificationText(alertType: String, currentPrice: Double, input: ForecastAdvisorInput) -> String {
        switch alertType {
        case "highSell": return "Export opportunity: \(String(format: "%.1f", currentPrice))¢/kWh"
        case "lowBuy": return "Cheap charging: \(String(format: "%.1f", currentPrice))¢/kWh"
        case "negative": return "🎉 Negative price: \(String(format: "%.1f", currentPrice))¢/kWh"
        case "spike": return "Price spike forecast. Check app."
        case "peakStarting": return "Peak period starting soon."
        default: return "Price alert: \(String(format: "%.1f", currentPrice))¢/kWh"
        }
    }
}

// MARK: - SwiftUI Environment

private struct IntelligentSummaryServiceKey: EnvironmentKey {
    static let defaultValue = IntelligentSummaryService()
}

extension EnvironmentValues {
    var intelligentSummary: IntelligentSummaryService {
        get { self[IntelligentSummaryServiceKey.self] }
        set { self[IntelligentSummaryServiceKey.self] = newValue }
    }
}

// MARK: - String Extension for Empty-to-Nil Conversion

extension String? {
    /// Converts empty, whitespace-only, or placeholder strings to nil
    var nilIfEmpty: String? {
        guard let self = self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Filter empty strings
        if trimmed.isEmpty { return nil }
        
        // Filter common placeholder phrases FM might generate
        let placeholders = [
            "no data",
            "no data.",
            "n/a",
            "none",
            "none.",
            "not applicable",
            "not available",
            "null",
            "-",
            // Anomaly-specific
            "no anomalies",
            "no anomalies.",
            "no anomalies detected",
            "no issues",
            "no issues found",
            "nothing to report",
            // Context-specific
            "no context",
            "no context available",
            "no comparison data",
            // Generic
            "no recommendations",
            "no advice"
        ]
        
        if placeholders.contains(trimmed.lowercased()) {
            return nil
        }
        
        return trimmed
    }
}

extension View {
    func withIntelligentSummary(_ service: IntelligentSummaryService) -> some View {
        environment(\.intelligentSummary, service)
    }
}
