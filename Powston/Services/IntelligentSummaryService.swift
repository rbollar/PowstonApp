//
//  IntelligentSummaryService.swift
//  Powston
//
//  Foundation Models integration layer for generating natural language summaries
//  Requires iOS 26+ / macOS 26+ with Apple Intelligence enabled
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Output Structures

/// Generated summary for historical performance (retrospective)
struct PerformanceSummaryOutput: Codable {
    let headline: String              // "Break-even day with excellent defensive metrics"
    let explanation: String           // 2-3 sentences explaining what happened
    let missedOpportunityNote: String? // "Could have earned ~$X more by..."
    let contextNote: String?          // "Still ahead $12 for the week" or cohort standing
    let investigationHint: String?    // "The 0% SOC readings are unusual..."
    let actionableAdvice: String?     // Most important recommendation in plain language
}

/// Generated explanation for current state and upcoming opportunities
struct ForecastExplanationOutput: Codable {
    let currentStateHeadline: String  // "Exporting at premium rates"
    let currentStateDetail: String    // What's happening right now
    let upcomingOpportunity: String?  // Next significant event
    let recommendation: String?       // What to do (or confirm auto is doing the right thing)
    let alertEnhancement: String?     // Enhanced text for push notification
}

// MARK: - Service

@MainActor
class IntelligentSummaryService: ObservableObject {
    
    @Published var isAvailable = false
    @Published var lastError: String?
    
    #if canImport(FoundationModels)
    private var session: LanguageModelSession?
    #endif
    
    init() {
        checkAvailability()
    }
    
    // MARK: - Availability Check
    
    func checkAvailability() {
        #if canImport(FoundationModels)
        Task {
            do {
                let availability = LanguageModel.Availability
                isAvailable = availability != .unavailable
                
                if isAvailable {
                    // Create session with system instructions
                    session = LanguageModelSession(instructions: systemInstructions)
                }
            }
        }
        #else
        isAvailable = false
        #endif
    }
    
    private let systemInstructions = """
    You are an energy advisor for home battery systems participating in electricity arbitrage. 
    Your role is to explain performance and opportunities in plain, direct language.
    
    Guidelines:
    - Be direct and specific. Use actual numbers.
    - If they lost money, say so clearly but constructively.
    - If they could have done better, explain what and roughly how much.
    - Keep explanations under 50 words unless detail is requested.
    - Use Australian English spelling.
    - Assume the user understands basic energy concepts (kWh, SOC, peak periods).
    - Frame negative prices as "you get paid to charge" — this is a good thing.
    - Peak periods (typically 4-9 PM) are expensive to import — avoiding them is key.
    """
    
    // MARK: - Performance Summary Generation
    
    func generatePerformanceSummary(from input: PerformanceSummaryInput) async -> PerformanceSummaryOutput {
        #if canImport(FoundationModels)
        guard isAvailable, let session = session else {
            return fallbackPerformanceSummary(from: input)
        }
        
        do {
            // Build prompt from structured input
            let prompt = buildPerformancePrompt(from: input)
            
            // Use guided generation for structured output
            let response = try await session.respond(
                to: prompt,
                generating: PerformanceSummaryOutput.self
            )
            
            return response
            
        } catch {
            lastError = error.localizedDescription
            return fallbackPerformanceSummary(from: input)
        }
        #else
        return fallbackPerformanceSummary(from: input)
        #endif
    }
    
