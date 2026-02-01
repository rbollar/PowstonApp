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
    
    /// Calculate performance for a contract by joining with trade records
    /// Buckets trade prices into contract tiers using dynamic midpoints
    @MainActor
    func getP2PContractPerformance(_ contract: P2PContract) -> P2PContractPerformance {
        // Get all trade records that overlap this contract's dates
        let tradeRecords = getP2PTradeRecords(
            siteId: contract.siteId,
            from: contract.startDate,
            to: contract.endDate
        )
        
        // If we have no trade records, return empty performance
        guard !tradeRecords.isEmpty else {
            let emptyTierPerf = contract.tiers.map { tier in
                P2PTierPerformance(tier: tier, matchedKwh: 0, matchedRevenue: 0, tradeCount: 0)
            }
            return P2PContractPerformance(
                contract: contract,
                tradeRecords: [],
                tierPerformance: emptyTierPerf,
                totalMatchedKwh: 0,
                totalRevenue: 0,
                counterpartyCount: 0
            )
        }
        
        // Aggregate totals from trade records
        let totalMatchedKwh = tradeRecords.reduce(0) { $0 + $1.p2pKwh }
        let totalRevenue = tradeRecords.reduce(0) { $0 + $1.p2pRevenue }
        let totalCounterparties = tradeRecords.reduce(0) { $0 + $1.counterpartyCount }
        
        // For tier-level breakdown, we need the per-price-point data
        // that was stored in the trade records. Since P2PTradeRecord stores
        // aggregate data, we approximate tier distribution using the
        // average price vs tier boundaries.
        let tierPerformance = approximateTierPerformance(
            contract: contract,
            tradeRecords: tradeRecords
        )
        
        return P2PContractPerformance(
            contract: contract,
            tradeRecords: tradeRecords,
            tierPerformance: tierPerformance,
            totalMatchedKwh: totalMatchedKwh,
            totalRevenue: totalRevenue,
            counterpartyCount: totalCounterparties
        )
    }
    
    /// Approximate tier performance from aggregate trade records
    /// Since P2PTradeRecord has avgPrice but not per-tier breakdown,
    /// we distribute proportionally based on tier volumes and actual totals
    private func approximateTierPerformance(
        contract: P2PContract,
        tradeRecords: [P2PTradeRecord]
    ) -> [P2PTierPerformance] {
        let totalMatched = tradeRecords.reduce(0) { $0 + $1.p2pKwh }
        let totalRevenue = tradeRecords.reduce(0) { $0 + $1.p2pRevenue }
        
        guard totalMatched > 0, !contract.tiers.isEmpty else {
            return contract.tiers.map { tier in
                P2PTierPerformance(tier: tier, matchedKwh: 0, matchedRevenue: 0, tradeCount: 0)
            }
        }
        
        // Distribute matched kWh across tiers proportionally to tier volume
        // Lower-price tiers fill first (they're most attractive to buyers)
        let sortedTiers = contract.tiers.sorted { $0.priceCents < $1.priceCents }
        var remaining = totalMatched
        var performances: [P2PTierPerformance] = []
        
        for tier in sortedTiers {
            let tierMatched = min(remaining, tier.volumeKwh)
            let tierRevenue = tierMatched * tier.priceCents / 100.0
            remaining -= tierMatched
            
            performances.append(P2PTierPerformance(
                tier: tier,
                matchedKwh: tierMatched,
                matchedRevenue: tierRevenue,
                tradeCount: tierMatched > 0 ? 1 : 0  // Approximation
            ))
        }
        
        return performances
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
                        Task { @MainActor in
                            self?.syncP2PContractsFromCloud(siteId: siteId)
                        }
                    }
                }
            }
        }
        
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}
