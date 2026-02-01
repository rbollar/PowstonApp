//
//  DecisionReasonService.swift
//  Powston
//
//  Translates Powston controller decision traces into human-readable explanations.
//  Uses Foundation Models when available, with deterministic fallback.
//  Reusable across Dashboard, ActionDetailsView, and Notifications.
//

import Foundation
import SwiftUI
import FoundationModels

// MARK: - Output Structure

struct DecisionExplanation {
    let headline: String
    let explanation: String
    let usedAI: Bool
}

// MARK: - Context for FM

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
    let finalAction: String
    let matchingChecks: [String]
    let infoEntries: [String]
    let failedChecks: [String]
}

// MARK: - FM Generable Output

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GenerableDecisionExplanation {
    /// Short headline for the action, e.g. "Charging: Low prices" or "Auto: Waiting for better spread"
    let headline: String
    /// 1-2 sentence explanation of why this decision was made. Be specific about prices, SOC, thresholds.
    let explanation: String
}

// MARK: - Service

@MainActor
class DecisionReasonService: ObservableObject {
    
    static let shared = DecisionReasonService()
    
    @Published var isAvailable = false
    
    private let systemInstructions = """
    You are explaining energy controller decisions for a home battery system.
    The controller decides whether to import (charge from grid), export (sell to grid), or stay in auto mode.
    
    KEY CONCEPTS:
    - "Arbitrage gate" checks if SOC is enough to survive overnight. If SOC < survival threshold, the gate is "bypassed" (skipped).
    - "Floor" is the minimum SOC the battery won't go below. Export is blocked if SOC ≤ floor.
    - "Not optimal" means the price isn't good enough compared to expected better prices.
    - "Physics urgent" means the physics model calculated an urgent need to charge.
    - Negative prices (< 0¢) mean you GET PAID to import electricity.
    - Peak periods are expensive — avoid importing during peaks.
    
    Be concise. Use plain language. Explain the WHY, not just restate the data.
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
            await MainActor.run { self.isAvailable = true }
        } catch {
            await MainActor.run { self.isAvailable = false }
        }
    }
    
    // MARK: - Main Entry Point
    
    func explain(reason: String?, action: String, context: DecisionContext) async -> DecisionExplanation {
        let reasonText = reason ?? ""
        let parsed = parseDecisionTrace(reasonText)
        
        // Try FM first
        if #available(iOS 26.0, macOS 26.0, *), isAvailable {
            do {
                return try await explainWithFoundationModels(
                    parsed: parsed,
                    action: action,
                    context: context,
                    rawReason: reasonText
                )
            } catch {
                // Fall through to deterministic
            }
        }
        
        // Deterministic fallback
        return buildDeterministicExplanation(
            parsed: parsed,
            action: action,
            context: context,
            rawReason: reasonText
        )
    }
    
    // MARK: - Foundation Models
    
    @available(iOS 26.0, macOS 26.0, *)
    private func explainWithFoundationModels(
        parsed: ParsedDecisionTrace,
        action: String,
        context: DecisionContext,
        rawReason: String
    ) async throws -> DecisionExplanation {
        let prompt = buildFMPrompt(parsed: parsed, action: action, context: context)
        
        let session = LanguageModelSession(instructions: systemInstructions)
        let response = try await session.respond(to: prompt, generating: GenerableDecisionExplanation.self)
        
        return DecisionExplanation(
            headline: response.content.headline,
            explanation: response.content.explanation,
            usedAI: true
        )
    }
    
    private func buildFMPrompt(parsed: ParsedDecisionTrace, action: String, context: DecisionContext) -> String {
        var prompt = """
        Explain this energy controller decision in plain language.
        
        CURRENT STATE:
        - Action: \(action.uppercased())
        - SOC: \(String(format: "%.0f", context.soc))%
        - Solar: \(String(format: "%.1f", context.solarKw)) kW
        - Grid: \(String(format: "%.1f", abs(context.gridKw))) kW (\(context.isExporting ? "exporting" : "importing"))
        - Battery: \(String(format: "%.1f", abs(context.batteryKw))) kW (\(context.isCharging ? "charging" : "discharging"))
        - Buy price: \(String(format: "%.1f", context.buyPrice))¢
        - Sell price: \(String(format: "%.1f", context.sellPrice))¢
        