    private func buildPerformancePrompt(from input: PerformanceSummaryInput) -> String {
        var prompt = """
        Generate a performance summary for this energy system:
        
        Period: \(input.period) (\(input.periodDays) day\(input.periodDays == 1 ? "" : "s"))
        Grade: \(input.grade) (\(input.score)/100)
        Net Position: $\(String(format: "%.2f", input.netPositionDollars)) (\(input.wasProfit ? "profit" : "cost"))
        
        Strengths: \(input.strengthsSummary)
        Weaknesses: \(input.weaknessesSummary)
        
        Financials:
        - Total costs: $\(String(format: "%.2f", input.totalCostDollars))
        - Total earnings: $\(String(format: "%.2f", input.totalEarningsDollars))
        - Avg buy rate: \(String(format: "%.1f", input.avgBuyRateCents))¢/kWh
        - Avg sell rate: \(String(format: "%.1f", input.avgSellRateCents))¢/kWh
        - Spread: \(String(format: "%.1f", input.spreadCents))¢
        
        Volumes:
        - Import: \(Int(input.importKwh)) kWh
        - Export: \(Int(input.exportKwh)) kWh
        - Peak import: \(String(format: "%.1f", input.peakImportKwh)) kWh
        """
        
        // Add missed opportunities if any
        if input.missedExportCount > 0 || input.missedNegativeCount > 0 {
            prompt += """
            
            
            Missed Opportunities:
            - Missed exports: \(input.missedExportCount)\(input.worstMissedExportPrice != nil ? " (highest: \(String(format: "%.0f", input.worstMissedExportPrice!))¢)" : "")
            - Missed negative prices: \(input.missedNegativeCount)\(input.bestMissedImportPrice != nil ? " (best: \(String(format: "%.1f", input.bestMissedImportPrice!))¢)" : "")
            - Estimated missed revenue: ~$\(String(format: "%.2f", input.estimatedMissedExportRevenue))
            """
            
            if let primaryReason = input.primaryMissedReason {
                prompt += "\n- Primary reason: \(primaryReason)"
            }
        }
        
        // Add anomalies
        if !input.anomalies.isEmpty {
            prompt += "\n\nAnomalies detected:"
            for anomaly in input.anomalies {
                prompt += "\n- [\(anomaly.severity.uppercased())] \(anomaly.description)"
            }
        }
        
        // Add cross-period context
        if let weekNet = input.weekNetPositionDollars {
            let weekStatus = weekNet <= 0 ? "ahead" : "behind"
            prompt += "\n\nCross-period: \(weekStatus) $\(String(format: "%.2f", abs(weekNet))) for the week"
        }
        
        // Add cohort context
        if let percentile = input.cohortPercentile {
            prompt += "\nCohort ranking: Top \(percentile)% of similar systems"
        }
        
        // Add recommendations
        if !input.recommendations.isEmpty {
            prompt += "\n\nTop recommendations:"
            for (i, rec) in input.recommendations.prefix(2).enumerated() {
                prompt += "\n\(i + 1). \(rec.action)"
            }
        }
        
        return prompt
    }
    
    // MARK: - Forecast Explanation Generation
    
    func generateForecastExplanation(from input: ForecastAdvisorInput) async -> ForecastExplanationOutput {
        #if canImport(FoundationModels)
        guard isAvailable, let session = session else {
            return fallbackForecastExplanation(from: input)
        }
        
        do {
            let prompt = buildForecastPrompt(from: input)
            
            let response = try await session.respond(
                to: prompt,
                generating: ForecastExplanationOutput.self
            )
            
            return response
            
        } catch {
            lastError = error.localizedDescription
            return fallbackForecastExplanation(from: input)
        }
        #else
        return fallbackForecastExplanation(from: input)
        #endif
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
        
        // Add upcoming spikes
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
        
        // Add negative price periods (critical!)
        if !input.upcomingNegativePeriods.isEmpty {
            prompt += "\n\nUPCOMING NEGATIVE PRICES (you get paid to charge!):"
            for neg in input.upcomingNegativePeriods {
                prompt += "\n- \(neg.expectedTime): \(String(format: "%.1f", neg.forecastPrice))¢/kWh"
                prompt += " (earn ~$\(String(format: "%.2f", neg.potentialEarningsDollars)))"
            }
        }
        
        // Add cheap periods
        if !input.upcomingCheapPeriods.isEmpty {
            prompt += "\n\nUpcoming cheap periods:"
            for cheap in input.upcomingCheapPeriods.prefix(2) {
                prompt += "\n- \(cheap.startTime)-\(cheap.endTime): ~\(String(format: "%.1f", cheap.forecastPrice))¢/kWh"
            }
        }
        
        // Add alert context if this is for a notification
        if let alertType = input.alertType {
            prompt += "\n\nThis is for a push notification triggered by: \(alertType)"
            if let threshold = input.alertThreshold {
                prompt += " (threshold: \(String(format: "%.1f", threshold))¢)"
            }
            prompt += "\nGenerate a concise, actionable alert message."
        }
        
        // Add controller reason if available
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
        
        return output.alertEnhancement ?? fallbackNotificationText(
            alertType: alertType,
            currentPrice: currentPrice,
            input: input
        )
    }
    
    private func fallbackNotificationText(
        alertType: String,
        currentPrice: Double,
        input: ForecastAdvisorInput
    ) -> String {
        switch alertType {
        case "highSell":
            return "Export opportunity: \(String(format: "%.1f", currentPrice))¢/kWh. " +
                   "\(Int(input.currentSoc))% SOC, \(String(format: "%.0f", input.availableExportKwh)) kWh available above floor."
            
        case "lowBuy":
            return "Cheap charging: \(String(format: "%.1f", currentPrice))¢/kWh. " +
                   "\(String(format: "%.0f", input.availableImportKwh)) kWh capacity available."
            
        case "negative":
            return "🎉 NEGATIVE PRICE: Get paid \(String(format: "%.1f", abs(currentPrice)))¢/kWh to charge! " +
                   "\(String(format: "%.0f", input.availableImportKwh)) kWh capacity available."
            
        case "spike":
            if let spike = input.bestUpcomingSpike {
                return "Price spike forecast: \(String(format: "%.0f", spike.forecastPrice))¢/kWh at \(spike.expectedTime). " +
                       "Potential: $\(String(format: "%.2f", spike.potentialRevenueDollars))."
            }
            return "Price spike forecast. Check app for details."
            
        case "peakStarting":
            return "Peak period starting. Current SOC: \(Int(input.currentSoc))%. " +
                   "Avoid grid imports until \(input.peakEndHour):00."
            
        default:
            return "Price alert: \(String(format: "%.1f", currentPrice))¢/kWh"
        }
    }
    
