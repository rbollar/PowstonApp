//
//  PowstonDataStore+ContractSnapshots.swift
//  Powston
//
//  Database operations for contract subscription tracking.
//  Stores snapshots of contract state over time to analyze subscription patterns.
//

import Foundation
import GRDB

extension PowstonDataStore {

    // MARK: - Schema

    func createContractSnapshotTables(in db: Database) throws {
        // Main snapshot table
        try db.create(table: "lv_contract_snapshots", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("order_id", .text).notNull().indexed()
            t.column("site_id", .integer).notNull()
            t.column("snapshot_time", .datetime).notNull()
            t.column("offered_volume_kwh", .double).notNull()
            t.column("subscribed_volume_kwh", .double).notNull()
            t.column("settled_volume_kwh", .double).notNull()
            t.column("counterparty_count", .integer).notNull()
            t.column("order_status", .text)
            t.column("is_closed", .boolean).notNull().defaults(to: false)
            t.column("direction", .text).notNull()
            t.column("price_cents", .double)
            t.column("date_from", .datetime).notNull()
            t.column("date_to", .datetime).notNull()
        }

        // Index for efficient queries
        try db.create(
            index: "idx_snapshots_order_time",
            on: "lv_contract_snapshots",
            columns: ["order_id", "snapshot_time"],
            ifNotExists: true
        )

        // Counterparty detail table
        try db.create(table: "lv_counterparty_snapshots", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("snapshot_id", .text).notNull()
                .references("lv_contract_snapshots", onDelete: .cascade)
            t.column("order_id", .text).notNull().indexed()
            t.column("counterparty_name", .text).notNull()
            t.column("dealt_volume_kwh", .double).notNull()
            t.column("settled_volume_kwh", .double).notNull()
            t.column("match_time", .datetime)
        }

        // Index for counterparty queries
        try db.create(
            index: "idx_counterparty_snapshots_order",
            on: "lv_counterparty_snapshots",
            columns: ["order_id", "counterparty_name"],
            ifNotExists: true
        )
    }

    // MARK: - Save Snapshot

    /// Record current state of a contract's subscriptions
    /// Returns true if this represents a change from the last snapshot
    @discardableResult
    func saveContractSnapshot(
        order: LVOrder,
        fills: [LVOrderFill],
        siteId: Int
    ) -> Bool {
        guard let db = dbQueue else { return false }

        // Calculate totals from fills
        let subscribedVolume = fills.reduce(0) { $0 + $1.dealtKwh }
        let settledVolume = fills.reduce(0) { $0 + $1.settledKwh }

        // Check if contract period has ended
        let now = Date()
        let isClosed = order.dateTo < now

        do {
            return try db.write { db in
                // Get last snapshot for this order
                let lastSnapshot = try LVContractSnapshot
                    .filter(Column("order_id") == order.id)
                    .order(Column("snapshot_time").desc)
                    .fetchOne(db)

                // Determine if state has changed
                let hasChanged: Bool
                if let last = lastSnapshot {
                    // Changed if subscribed/settled volume differs or status changed
                    let volumeChanged = abs(last.subscribedVolumeKwh - subscribedVolume) > 0.001 ||
                                        abs(last.settledVolumeKwh - settledVolume) > 0.001
                    let statusChanged = last.orderStatus != order.status
                    let closedChanged = last.isClosed != isClosed
                    let counterpartyChanged = last.counterpartyCount != fills.count

                    hasChanged = volumeChanged || statusChanged || closedChanged || counterpartyChanged
                } else {
                    // First snapshot for this order
                    hasChanged = true
                }

                // Only save if changed (or first snapshot)
                guard hasChanged else { return false }

                let snapshotId = UUID()
                let snapshot = LVContractSnapshot(
                    id: snapshotId,
                    orderId: order.id,
                    siteId: siteId,
                    snapshotTime: now,
                    offeredVolumeKwh: order.volumeKwh,
                    subscribedVolumeKwh: subscribedVolume,
                    settledVolumeKwh: settledVolume,
                    counterpartyCount: fills.count,
                    orderStatus: order.status,
                    isClosed: isClosed,
                    direction: order.direction,
                    priceCents: order.priceCents,
                    dateFrom: order.dateFrom,
                    dateTo: order.dateTo
                )

                try snapshot.save(db)

                // Save counterparty details
                for fill in fills {
                    let counterpartySnapshot = LVCounterpartySnapshot(
                        id: UUID(),
                        snapshotId: snapshotId,
                        orderId: order.id,
                        counterpartyName: fill.counterpartyName,
                        dealtVolumeKwh: fill.dealtKwh,
                        settledVolumeKwh: fill.settledKwh,
                        matchTime: fill.matchTime
                    )
                    try counterpartySnapshot.save(db)
                }

                print("📸 Contract snapshot saved for order \(order.id): \(fills.count) counterparties, \(String(format: "%.1f", subscribedVolume)) kWh subscribed")
                return true
            }
        } catch {
            print("❌ Failed to save contract snapshot: \(error)")
            return false
        }
    }

