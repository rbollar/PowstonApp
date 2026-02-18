//
//  ActionItemsEngine.swift
//  Powston
//
//  Central service for aggregating recommendations from multiple analysis sources
//  (Scorecard, Peak Analysis, Bargain Hunter, Peer Power, Decision Efficiency)
//  and applying diminishing returns and conflict resolution based on user goals.
//

import Foundation
import SwiftUI
import Combine

@MainActor
class ActionItemsEngine: ObservableObject {

    static let shared = ActionItemsEngine()

    // MARK: - Published State

    @Published var isLoading = false
    @Published var loadingProgress: String = ""
    @Published var result: ActionItemsResult?
    @Published var error: String?

    // MARK: - Dependencies

    private let scorecardCache = ScorecardCache.shared
    private let bargainHunterAnalysis = BargainHunterAnalysis()
    private let decisionEfficiencyAnalysis = DecisionEfficiencyAnalysis()
    private let peerPowerAnalysis = PeerPowerAnalysis()

    // MARK: - Cache

    private var cachedResult: [String: ActionItemsResult] = [:]  // "siteId_goal" -> result
    private let cacheValiditySeconds: TimeInterval = 300  // 5 minutes

    // MARK: - Public Interface

    /// Refresh action items from all sources
    func refreshActionItems(
        siteId: Int,
        goal: UserGoal,
        api: PowstonAPI,
        forceRefresh: Bool = false
    ) async {
        let cacheKey = "\(siteId)_\(goal.rawValue)"

        // Return cached if fresh
        if !forceRefresh,
           let cached = cachedResult[cacheKey],
           Date().timeIntervalSince(cached.generatedAt) < cacheValiditySeconds {
            result = cached
            return
        }

        isLoading = true
        error = nil
        loadingProgress = "Gathering recommendations..."

        var allItems: [ActionItem] = []

        // Get site for config
        guard let site = api.sites.first(where: { $0.id == siteId }) else {
            error = "Site not found"
            isLoading = false
            return
        }

        let config = AnalysisConfig.from(site: site)

        // 1. Collect from Scorecard
        loadingProgress = "Analyzing performance..."
        if let scorecardItems = await collectFromScorecard(siteId: siteId, api: api) {
            allItems.append(contentsOf: scorecardItems)
        }

        // 2. Collect from Bargain Hunter
        loadingProgress = "Analyzing import timing..."
        if let bargainItems = await collectFromBargainHunter(config: config, api: api) {
            allItems.append(contentsOf: bargainItems)
        }

        // 3. Collect from Decision Efficiency
        loadingProgress = "Analyzing decision quality..."
        if let efficiencyItems = await collectFromDecisionEfficiency(config: config, api: api) {
            allItems.append(contentsOf: efficiencyItems)
        }

        // 4. Collect from Peer Power (P2P)
        loadingProgress = "Analyzing P2P opportunities..."
        if let p2pItems = await collectFromPeerPower(config: config, api: api) {
            allItems.append(contentsOf: p2pItems)
        }

        // 5. Resolve conflicts based on goal
        loadingProgress = "Resolving conflicts..."
        let (resolvedItems, conflictsFiltered) = resolveConflicts(allItems, goal: goal)

        // 6. Calculate combined impact with diminishing returns
        let rawTotal = allItems.reduce(0) { $0 + $1.potentialImpact }
        let combinedImpact = calculateCombinedImpact(resolvedItems)

        // 7. Sort by goal alignment and priority
        let sortedItems = prioritizeForGoal(resolvedItems, goal: goal)

        // Build result
        let actionResult = ActionItemsResult(
            items: sortedItems,
            combinedImpact: combinedImpact,
            rawTotalImpact: rawTotal,
            goal: goal,
            generatedAt: Date(),
            conflictsResolved: conflictsFiltered
        )

        cachedResult[cacheKey] = actionResult
        result = actionResult
        isLoading = false
        loadingProgress = ""
    }

    /// Clear all cached results
    func clearCache() {
        cachedResult.removeAll()
        result = nil
    }

    // MARK: - Source Collection

    private func collectFromScorecard(siteId: Int, api: PowstonAPI) async -> [ActionItem]? {
        // Get week scorecard for recommendations
        guard let scorecard = await scorecardCache.getScorecard(
            siteId: siteId,
            period: .week,
            api: api
        ) else {
            return nil
        }

        return scorecard.recommendations.map { rec in
            ActionItem(
                source: .scorecard,
                category: mapScorecardCategory(rec.category),
                title: rec.category,
                description: rec.action,
                potentialImpact: rec.potentialSavings,
                confidence: 0.7,
                priority: mapScorecardPriority(rec.priority),
                conflictsWith: conflictsForScorecardCategory(rec.category)
            )
        }
    }

