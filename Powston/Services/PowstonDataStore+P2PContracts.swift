//
//  PowstonDataStore+P2PContracts.swift
//  Powston
//
//  P2P contract persistence with iCloud KVS sync
//  Follows same patterns as PowstonDataStore+P2PTrades.swift
//
//  IMPORTANT: Requires schema migration in PowstonDataStore.swift
//  Add createP2PContractSchema(db) call in performMigrations()
//

import Foundation
import GRDB

// MARK: - iCloud KVS Keys

private let kP2PContractsKey = "p2p_contracts_v1"

// MARK: - PowstonDataStore P2P Contracts Extension

extension PowstonDataStore {
    
    // MARK: - Schema Creation
    
    /// Call this from PowstonDataStore.performMigrations() as a new migration
    func createP2PContractSchema(_ db: Database) throws {
        try db.create(table: "p2p_contracts", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("site_id", .integer).notNull()
            t.column("direction", .text).notNull().defaults(to: "Sell")
            t.column("start_date", .datetime).notNull()
            t.column("end_date", .datetime).notNull()
            t.column("start_hour", .integer).notNull()
            t.column("end_hour", .integer).notNull()
            t.column("tiers_json", .text).notNull()
            t.column("total_volume_kwh", .double).notNull()
            t.column("renewal_days", .integer)
            t.column("is_active", .boolean).notNull().defaults(to: true)
            t.column("created_at", .datetime).notNull()
            t.column("notes", .text)
        }
        
        try db.create(
            index: "idx_p2p_contracts_site_date",
            on: "p2p_contracts",
            columns: ["site_id", "start_date", "end_date"],
            ifNotExists: true
        )
        
        try db.create(
            index: "idx_p2p_contracts_active",
            on: "p2p_contracts",
            columns: ["site_id", "is_active"],
            ifNotExists: true
        )
    }
    
    // MARK: - Save Operations
    
    /// Save a P2P contract
    @MainActor
    func saveP2PContract(_ contract: P2PContract) -> Bool {
        guard let db = dbQueue else { return false }
        
        do {
            try db.write { db in
                // If this contract is active, deactivate any other active contracts for this site
                if contract.isActive {
                    try db.execute(
                        sql: """
                            UPDATE p2p_contracts SET is_active = 0
                            WHERE site_id = ? AND id != ? AND is_active = 1
                            """,
                        arguments: [contract.siteId, contract.id.uuidString]
                    )
                }
                
                // Upsert the contract
                try contract.save(db)
            }
            
            print("💾 Saved P2P contract: \(contract.dateRangeString), \(contract.tiers.count) tiers, \(String(format: "%.1f", contract.totalVolumeKwh)) kWh")
            
            syncP2PContractsToCloud(siteId: contract.siteId)
            return true
        } catch {
            print("❌ Failed to save P2P contract: \(error)")
            return false
        }
    }
    
    /// Delete a P2P contract
    @MainActor
    func deleteP2PContract(_ contract: P2PContract) -> Bool {
        guard let db = dbQueue else { return false }
        
        do {
            try db.write { db in
                try db.execute(
                    sql: "DELETE FROM p2p_contracts WHERE id = ?",
                    arguments: [contract.id.uuidString]
                )
            }
            
            print("🗑️ Deleted P2P contract: \(contract.dateRangeString)")
            syncP2PContractsToCloud(siteId: contract.siteId)
            return true
        } catch {
            print("❌ Failed to delete P2P contract: \(error)")
            return false
        }
    }
    
    // MARK: - Query Operations
    