    // MARK: - Query Snapshots

    /// Get all snapshots for an order, ordered by time
    func getContractSnapshots(orderId: String) -> [LVContractSnapshot] {
        guard let db = dbQueue else { return [] }

        return (try? db.read { db in
            try LVContractSnapshot
                .filter(Column("order_id") == orderId)
                .order(Column("snapshot_time").asc)
                .fetchAll(db)
        }) ?? []
    }

    /// Get the latest snapshot for each tracked order
    func getLatestContractSnapshots(siteId: Int, activeOnly: Bool = false) -> [LVContractSnapshot] {
        guard let db = dbQueue else { return [] }

        return (try? db.read { db in
            // Subquery to get max snapshot_time per order
            let sql = """
                SELECT cs.*
                FROM lv_contract_snapshots cs
                INNER JOIN (
                    SELECT order_id, MAX(snapshot_time) as max_time
                    FROM lv_contract_snapshots
                    WHERE site_id = ?
                    GROUP BY order_id
                ) latest ON cs.order_id = latest.order_id AND cs.snapshot_time = latest.max_time
                WHERE cs.site_id = ?
                \(activeOnly ? "AND cs.is_closed = 0" : "")
                ORDER BY cs.date_from DESC
                """

            return try LVContractSnapshot.fetchAll(db, sql: sql, arguments: [siteId, siteId])
        }) ?? []
    }

    /// Get counterparty snapshots for a specific contract snapshot
    func getCounterpartySnapshots(snapshotId: UUID) -> [LVCounterpartySnapshot] {
        guard let db = dbQueue else { return [] }

        return (try? db.read { db in
            try LVCounterpartySnapshot
                .filter(Column("snapshot_id") == snapshotId.uuidString)
                .order(Column("dealt_volume_kwh").desc)
                .fetchAll(db)
        }) ?? []
    }

    /// Get all counterparty snapshots for an order (from the latest snapshot)
    func getCounterpartySnapshots(orderId: String) -> [LVCounterpartySnapshot] {
        guard let db = dbQueue else { return [] }

        return (try? db.read { db in
            try LVCounterpartySnapshot
                .filter(Column("order_id") == orderId)
                .order(Column("dealt_volume_kwh").desc)
                .fetchAll(db)
        }) ?? []
    }

    // MARK: - Detect Changes