    private func collectFromBargainHunter(config: AnalysisConfig, api: PowstonAPI) async -> [ActionItem]? {
        // Check cache first
        if let cached = bargainHunterAnalysis.getCachedResult(config: config) {
            return convertBargainHunterToItems(cached)
        }

        // Run analysis
        await api.refreshLatestCompleteDataDate()
        guard let result = await bargainHunterAnalysis.analyzeImports(
            config: config,
            latestCompleteDataDate: api.latestCompleteDataDate
        ) else {
            return nil
        }

        return convertBargainHunterToItems(result)
    }

    private func convertBargainHunterToItems(_ result: BargainHunterResult) -> [ActionItem] {
        var items: [ActionItem] = []

        let deadlineCount = result.breakdown.deadlinePressure.count
        let waitableCount = result.breakdown.bestNFailures.count

        // Only flag imports that genuinely could have waited (not deadline fills)
        if waitableCount > 0 && result.potentialSavingsDollars > 1 {
            let avgOverpaid = result.breakdown.bestNFailures.overpaidCents / Double(max(1, waitableCount))
            let contextNote = deadlineCount > 0
                ? " (\(deadlineCount) other imports were necessary deadline fills)"
                : ""
            items.append(ActionItem(
                source: .bargainHunter,
                category: .importTiming,
                title: "Improve import timing",
                description: "\(waitableCount) imports could have waited for cheaper prices (avg overpaid \(String(format: "%.1f", avgOverpaid))¢/kWh).\(contextNote)",
                potentialImpact: result.potentialSavingsDollars * 4,  // Scale weekly to monthly
                confidence: 0.8,
                priority: result.potentialSavingsDollars > 5 ? .high : .medium,
                conflictsWith: [.batteryReserve]
            ))
        }

        // Deadline pressure — only flag if it's a very large proportion
        if deadlineCount > result.totalImports / 2 {
            items.append(ActionItem(
                source: .bargainHunter,
                category: .batteryReserve,
                title: "Start charging earlier",
                description: "\(deadlineCount) of \(result.totalImports) imports (\(deadlineCount * 100 / max(1, result.totalImports))%) were urgent deadline fills. The system may benefit from starting charge earlier or raising the overnight floor.",
                potentialImpact: result.breakdown.deadlinePressure.totalCostCents / 100 * 0.15,  // Conservative ~15% savings
                confidence: 0.5,
                priority: .low,
                conflictsWith: []
            ))
        }

        return items
    }

    private func collectFromDecisionEfficiency(config: AnalysisConfig, api: PowstonAPI) async -> [ActionItem]? {
        // Check cache first
        if let cached = decisionEfficiencyAnalysis.result,
           Date().timeIntervalSince(cached.analyzedAt) < cacheValiditySeconds {
            return convertDecisionEfficiencyToItems(cached)
        }

        // Run analysis
        await api.refreshLatestCompleteDataDate()
        guard let result = await decisionEfficiencyAnalysis.analyzeDecisionEfficiency(
            config: config,
            latestCompleteDataDate: api.latestCompleteDataDate
        ) else {
            return nil
        }

        return convertDecisionEfficiencyToItems(result)
    }

    private func convertDecisionEfficiencyToItems(_ result: DecisionEfficiencyResult) -> [ActionItem] {
        var items: [ActionItem] = []

        // Low export capture
        if let exportCapture = result.exportAnalysis.priceCapture, exportCapture < 80 {
            let missedRevenue = (100 - exportCapture) / 100 * result.exportAnalysis.totalEarnings / 100
            items.append(ActionItem(
                source: .decisionEfficiency,
                category: .exportTiming,
                title: "Improve export timing",
                description: "Export price capture at \(String(format: "%.0f", exportCapture))% - missing high-price windows. Review export floor settings.",
                potentialImpact: missedRevenue * 4,  // Monthly estimate
                confidence: 0.75,
                priority: exportCapture < 60 ? .high : .medium,
                conflictsWith: [.exportFloor]
            ))
        }

        // Low import efficiency
        if let importEfficiency = result.importAnalysis.priceEfficiency, importEfficiency < 80 {
            let potentialSavings = (100 - importEfficiency) / 100 * result.importAnalysis.totalCosts / 100
            items.append(ActionItem(
                source: .decisionEfficiency,
                category: .importTiming,
                title: "Improve import efficiency",
                description: "Import efficiency at \(String(format: "%.0f", importEfficiency))% - missing cheap import windows.",
                potentialImpact: potentialSavings * 4,  // Monthly estimate
                confidence: 0.7,
                priority: importEfficiency < 60 ? .high : .medium,
                conflictsWith: []
            ))
        }

        // Missed high exports
        if result.missedOpportunities.missedHighExports > 5 {
            items.append(ActionItem(
                source: .decisionEfficiency,
                category: .priceResponse,
                title: "Capture high export prices",
                description: "Missed \(result.missedOpportunities.missedHighExports) high-price export opportunities worth $\(String(format: "%.2f", result.missedOpportunities.missedHighExportValue))",
                potentialImpact: result.missedOpportunities.missedHighExportValue * 4,
                confidence: 0.8,
                priority: result.missedOpportunities.missedHighExportValue > 10 ? .high : .medium,
                conflictsWith: []
            ))
        }

        return items
    }

