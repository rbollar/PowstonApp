//
//  ContractSubscriptionTracker.swift
//  Powston
//
//  Manages contract subscription tracking - recording snapshots of contract state
//  over time to analyze counterparty decision patterns.
//
//  This service is called when orders are synced to check for and record changes.
//

import Foundation
import Combine

@MainActor
class ContractSubscriptionTracker: ObservableObject {

    static let shared = ContractSubscriptionTracker()

    @Published var isTracking = false
    @Published var lastTrackingTime: Date?
    @Published var trackedContracts: Int = 0
    @Published var changesDetected: Int = 0

    private let dataStore = PowstonDataStore.shared

    private init() {}

    // MARK: - Track Orders

    /// Process orders and record snapshots for any that have changed
    /// Call this after orders are synced from LocalVolts
    func trackOrders(_ orders: [LVOrder], fills: [String: [LVOrderFill]] = [:], siteId: Int) {
        isTracking = true
        defer {
            isTracking = false
            lastTrackingTime = Date()
        }

        var changesCount = 0

        for order in orders {
            // Track both sell and buy orders
            // Buy contracts also have pre-commitment data we want to track

            // Only track active or recently-ended orders
            let calendar = Calendar.current
            let daysAgo = calendar.dateComponents([.day], from: order.dateTo, to: Date()).day ?? 0
            guard order.isActive || daysAgo <= 7 else { continue }

            // Get fills for this order (if available)
            let orderFills = fills[order.id] ?? []

            // Save snapshot - returns true if state changed
            let changed = dataStore.saveContractSnapshot(
                order: order,
                fills: orderFills,
                siteId: siteId
            )

            if changed {
                changesCount += 1
            }
        }

        // Update stats
        changesDetected = changesCount
        trackedContracts = dataStore.getActiveTrackedOrderIds(siteId: siteId).count

        if changesCount > 0 {
            print("📊 Subscription tracking: \(changesCount) contract changes recorded")
        }
    }

    /// Start tracking a specific order (e.g., when user creates a new contract)
    func startTracking(order: LVOrder, siteId: Int) {
        // Create initial snapshot with empty fills
        _ = dataStore.saveContractSnapshot(order: order, fills: [], siteId: siteId)
        print("📊 Started tracking contract \(order.id)")
    }

    /// Get subscription history for a contract
    func getSubscriptionHistory(orderId: String) -> [LVSubscriptionChange] {
        dataStore.getContractSubscriptionHistory(orderId: orderId)
    }

    /// Get all tracked contracts summary
    func getTrackedContractSummaries(siteId: Int) -> [LVContractSubscriptionSummary] {
        dataStore.getContractSubscriptionSummaries(siteId: siteId)
    }

    /// Get snapshots for a specific order
    func getSnapshots(orderId: String) -> [LVContractSnapshot] {
        dataStore.getContractSnapshots(orderId: orderId)
    }

    /// Get latest snapshot for each tracked order
    func getLatestSnapshots(siteId: Int, activeOnly: Bool = false) -> [LVContractSnapshot] {
        dataStore.getLatestContractSnapshots(siteId: siteId, activeOnly: activeOnly)
    }

    /// Get counterparty reliability metrics
    func getCounterpartyMetrics(siteId: Int) -> [LVSubscriptionPatternAnalysis.CounterpartyMetrics] {
        dataStore.getCounterpartyReliabilityMetrics(siteId: siteId)
    }

    // MARK: - Maintenance

    /// Clean up old snapshots for closed contracts
    func pruneOldData() {
        dataStore.pruneOldSnapshots(keepLast: 50)
    }
}

// MARK: - LocalVoltsService Integration

extension LocalVoltsService {

    /// Trigger subscription tracking after orders are synced
    /// Called with the siteId from the fetch context
    func trackContractSubscriptions(siteId: Int, orders: [LVOrder]) {
        guard siteId > 0, !orders.isEmpty else { return }

        // For now, we don't have fill data from TradeDetail
        // The tracker will still record volume and status changes
        let fills: [String: [LVOrderFill]] = [:]

        Task { @MainActor in
            ContractSubscriptionTracker.shared.trackOrders(
                orders,
                fills: fills,
                siteId: siteId
            )
        }
    }
}