        DECISION TRACE:
        Final action: \(parsed.finalAction)
        """
        
        if !parsed.matchingChecks.isEmpty {
            prompt += "\n\nWINNING CHECKS (✅ → \(parsed.finalAction)):"
            for check in parsed.matchingChecks {
                prompt += "\n- \(check)"
            }
        }
        
        if !parsed.infoEntries.isEmpty {
            prompt += "\n\nINFO (why other actions weren't taken):"
            for info in parsed.infoEntries.prefix(5) {
                prompt += "\n- \(info)"
            }
        }
        
        if !parsed.failedChecks.isEmpty {
            prompt += "\n\nBLOCKED (❌):"
            for check in parsed.failedChecks.prefix(3) {
                prompt += "\n- \(check)"
            }
        }
        
        prompt += """
        
        Generate:
        - headline: Short action summary (e.g., "Auto: Waiting for better prices" or "Import: Solar shortfall")
        - explanation: 1-2 sentences explaining WHY. Be specific about the key threshold or condition.
        
        Respond in \(userLanguage).
        """
        
        return prompt
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
    
    // MARK: - Deterministic Fallback
    
    private func buildDeterministicExplanation(
        parsed: ParsedDecisionTrace,
        action: String,
        context: DecisionContext,
        rawReason: String
    ) -> DecisionExplanation {
        let headline = buildHeadline(parsed: parsed, action: action, context: context, rawReason: rawReason)
        let explanation = buildExplanation(parsed: parsed, action: action, context: context, rawReason: rawReason)
        
        return DecisionExplanation(
            headline: headline,
            explanation: explanation,
            usedAI: false
        )
    }
    
    private func buildHeadline(parsed: ParsedDecisionTrace, action: String, context: DecisionContext, rawReason: String) -> String {
        let actionLower = action.lowercased()
        
        switch actionLower {
        case "charge", "import":
            if context.buyPrice < 0 {
                return "Import: Getting paid to charge!"
            }
            if let winningReason = parsed.matchingChecks.last {
                return "Import: \(summarizeReason(winningReason))"
            }
            if context.buyPrice < 3 {
                return "Import: Ultra-cheap rates"
            }
            return "Charging from grid"
            
        case "discharge", "export":
            if let winningReason = parsed.matchingChecks.last {
                return "Export: \(summarizeReason(winningReason))"
            }
            if context.sellPrice > 40 {
                return "Export: Capturing price spike"
            } else if context.sellPrice > 20 {
                return "Export: Premium rates"
            }
            return "Exporting to grid"
            
        case "auto":
            if let winningReason = parsed.matchingChecks.last {
                let isJustDefault = winningReason.lowercased().contains("starting in auto") ||
                                    winningReason.lowercased().contains("default")
                
                if !isJustDefault {
                    return "Auto: \(summarizeReason(winningReason))"
                }
            }
            
            if let infoReason = extractBestInfoReason(parsed.infoEntries) {
                return "Auto: \(infoReason)"
            }
            
            let reasonLower = rawReason.lowercased()
            if reasonLower.contains("floor") || reasonLower.contains("holding") {
                return "Auto: Near floor — holding"
            }
            if reasonLower.contains("survival") || reasonLower.contains("overnight") {
                return "Auto: Preserving overnight reserve"
            }
            
            if context.solarKw > 1 && context.isCharging && abs(context.batteryKw) > 1 {
                return "Auto: Storing solar"
            } else if context.isCharging && abs(context.batteryKw) > 1 {
                return "Auto: Charging"
            } else if context.isExporting && abs(context.gridKw) > 0.5 {
                return "Auto: Exporting surplus"
            } else if context.solarKw > 1 {
                return "Auto: Solar powering home"
            }
            
            return "Auto: Monitoring"
            
        case "curtail":
            return "Curtailed: Grid limit reached"
            
        default:
            return "Controller active"
        }
    }
    
    private func buildExplanation(parsed: ParsedDecisionTrace, action: String, context: DecisionContext, rawReason: String) -> String {
        if parsed.finalAction == "import" || parsed.finalAction == "export" {
            if let matchingReason = parsed.matchingChecks.last {
                return translateReasonDetail(matchingReason)
            }
        }
        
        if parsed.finalAction == "auto" {
            if let matchingReason = parsed.matchingChecks.last {
                let isJustDefault = matchingReason.lowercased().contains("starting in auto") ||
                                    matchingReason.lowercased().contains("default")
                if !isJustDefault {
                    return translateReasonDetail(matchingReason)
                }
            }
            
            if let infoDetail = buildAutoDetailFromInfo(parsed.infoEntries) {
                return infoDetail
            }
        }
        
        let reasonLower = rawReason.lowercased()
        if reasonLower.contains("floor") || reasonLower.contains("holding") {
            return "Battery near minimum — protecting reserves"
        }
        if reasonLower.contains("survival") || reasonLower.contains("overnight") {
            return "SOC sufficient for overnight — holding position"
        }
        if reasonLower.contains("arbitrage gate") {
            if reasonLower.contains("< ") || reasonLower.contains("bypassed") {
                return "SOC below survival threshold — arbitrage gate bypassed"
            }
            return "Arbitrage gate passed — SOC sufficient"
        }
        
        return buildFallbackExplanation(action: action, context: context)
    }
    
    private func buildFallbackExplanation(action: String, context: DecisionContext) -> String {
        let actionLower = action.lowercased()
        
        switch actionLower {
        case "charge", "import":
            if context.buyPrice < 0 {
                return "Negative prices — earning while charging"
            } else if context.buyPrice < 5 {
                return "Low import rates"
            }
            return "Building reserves"
            
        case "discharge", "export":
            if context.sellPrice > 30 {
                return "High export rates"
            }
            return "Favorable spread"
            
        case "auto":
            if context.solarKw > 1 {
                return "Solar covering load"
            }
            let spread = context.sellPrice - context.buyPrice
            if spread >= 0 && spread < 5 {
                return "Spread \(String(format: "%.1f", spread))¢ below trading threshold"
            }
            return "Monitoring for opportunities"
            
        case "curtail":
            return "Grid operator limiting export"
            
        default:
            return "Managing energy flow"
        }
    }
    
    // MARK: - Pattern Matching Helpers
    
    private func summarizeReason(_ reason: String) -> String {
        let lower = reason.lowercased()
        
        if lower.contains("arbitrage gate") {
            return lower.contains("bypassed") || lower.contains("< ") ? "Low SOC — gate bypassed" : "Arbitrage gate passed"
        }
        if lower.contains("physics urgent") {
            return lower.contains("not") ? "No urgent charge needed" : "Physics model: urgent charge"
        }
        if lower.contains("not in best") || lower.contains("not optimal") {
            if lower.contains("sell") { return "Sell price not optimal" }
            if lower.contains("buy") || lower.contains("daytime") { return "Buy price not optimal" }
            return "Price not optimal"
        }
        if lower.contains("floor") && (lower.contains("block") || lower.contains("≤")) {
            return "Export blocked by floor"
        }
        if lower.contains("near-miss") { return "Near floor threshold" }
        if lower.contains("peak period") { return "Peak period protection" }
        if lower.contains("sunny day") { return "Sunny day — waiting" }
        if lower.contains("waiting for") && lower.contains("price") { return "Waiting for better price" }
        if lower.contains("deficit") && lower.contains("block") { return "Deficit block active" }
        if lower.contains("negative price") { return "Negative price handling" }
        if lower.contains("battery full") || lower.contains("nearly full") { return "Battery nearly full" }
        if lower.contains("import restriction") { return "Import restricted" }
        if lower.contains("spread check") { return "Spread too tight" }
        if lower.contains("insufficient margin") || lower.contains("insufficient savings") { return "Insufficient margin" }
        if lower.contains("solar shortfall") { return "Solar shortfall" }
        if lower.contains("morning dumping") || lower.contains("morning dump") { return "Morning dump — high SOC" }
        
        // Strip P## prefix
        var cleanReason = reason
        if let match = reason.range(of: #"^P\d+:\s*"#, options: .regularExpression) {
            cleanReason = String(reason[match.upperBound...])
        }
        
        if cleanReason.count <= 35 { return cleanReason.trimmingCharacters(in: .whitespaces) }
        
        let index = cleanReason.index(cleanReason.startIndex, offsetBy: min(32, cleanReason.count))
        return String(cleanReason[..<index]) + "..."
    }
    
    private func translateReasonDetail(_ reason: String) -> String {
        let lower = reason.lowercased()
        
        if lower.contains("arbitrage gate") {
            if lower.contains("bypassed") || lower.contains("< ") {
                if let match = reason.range(of: #"SOC (\d+)%\s*<\s*(\d+)%"#, options: [.regularExpression, .caseInsensitive]) {
                    return "SOC \(String(reason[match])) survival — gate bypassed"
                }
                return "SOC below survival threshold — arbitrage gate bypassed"
            }
            return "Arbitrage gate passed — SOC sufficient for overnight"
        }
        
        if lower.contains("floor") && (lower.contains("block") || lower.contains("≤")) {
            if let socMatch = reason.range(of: #"SOC (\d+)%"#, options: [.regularExpression, .caseInsensitive]),
               let floorMatch = reason.range(of: #"floor (\d+)%"#, options: [.regularExpression, .caseInsensitive]) {
                let soc = String(reason[socMatch]).replacingOccurrences(of: "SOC ", with: "")
                let floor = String(reason[floorMatch]).replacingOccurrences(of: "floor ", with: "")
                return "SOC \(soc) at floor \(floor) — export blocked"
            }
            return "Export blocked by floor setting"
        }
        
        if lower.contains("not physics urgent") { return "No urgent charge window — deadline not imminent" }
        
        if lower.contains("not in best") || lower.contains("not optimal") {
            if lower.contains("sell") {
                if let match = reason.range(of: #"Sell (\d+\.?\d*)c"#, options: [.regularExpression, .caseInsensitive]) {
                    return "\(String(reason[match])) not in optimal sell range"
                }
                return "Sell price not in optimal range"
            }
            if lower.contains("buy") || lower.contains("daytime") {
                if let match = reason.range(of: #"Daytime (\d+\.?\d*)c"#, options: [.regularExpression, .caseInsensitive]) {
                    return "\(String(reason[match])) — waiting for cheaper"
                }
                return "Buy price not optimal — waiting"
            }
        }
        
        if lower.contains("solar shortfall") { return "Solar shortfall detected — importing while price acceptable" }
        if lower.contains("morning dumping") || lower.contains("morning dump") { return "Morning dump — high SOC + good sun + better buy prices coming" }
        if lower.contains("surplus") && lower.contains("block") { return "Surplus export blocked by floor" }
        if lower.contains("negative price") { return "Negative price — getting paid to charge" }
        if lower.contains("waiting for") && lower.contains("price") { return "Waiting for optimal price window" }
        if lower.contains("sunny day") { return "Sunny day — expecting solar, holding off" }
        if lower.contains("spread check") { return "Spread too tight for profitable trade" }
        
        // Strip P## prefix
        var cleanReason = reason
        if let match = reason.range(of: #"^P\d+:\s*"#, options: .regularExpression) {
            cleanReason = String(reason[match.upperBound...])
        }
        
        if cleanReason.count > 60 {
            let index = cleanReason.index(cleanReason.startIndex, offsetBy: 57)
            return String(cleanReason[..<index]) + "..."
        }
        
        return cleanReason
    }
    
    private func extractBestInfoReason(_ infoEntries: [String]) -> String? {
        for entry in infoEntries {
            let lower = entry.lowercased()
            
            if lower.contains("floor") && (lower.contains("block") || lower.contains("≤")) { return "Export blocked by floor" }
            if lower.contains("near floor") || (lower.contains("floor") && lower.contains("holding")) { return "Near floor — holding reserves" }
            if lower.contains("below night reserve") || lower.contains("reserve level") { return "Preserving night reserve" }
            if lower.contains("arbitrage gate") { return lower.contains("bypassed") || lower.contains("< ") ? "SOC below survival — gate bypassed" : "Arbitrage gate passed" }
            if lower.contains("not physics urgent") { return "No urgent charge needed" }
            
            if lower.contains("not selling") {
                if let match = entry.range(of: #"(\d+\.?\d*)c?\s*<\s*(\d+\.?\d*)c"#, options: .regularExpression) {
                    return "Spread too tight (\(String(entry[match])))"
                }
                return "Spread too tight"
            }
            
            if lower.contains("not in best") || lower.contains("not optimal") {
                if lower.contains("sell") { return "Sell price not in optimal range" }
                if lower.contains("buy") || lower.contains("daytime") { return "Buy price not optimal" }
                return "Price not optimal"
            }
            
            if lower.contains("price too high") { return "Import price too high" }
            if lower.contains("spread check") { return "Spread check failed" }
        }
        
        for entry in infoEntries {
            let lower = entry.lowercased()
            if lower.contains("solar forecast low") { return "Solar forecast low" }
            if lower.contains("good sun day") || lower.contains("sunny day") { return "Sunny day — waiting for optimal" }
            if lower.contains("waiting for") && lower.contains("price") { return "Waiting for better price" }
        }
        
        for entry in infoEntries {
            let lower = entry.lowercased()
            if lower.contains("threshold") && lower.contains("not met") { return "Export threshold not met" }
            if lower.contains("insufficient surplus") || lower.contains("insufficient margin") { return "Insufficient margin" }
            if lower.contains("battery full") || lower.contains("nearly full") { return "Battery nearly full" }
            if lower.contains("ev charging") { return lower.contains("limiting") ? "Limiting EV charging" : "EV charging active" }
            if lower.contains("import restriction") { return "Import restricted" }
        }
        
        return nil
    }
    
    private func buildAutoDetailFromInfo(_ infoEntries: [String]) -> String? {
        for entry in infoEntries {
            let lower = entry.lowercased()
            
            if lower.contains("floor") && (lower.contains("block") || lower.contains("≤")) {
                if let socMatch = entry.range(of: #"SOC (\d+)%"#, options: [.regularExpression, .caseInsensitive]),
                   let floorMatch = entry.range(of: #"floor (\d+)%"#, options: [.regularExpression, .caseInsensitive]) {
                    let soc = String(entry[socMatch]).replacingOccurrences(of: "SOC ", with: "")
                    let floor = String(entry[floorMatch]).replacingOccurrences(of: "floor ", with: "")
                    return "SOC \(soc) at floor \(floor) — export blocked"
                }
                return "Export blocked by floor setting"
            }
            
            if lower.contains("near floor") || (lower.contains("floor") && lower.contains("holding")) {
                return "Battery near minimum — protecting reserves"
            }
            
            if lower.contains("arbitrage gate") {
                if lower.contains("bypassed") || lower.contains("< ") {
                    if let match = entry.range(of: #"SOC (\d+)%\s*<\s*(\d+)%"#, options: [.regularExpression, .caseInsensitive]) {
                        return "SOC \(String(entry[match])) survival — gate bypassed"
                    }
                    return "SOC below survival threshold — arbitrage gate bypassed"
                }
                return "Arbitrage gate passed — SOC sufficient"
            }
            
            if lower.contains("not physics urgent") { return "No urgent charge window — deadline not imminent" }
            
            if lower.contains("not in best") || lower.contains("not optimal") {
                if lower.contains("sell") {
                    if let match = entry.range(of: #"Sell (\d+\.?\d*)c"#, options: [.regularExpression, .caseInsensitive]) {
                        return "\(String(entry[match])) not in optimal sell range"
                    }
                    return "Sell price not in optimal range"
                }
                if lower.contains("buy") || lower.contains("daytime") {
                    return "Buy price not in optimal range"
                }
            }
            
            if lower.contains("not selling") {
                if let match = entry.range(of: #"(\d+\.?\d*)c?\s*<\s*(\d+\.?\d*)c"#, options: .regularExpression) {
                    return "Sell price \(String(entry[match])) threshold"
                }
            }
            
            if lower.contains("waiting for optimal price") || lower.contains("waiting for better price") { return "Waiting for optimal price window" }
            if lower.contains("solar forecast low") { return "Solar forecast low — holding position" }
            if lower.contains("insufficient surplus") || lower.contains("insufficient margin") { return "Insufficient margin for trading" }
            if lower.contains("sunny day") || lower.contains("good sun day") { return "Sunny day expected — waiting for optimal window" }
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