    /// Compare two snapshots and identify what changed
    func detectSubscriptionChanges(
        previousSnapshot: LVContractSnapshot,
        currentSnapshot: LVContractSnapshot
    ) -> [LVSubscriptionChange] {
        guard dbQueue != nil else { return [] }

        var changes: [LVSubscriptionChange] = []

        // Get counterparty details for both snapshots
        let previousCounterparties = getCounterpartySnapshots(snapshotId: previousSnapshot.id)
        let currentCounterparties = getCounterpartySnapshots(snapshotId: currentSnapshot.id)

        let previousByName = Dictionary(uniqueKeysWithValues: previousCounterparties.map { ($0.counterpartyName, $0) })
        let currentByName = Dictionary(uniqueKeysWithValues: currentCounterparties.map { ($0.counterpartyName, $0) })

        // Check for new subscriptions
        for current in currentCounterparties {
            if let previous = previousByName[current.counterpartyName] {
                // Existing counterparty - check for volume changes
                let dealDelta = current.dealtVolumeKwh - previous.dealtVolumeKwh
                let settleDelta = current.settledVolumeKwh - previous.settledVolumeKwh

                if abs(dealDelta) > 0.001 {
                    changes.append(LVSubscriptionChange(
                        orderId: currentSnapshot.orderId,
                        changeTime: currentSnapshot.snapshotTime,
                        changeType: dealDelta > 0 ? .volumeIncrease : .volumeDecrease,
                        previousVolume: previous.totalCommittedKwh,
                        newVolume: current.totalCommittedKwh,
                        counterpartyName: current.counterpartyName,
                        volumeDelta: dealDelta
                    ))
                }

                if settleDelta > 0.001 {
                    changes.append(LVSubscriptionChange(
                        orderId: currentSnapshot.orderId,
                        changeTime: currentSnapshot.snapshotTime,
                        changeType: .settled,
                        previousVolume: previous.settledVolumeKwh,
                        newVolume: current.settledVolumeKwh,
                        counterpartyName: current.counterpartyName,
                        volumeDelta: settleDelta
                    ))
                }
            } else {
                // New counterparty subscription
                changes.append(LVSubscriptionChange(
                    orderId: currentSnapshot.orderId,
                    changeTime: currentSnapshot.snapshotTime,
                    changeType: .newSubscription,
                    previousVolume: 0,
                    newVolume: current.totalCommittedKwh,
                    counterpartyName: current.counterpartyName,
                    volumeDelta: current.totalCommittedKwh
                ))
            }
        }

        // Check for cancellations (counterparties who were present before but not now)
        for previous in previousCounterparties {
            if currentByName[previous.counterpartyName] == nil {
                changes.append(LVSubscriptionChange(
                    orderId: currentSnapshot.orderId,
                    changeTime: currentSnapshot.snapshotTime,
                    changeType: .cancellation,
                    previousVolume: previous.totalCommittedKwh,
                    newVolume: 0,
                    counterpartyName: previous.counterpartyName,
                    volumeDelta: -previous.totalCommittedKwh
                ))
            }
        }

        return changes
    }

    /// Get all changes for a contract over time
    func getContractSubscriptionHistory(orderId: String) -> [LVSubscriptionChange] {
        let snapshots = getContractSnapshots(orderId: orderId)
        guard snapshots.count >= 2 else { return [] }

        var allChanges: [LVSubscriptionChange] = []

        for i in 1..<snapshots.count {
            let changes = detectSubscriptionChanges(
                previousSnapshot: snapshots[i-1],
                currentSnapshot: snapshots[i]
            )
            allChanges.append(contentsOf: changes)
        }

        return allChanges.sorted { $0.changeTime < $1.changeTime }
    }

    // MARK: - Summary & Analysis

    /// Get subscription summary for all tracked contracts
    func getContractSubscriptionSummaries(siteId: Int) -> [LVContractSubscriptionSummary] {
        guard let db = dbQueue else { return [] }

        return (try? db.read { db in
            let sql = """
                SELECT
                    order_id,
                    direction,
                    price_cents,
                    date_from,
                    date_to,
                    MAX(offered_volume_kwh) as offered_volume_kwh,
                    -- Current state (from latest snapshot)
                    (SELECT subscribed_volume_kwh FROM lv_contract_snapshots s2
                     WHERE s2.order_id = s1.order_id ORDER BY snapshot_time DESC LIMIT 1) as current_subscribed,
                    (SELECT settled_volume_kwh FROM lv_contract_snapshots s2
                     WHERE s2.order_id = s1.order_id ORDER BY snapshot_time DESC LIMIT 1) as current_settled,
                    (SELECT counterparty_count FROM lv_contract_snapshots s2
                     WHERE s2.order_id = s1.order_id ORDER BY snapshot_time DESC LIMIT 1) as current_counterparties,
                    (SELECT is_closed FROM lv_contract_snapshots s2
                     WHERE s2.order_id = s1.order_id ORDER BY snapshot_time DESC LIMIT 1) as is_closed,
                    -- History
                    COUNT(*) as snapshot_count,
                    MIN(snapshot_time) as first_snapshot,
                    MAX(snapshot_time) as last_snapshot,
                    MAX(subscribed_volume_kwh) as peak_subscribed
                FROM lv_contract_snapshots s1
                WHERE site_id = ?
                GROUP BY order_id
                ORDER BY date_from DESC
                """

            var summaries: [LVContractSubscriptionSummary] = []

            let rows = try Row.fetchAll(db, sql: sql, arguments: [siteId])
            for row in rows {
                guard let orderId: String = row["order_id"],
                      let direction: String = row["direction"],
                      let dateFrom: Date = row["date_from"],
                      let dateTo: Date = row["date_to"],
                      let offeredVolume: Double = row["offered_volume_kwh"] else { continue }

                let summary = LVContractSubscriptionSummary(
                    id: orderId,
                    orderId: orderId,
                    direction: direction,
                    priceCents: row["price_cents"],
                    dateFrom: dateFrom,
                    dateTo: dateTo,
                    offeredVolumeKwh: offeredVolume,
                    currentSubscribedKwh: row["current_subscribed"] ?? 0,
                    currentSettledKwh: row["current_settled"] ?? 0,
                    currentCounterparties: row["current_counterparties"] ?? 0,
                    isClosed: row["is_closed"] ?? false,
                    snapshotCount: row["snapshot_count"] ?? 0,
                    firstSnapshotTime: row["first_snapshot"],
                    lastSnapshotTime: row["last_snapshot"],
                    peakSubscribedKwh: row["peak_subscribed"] ?? 0,
                    changesDetected: 0  // TODO: Count changes
                )
                summaries.append(summary)
            }

            return summaries
        }) ?? []
    }