    private func collectFromPeerPower(config: AnalysisConfig, api: PowstonAPI) async -> [ActionItem]? {
        // Check cache first
        if let cached = peerPowerAnalysis.result,
           Date().timeIntervalSince(cached.analysisDate) < cacheValiditySeconds {
            return convertPeerPowerToItems(cached, batteryCapacityKwh: config.batteryCapacityKWh)
        }

        // Run analysis
        await peerPowerAnalysis.runAnalysis(api: api, config: config)

        // Check if analysis produced results
        guard let result = peerPowerAnalysis.result else {
            return nil
        }

        return convertPeerPowerToItems(result, batteryCapacityKwh: config.batteryCapacityKWh)
    }

    private func convertPeerPowerToItems(_ result: PeerPowerResult, batteryCapacityKwh: Double) -> [ActionItem] {
        // Consolidate P2P into a single item — price + window together
        guard result.maxOpportunityDollars > 5 else { return [] }

        let rec = result.recommendation
        let windowStr: String
        if rec.dailyKwh > 5 {
            let startHr = rec.startHour > 12 ? rec.startHour - 12 : rec.startHour
            let startAP = rec.startHour >= 12 ? "PM" : "AM"
            let endHr = rec.endHour > 12 ? rec.endHour - 12 : rec.endHour
            let endAP = rec.endHour >= 12 ? "PM" : "AM"
            windowStr = " (\(startHr)\(startAP)-\(endHr)\(endAP), ~\(String(format: "%.0f", rec.dailyKwh)) kWh/day)"
        } else {
            windowStr = ""
        }

        // System size gating: adjust priority and description based on battery capacity
        let priority: ActionPriority
        let sizeNote: String
        if batteryCapacityKwh >= 40 {
            priority = .medium
            sizeNote = ""
        } else if batteryCapacityKwh >= 15 {
            priority = .low
            sizeNote = " Note: With \(Int(batteryCapacityKwh)) kWh battery, P2P returns will be moderate."
        } else {
            priority = .low
            sizeNote = " Note: With \(Int(batteryCapacityKwh)) kWh battery, P2P returns may only be modest. Factor in battery cycling costs."
        }

        return [ActionItem(
            source: .peerPower,
            category: .p2pPricing,
            title: "P2P at \(String(format: "%.0f", result.recommendedPrice))¢\(windowStr)",
            description: "Sell directly to buyers at a price that beats spot for you and grid for them. Win-win rate: \(String(format: "%.0f", result.winWinPercent))%. Extra revenue above spot: ~$\(String(format: "%.0f", result.maxOpportunityDollars))/mo.\(sizeNote)",
            potentialImpact: result.maxOpportunityDollars,
            confidence: result.winWinPercent / 100,
            priority: priority,
            conflictsWith: []
        )]
    }

    // MARK: - Conflict Resolution

    private func resolveConflicts(_ items: [ActionItem], goal: UserGoal) -> ([ActionItem], Int) {
        var resolved: [ActionItem] = []
        var excludedCategories: Set<ActionCategory> = []
        var conflictsFiltered = 0

        // Sort by goal alignment, then by impact
        let sorted = items.sorted { item1, item2 in
            let align1 = item1.alignment(for: goal)
            let align2 = item2.alignment(for: goal)
            if abs(align1 - align2) > 0.1 {
                return align1 > align2
            }
            return item1.potentialImpact > item2.potentialImpact
        }

        for item in sorted {
            // Check if this item conflicts with already-included categories
            let conflictsWithIncluded = !item.conflictsWith.isEmpty &&
                !excludedCategories.isDisjoint(with: Set(item.conflictsWith))

            // Also check if any included item conflicts with this one's category
            let includedConflictsWithThis = resolved.contains { $0.conflictsWith.contains(item.category) }

            if conflictsWithIncluded || includedConflictsWithThis {
                conflictsFiltered += 1
                continue
            }

            resolved.append(item)
            excludedCategories.insert(item.category)
        }

        return (resolved, conflictsFiltered)
    }

