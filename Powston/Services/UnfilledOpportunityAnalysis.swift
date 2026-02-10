//
//  UnfilledOpportunityAnalysis.swift
//  Powston
//
//  Analyzes unfilled P2P sell orders vs spot price and market clearing rates.
//  Surfaces opportunities to reprice unfilled capacity before it exports at spot.
//
//  Key insight: LocalVolts functions like a sealed-bid auction because the market
//  clearing data is hidden behind an undocumented WebSocket API. Users with visibility
//  into clearing prices can identify when their standing offers are too high and
//  reprice to capture value that would otherwise be lost to spot export.
//

import Foundation
import Combine

// MARK: - Unfilled Opportunity

struct UnfilledOpportunity: Identifiable {
    let id = UUID()
    let orderId: String
    let periodStart: Date
    let periodEnd: Date
    let unfilledKwh: Double
    let yourOfferCents: Double
    let spotPriceCents: Double
    let marketClearingCents: Double?  // P50 of similar period contracts
    let hoursUntilDelivery: Double

    /// Potential value capture if repriced to market clearing
    var potentialGainCents: Double {
        guard let clearing = marketClearingCents else {
            return (yourOfferCents - spotPriceCents) * unfilledKwh  // vs exporting at spot
        }
        return (clearing - spotPriceCents) * unfilledKwh
    }

    /// Suggested reprice point (halfway between spot and market clearing, or market clearing)
    var suggestedPriceCents: Double? {
        guard let clearing = marketClearingCents, clearing > spotPriceCents else { return nil }
        // Suggest slightly below market clearing to ensure match
        return clearing * 0.95
    }

    /// Urgency level based on time until delivery
    var urgency: Urgency {
        if hoursUntilDelivery < 1 { return .critical }
        if hoursUntilDelivery < 4 { return .high }
        if hoursUntilDelivery < 12 { return .medium }
        return .low
    }

    enum Urgency: String {
        case critical = "Now"
        case high = "Soon"
        case medium = "Today"
        case low = "Later"

        var color: String {
            switch self {
            case .critical: return "red"
            case .high: return "orange"
            case .medium: return "yellow"
            case .low: return "green"
            }
        }
    }
}

// MARK: - Opportunity Alert (for display)

struct OpportunityAlert: Identifiable {
    let id = UUID()
    let totalUnfilledKwh: Double
    let periodDescription: String  // e.g., "14:00–18:00 today"
    let spotPriceCents: Double
    let marketClearingCents: Double?
    let yourAvgOfferCents: Double
    let potentialLossCents: Double  // Value lost if exported at spot instead of market clearing
    let opportunities: [UnfilledOpportunity]

    var headline: String {
        let kwh = String(format: "%.1f", totalUnfilledKwh)
        return "\(kwh) kWh unfilled for \(periodDescription)"
    }

    var recommendation: String {
        guard let clearing = marketClearingCents else {
            return "Spot is \(formatPrice(spotPriceCents)), your offer is \(formatPrice(yourAvgOfferCents))"
        }
        return "Spot: \(formatPrice(spotPriceCents)), Market clearing: \(formatPrice(clearing)), Your offer: \(formatPrice(yourAvgOfferCents))"
    }

    private func formatPrice(_ cents: Double) -> String {
        String(format: "%.1f¢", cents)
    }
}

// MARK: - Analysis Service

@MainActor
class UnfilledOpportunityAnalysis: ObservableObject {

    static let shared = UnfilledOpportunityAnalysis()

    @Published var currentAlert: OpportunityAlert?
    @Published var opportunities: [UnfilledOpportunity] = []
    @Published var lastAnalysis: Date?

    private init() {}

