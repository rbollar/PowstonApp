//
//  LVContractSnapshot.swift
//  Powston
//
//  Tracks subscription changes to P2P contracts over time.
//  Each snapshot captures the state of counterparty commitments at a point in time.
//
//  Use cases:
//  - See when buyers subscribed vs unsubscribed
//  - Track commitment growth patterns (do buyers commit early or late?)
//  - Identify counterparties who frequently cancel
//  - Compare final subscription rate to initial offers
//

import Foundation
import GRDB

// MARK: - Contract Snapshot Model

struct LVContractSnapshot: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lv_contract_snapshots"

    var id: UUID
    var orderId: String              // The order being tracked
    var siteId: Int
    var snapshotTime: Date           // When this state was observed
    var offeredVolumeKwh: Double     // Total volume offered in the contract
    var subscribedVolumeKwh: Double  // Total volume matched/dealt
    var settledVolumeKwh: Double     // Volume already delivered (settled)
    var counterpartyCount: Int       // Number of distinct counterparties
    var orderStatus: String?         // "Confirmed", "Cancelled", etc.
    var isClosed: Bool               // True if contract period has ended

    // Order metadata (denormalized for query convenience)
    var direction: String            // "Sell" or "Buy"
    var priceCents: Double?
    var dateFrom: Date
    var dateTo: Date

    enum CodingKeys: String, CodingKey {
        case id
        case orderId = "order_id"
        case siteId = "site_id"
        case snapshotTime = "snapshot_time"
        case offeredVolumeKwh = "offered_volume_kwh"
        case subscribedVolumeKwh = "subscribed_volume_kwh"
        case settledVolumeKwh = "settled_volume_kwh"
        case counterpartyCount = "counterparty_count"
        case orderStatus = "order_status"
        case isClosed = "is_closed"
        case direction
        case priceCents = "price_cents"
        case dateFrom = "date_from"
        case dateTo = "date_to"
    }

    // MARK: - Computed Properties

    /// Fill rate at this snapshot (subscribed / offered)
    var fillRate: Double {
        guard offeredVolumeKwh > 0 else { return 0 }
        return subscribedVolumeKwh / offeredVolumeKwh
    }

    /// Fill rate as percentage string
    var fillRateString: String {
        String(format: "%.0f%%", fillRate * 100)
    }

    /// Unfilled volume
    var unfilledVolumeKwh: Double {
        max(0, offeredVolumeKwh - subscribedVolumeKwh)
    }

    var isSell: Bool { direction == "Sell" }
    var isBuy: Bool { direction == "Buy" }
}

// MARK: - Counterparty Snapshot Detail

struct LVCounterpartySnapshot: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lv_counterparty_snapshots"

    var id: UUID
    var snapshotId: UUID             // Links to LVContractSnapshot
    var orderId: String
    var counterpartyName: String
    var dealtVolumeKwh: Double       // Volume matched but not yet delivered
    var settledVolumeKwh: Double     // Volume already delivered
    var matchTime: Date?             // When the match occurred (if known)

    enum CodingKeys: String, CodingKey {
        case id
        case snapshotId = "snapshot_id"
        case orderId = "order_id"
        case counterpartyName = "counterparty_name"
        case dealtVolumeKwh = "dealt_volume_kwh"
        case settledVolumeKwh = "settled_volume_kwh"
        case matchTime = "match_time"
    }

    /// Total volume committed by this counterparty
    var totalCommittedKwh: Double {
        dealtVolumeKwh + settledVolumeKwh
    }
}

// MARK: - Subscription Change Event

/// Represents a detected change in subscription state
struct LVSubscriptionChange: Identifiable {
    let id = UUID()
    let orderId: String
    let changeTime: Date
    let changeType: ChangeType
    let previousVolume: Double
    let newVolume: Double
    let counterpartyName: String?    // nil for aggregate changes
    let volumeDelta: Double          // positive = subscription, negative = cancellation

    enum ChangeType: String, Codable {
        case newSubscription = "New Subscription"
        case volumeIncrease = "Increased"
        case volumeDecrease = "Decreased"
        case cancellation = "Cancelled"
        case settled = "Settled"
    }

    var isPositive: Bool {
        switch changeType {
        case .newSubscription, .volumeIncrease, .settled:
            return true
        case .volumeDecrease, .cancellation:
            return false
        }
    }

    var description: String {
        let deltaStr = String(format: "%.1f kWh", abs(volumeDelta))
        switch changeType {
        case .newSubscription:
            if let name = counterpartyName {
                return "\(name) subscribed \(deltaStr)"
            }
            return "New subscription: \(deltaStr)"
        case .volumeIncrease:
            return "Commitment increased by \(deltaStr)"
        case .volumeDecrease:
            return "Commitment decreased by \(deltaStr)"
        case .cancellation:
            if let name = counterpartyName {
                return "\(name) cancelled \(deltaStr)"
            }
            return "Subscription cancelled: \(deltaStr)"
        case .settled:
            return "Delivered \(deltaStr)"
        }
    }
}

// MARK: - Contract Subscription Summary

/// Aggregated view of subscription activity for a contract
struct LVContractSubscriptionSummary: Identifiable {
    let id: String  // orderId
    let orderId: String
    let direction: String
    let priceCents: Double?
    let dateFrom: Date
    let dateTo: Date
    let offeredVolumeKwh: Double

    // Current state
    let currentSubscribedKwh: Double
    let currentSettledKwh: Double
    let currentCounterparties: Int
    let isClosed: Bool

    // History
    let snapshotCount: Int
    let firstSnapshotTime: Date?
    let lastSnapshotTime: Date?
    let peakSubscribedKwh: Double    // Highest subscription level reached
    let changesDetected: Int         // Number of subscription changes

    // Derived metrics
    var currentFillRate: Double {
        guard offeredVolumeKwh > 0 else { return 0 }
        return currentSubscribedKwh / offeredVolumeKwh
    }

    var peakFillRate: Double {
        guard offeredVolumeKwh > 0 else { return 0 }
        return peakSubscribedKwh / offeredVolumeKwh
    }

    /// Did subscriptions ever exceed current level? (indicates some cancellations)
    var hadCancellations: Bool {
        peakSubscribedKwh > currentSubscribedKwh + 0.01
    }

    var daysTracked: Int {
        guard let first = firstSnapshotTime, let last = lastSnapshotTime else { return 0 }
        return Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
    }
}

// MARK: - Subscription Pattern Analysis

/// Analysis of subscription timing patterns across multiple contracts
struct LVSubscriptionPatternAnalysis {
    /// When do most subscriptions come in relative to contract start?
    struct TimingPattern {
        let daysBeforeStart: Int
        let subscriptionCount: Int
        let avgVolumeKwh: Double
    }

    /// Counterparty reliability metrics
    struct CounterpartyMetrics: Identifiable {
        let id: String  // counterparty name
        let counterpartyName: String
        let totalContracts: Int
        let subscriptionCount: Int
        let cancellationCount: Int
        let avgCommitmentKwh: Double
        let reliabilityScore: Double  // 0-100, based on commitment consistency

        var cancellationRate: Double {
            guard subscriptionCount > 0 else { return 0 }
            return Double(cancellationCount) / Double(subscriptionCount)
        }
    }

    let timingPatterns: [TimingPattern]
    let counterpartyMetrics: [CounterpartyMetrics]
    let avgDaysToFirstSubscription: Double
    let avgDaysToFullSubscription: Double?  // nil if never reaches 100%
    let overallFillRate: Double
}