    // MARK: - Realistic Impact Calculation
    //
    // Key insight: Recommendations within the same "strategy bucket" address the same
    // underlying opportunity. If you optimize all your exports perfectly, you get ONE
    // benefit - not the sum of "improve timing" + "raise floor" + "capture peaks".
    //
    // Strategy buckets:
    // - EXPORTS: exportFloor, exportTiming, priceResponse (export-related)
    // - IMPORTS: importTiming, batteryReserve
    // - P2P: p2pPricing, p2pWindow (additive but higher risk)
    //

    /// Calculate realistic combined impact - best strategy per bucket, not sum of all
    func calculateCombinedImpact(_ items: [ActionItem]) -> Double {
        // Group into strategy buckets
        let exportCategories: Set<ActionCategory> = [.exportFloor, .exportTiming, .priceResponse]
        let importCategories: Set<ActionCategory> = [.importTiming, .batteryReserve]
        let p2pCategories: Set<ActionCategory> = [.p2pPricing, .p2pWindow]

        let exportItems = items.filter { exportCategories.contains($0.category) }
        let importItems = items.filter { importCategories.contains($0.category) }
        let p2pItems = items.filter { p2pCategories.contains($0.category) }

        // Best strategy per bucket (not sum - they address same opportunity)
        let bestExport = exportItems.map { $0.potentialImpact }.max() ?? 0
        let bestImport = importItems.map { $0.potentialImpact }.max() ?? 0
        let bestP2P = p2pItems.map { $0.potentialImpact }.max() ?? 0

        // Import is independent of export/P2P
        // P2P partially or fully replaces export opportunity — same energy, different channel
        // Take the max of (export, P2P) rather than summing, since they address the same kWh
        let bestExportOrP2P = max(bestExport, bestP2P)
        return bestExportOrP2P + bestImport
    }

    /// Detailed breakdown for display
    func calculateImpactBreakdown(_ items: [ActionItem]) -> ImpactBreakdown {
        let exportCategories: Set<ActionCategory> = [.exportFloor, .exportTiming, .priceResponse]
        let importCategories: Set<ActionCategory> = [.importTiming, .batteryReserve]
        let p2pCategories: Set<ActionCategory> = [.p2pPricing, .p2pWindow]

        let exportItems = items.filter { exportCategories.contains($0.category) }
        let importItems = items.filter { importCategories.contains($0.category) }
        let p2pItems = items.filter { p2pCategories.contains($0.category) }

        let bestExport = exportItems.max(by: { $0.potentialImpact < $1.potentialImpact })
        let bestP2P = p2pItems.max(by: { $0.potentialImpact < $1.potentialImpact })

        // P2P replaces export opportunity (same energy, different channel).
        // Show whichever is higher as the export/revenue strategy.
        let p2pReplacesExport = (bestP2P?.potentialImpact ?? 0) > (bestExport?.potentialImpact ?? 0)

        return ImpactBreakdown(
            bestExportStrategy: p2pReplacesExport ? nil : bestExport,
            bestImportStrategy: importItems.max(by: { $0.potentialImpact < $1.potentialImpact }),
            p2pOpportunity: bestP2P,
            exportAlternatives: p2pReplacesExport ? exportItems.count : max(0, exportItems.count - 1),
            importAlternatives: max(0, importItems.count - 1)
        )
    }

    // MARK: - Prioritization

    private func prioritizeForGoal(_ items: [ActionItem], goal: UserGoal) -> [ActionItem] {
        items.sorted { item1, item2 in
            // First by priority
            if item1.priority != item2.priority {
                return item1.priority < item2.priority
            }

            // Then by goal alignment
            let align1 = item1.alignment(for: goal)
            let align2 = item2.alignment(for: goal)
            if abs(align1 - align2) > 0.1 {
                return align1 > align2
            }

            // Finally by impact
            return item1.potentialImpact > item2.potentialImpact
        }
    }

    // MARK: - Category Mapping Helpers

    private func mapScorecardCategory(_ category: String) -> ActionCategory {
        switch category {
        case "Overnight Strategy", "Morning Buffer":
            return .batteryReserve
        case "Peak Avoidance":
            return .importTiming
        case "Opportunity Capture":
            return .priceResponse
        case "Arbitrage Spread":
            return .exportTiming
        default:
            return .priceResponse
        }
    }

    private func mapScorecardPriority(_ priority: Int) -> ActionPriority {
        switch priority {
        case 1: return .high
        case 2: return .medium
        default: return .low
        }
    }

    private func conflictsForScorecardCategory(_ category: String) -> [ActionCategory] {
        switch category {
        case "Overnight Strategy", "Morning Buffer":
            return []  // Reserve strategies don't conflict
        case "Peak Avoidance":
            return [.importTiming]  // May overlap with bargain hunter timing
        case "Arbitrage Spread":
            return [.exportFloor]  // Spread adjustment affects floor
        default:
            return []
        }
    }
}