    /// Analyze unfilled orders against market conditions
    /// - Parameters:
    ///   - orders: Your active sell orders (from TradeList)
    ///   - fills: Fill status per order (from TradeDetail)
    ///   - marketContracts: Today's market contracts (from ContractTable)
    ///   - spotPriceCents: Current AEMO spot price in cents
    func analyze(
        orders: [LVOrder],
        fills: [String: Double],  // orderId -> filledKwh
        marketContracts: [LVMarketContract],
        spotPriceCents: Double
    ) {
        let now = Date()
        var opps: [UnfilledOpportunity] = []

        // Filter to active sell orders for upcoming periods
        let sellOrders = orders.filter { $0.isSell && $0.isActive }

        for order in sellOrders {
            let filledKwh = fills[order.id] ?? 0
            let unfilledKwh = order.volumeKwh - filledKwh

            guard unfilledKwh > 0.1 else { continue }  // Ignore tiny amounts

            // Calculate hours until delivery
            let hoursUntil = order.dateFrom.timeIntervalSince(now) / 3600
            guard hoursUntil > 0 && hoursUntil < 24 else { continue }  // Only upcoming 24h

            // Get market clearing price for similar hours (settled contracts)
            let orderHour = Calendar.current.component(.hour, from: order.dateFrom)
            let similarContracts = marketContracts.filter { contract in
                let contractHour = (contract.period - 1) * 5 / 60
                return contract.isSettled && abs(contractHour - orderHour) <= 2
            }

            let marketClearing: Double?
            if !similarContracts.isEmpty {
                let prices = similarContracts.map { $0.sellPriceCents }.sorted()
                let medianIndex = prices.count / 2
                marketClearing = prices[medianIndex]
            } else {
                marketClearing = nil
            }

            // Only alert if there's an opportunity
            let yourOffer = order.priceCents ?? 0
            let shouldAlert: Bool
            if let clearing = marketClearing {
                // Alert if your offer is above market clearing and market clearing > spot
                shouldAlert = yourOffer > clearing && clearing > spotPriceCents
            } else {
                // Alert if your offer is significantly above spot (>50% premium)
                shouldAlert = yourOffer > spotPriceCents * 1.5
            }

            if shouldAlert {
                opps.append(UnfilledOpportunity(
                    orderId: order.id,
                    periodStart: order.dateFrom,
                    periodEnd: order.dateTo,
                    unfilledKwh: unfilledKwh,
                    yourOfferCents: yourOffer,
                    spotPriceCents: spotPriceCents,
                    marketClearingCents: marketClearing,
                    hoursUntilDelivery: hoursUntil
                ))
            }
        }

        // Sort by urgency then by potential gain
        opps.sort { a, b in
            if a.urgency != b.urgency {
                return a.hoursUntilDelivery < b.hoursUntilDelivery
            }
            return a.potentialGainCents > b.potentialGainCents
        }

        self.opportunities = opps
        self.lastAnalysis = now

        // Create consolidated alert if there are opportunities
        if !opps.isEmpty {
            let totalUnfilled = opps.reduce(0) { $0 + $1.unfilledKwh }
            let avgOffer = opps.reduce(0) { $0 + $1.yourOfferCents * $1.unfilledKwh } / totalUnfilled
            let marketClearing = opps.compactMap { $0.marketClearingCents }.first
            let potentialLoss = opps.reduce(0) { $0 + $1.potentialGainCents }

            // Period description
            let earliest = opps.map { $0.periodStart }.min() ?? now
            let latest = opps.map { $0.periodEnd }.max() ?? now
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
            let periodDesc = "\(formatter.string(from: earliest))–\(formatter.string(from: latest)) today"

            self.currentAlert = OpportunityAlert(
                totalUnfilledKwh: totalUnfilled,
                periodDescription: periodDesc,
                spotPriceCents: spotPriceCents,
                marketClearingCents: marketClearing,
                yourAvgOfferCents: avgOffer,
                potentialLossCents: potentialLoss,
                opportunities: opps
            )
        } else {
            self.currentAlert = nil
        }
    }

    /// Quick check if there might be opportunities (before full analysis)
    func hasActiveOrders(_ orders: [LVOrder]) -> Bool {
        orders.contains { $0.isSell && $0.isActive }
    }
}