    // MARK: - Fallback Implementations (when Foundation Models unavailable)
    
    private func fallbackPerformanceSummary(from input: PerformanceSummaryInput) -> PerformanceSummaryOutput {
        // Deterministic fallback using the computed properties
        
        let headline: String
        if input.wasProfit {
            if input.score >= 80 {
                headline = "Strong day with \(input.grade) grade"
            } else {
                headline = "Profitable day despite challenges"
            }
        } else {
            if input.isDefensivePattern {
                headline = "Near break-even with strong defensive metrics"
            } else {
                headline = "Challenging day — $\(String(format: "%.2f", input.netPositionDollars)) net cost"
            }
        }
        
        var explanation = ""
        if !input.strengths.isEmpty {
            explanation += "Strong performance in \(input.strengths.map { $0.name }.joined(separator: ", ")). "
        }
        if !input.weaknesses.isEmpty {
            explanation += "Room for improvement in \(input.weaknesses.map { $0.name }.joined(separator: ", "))."
        }
        
        let missedNote: String?
        if input.missedExportCount > 0 {
            missedNote = "Missed \(input.missedExportCount) export opportunities. " +
                        "Estimated impact: ~$\(String(format: "%.2f", input.estimatedMissedExportRevenue))."
        } else {
            missedNote = nil
        }
        
        let contextNote = input.crossPeriodContext
        
        let investigationHint: String?
        if let criticalAnomaly = input.anomalies.first(where: { $0.severity == "critical" }) {
            investigationHint = criticalAnomaly.description
        } else if let warningAnomaly = input.anomalies.first(where: { $0.severity == "warning" }) {
            investigationHint = warningAnomaly.description
        } else {
            investigationHint = nil
        }
        
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
    
    private func fallbackForecastExplanation(from input: ForecastAdvisorInput) -> ForecastExplanationOutput {
        let currentStateHeadline = input.simpleActionExplanation
        let currentStateDetail = input.powerFlowSummary
        
        let upcomingOpportunity: String?
        if let spike = input.upcomingSpikes.first {
            upcomingOpportunity = "Price spike at \(spike.expectedTime) — " +
                                  "\(String(format: "%.0f", spike.forecastPrice))¢/kWh " +
                                  "(potential $\(String(format: "%.2f", spike.potentialRevenueDollars)))"
        } else if let neg = input.upcomingNegativePeriods.first {
            upcomingOpportunity = "Negative price at \(neg.expectedTime) — " +
                                  "get paid \(String(format: "%.1f", abs(neg.forecastPrice)))¢/kWh to charge"
        } else {
            upcomingOpportunity = nil
        }
        
        let recommendation = input.urgentActionHint
        
        return ForecastExplanationOutput(
            currentStateHeadline: currentStateHeadline,
            currentStateDetail: currentStateDetail,
            upcomingOpportunity: upcomingOpportunity,
            recommendation: recommendation,
            alertEnhancement: nil  // Use fallback notification text
        )
    }
}

// MARK: - SwiftUI Integration

#if canImport(SwiftUI)
import SwiftUI

/// Environment key for the intelligent summary service
private struct IntelligentSummaryServiceKey: EnvironmentKey {
    static let defaultValue = IntelligentSummaryService()
}

extension EnvironmentValues {
    var intelligentSummary: IntelligentSummaryService {
        get { self[IntelligentSummaryServiceKey.self] }
        set { self[IntelligentSummaryServiceKey.self] = newValue }
    }
}

/// View modifier to add intelligent summary capability
extension View {
    func withIntelligentSummary(_ service: IntelligentSummaryService) -> some View {
        environment(\.intelligentSummary, service)
    }
}
#endif

// MARK: - Generable Conformance (when Foundation Models available)

#if canImport(FoundationModels)
extension PerformanceSummaryOutput: Generable {
    static var generableDescription: String {
        "A summary of energy system performance including headline, explanation, and actionable insights"
    }
}

extension ForecastExplanationOutput: Generable {
    static var generableDescription: String {
        "An explanation of current energy system state and upcoming price opportunities"
    }
}
#endif
