//
//  DecisionReasonService.swift
//  Powston
//
//  Translates Powston controller decision traces into human-readable explanations.
//  Uses hybrid architecture: deterministic engine extracts facts, AI writes prose.
//  Reusable across Dashboard, ActionDetailsView, and Notifications.
//

import Foundation
import SwiftUI
import Combine
import FoundationModels

// MARK: - Output Structure

struct DecisionExplanation: Equatable {
    let headline: String           // "Holding: Near floor" (deterministic)
    let explanation: String        // "Battery at 5%, near 53% floor." (AI or deterministic)
    let keyFact: String?           // Most important extracted fact (deterministic)
    let usedAI: Bool
}

// MARK: - Context for Analysis

struct DecisionContext {
    let currentAction: String
    let soc: Double
    let solarKw: Double
    let gridKw: Double
    let batteryKw: Double
    let buyPrice: Double
    let sellPrice: Double
    let isCharging: Bool
    let isExporting: Bool
}

// MARK: - Parsed Trace

struct ParsedDecisionTrace {
    let finalAction: String         // "auto", "import", "export"
    let matchingChecks: [String]    // ✅ entries that led to action
    let infoEntries: [String]       // ℹ️ informational context
    let failedChecks: [String]      // ❌ blocked conditions
}

// MARK: - Decision Analysis (Deterministic)

struct DecisionAnalysis {
    let action: ActionType
    let headline: String
    
    // Extracted facts (all deterministic)
    let soc: Int
    let floorPercent: Int?
    let buyPrice: Double
    let sellPrice: Double
    
    // Reasons (extracted from trace)
    let primaryReason: String?      // Why this action
    let blockedReason: String?      // Why not the alternative
    let priceContext: String?       // Price-related info
    
    // State flags
    let isNearFloor: Bool
    let isLowBattery: Bool
    let isPriceOptimal: Bool
    let hasNegativePrice: Bool
    let hasPriceSpike: Bool
    
    enum ActionType: String {
        case buying = "import"
        case selling = "export"
        case holding = "auto"
        case curtailed = "curtail"
        case unknown = "unknown"
    }
}

// MARK: - FM Generable Output

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GenerableDecisionExplanation {
    /// 1-2 sentences explaining what's happening. Use the exact numbers from VERIFIED FACTS. Do NOT invent reasons.
    let explanation: String
}

// MARK: - Service

@MainActor
class DecisionReasonService: ObservableObject {
    
    static let shared = DecisionReasonService()
    
    @Published var isAvailable = false
    @AppStorage("enableAppleIntelligence") private var enableAppleIntelligence: Bool = true
    
    var shouldUseAI: Bool {
        enableAppleIntelligence && isAvailable
    }
    
    private let systemInstructions = """
    Write ONE sentence explaining what the battery is doing NOW. Be concise.

    RULES:
    - ONE sentence max
    - Use ONLY facts from VERIFIED FACTS
    - NEVER repeat prices (already shown in UI)
    - NEVER mention forecasts or future prices
    - NEVER use jargon: SOC, arbitrage, gate, Best-N, threshold, floor
    - Focus on current state, not strategy

    GOOD:
    ✓ "Battery at 12%, waiting for better rates."
    ✓ "Buying while rates are cheap."
    ✓ "Selling — good prices right now."
    ✓ "Battery low, can't sell."

    BAD:
    ✗ "Battery at 12%, buy price 11.1¢, sell price 3.8¢" (repeats prices)
    ✗ "Waiting for ultra-cheap rates at 2¢" (forecasting)
    ✗ "SOC below arbitrage gate threshold" (jargon)
    """
    
    private var userLanguage: String {
        Locale.preferredLanguages.first ?? "en-AU"
    }
    
    init() {
        checkAvailability()
    }
    
