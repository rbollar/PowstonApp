//
//  DecisionSnapshotCard.swift
//  Powston
//
//  A 5-minute decision snapshot dashboard showing energy flow visualization
//

import SwiftUI

// MARK: - Main Dashboard View
struct DecisionSnapshotDashboard: View {
    let data: InverterResponse
    
    @Environment(\.decisionReasonService) private var reasonService
    @State private var explanation: DecisionExplanation?
    
    var body: some View {
        TimelineView(.animation) { timeline in
            let flowPhase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
            VStack(spacing: 16) {
                // Main card
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack {
                        Text("5-MINUTE DECISION SNAPSHOT")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .tracking(0.5)
                        
                        Spacer()
                        
                        // Interval time
                        if let intervalTime = data.intervalTime {
                            Text(formatIntervalTime(intervalTime))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // SOC Bar
                    SnapshotSOCBar(soc: data.batterySoc ?? 0)
                    
                    // Energy Flow Diagram - Inverter Centric
                    SnapshotEnergyFlow(
                        solarKw: data.solarKw,
                        homeKw: data.displayHouseKw,
                        gridKw: data.gridKw,
                        batteryKw: data.batteryKw,
                        batterySoc: data.batterySoc ?? 0,
                        currentAction: data.currentAction,
                        lastAction: data.lastAction,
                        isGridExporting: data.isGridExporting,
                        isCharging: data.isCharging,
                        flowPhase: flowPhase
                    )
                    
                    // Price Pills
                    HStack(spacing: 12) {
                        PricePillView(label: "Buy", cents: data.buyPrice ?? 0, isBuy: true)
                        PricePillView(label: "Sell", cents: data.sellPrice ?? 0, isBuy: false)
                        Spacer()
                    }
                    
                    // Decision Explanation
                    SnapshotDecisionExplanation(
                        headline: explanation?.headline ?? decisionHeadline,
                        reason: explanation?.explanation ?? decisionReason,
                        fullReason: data.reason,
                        isAIEnhanced: explanation?.usedAI ?? false
                    )
                    
                    // Large Price Cards
                    HStack(spacing: 12) {
                        LargePriceCardView(label: "Buy Price", cents: data.buyPrice ?? 0, isBuy: true)
                        LargePriceCardView(label: "Sell Price", cents: data.sellPrice ?? 0, isBuy: false)
                    }
                }
                .padding(20)
                .background(Color(.systemBackground))
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 2)
                .padding(.horizontal)
                
                // P&L Card
                TodayPLCard()
                    .padding(.horizontal)
            }
        }
        .task(id: data.reason) {
            await generateExplanation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("DecisionReasonServiceAvailable"))) { _ in
            // Re-generate when AI becomes available
            Task {
                await generateExplanation()
            }
        }
    }
    
    private func generateExplanation() async {
        let context = DecisionContext(
            currentAction: data.currentAction,
            soc: data.batterySoc ?? 0,
            solarKw: data.solarKw,
            gridKw: data.gridKw,
            batteryKw: data.batteryKw,
            buyPrice: data.buyPrice ?? 0,
            sellPrice: data.sellPrice ?? 0,
            isCharging: data.isCharging,
            isExporting: data.isGridExporting
        )
        
        explanation = await reasonService.explain(
            reason: data.reason,
            action: data.currentAction,
            context: context
        )
    }
    
    // MARK: - Decision Trace Parsing
    
    /// Parsed decision trace info
    struct ParsedDecisionTrace {
        let finalAction: String  // "auto", "import", "export"
        let matchingChecks: [String]  // ✅ entries that match final action
        let infoEntries: [String]  // ℹ️ entries explaining why
    }
    
    /// Parse the decision trace to extract final action and matching reasons
    private func parseDecisionTrace(_ reason: String) -> ParsedDecisionTrace {
        // Extract final action
        var finalAction = "auto"
        if let match = reason.range(of: #"final:(\w+)"#, options: .regularExpression) {
            let extracted = String(reason[match]).replacingOccurrences(of: "final:", with: "")
            finalAction = extracted.lowercased()
        }
        
        // Split into segments
        let segments = reason.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        
        var matchingChecks: [String] = []
        var infoEntries: [String] = []
        
        for segment in segments {
            // Check if this is a ✅ entry
            if segment.contains("✅") {
                // Check if it matches the final action (ends with →finalAction)
                let actionSuffix = "→\(finalAction)"
                if segment.lowercased().contains(actionSuffix) {
                    // Extract the reason text, removing emoji and arrow suffix
                    var cleanText = segment
                        .replacingOccurrences(of: "✅", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    
                    // Remove the →action suffix
                    if let arrowRange = cleanText.range(of: #"→\w+$"#, options: .regularExpression) {
                        cleanText = String(cleanText[..<arrowRange.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
                    }
                    
                    if !cleanText.isEmpty {
                        matchingChecks.append(cleanText)
                    }
                }
            }
            // Check if this is an ℹ️ entry
            else if segment.contains("ℹ️") || segment.contains("ℹ") {
                var cleanText = segment
                    .replacingOccurrences(of: "ℹ️", with: "")
                    .replacingOccurrences(of: "ℹ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                
                // Remove the →action suffix
                if let arrowRange = cleanText.range(of: #"→\w+$"#, options: .regularExpression) {
                    cleanText = String(cleanText[..<arrowRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                }
                
                if !cleanText.isEmpty {
                    infoEntries.append(cleanText)
                }
            }
        }
        
        return ParsedDecisionTrace(
            finalAction: finalAction,
            matchingChecks: matchingChecks,
            infoEntries: infoEntries
        )
    }
    
    // MARK: - Decision Logic
    
    var decisionHeadline: String {
        let action = data.currentAction.lowercased()
        let buy = data.buyPrice ?? 0
        let reason = data.reason ?? ""
        
        // Parse the decision trace
        let parsed = parseDecisionTrace(reason)
        
        switch action {
        case "charge", "import":
            if buy < 0 {
                return "Charging: Getting paid to import!"
            }
            // Use matching ✅ reason if available
            if let winningReason = parsed.matchingChecks.last {
                return "Import: \(summarizeReason(winningReason))"
            }
            if buy < 3 {
                return "Charging: Ultra-cheap rates"
            }
            return "Charging from grid"
            
        case "discharge", "export":
            let sell = data.sellPrice ?? 0
            // Use matching ✅ reason if available
            if let winningReason = parsed.matchingChecks.last {
                return "Export: \(summarizeReason(winningReason))"
            }
            if sell > 40 {
                return "Exporting: Capturing price spike"
            } else if sell > 20 {
                return "Exporting: Premium rates"
            }
            return "Exporting to grid"
            
        case "auto":
            // Use matching ✅ reason if it's not just the default
            if let winningReason = parsed.matchingChecks.last {
                let isJustDefault = winningReason.lowercased().contains("starting in auto") ||
                                    winningReason.lowercased().contains("default")
                
                if !isJustDefault {
                    return "Auto: \(summarizeReason(winningReason))"
                }
            }
            
            // For default auto, explain WHY using ℹ️ entries
            if let infoReason = extractBestInfoReason(parsed.infoEntries) {
                return "Auto: \(infoReason)"
            }
            
            // Direct scan of raw reason for key patterns (backup if parsing missed it)
            let reasonLower = reason.lowercased()
            if reasonLower.contains("floor") || reasonLower.contains("holding") {
                return "Auto: Near floor — holding"
            }
            if reasonLower.contains("survival") || reasonLower.contains("overnight") {
                return "Auto: Preserving overnight reserve"
            }
            
            // Fallback: infer from current state (only if solar actually producing)
            if data.solarKw > 1 && data.isCharging && abs(data.batteryKw) > 1 {
                return "Auto: Storing solar"
            } else if data.isCharging && abs(data.batteryKw) > 1 {
                return "Auto: Charging"
            } else if data.isGridExporting && abs(data.gridKw) > 0.5 {
                return "Auto: Exporting surplus"
            } else if data.solarKw > 1 && data.solarKw > data.displayHouseKw {
                return "Auto: Solar powering home"
            }
            
            return "Auto: Monitoring"
            
        case "curtail":
            return "Curtailed: Grid limit reached"
            
        default:
            return "Controller active"
        }
    }
    
    /// Summarize a reason string for the headline (keep it short)
    private func summarizeReason(_ reason: String) -> String {
        let lower = reason.lowercased()
        
        // Powston P-code patterns - extract the meaningful part
        
        // P83: Arbitrage gate
        if lower.contains("arbitrage gate") {
            if lower.contains("bypassed") || lower.contains("< ") {
                return "Low SOC — gate bypassed"
            }
            return "Arbitrage gate passed"
        }
        
        // P82: Physics urgent
        if lower.contains("physics urgent") || lower.contains("not physics urgent") {
            if lower.contains("not") {
                return "No urgent charge needed"
            }
            return "Physics model: urgent charge"
        }
        
        // P80/P85: Spread check, not optimal
        if lower.contains("not in best") || lower.contains("not optimal") {
            if lower.contains("sell") {
                return "Sell price not optimal"
            }
            if lower.contains("buy") || lower.contains("daytime") {
                return "Buy price not optimal"
            }
            return "Price not optimal"
        }
        
        // P60/P80/P85: Floor block
        if lower.contains("floor") && (lower.contains("block") || lower.contains("≤")) {
            return "Export blocked by floor"
        }
        
        // P99: Near-miss
        if lower.contains("near-miss") || lower.contains("near miss") {
            return "Near floor threshold"
        }
        
        // P97: Peak period
        if lower.contains("peak period") {
            return "Peak period protection"
        }
        
        // P70: Sunny day skip
        if lower.contains("sunny day") {
            return "Sunny day — waiting"
        }
        
        // P63/P64: Waiting for better price
        if lower.contains("waiting for") && lower.contains("price") {
            return "Waiting for better price"
        }
        
        // P60: Deficit block
        if lower.contains("deficit") && lower.contains("block") {
            return "Deficit block active"
        }
        
        // P60: Negative price
        if lower.contains("negative price") {
            return "Negative price handling"
        }
        
        // Battery full
        if lower.contains("battery full") || lower.contains("nearly full") {
            return "Battery nearly full"
        }
        
        // Import restriction
        if lower.contains("import restriction") {
            return "Import restricted"
        }
        
        // Spread check failed
        if lower.contains("spread check") {
            return "Spread too tight"
        }
        
        // Insufficient margin/savings
        if lower.contains("insufficient margin") || lower.contains("insufficient savings") {
            return "Insufficient margin"
        }
        
        // Generic solar shortfall
        if lower.contains("solar shortfall") {
            return "Solar shortfall"
        }
        
        // Morning dumping
        if lower.contains("morning dumping") || lower.contains("morning dump") {
            return "Morning dump — high SOC"
        }
        
        // Already short enough
        if reason.count <= 35 {
            // Strip P## prefix if present
            if let match = reason.range(of: #"^P\d+:\s*"#, options: .regularExpression) {
                return String(reason[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return reason
        }
        
        // Strip P## prefix and truncate
        var cleanReason = reason
        if let match = reason.range(of: #"^P\d+:\s*"#, options: .regularExpression) {
            cleanReason = String(reason[match.upperBound...])
        }
        
        if cleanReason.count <= 35 {
            return cleanReason
        }
        
        let index = cleanReason.index(cleanReason.startIndex, offsetBy: 32)
        return String(cleanReason[..<index]) + "..."
    }
    
    /// Extract the best info reason to explain why auto stayed auto
    private func extractBestInfoReason(_ infoEntries: [String]) -> String? {
        // Priority order for explaining "why not acting"
        for entry in infoEntries {
            let lower = entry.lowercased()
            
            // Floor/reserve protection (highest priority - safety)
            if lower.contains("floor") && (lower.contains("block") || lower.contains("≤")) {
                return "Export blocked by floor"
            }
            if lower.contains("near floor") || (lower.contains("floor") && lower.contains("holding")) {
                return "Near floor — holding reserves"
            }
            if lower.contains("below night reserve") || lower.contains("reserve level") {
                return "Preserving night reserve"
            }
            
            // Arbitrage gate
            if lower.contains("arbitrage gate") {
                if lower.contains("bypassed") || lower.contains("< ") {
                    return "SOC below survival — gate bypassed"
                }
                return "Arbitrage gate passed"
            }
            
            // Physics urgent
            if lower.contains("not physics urgent") {
                return "No urgent charge needed"
            }
            
            // Price/spread reasons
            if lower.contains("not selling") {
                if let match = entry.range(of: #"(\d+\.?\d*)c?\s*<\s*(\d+\.?\d*)c"#, options: .regularExpression) {
                    let prices = String(entry[match])
                    return "Spread too tight (\(prices))"
                }
                return "Spread too tight"
            }
            
            if lower.contains("not in best") || lower.contains("not optimal") {
                if lower.contains("sell") {
                    return "Sell price not in optimal range"
                }
                if lower.contains("buy") || lower.contains("daytime") {
                    return "Buy price not optimal"
                }
                return "Price not optimal"
            }
            
            if lower.contains("price too high") {
                return "Import price too high"
            }
            
            if lower.contains("spread check") {
                return "Spread check failed"
            }
        }
        
        // Solar/forecast reasons
        for entry in infoEntries {
            let lower = entry.lowercased()
            
            if lower.contains("solar forecast low") {
                return "Solar forecast low"
            }
            if lower.contains("good sun day") || lower.contains("sunny day") {
                return "Sunny day — waiting for optimal"
            }
            if lower.contains("waiting for") && lower.contains("price") {
                return "Waiting for better price"
            }
        }
        
        // Threshold/reserve reasons
        for entry in infoEntries {
            let lower = entry.lowercased()
            
            if lower.contains("threshold") && lower.contains("not met") {
                return "Export threshold not met"
            }
            if lower.contains("insufficient surplus") || lower.contains("insufficient margin") {
                return "Insufficient margin"
            }
            if lower.contains("projected_deficit") || lower.contains("not enough") || lower.contains("deficit block") {
                return "Not enough deficit to export"
            }
            if lower.contains("battery full") || lower.contains("nearly full") {
                return "Battery nearly full"
            }
        }
        
        // EV/other reasons
        for entry in infoEntries {
            let lower = entry.lowercased()
            
            if lower.contains("ev charging") {
                if lower.contains("limiting") {
                    return "Limiting EV charging"
                }
                return "EV charging active"
            }
            if lower.contains("import restriction") {
                return "Import restricted"
            }
        }
        
        return nil
    }
    
    var decisionReason: String {
        let reason = data.reason ?? ""
        let parsed = parseDecisionTrace(reason)
        
        // For import/export, use the matching ✅ reason as detail
        if parsed.finalAction == "import" || parsed.finalAction == "export" {
            if let matchingReason = parsed.matchingChecks.last {
                return translateReasonDetail(matchingReason)
            }
        }
        
        // For auto, provide context from ℹ️ entries or ✅ reason
        if parsed.finalAction == "auto" {
            // Check if we have meaningful ✅ reason
            if let matchingReason = parsed.matchingChecks.last {
                let isJustDefault = matchingReason.lowercased().contains("starting in auto") ||
                                    matchingReason.lowercased().contains("default")
                if !isJustDefault {
                    return translateReasonDetail(matchingReason)
                }
            }
            
            // Build explanation from ℹ️ entries
            if let infoDetail = buildAutoDetailFromInfo(parsed.infoEntries) {
                return infoDetail
            }
        }
        
        // Direct scan of raw reason for key patterns (backup)
        let reasonLower = reason.lowercased()
        if reasonLower.contains("floor") || reasonLower.contains("holding") {
            return "Battery near minimum — protecting reserves"
        }
        if reasonLower.contains("survival") || reasonLower.contains("overnight") {
            return "SOC sufficient for overnight — holding position"
        }
        if reasonLower.contains("arbitrage gate") {
            if reasonLower.contains("< ") || reasonLower.contains("bypassed") {
                return "SOC below survival threshold — gate bypassed"
            }
            return "Arbitrage gate passed — SOC sufficient"
        }
        
        return fallbackReason
    }
    
    /// Translate a Powston reason to readable detail for the "Why:" line
    private func translateReasonDetail(_ reason: String) -> String {
        let lower = reason.lowercased()
        
        // Arbitrage gate - most common
        if lower.contains("arbitrage gate") {
            if lower.contains("bypassed") || lower.contains("< ") {
                // Extract the SOC comparison
                if let match = reason.range(of: #"SOC (\d+)%\s*<\s*(\d+)%"#, options: [.regularExpression, .caseInsensitive]) {
                    return "SOC \(String(reason[match])) survival — gate bypassed"
                }
                return "SOC below survival threshold — arbitrage gate bypassed"
            }
            return "Arbitrage gate passed — SOC sufficient for overnight"
        }
        
        // Floor block
        if lower.contains("floor") && (lower.contains("block") || lower.contains("≤")) {
            if let socMatch = reason.range(of: #"SOC (\d+)%"#, options: [.regularExpression, .caseInsensitive]),
               let floorMatch = reason.range(of: #"floor (\d+)%"#, options: [.regularExpression, .caseInsensitive]) {
                let soc = String(reason[socMatch]).replacingOccurrences(of: "SOC ", with: "")
                let floor = String(reason[floorMatch]).replacingOccurrences(of: "floor ", with: "")
                return "SOC \(soc) at floor \(floor) — export blocked"
            }
            return "Export blocked by floor setting"
        }
        
        // Physics urgent
        if lower.contains("not physics urgent") {
            return "No urgent charge window — deadline not imminent"
        }
        
        // Not optimal
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
        
        // Solar shortfall
        if lower.contains("solar shortfall") {
            return "Solar shortfall detected — importing while price acceptable"
        }
        
        // Morning dumping
        if lower.contains("morning dumping") || lower.contains("morning dump") {
            return "Morning dump — high SOC + good sun + better buy prices coming"
        }
        
        // Surplus blocked
        if lower.contains("surplus") && lower.contains("block") {
            return "Surplus export blocked by floor"
        }
        
        // Negative price
        if lower.contains("negative price") {
            return "Negative price — getting paid to charge"
        }
        
        // Waiting for price
        if lower.contains("waiting for") && lower.contains("price") {
            return "Waiting for optimal price window"
        }
        
        // Sunny day skip
        if lower.contains("sunny day") {
            return "Sunny day — expecting solar, holding off"
        }
        
        // Spread check
        if lower.contains("spread check") {
            return "Spread too tight for profitable trade"
        }
        
        // Strip P## prefix for anything else and return
        var cleanReason = reason
        if let match = reason.range(of: #"^P\d+:\s*"#, options: .regularExpression) {
            cleanReason = String(reason[match.upperBound...])
        }
        
        // Truncate if too long
        if cleanReason.count > 60 {
            let index = cleanReason.index(cleanReason.startIndex, offsetBy: 57)
            return String(cleanReason[..<index]) + "..."
        }
        
        return cleanReason
    }
    
    /// Build detailed explanation for auto mode from info entries
    private func buildAutoDetailFromInfo(_ infoEntries: [String]) -> String? {
        for entry in infoEntries {
            let lower = entry.lowercased()
            
            // Floor/reserve protection
            if lower.contains("floor") && (lower.contains("block") || lower.contains("≤")) {
                // Try to extract SOC and floor values
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
            if lower.contains("below night reserve") {
                return "Below night reserve level"
            }
            
            // Arbitrage gate
            if lower.contains("arbitrage gate") {
                if lower.contains("bypassed") || lower.contains("< ") {
                    // Extract the SOC comparison
                    if let match = entry.range(of: #"SOC (\d+)%\s*<\s*(\d+)%"#, options: [.regularExpression, .caseInsensitive]) {
                        return "SOC \(String(entry[match])) survival — gate bypassed"
                    }
                    return "SOC below survival threshold — arbitrage gate bypassed"
                }
                return "Arbitrage gate passed — SOC sufficient"
            }
            
            // Physics urgent
            if lower.contains("not physics urgent") {
                return "No urgent charge window — deadline not imminent"
            }
            
            // Not optimal patterns
            if lower.contains("not in best") || lower.contains("not optimal") {
                if lower.contains("sell") {
                    // Extract sell price
                    if let match = entry.range(of: #"Sell (\d+\.?\d*)c"#, options: [.regularExpression, .caseInsensitive]) {
                        return "\(String(entry[match])) not in optimal sell range"
                    }
                    return "Sell price not in optimal range"
                }
                if lower.contains("buy") || lower.contains("daytime") {
                    if let match = entry.range(of: #"(\d+\.?\d*)c not optimal"#, options: [.regularExpression, .caseInsensitive]) {
                        return "Buy \(String(entry[match]))"
                    }
                    return "Buy price not in optimal range"
                }
            }
            
            // Spread/price reasons
            if lower.contains("not selling") {
                if let match = entry.range(of: #"(\d+\.?\d*)c?\s*<\s*(\d+\.?\d*)c"#, options: .regularExpression) {
                    return "Sell price \(String(entry[match])) threshold"
                }
            }
            
            if lower.contains("spread check") {
                return "Spread check failed — not profitable"
            }
            
            // Waiting for optimal
            if lower.contains("waiting for optimal price") || lower.contains("waiting for better price") {
                return "Waiting for optimal price window"
            }
            
            if lower.contains("solar forecast low") {
                return "Solar forecast low — holding position"
            }
            if lower.contains("insufficient surplus") || lower.contains("insufficient margin") {
                return "Insufficient margin for trading"
            }
            if lower.contains("sunny day") || lower.contains("good sun day") {
                return "Sunny day expected — waiting for optimal window"
            }
        }
        
        return nil
    }
    
    private var fallbackReason: String {
        let action = data.currentAction.lowercased()
        let buy = data.buyPrice ?? 0
        let sell = data.sellPrice ?? 0
        
        switch action {
        case "charge", "import":
            if buy < 0 {
                return "Negative prices — earning while charging"
            } else if buy < 5 {
                return "Low import rates"
            }
            return "Building reserves"
            
        case "discharge", "export":
            if sell > 30 {
                return "High export rates"
            }
            return "Favorable spread"
            
        case "auto":
            // Check solar first (only if actually producing)
            if data.solarKw > 1 && data.solarKw > data.displayHouseKw {
                return "Solar covering load"
            }
            // Only mention spread if it's positive but tight (not negative/weird)
            let spread = sell - buy
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
    
    func formatIntervalTime(_ str: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: str) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            timeFormatter.timeZone = powstonTimezone()
            return timeFormatter.string(from: date)
        }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: str) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            timeFormatter.timeZone = powstonTimezone()
            return timeFormatter.string(from: date)
        }
        
        return str
    }
}

// MARK: - SOC Bar View
struct SnapshotSOCBar: View {
    let soc: Double
    
    var socColor: Color {
        if soc >= 80 { return .green }
        if soc >= 40 { return .yellow }
        if soc >= 20 { return .orange }
        return .red
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("State of Charge")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Text(String(format: "%.0f%%", soc))
                    .font(.title2)
                    .fontWeight(.bold)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(socColor)
                        .frame(width: geo.size.width * min(soc / 100, 1), height: 8)
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Energy Flow Diagram (Inverter-Centric Cross Layout)
struct SnapshotEnergyFlow: View {
    let solarKw: Double
    let homeKw: Double
    let gridKw: Double
    let batteryKw: Double
    let batterySoc: Double
    let currentAction: String
    let lastAction: String?  // Action from flows (5 min ago)
    let isGridExporting: Bool
    let isCharging: Bool
    var flowPhase: CGFloat = 0
    
    var body: some View {
        GeometryReader { geo in
            let centerX = geo.size.width / 2
            let centerY = geo.size.height / 2
            
            // Node positions - cross layout with inverter at center
            // Grid/Home pushed to edges for better use of space
            let solarPos = CGPoint(x: centerX, y: 70)
            let inverterPos = CGPoint(x: centerX, y: centerY)
            let gridPos = CGPoint(x: 40, y: centerY)  // Closer to left edge
            let homePos = CGPoint(x: geo.size.width - 40, y: centerY)  // Closer to right edge
            let batteryPos = CGPoint(x: centerX, y: geo.size.height - 70)
            
            ZStack {
                // Flow lines (drawn first, behind nodes)
                
                // Solar → Inverter
                SnapshotFlowLine(
                    from: CGPoint(x: solarPos.x, y: solarPos.y + 45),
                    to: CGPoint(x: inverterPos.x, y: inverterPos.y - 45),
                    isActive: solarKw > 0.01,
                    flowPhase: flowPhase,
                    color: .yellow
                )
                
                // Grid ↔ Inverter
                if isGridExporting {
                    SnapshotFlowLine(
                        from: CGPoint(x: inverterPos.x - 40, y: inverterPos.y),
                        to: CGPoint(x: gridPos.x + 30, y: gridPos.y),
                        isActive: abs(gridKw) > 0.01,
                        flowPhase: flowPhase,
                        color: .green
                    )
                } else {
                    SnapshotFlowLine(
                        from: CGPoint(x: gridPos.x + 30, y: gridPos.y),
                        to: CGPoint(x: inverterPos.x - 40, y: inverterPos.y),
                        isActive: abs(gridKw) > 0.01,
                        flowPhase: flowPhase,
                        color: .blue
                    )
                }
                
                // Inverter → Home
                SnapshotFlowLine(
                    from: CGPoint(x: inverterPos.x + 40, y: inverterPos.y),
                    to: CGPoint(x: homePos.x - 30, y: homePos.y),
                    isActive: homeKw > 0.01,
                    flowPhase: flowPhase,
                    color: .purple
                )
                
                // Battery ↔ Inverter
                if isCharging {
                    SnapshotFlowLine(
                        from: CGPoint(x: inverterPos.x, y: inverterPos.y + 50),
                        to: CGPoint(x: batteryPos.x, y: batteryPos.y - 40),
                        isActive: abs(batteryKw) > 0.01,
                        flowPhase: flowPhase,
                        color: .cyan
                    )
                } else {
                    SnapshotFlowLine(
                        from: CGPoint(x: batteryPos.x, y: batteryPos.y - 40),
                        to: CGPoint(x: inverterPos.x, y: inverterPos.y + 50),
                        isActive: abs(batteryKw) > 0.01,
                        flowPhase: flowPhase,
                        color: .orange
                    )
                }
                
                // Nodes
                
                // Solar Node (top)
                SnapshotEnergyNode(
                    icon: "sun.max.fill",
                    label: "SOLAR",
                    value: formatPower(solarKw),
                    color: .yellow,
                    isHighlighted: solarKw > 0.01
                )
                .position(solarPos)
                
                // Grid Node (left)
                SnapshotEnergyNode(
                    icon: "bolt.fill",
                    label: "GRID",
                    value: formatPower(abs(gridKw)),
                    color: isGridExporting ? .green : .blue,
                    isHighlighted: abs(gridKw) > 0.01
                )
                .position(gridPos)
                
                // Inverter Node (center)
                SnapshotInverterNode(action: currentAction, lastAction: lastAction)
                    .position(inverterPos)
                
                // Home Node (right)
                SnapshotEnergyNode(
                    icon: "house.fill",
                    label: "HOME",
                    value: formatPower(homeKw),
                    color: .purple,
                    isHighlighted: homeKw > 0.01
                )
                .position(homePos)
                
                // Battery Node (bottom)
                SnapshotBatteryNode(
                    soc: batterySoc,
                    power: batteryKw,
                    isCharging: isCharging
                )
                .position(batteryPos)
            }
        }
        .frame(height: 400)
    }
    
    func formatPower(_ kw: Double) -> String {
        if abs(kw) < 1 {
            return String(format: "%.0f W", abs(kw) * 1000)
        }
        return String(format: "%.1f kW", abs(kw))
    }
}

// MARK: - Inverter Node (Center Hub)
struct SnapshotInverterNode: View {
    let action: String
    let lastAction: String?  // Action from flows (5 min ago)
    
    var displayAction: String {
        // Check for transition between flow and realtime action
        if let last = lastAction?.lowercased(),
           normalizeAction(action) != normalizeAction(last) {
            return "\(shortName(last))→\(shortName(action))"
        }
        return action.uppercased()
    }
    
    private func normalizeAction(_ act: String) -> String {
        switch act.lowercased() {
        case "charge", "import": return "import"
        case "discharge", "export": return "export"
        default: return act.lowercased()
        }
    }
    
    private func shortName(_ act: String) -> String {
        switch act.lowercased() {
        case "charge", "import": return "IMPORT"
        case "discharge", "export": return "EXPORT"
        case "auto": return "AUTO"
        default: return act.uppercased()
        }
    }
    
    var actionColor: Color {
        switch action.lowercased() {
        case "import", "charge": return .cyan
        case "export", "discharge": return .orange
        case "curtail": return .red
        case "auto": return .yellow
        default: return .gray
        }
    }
    
    var body: some View {
        VStack(spacing: 6) {
            // Action label with glow
            ZStack {
                // Glow behind pill
                Text(displayAction)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(actionColor.opacity(0.5))
                    .cornerRadius(4)
                    .blur(radius: 6)
                
                Text(displayAction)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(actionColor)
            }
            
            // Stacked rectangles suggesting dual inverters
            ZStack {
                // Glow behind when active
                RoundedRectangle(cornerRadius: 10)
                    .fill(actionColor.opacity(0.2))
                    .frame(width: 68, height: 68)
                    .blur(radius: 8)
                
                // Back rectangle (offset)
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 60, height: 60)
                    .offset(x: 4, y: 4)
                
                // Front rectangle
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 60, height: 60)
                    
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(actionColor.opacity(0.6), lineWidth: 2)
                        .frame(width: 60, height: 60)
                    
                    // Inverter symbol
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title2)
                        .foregroundColor(actionColor)
                }
            }
        }
    }
}

// MARK: - Battery Node (Bottom)
struct SnapshotBatteryNode: View {
    let soc: Double
    let power: Double
    let isCharging: Bool
    
    var activeColor: Color {
        isCharging ? .cyan : .orange
    }
    
    var body: some View {
        VStack(spacing: 4) {
            // Battery icon with SOC visualization
            ZStack {
                // Glow when active
                if abs(power) > 0.01 {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(activeColor.opacity(0.3))
                        .frame(width: 68, height: 68)
                        .blur(radius: 8)
                }
                
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 64, height: 64)
                
                // Battery shape
                VStack(spacing: 2) {
                    // Battery tip
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 12, height: 4)
                    
                    // Battery body
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.4), lineWidth: 2)
                            .frame(width: 28, height: 36)
                        
                        RoundedRectangle(cornerRadius: 2)
                            .fill(socColor)
                            .frame(width: 24, height: max(2, 32 * soc / 100))
                            .padding(.bottom, 2)
                    }
                }
            }
            
            // Power value
            Text(formatPower(power))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(isCharging ? .cyan : .orange)
            
            // SOC percentage
            Text(String(format: "%.0f%%", soc))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    var socColor: Color {
        if soc >= 80 { return .green }
        if soc >= 40 { return .yellow }
        if soc >= 20 { return .orange }
        return .red
    }
    
    func formatPower(_ kw: Double) -> String {
        if abs(kw) < 1 {
            return String(format: "%.0f W", abs(kw) * 1000)
        }
        return String(format: "%.1f kW", abs(kw))
    }
}

// MARK: - Flow Line with Animated Dots
struct SnapshotFlowLine: View {
    let from: CGPoint
    let to: CGPoint
    let isActive: Bool
    var flowPhase: CGFloat = 0
    var color: Color = .blue
    
    var body: some View {
        ZStack {
            // Base line
            Path { path in
                path.move(to: from)
                path.addLine(to: to)
            }
            .stroke(Color.gray.opacity(0.2), lineWidth: 2)
            
            // Active line with subtle glow
            if isActive {
                Path { path in
                    path.move(to: from)
                    path.addLine(to: to)
                }
                .stroke(color.opacity(0.3), lineWidth: 4)
                .blur(radius: 2)
                
                // Animated dots
                SnapshotFlowDots(from: from, to: to, phase: flowPhase, color: color)
            }
        }
    }
}

// MARK: - Flow Dots Animation with Glow
struct SnapshotFlowDots: View {
    let from: CGPoint
    let to: CGPoint
    let phase: CGFloat
    var color: Color = .blue
    
    var body: some View {
        let dotCount = 3
        
        ForEach(0..<dotCount, id: \.self) { i in
            let progress = (phase + CGFloat(i) / CGFloat(dotCount)).truncatingRemainder(dividingBy: 1)
            let x = from.x + (to.x - from.x) * progress
            let y = from.y + (to.y - from.y) * progress
            
            ZStack {
                // Outer glow
                Circle()
                    .fill(color.opacity(0.4))
                    .frame(width: 16, height: 16)
                    .blur(radius: 4)
                
                // Core dot with white center gradient
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white, color],
                            center: .center,
                            startRadius: 0,
                            endRadius: 4
                        )
                    )
                    .frame(width: 8, height: 8)
            }
            .position(x: x, y: y)
            .opacity(progress > 0.1 && progress < 0.9 ? 1 : 0)
        }
    }
}