    /// Get all contracts for a site, newest first
    func getP2PContracts(siteId: Int) -> [P2PContract] {
        guard let db = dbQueue else { return [] }
        
        do {
            return try db.read { db in
                try P2PContract.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM p2p_contracts
                        WHERE site_id = ?
                        ORDER BY start_date DESC
                        """,
                    arguments: [siteId]
                )
            }
        } catch {
            print("❌ getP2PContracts failed: \(error)")
            return []
        }
    }
    
    /// Get the currently active contract for a site
    func getActiveP2PContract(siteId: Int) -> P2PContract? {
        guard let db = dbQueue else { return nil }
        
        do {
            return try db.read { db in
                try P2PContract.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM p2p_contracts
                        WHERE site_id = ? AND is_active = 1
                        ORDER BY start_date DESC
                        LIMIT 1
                        """,
                    arguments: [siteId]
                )
            }
        } catch {
            print("❌ getActiveP2PContract failed: \(error)")
            return nil
        }
    }
    
    /// Get the contract covering a specific date
    func getP2PContract(siteId: Int, forDate date: Date) -> P2PContract? {
        guard let db = dbQueue else { return nil }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let normalizedDate = calendar.startOfDay(for: date)
        
        do {
            return try db.read { db in
                try P2PContract.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM p2p_contracts
                        WHERE site_id = ?
                        AND start_date <= ?
                        AND end_date >= ?
                        ORDER BY start_date DESC
                        LIMIT 1
                        """,
                    arguments: [siteId, normalizedDate, normalizedDate]
                )
            }
        } catch {
            print("❌ getP2PContract(forDate:) failed: \(error)")
            return nil
        }
    }
    
    /// Get contracts overlapping a date range
    func getP2PContracts(siteId: Int, from startDate: Date, to endDate: Date) -> [P2PContract] {
        guard let db = dbQueue else { return [] }
        
        do {
            return try db.read { db in
                try P2PContract.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM p2p_contracts
                        WHERE site_id = ?
                        AND start_date <= ?
                        AND end_date >= ?
                        ORDER BY start_date DESC
                        """,
                    arguments: [siteId, endDate, startDate]
                )
            }
        } catch {
            print("❌ getP2PContracts(range) failed: \(error)")
            return []
        }
    }
    
    // MARK: - Performance Queries

    /// Calculate performance for a contract by joining with counterparty trades
    /// Buckets actual trade prices into contract tiers using dynamic midpoints
    /// Includes both CSV imports (p2p_counterparty_trades) and LocalVolts API data (lv_interval_trades)
    @MainActor
    func getP2PContractPerformance(_ contract: P2PContract) -> P2PContractPerformance {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"
        print("📊 getP2PContractPerformance: \(contract.direction) \(dateFormatter.string(from: contract.startDate))–\(dateFormatter.string(from: contract.endDate)), siteId=\(contract.siteId)")

        // Get all trade records that overlap this contract's dates (CSV imports)
        let tradeRecords = getP2PTradeRecords(
            siteId: contract.siteId,
            from: contract.startDate,
            to: contract.endDate
        )
        print("   └─ Found \(tradeRecords.count) CSV trade records")

        // Build a map of trade record ID to isProvisional for attribution
        var provisionalRecordIds: Set<UUID> = []
        for record in tradeRecords {
            if record.isProvisional {
                provisionalRecordIds.insert(record.id)
            }
        }

        // Get counterparty trades for ONLY those specific trade records (CSV imports)
        // Filter by direction to match the contract type (Buy vs Sell)
        var counterpartyTrades: [P2PCounterpartyTrade] = []
        for record in tradeRecords {
            // Only include trades from records matching this contract's direction
            guard record.direction == contract.direction else { continue }
            let trades = getP2PCounterpartyTrades(forTradeRecord: record.id)
            counterpartyTrades.append(contentsOf: trades)
        }

        // Also include LocalVolts API trades (lv_interval_trades) for the contract date range
        // These are converted to P2PCounterpartyTrade format for compatibility
        let lvTrades = getLVIntervalTrades(
            siteId: contract.siteId,
            from: contract.startDate,
            to: contract.endDate
        )
        print("   └─ Found \(lvTrades.count) LV interval trades")

        // Filter LV trades by direction and convert to P2PCounterpartyTrade
        let directionString = contract.direction == .sell ? "Sell" : "Buy"
        for lvTrade in lvTrades {
            guard lvTrade.direction.rawValue == directionString else { continue }
            let converted = P2PCounterpartyTrade(
                id: lvTrade.id,
                tradeRecordId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,  // Sentinel for LV trades
                siteId: lvTrade.siteId,
                counterpartyName: lvTrade.counterpartyName,
                volumeKwh: lvTrade.volumeKwh,
                priceCents: lvTrade.priceCents,
                tradeDate: lvTrade.periodStart,
                importedAt: lvTrade.fetchedAt,
                direction: contract.direction,
                facility: lvTrade.cpFacility
            )
            counterpartyTrades.append(converted)
        }

        print("   └─ After direction filtering: \(counterpartyTrades.count) counterparty trades")

        // If we have no trades, return empty performance
        guard !counterpartyTrades.isEmpty else {
            let emptyTierPerf = contract.tiers.map { tier in
                P2PTierPerformance(
                    tier: tier,
                    matchedKwh: 0,
                    matchedRevenue: 0,
                    tradeCount: 0,
                    actualKwh: 0,
                    actualRevenue: 0,
                    provisionalKwh: 0,
                    provisionalRevenue: 0
                )
            }
            return P2PContractPerformance(
                contract: contract,
                tradeRecords: tradeRecords,
                tierPerformance: emptyTierPerf,
                totalMatchedKwh: 0,
                totalRevenue: 0,
                counterpartyCount: 0,
                counterpartyBreakdown: [],
                actualKwh: 0,
                actualRevenue: 0,
                provisionalKwh: 0,
                provisionalRevenue: 0
            )
        }

        // Calculate tier performance using actual trade prices
        let tierPerformance = calculateTierPerformance(
            contract: contract,
            trades: counterpartyTrades,
            provisionalRecordIds: provisionalRecordIds
        )

        // Calculate totals from actual trades, split by provisional
        var actualKwh = 0.0
        var actualRevenue = 0.0
        var provisionalKwh = 0.0
        var provisionalRevenue = 0.0

        for trade in counterpartyTrades {
            if provisionalRecordIds.contains(trade.tradeRecordId) {
                provisionalKwh += trade.volumeKwh
                provisionalRevenue += trade.revenue
            } else {
                actualKwh += trade.volumeKwh
                actualRevenue += trade.revenue
            }
        }

        let totalMatchedKwh = actualKwh + provisionalKwh
        let totalRevenue = actualRevenue + provisionalRevenue
        let uniqueCounterparties = Set(counterpartyTrades.map { $0.counterpartyName }).count

        // Calculate counterparty breakdown
        var counterpartyAggregates: [String: (kwh: Double, revenue: Double, count: Int)] = [:]
        for trade in counterpartyTrades {
            let existing = counterpartyAggregates[trade.counterpartyName] ?? (0, 0, 0)
            counterpartyAggregates[trade.counterpartyName] = (
                existing.kwh + trade.volumeKwh,
                existing.revenue + trade.revenue,
                existing.count + 1
            )
        }
        let counterpartyBreakdown = counterpartyAggregates.map { name, data in
            CounterpartyBreakdownItem(
                counterpartyName: name,
                matchedKwh: data.kwh,
                revenue: data.revenue,
                tradeCount: data.count
            )
        }.sorted { $0.matchedKwh > $1.matchedKwh }

        return P2PContractPerformance(
            contract: contract,
            tradeRecords: tradeRecords,
            tierPerformance: tierPerformance,
            totalMatchedKwh: totalMatchedKwh,
            totalRevenue: totalRevenue,
            counterpartyCount: uniqueCounterparties,
            counterpartyBreakdown: counterpartyBreakdown,
            actualKwh: actualKwh,
            actualRevenue: actualRevenue,
            provisionalKwh: provisionalKwh,
            provisionalRevenue: provisionalRevenue
        )
    }

    /// Calculate tier performance by bucketing actual trades based on their prices
    /// Uses contract's tier boundaries (midpoints between prices) for bucketing
    private func calculateTierPerformance(
        contract: P2PContract,
        trades: [P2PCounterpartyTrade],
        provisionalRecordIds: Set<UUID>
    ) -> [P2PTierPerformance] {
        guard !contract.tiers.isEmpty else { return [] }

        // Initialize accumulators for each tier (total and split by provisional)
        struct TierAccumulator {
            var kwh: Double = 0
            var revenue: Double = 0
            var count: Int = 0
            var actualKwh: Double = 0
            var actualRevenue: Double = 0
            var provisionalKwh: Double = 0
            var provisionalRevenue: Double = 0
        }
        var tierData: [UUID: TierAccumulator] = [:]
        for tier in contract.tiers {
            tierData[tier.id] = TierAccumulator()
        }

        // Bucket each trade into the appropriate tier based on its price
        for trade in trades {
            guard trade.volumeKwh > 0 else { continue }

            if let matchedTier = contract.matchingTier(forPriceCents: trade.priceCents) {
                var data = tierData[matchedTier.id] ?? TierAccumulator()
                data.kwh += trade.volumeKwh
                data.revenue += trade.revenue  // Use actual revenue, not tier price
                data.count += 1

                // Split by provisional status
                if provisionalRecordIds.contains(trade.tradeRecordId) {
                    data.provisionalKwh += trade.volumeKwh
                    data.provisionalRevenue += trade.revenue
                } else {
                    data.actualKwh += trade.volumeKwh
                    data.actualRevenue += trade.revenue
                }
                tierData[matchedTier.id] = data
            }
        }

        // Build tier performance array
        return contract.tiers.map { tier in
            let data = tierData[tier.id] ?? TierAccumulator()
            return P2PTierPerformance(
                tier: tier,
                matchedKwh: data.kwh,
                matchedRevenue: data.revenue,
                tradeCount: data.count,
                actualKwh: data.actualKwh,
                actualRevenue: data.actualRevenue,
                provisionalKwh: data.provisionalKwh,
                provisionalRevenue: data.provisionalRevenue
            )
        }
    }
    
    // MARK: - iCloud KVS Sync
    
    /// Sync contracts to iCloud KVS
    private func syncP2PContractsToCloud(siteId: Int) {
        let contracts = getP2PContracts(siteId: siteId)
        
        guard let data = P2PContract.encodeForSync(contracts) else {
            print("❌ Failed to encode P2P contracts for sync")
            return
        }
        
        let key = "\(kP2PContractsKey)_site\(siteId)"
        NSUbiquitousKeyValueStore.default.set(data, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
        
        print("☁️ Synced \(contracts.count) P2P contracts to iCloud for site \(siteId)")
    }
    
    /// Pull contracts from iCloud KVS and merge with local
    @MainActor
    func syncP2PContractsFromCloud(siteId: Int) {
        let key = "\(kP2PContractsKey)_site\(siteId)"
        
        NSUbiquitousKeyValueStore.default.synchronize()
        
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: key) else {
            print("☁️ No P2P contract data found in iCloud for site \(siteId)")
            return
        }
        
        guard let cloudContracts = P2PContract.decodeFromSync(data) else {
            print("☁️ Failed to decode P2P contracts from iCloud")
            return
        }
        
        let localContracts = getP2PContracts(siteId: siteId)
        let localIds = Set(localContracts.map { $0.id })
        
        let newContracts = cloudContracts.filter { !localIds.contains($0.id) }
        
        if newContracts.isEmpty {
            print("☁️ No new P2P contracts from iCloud")
            return
        }
        
        guard let db = dbQueue else { return }
        
        do {
            try db.write { db in
                for contract in newContracts {
                    try contract.insert(db)
                }
            }
            print("☁️ Merged \(newContracts.count) P2P contracts from iCloud")
        } catch {
            print("❌ Failed to merge P2P contracts from iCloud: \(error)")
        }
    }
    
    /// Register for iCloud KVS change notifications for contracts
    /// Call alongside registerForP2PCloudSync()
    func registerForP2PContractCloudSync() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] notification in
            guard let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
                return
            }
            
            let contractKeysChanged = changedKeys.filter { $0.hasPrefix(kP2PContractsKey) }
            if !contractKeysChanged.isEmpty {
                print("☁️ P2P contracts changed externally, syncing...")
                for key in contractKeysChanged {
                    if let siteIdStr = key.components(separatedBy: "_site").last,
                       let siteId = Int(siteIdStr) {
                        Task {
                            await MainActor.run { [weak self] in
                                self?.syncP2PContractsFromCloud(siteId: siteId)
                            }
                        }
                    }
                }
            }
        }
        
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}
