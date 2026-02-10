//
//  P2PCounterpartyLocation.swift
//  Powston
//
//  Model for caching geocoded counterparty locations
//

import Foundation
import CoreLocation
import GRDB

struct P2PCounterpartyLocation: Identifiable, Equatable, Sendable {
    var id: UUID
    let counterpartyName: String
    let latitude: Double
    let longitude: Double
    let formattedAddress: String?
    let locality: String?           // City/suburb
    let administrativeArea: String? // State
    let searchedAt: Date
    let isVerified: Bool            // User confirmed this is correct

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - GRDB Persistence

extension P2PCounterpartyLocation: FetchableRecord, PersistableRecord {
    nonisolated static var databaseTableName: String { "p2p_counterparty_locations" }

    nonisolated init(row: Row) {
        let idString: String = row["id"]
        id = UUID(uuidString: idString) ?? UUID()
        counterpartyName = row["counterparty_name"]
        latitude = row["latitude"]
        longitude = row["longitude"]
        formattedAddress = row["formatted_address"]
        locality = row["locality"]
        administrativeArea = row["administrative_area"]
        searchedAt = row["searched_at"]
        isVerified = row["is_verified"]
    }

    nonisolated func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["counterparty_name"] = counterpartyName
        container["latitude"] = latitude
        container["longitude"] = longitude
        container["formatted_address"] = formattedAddress
        container["locality"] = locality
        container["administrative_area"] = administrativeArea
        container["searched_at"] = searchedAt
        container["is_verified"] = isVerified
    }
}

// MARK: - Search Result (not persisted, for UI selection)

struct P2PLocationSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    let locality: String?
    let administrativeArea: String?
}
