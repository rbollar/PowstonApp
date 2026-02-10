//
//  CounterpartyGeocodingService.swift
//  Powston
//
//  Service for geocoding P2P counterparty business names using Apple Maps
//

import Foundation
import MapKit
import CoreLocation
import Combine

@MainActor
class CounterpartyGeocodingService: ObservableObject {
    static let shared = CounterpartyGeocodingService()

    @Published var isSearching = false
    @Published var lastError: String?

    // Australia bounding box for search region
    private let australiaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -25.2744, longitude: 133.7751),
        span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
    )

    // More focused region for Queensland/NSW (NEM region)
    private let nemRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -27.5, longitude: 153.0), // Brisbane area
        span: MKCoordinateSpan(latitudeDelta: 15, longitudeDelta: 10)
    )

    private init() {}

    // MARK: - Search for Business

    /// Search for a business by name, returns multiple results for user selection
    func searchBusiness(name: String) async -> [P2PLocationSearchResult] {
        isSearching = true
        lastError = nil

        defer { isSearching = false }

        // Clean up the name for searching
        let searchQuery = cleanBusinessName(name)

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchQuery
        request.region = nemRegion
        request.resultTypes = .pointOfInterest

        do {
            let search = MKLocalSearch(request: request)
            let response = try await search.start()

            return response.mapItems.compactMap { item -> P2PLocationSearchResult? in
                guard let location = item.placemark.location else { return nil }

                let address = formatAddress(item.placemark)

                return P2PLocationSearchResult(
                    name: item.name ?? searchQuery,
                    address: address,
                    coordinate: location.coordinate,
                    locality: item.placemark.locality,
                    administrativeArea: item.placemark.administrativeArea
                )
            }
        } catch {
            lastError = "Search failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Search with broader Australia region if NEM search fails
    func searchBusinessWide(name: String) async -> [P2PLocationSearchResult] {
        isSearching = true
        lastError = nil

        defer { isSearching = false }

        let searchQuery = cleanBusinessName(name)

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchQuery
        request.region = australiaRegion
        request.resultTypes = .pointOfInterest

        do {
            let search = MKLocalSearch(request: request)
            let response = try await search.start()

            return response.mapItems.compactMap { item -> P2PLocationSearchResult? in
                guard let location = item.placemark.location else { return nil }

                let address = formatAddress(item.placemark)

                return P2PLocationSearchResult(
                    name: item.name ?? searchQuery,
                    address: address,
                    coordinate: location.coordinate,
                    locality: item.placemark.locality,
                    administrativeArea: item.placemark.administrativeArea
                )
            }
        } catch {
            lastError = "Search failed: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: - Batch Geocoding

    /// Geocode multiple counterparties (with rate limiting)
    func geocodeCounterparties(_ names: [String], delay: TimeInterval = 1.0) async -> [String: P2PLocationSearchResult] {
        var results: [String: P2PLocationSearchResult] = [:]

        for name in names {
            let searchResults = await searchBusiness(name: name)
            if let first = searchResults.first {
                results[name] = first
            }

            // Rate limit to avoid hitting API limits
            if name != names.last {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        return results
    }

    // MARK: - Helpers

    /// Clean business name for better search results
    private func cleanBusinessName(_ name: String) -> String {
        var cleaned = name

        // Remove common suffixes that might confuse search
        let suffixesToRemove = [
            " Pty Ltd", " Pty. Ltd", " Pty. Ltd.", " PTY LTD",
            " Ltd", " Ltd.", " LTD",
            " Inc", " Inc.",
            " Corp", " Corp.",
            " Holdings",
            " Group",
            " Australia"
        ]

        for suffix in suffixesToRemove {
            if cleaned.lowercased().hasSuffix(suffix.lowercased()) {
                cleaned = String(cleaned.dropLast(suffix.count))
            }
        }

        // Add "Australia" to improve local results
        return cleaned.trimmingCharacters(in: .whitespaces) + " Australia"
    }

    private func formatAddress(_ placemark: MKPlacemark) -> String {
        var components: [String] = []

        if let street = placemark.thoroughfare {
            if let number = placemark.subThoroughfare {
                components.append("\(number) \(street)")
            } else {
                components.append(street)
            }
        }

        if let locality = placemark.locality {
            components.append(locality)
        }

        if let state = placemark.administrativeArea {
            components.append(state)
        }

        return components.joined(separator: ", ")
    }
}
