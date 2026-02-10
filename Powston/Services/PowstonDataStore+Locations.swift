//
//  PowstonDataStore+Locations.swift
//  Powston
//
//  Database operations for P2P counterparty locations
//

import Foundation
import GRDB
import CoreLocation

extension PowstonDataStore {

    // MARK: - Table Creation

    func createLocationsTables(_ db: Database) throws {
        try db.create(table: "p2p_counterparty_locations", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("counterparty_name", .text).notNull().unique()
            t.column("latitude", .double).notNull()
            t.column("longitude", .double).notNull()
            t.column("formatted_address", .text)
            t.column("locality", .text)
            t.column("administrative_area", .text)
            t.column("searched_at", .datetime).notNull()
            t.column("is_verified", .boolean).notNull().defaults(to: false)
        }
    }

    // MARK: - Save Location

    func saveCounterpartyLocation(_ location: P2PCounterpartyLocation) {
        do {
            try dbQueue?.write { db in
                // Use INSERT OR REPLACE to update existing
                try location.save(db)
            }
        } catch {
            print("❌ Failed to save counterparty location: \(error)")
        }
    }

    func saveCounterpartyLocation(
        counterpartyName: String,
        coordinate: CLLocationCoordinate2D,
        address: String?,
        locality: String?,
        administrativeArea: String?,
        isVerified: Bool = false
    ) {
        let location = P2PCounterpartyLocation(
            id: UUID(),
            counterpartyName: counterpartyName,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            formattedAddress: address,
            locality: locality,
            administrativeArea: administrativeArea,
            searchedAt: Date(),
            isVerified: isVerified
        )
        saveCounterpartyLocation(location)
    }

    // MARK: - Get Locations

    func getCounterpartyLocation(name: String) -> P2PCounterpartyLocation? {
        do {
            return try dbQueue?.read { db in
                try P2PCounterpartyLocation
                    .filter(Column("counterparty_name") == name)
                    .fetchOne(db)
            }
        } catch {
            print("❌ Failed to fetch counterparty location: \(error)")
            return nil
        }
    }

    func getAllCounterpartyLocations() -> [P2PCounterpartyLocation] {
        do {
            return try dbQueue?.read { db in
                try P2PCounterpartyLocation
                    .order(Column("counterparty_name"))
                    .fetchAll(db)
            } ?? []
        } catch {
            print("❌ Failed to fetch counterparty locations: \(error)")
            return []
        }
    }

    func getVerifiedCounterpartyLocations() -> [P2PCounterpartyLocation] {
        do {
            return try dbQueue?.read { db in
                try P2PCounterpartyLocation
                    .filter(Column("is_verified") == true)
                    .order(Column("counterparty_name"))
                    .fetchAll(db)
            } ?? []
        } catch {
            print("❌ Failed to fetch verified locations: \(error)")
            return []
        }
    }

    // MARK: - Update Verification

    func setLocationVerified(counterpartyName: String, verified: Bool) {
        do {
            try dbQueue?.write { db in
                try db.execute(
                    sql: """
                        UPDATE p2p_counterparty_locations
                        SET is_verified = ?
                        WHERE counterparty_name = ?
                        """,
                    arguments: [verified, counterpartyName]
                )
            }
        } catch {
            print("❌ Failed to update location verification: \(error)")
        }
    }

    // MARK: - Delete Location

    func deleteCounterpartyLocation(name: String) {
        do {
            try dbQueue?.write { db in
                try db.execute(
                    sql: "DELETE FROM p2p_counterparty_locations WHERE counterparty_name = ?",
                    arguments: [name]
                )
            }
        } catch {
            print("❌ Failed to delete counterparty location: \(error)")
        }
    }

    // MARK: - Counterparties Without Locations

    /// Returns commercial counterparty names that don't have a cached location
    func getCounterpartiesWithoutLocations(siteId: Int) -> [String] {
        do {
            return try dbQueue?.read { db in
                // Get all unique commercial counterparty names
                let allCommercial = try String.fetchAll(db, sql: """
                    SELECT DISTINCT counterparty_name
                    FROM p2p_counterparty_trades
                    WHERE site_id = ?
                    AND (
                        LOWER(counterparty_name) LIKE '%pty ltd%' OR
                        LOWER(counterparty_name) LIKE '%pty. ltd%' OR
                        LOWER(counterparty_name) LIKE '% ltd%' OR
                        LOWER(counterparty_name) LIKE '%holdings%' OR
                        LOWER(counterparty_name) LIKE '%group%' OR
                        LOWER(counterparty_name) LIKE '%services%' OR
                        LOWER(counterparty_name) LIKE '%solutions%' OR
                        LOWER(counterparty_name) LIKE '%enterprises%' OR
                        LOWER(counterparty_name) LIKE '%industries%' OR
                        LOWER(counterparty_name) LIKE '%corp%' OR
                        LOWER(counterparty_name) LIKE '%cafe%' OR
                        LOWER(counterparty_name) LIKE '%restaurant%' OR
                        LOWER(counterparty_name) LIKE '%hotel%' OR
                        LOWER(counterparty_name) LIKE '%meats%' OR
                        LOWER(counterparty_name) LIKE '%bakery%' OR
                        LOWER(counterparty_name) LIKE '%automation%'
                    )
                    """, arguments: [siteId])

                // Get names that already have locations
                let locatedNames = try String.fetchAll(db, sql: """
                    SELECT counterparty_name FROM p2p_counterparty_locations
                    """)

                let locatedSet = Set(locatedNames)
                return allCommercial.filter { !locatedSet.contains($0) }
            } ?? []
        } catch {
            print("❌ Failed to get counterparties without locations: \(error)")
            return []
        }
    }
}