    func checkAvailability() {
        if #available(iOS 26.0, macOS 26.0, *) {
            Task {
                await checkFoundationModelsAvailability()
            }
        }
    }
    
    @available(iOS 26.0, macOS 26.0, *)
    private func checkFoundationModelsAvailability() async {
        do {
            let session = LanguageModelSession()
            _ = try await session.respond(to: "test")
            await MainActor.run {
                self.isAvailable = true
                NotificationCenter.default.post(name: .init("DecisionReasonServiceAvailable"), object: nil)
            }
        } catch {
            await MainActor.run { self.isAvailable = false }
        }
    }
    
    // MARK: - Main Entry Point
    
    func explain(reason: String?, action: String, context: DecisionContext) async -> DecisionExplanation {
        let reasonText = reason ?? ""
        let parsed = parseDecisionTrace(reasonText)
        
        // Build deterministic analysis first
        let analysis = buildAnalysis(parsed: parsed, action: action, context: context, rawReason: reasonText)
        
        // Try AI for explanation prose if enabled
        if #available(iOS 26.0, macOS 26.0, *), shouldUseAI {
            do {
                return try await explainWithAI(analysis: analysis)
            } catch {
                // Fall through to deterministic
            }
        }
        
        // Deterministic fallback
        return buildDeterministicExplanation(analysis: analysis)
    }
    
    // MARK: - Analysis Builder (Deterministic)
    
    private func buildAnalysis(parsed: ParsedDecisionTrace, action: String, context: DecisionContext, rawReason: String) -> DecisionAnalysis {
        let actionLower = action.lowercased()
        let reasonLower = rawReason.lowercased()
        
        // Determine action type
        let actionType: DecisionAnalysis.ActionType
        switch actionLower {
        case "charge", "import": actionType = .buying
        case "discharge", "export": actionType = .selling
        case "curtail": actionType = .curtailed
        case "auto": actionType = .holding
        default: actionType = .unknown
        }
        
        // Extract floor percentage
        var floorPercent: Int? = nil
        let allEntries = parsed.matchingChecks + parsed.infoEntries + parsed.failedChecks + [rawReason]
        for entry in allEntries {
            if let match = entry.range(of: #"floor\s*(\d+)%"#, options: [.regularExpression, .caseInsensitive]) {
                let numStr = entry[match].filter { $0.isNumber }
                if let num = Int(numStr) {
                    floorPercent = num
                    break
                }
            }
            if let match = entry.range(of: #"(\d+)%/(\d+)%"#, options: .regularExpression) {
                let nums = entry[match].split(separator: "/").compactMap { Int($0.filter { $0.isNumber }) }
                if nums.count == 2 {
                    floorPercent = nums[1]
                    break
                }
            }
        }
        
        // State flags
        // Near floor: only if SOC is within 10% of floor (not if way below)
        let isNearFloor: Bool
        if let floor = floorPercent {
            let floorD = Double(floor)
            isNearFloor = (reasonLower.contains("holding") || reasonLower.contains("near floor") || reasonLower.contains("near-miss"))
                          && context.soc >= floorD - 5 && context.soc <= floorD + 10
        } else {
            isNearFloor = reasonLower.contains("holding") || reasonLower.contains("near floor") || reasonLower.contains("near-miss")
        }
        
        // Low battery: SOC is low OR way below floor OR survival/gate mentioned
        let isLowBattery = context.soc < 30 || reasonLower.contains("survival") || reasonLower.contains("gate")
                           || (floorPercent != nil && context.soc < Double(floorPercent!) - 10)
        let isPriceOptimal = !reasonLower.contains("not in best") && !reasonLower.contains("not optimal")
        let hasNegativePrice = context.buyPrice < 0
        let hasPriceSpike = context.sellPrice > 40
        
        // Build headline (deterministic)
        let headline = buildHeadline(actionType: actionType, context: context, isNearFloor: isNearFloor, isLowBattery: isLowBattery, isPriceOptimal: isPriceOptimal, hasNegativePrice: hasNegativePrice, hasPriceSpike: hasPriceSpike, reasonLower: reasonLower)
        
        // Extract primary reason from trace
        let primaryReason = extractPrimaryReason(parsed: parsed, actionType: actionType, reasonLower: reasonLower)
        
        // Extract blocked reason
        let blockedReason = extractBlockedReason(parsed: parsed)
        
        // Price context
        let priceContext = buildPriceContext(context: context, actionType: actionType)
        
        return DecisionAnalysis(
            action: actionType,
            headline: headline,
            soc: Int(context.soc),
            floorPercent: floorPercent,
            buyPrice: context.buyPrice,
            sellPrice: context.sellPrice,
            primaryReason: primaryReason,
            blockedReason: blockedReason,
            priceContext: priceContext,
            isNearFloor: isNearFloor,
            isLowBattery: isLowBattery,
            isPriceOptimal: isPriceOptimal,
            hasNegativePrice: hasNegativePrice,
            hasPriceSpike: hasPriceSpike
        )
    }
    
    private func buildHeadline(actionType: DecisionAnalysis.ActionType, context: DecisionContext, isNearFloor: Bool, isLowBattery: Bool, isPriceOptimal: Bool, hasNegativePrice: Bool, hasPriceSpike: Bool, reasonLower: String) -> String {
        switch actionType {
        case .buying:
            if hasNegativePrice {
                return "Buying: Getting paid to charge"
            } else if context.buyPrice < 3 {
                return "Buying: Ultra-cheap rates"
            } else if context.buyPrice < 8 {
                return "Buying: Cheap rates"
            } else if reasonLower.contains("urgent") || reasonLower.contains("physics") {
                return "Buying: Needs charge"
            }
            return "Buying from grid"
            
        case .selling:
            if hasPriceSpike {
                return "Selling: Price spike"
            } else if context.sellPrice > 20 {
                return "Selling: Great prices"
            } else if context.sellPrice > 10 {
                return "Selling: Good prices"
            }
            return "Selling to grid"
            
        case .holding:
            // Priority 1: Low battery (can't do much)
            if isLowBattery || context.soc < 30 {
                return "Holding: Battery low"
            }
            // Priority 2: Near floor (protecting reserves)
            if isNearFloor {
                return "Holding: Near floor"
            }
            // Priority 3: Waiting for prices
            if !isPriceOptimal {
                return "Waiting: Prices not right"
            }
            // Priority 4: Current activity
            if context.solarKw > 1 && context.isCharging {
                return "Auto: Storing solar"
            } else if context.isExporting && abs(context.gridKw) > 0.5 {
                return "Auto: Selling surplus"
            } else if context.solarKw > 1 {
                return "Auto: Solar powering home"
            }
            return "Waiting"
            
        case .curtailed:
            return "Curtailed: Grid limit"
            
        case .unknown:
            return "Monitoring"
        }
    }
    
    private func extractPrimaryReason(parsed: ParsedDecisionTrace, actionType: DecisionAnalysis.ActionType, reasonLower: String) -> String? {
        // Look for the most relevant matching check
        for check in parsed.matchingChecks {
            let lower = check.lowercased()
            
            // Physics/urgent charge
            if lower.contains("physics urgent") || lower.contains("urgent charge") {
                return "urgent charge needed"
            }
            
            // Best-N periods (price optimization)
            if lower.contains("best") && (lower.contains("buy") || lower.contains("sell") || lower.contains("daytime")) {
                if actionType == .buying {
                    return "in best buy window"
                } else if actionType == .selling {
                    return "in best sell window"
                }
            }
            
            // Negative price
            if lower.contains("negative") {
                return "negative prices"
            }
            
            // Peak period
            if lower.contains("peak period") {
                return "peak period"
            }
        }
        
        // Check info entries
        for info in parsed.infoEntries {
            let lower = info.lowercased()
            
            if lower.contains("holding") || lower.contains("near floor") {
                return "near floor minimum"
            }
            if lower.contains("not optimal") || lower.contains("not in best") {
                return "price not optimal"
            }
        }
        
        return nil
    }
    
    private func extractBlockedReason(parsed: ParsedDecisionTrace) -> String? {
        for failed in parsed.failedChecks {
            let lower = failed.lowercased()
            
            if lower.contains("floor") {
                return "below floor minimum"
            }
            if lower.contains("gate") || lower.contains("survival") {
                return "battery too low"
            }
            if lower.contains("max buy") || lower.contains("expensive") {
                return "buy price too high"
            }
        }
        return nil
    }
    
    private func buildPriceContext(context: DecisionContext, actionType: DecisionAnalysis.ActionType) -> String? {
        switch actionType {
        case .buying:
            if context.buyPrice < 0 {
                return "getting paid \(String(format: "%.1f", abs(context.buyPrice)))¢"
            }
            return "at \(String(format: "%.1f", context.buyPrice))¢"
            
        case .selling:
            return "at \(String(format: "%.1f", context.sellPrice))¢"
            
        case .holding:
            if context.sellPrice < 5 {
                return "sell price only \(String(format: "%.1f", context.sellPrice))¢"
            } else if context.buyPrice > 15 {
                return "buy price \(String(format: "%.1f", context.buyPrice))¢ too high"
            }
            return nil
            
        default:
            return nil
        }
    }
    
    // MARK: - Trace Parsing
    
    func parseDecisionTrace(_ reason: String) -> ParsedDecisionTrace {
        var finalAction = "auto"
        if let match = reason.range(of: #"final:(\w+)"#, options: .regularExpression) {
            let extracted = String(reason[match]).replacingOccurrences(of: "final:", with: "")
            finalAction = extracted.lowercased()
        }
        
        let segments = reason.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        
        var matchingChecks: [String] = []
        var infoEntries: [String] = []
        var failedChecks: [String] = []
        
        for segment in segments {
            if segment.contains("✅") {
                let actionSuffix = "→\(finalAction)"
                if segment.lowercased().contains(actionSuffix) {
                    let cleanText = cleanSegment(segment, removing: "✅")
                    if !cleanText.isEmpty {
                        matchingChecks.append(cleanText)
                    }
                }
            } else if segment.contains("ℹ️") || segment.contains("ℹ") {
                var cleanText = segment
                    .replacingOccurrences(of: "ℹ️", with: "")
                    .replacingOccurrences(of: "ℹ", with: "")
                cleanText = cleanSegment(cleanText, removing: "")
                if !cleanText.isEmpty {
                    infoEntries.append(cleanText)
                }
            } else if segment.contains("❌") {
                let cleanText = cleanSegment(segment, removing: "❌")
                if !cleanText.isEmpty {
                    failedChecks.append(cleanText)
                }
            }
        }
        
        return ParsedDecisionTrace(
            finalAction: finalAction,
            matchingChecks: matchingChecks,
            infoEntries: infoEntries,
            failedChecks: failedChecks
        )
    }
    
    private func cleanSegment(_ segment: String, removing emoji: String) -> String {
        var cleanText = segment
            .replacingOccurrences(of: emoji, with: "")
            .trimmingCharacters(in: .whitespaces)
        
        if let arrowRange = cleanText.range(of: #"→\w+$"#, options: .regularExpression) {
            cleanText = String(cleanText[..<arrowRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        
        return cleanText
    }
    
    // MARK: - Foundation Models
    
    @available(iOS 26.0, macOS 26.0, *)
    private func explainWithAI(analysis: DecisionAnalysis) async throws -> DecisionExplanation {
        let prompt = buildFMPrompt(analysis: analysis)
        let session = LanguageModelSession(instructions: systemInstructions)
        let response = try await session.respond(to: prompt, generating: GenerableDecisionExplanation.self)
        
        return DecisionExplanation(
            headline: analysis.headline,
            explanation: response.content.explanation,
            keyFact: buildKeyFact(analysis: analysis),
            usedAI: true
        )
    }
    
    private func buildFMPrompt(analysis: DecisionAnalysis) -> String {
        var prompt = """
        Explain what the battery is doing NOW in ONE sentence.

        ACTION: \(analysis.action.rawValue) (\(actionDescription(analysis.action)))
        
        ✅ VERIFIED FACTS:
        - Battery: \(analysis.soc)%
        """
        
        // Only mention floor if actually near it (within 10%)
        if let floor = analysis.floorPercent, analysis.soc <= floor + 10, analysis.soc >= floor - 5 {
            prompt += "\n- Near floor minimum (\(floor)%)"
        }
        
        // State context - simplified
        if analysis.isLowBattery {
            prompt += "\n- Battery is low"
        }
        if analysis.hasNegativePrice {
            prompt += "\n- Negative prices (getting paid to charge)"
        }
        if analysis.hasPriceSpike {
            prompt += "\n- Price spike happening"
        }
        if !analysis.isPriceOptimal && analysis.action == .holding {
            prompt += "\n- Waiting for better prices"
        }
        
        prompt += """
        

        Write ONE sentence. Do NOT mention specific prices (already shown in UI).
        
        Respond in \(userLanguage).
        """
        
        return prompt
    }
    
    private func actionDescription(_ action: DecisionAnalysis.ActionType) -> String {
        switch action {
        case .buying: return "charging from grid"
        case .selling: return "exporting to grid"
        case .holding: return "waiting/holding"
        case .curtailed: return "grid limited"
        case .unknown: return "monitoring"
        }
    }
    
    // MARK: - Deterministic Fallback
    
    private func buildDeterministicExplanation(analysis: DecisionAnalysis) -> DecisionExplanation {
        let explanation = buildExplanationText(analysis: analysis)
        
        return DecisionExplanation(
            headline: analysis.headline,
            explanation: explanation,
            keyFact: buildKeyFact(analysis: analysis),
            usedAI: false
        )
    }
    
    private func buildExplanationText(analysis: DecisionAnalysis) -> String {
        switch analysis.action {
        case .buying:
            if analysis.hasNegativePrice {
                return "Getting paid to charge!"
            } else if analysis.buyPrice < 3 {
                return "Ultra-cheap rates — charging up."
            } else if analysis.buyPrice < 8 {
                return "Cheap rates — good time to charge."
            } else if analysis.primaryReason == "urgent charge needed" {
                return "Battery low, needs to charge."
            }
            return "Charging from grid."
            
        case .selling:
            if analysis.hasPriceSpike {
                return "Price spike — selling stored power."
            } else if analysis.sellPrice > 20 {
                return "Great prices — selling stored power."
            }
            return "Selling to grid."
            
        case .holding:
            // Low battery is the main constraint
            if analysis.isLowBattery || analysis.soc < 30 {
                return "Battery at \(analysis.soc)%, waiting for better rates."
            }
            
            // Near floor - protecting reserves
            if analysis.isNearFloor, let floor = analysis.floorPercent {
                return "Battery at \(analysis.soc)%, near \(floor)% floor for tonight."
            }
            
            // Just waiting for prices
            if !analysis.isPriceOptimal {
                return "Waiting for better prices."
            }
            
            return "Monitoring conditions."
            
        case .curtailed:
            return "Grid export limit reached."
            
        case .unknown:
            return "Controller active."
        }
    }
    
    private func buildKeyFact(analysis: DecisionAnalysis) -> String? {
        // Only show key facts that add real value
        if analysis.hasNegativePrice {
            return "Negative!"
        }
        if analysis.hasPriceSpike {
            return "Spike!"
        }
        // Only show floor if actually near it
        if analysis.isNearFloor, let floor = analysis.floorPercent,
           analysis.soc <= floor + 5 && analysis.soc >= floor - 5 {
            return "Floor: \(floor)%"
        }
        return nil
    }
}

// MARK: - SwiftUI Environment

private struct DecisionReasonServiceKey: EnvironmentKey {
    static let defaultValue = DecisionReasonService.shared
}

extension EnvironmentValues {
    var decisionReasonService: DecisionReasonService {
        get { self[DecisionReasonServiceKey.self] }
        set { self[DecisionReasonServiceKey.self] = newValue }
    }
}