// MARK: - Energy Node with Glow
struct SnapshotEnergyNode: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    var isHighlighted: Bool = false
    var subtitle: String? = nil
    
    var body: some View {
        VStack(spacing: 4) {
            iconView
            
            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(isHighlighted ? color : .secondary)
            
            // Always reserve space for subtitle to keep heights consistent
            Text(subtitle ?? " ")
                .font(.caption2)
                .foregroundColor(.secondary)
                .opacity(subtitle != nil ? 1 : 0)
        }
    }
    
    var iconView: some View {
        ZStack {
            // Glow behind when active
            if isHighlighted {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.3))
                    .frame(width: 60, height: 60)
                    .blur(radius: 8)
            }
            
            RoundedRectangle(cornerRadius: 12)
                .fill(isHighlighted ? color.opacity(0.15) : Color.gray.opacity(0.1))
                .frame(width: 56, height: 56)
            
            if isHighlighted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color, lineWidth: 2)
                    .frame(width: 56, height: 56)
            }
            
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(isHighlighted ? color : .gray)
        }
    }
}

// MARK: - Decision Explanation
struct SnapshotDecisionExplanation: View {
    let headline: String
    let reason: String
    let fullReason: String?
    var isAIEnhanced: Bool = false
    
    @State private var showingTrace = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.title3)
                .fontWeight(.semibold)
            
            Text(reason)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack {
                if fullReason != nil {
                    Button(action: { showingTrace.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: showingTrace ? "chevron.down" : "chevron.right")
                                .font(.caption)
                            Text("Show decision trace")
                                .font(.subheadline)
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                if isAIEnhanced {
                    AppleIntelligenceIndicator()
                }
            }
            
            if showingTrace, let trace = fullReason {
                Text(trace.formattedDecisionTrace)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            }
        }
    }
    
}

// MARK: - AI-Powered Decision Explanation
// MARK: - Preview
#Preview {
    ScrollView {
        DecisionSnapshotDashboard(
            data: InverterResponse(
                batterySocRaw: 85,
                batteryPower: -5000,
                action: "auto",
                solarPower: 21600,
                gridPower: -1200,
                housePower: 9400,
                buyPrice: 3.83,
                sellPrice: 1.21,
                reason: "P82: Physics urgent charge→import"
            )
        )
    }
    .background(Color.gray.opacity(0.1))
}