    /// Get counterparty reliability metrics across all contracts
    func getCounterpartyReliabilityMetrics(siteId: Int) -> [LVSubscriptionPatternAnalysis.CounterpartyMetrics] {
        guard let db = dbQueue else { return [] }

        return (try? db.read { db in
            let sql = """
                SELECT
                    counterparty_name,
                    COUNT(DISTINCT order_id) as total_contracts,
                    COUNT(*) as subscription_count,
                    AVG(dealt_volume_kwh + settled_volume_kwh) as avg_commitment
                FROM lv_counterparty_snapshots cs
                JOIN lv_contract_snapshots s ON cs.snapshot_id = s.id
                WHERE s.site_id = ?
                GROUP BY counterparty_name
                HAVING total_contracts >= 1
                ORDER BY subscription_count DESC
                """

            var metrics: [LVSubscriptionPatternAnalysis.CounterpartyMetrics] = []

            let rows = try Row.fetchAll(db, sql: sql, arguments: [siteId])
            for row in rows {
                guard let name: String = row["counterparty_name"],
                      let totalContracts: Int = row["total_contracts"],
                      let subscriptionCount: Int = row["subscription_count"] else { continue }

                let avgCommitment: Double = row["avg_commitment"] ?? 0

                // TODO: Calculate cancellation count from change history
                let cancellationCount = 0

                // Reliability score based on contract participation
                let reliability = min(100, Double(totalContracts) * 20)

                metrics.append(LVSubscriptionPatternAnalysis.CounterpartyMetrics(
                    id: name,
                    counterpartyName: name,
                    totalContracts: totalContracts,
                    subscriptionCount: subscriptionCount,
                    cancellationCount: cancellationCount,
                    avgCommitmentKwh: avgCommitment,
                    reliabilityScore: reliability
                ))
            }

            return metrics
        }) ?? []
    }

    // MARK: - Cleanup

    /// Remove old snapshots for closed contracts (keep last N snapshots per contract)
    func pruneOldSnapshots(keepLast: Int = 50) {
        guard let db = dbQueue else { return }

        do {
            try db.write { db in
                // Get closed contracts with more than keepLast snapshots
                let sql = """
                    DELETE FROM lv_contract_snapshots
                    WHERE id IN (
                        SELECT id FROM (
                            SELECT id,
                                   ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY snapshot_time DESC) as rn
                            FROM lv_contract_snapshots
                            WHERE is_closed = 1
                        )
                        WHERE rn > ?
                    )
                    """
                try db.execute(sql: sql, arguments: [keepLast])
            }
        } catch {
            print("❌ Failed to prune old snapshots: \(error)")
        }
    }

    // MARK: - Check if Order is Being Tracked

    /// Check if we have any snapshots for this order
    func isTrackingContract(orderId: String) -> Bool {
        guard let db = dbQueue else { return false }

        return (try? db.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM lv_contract_snapshots WHERE order_id = ?",
                arguments: [orderId]
            )
            return (count ?? 0) > 0
        }) ?? false
    }

    /// Get list of order IDs we're actively tracking (not yet closed)
    func getActiveTrackedOrderIds(siteId: Int) -> [String] {
        guard let db = dbQueue else { return [] }

        return (try? db.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT order_id
                    FROM lv_contract_snapshots
                    WHERE site_id = ? AND is_closed = 0
                    """,
                arguments: [siteId]
            )
        }) ?? []
    }
}
