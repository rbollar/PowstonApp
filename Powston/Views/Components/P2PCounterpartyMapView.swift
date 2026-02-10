//
//  P2PCounterpartyMapView.swift
//  Powston
//
//  Map view showing geocoded commercial counterparty locations
//

import SwiftUI
import MapKit

struct P2PCounterpartyMapView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var geocoder = CounterpartyGeocodingService.shared
    @StateObject private var classifier = P2PCounterpartyClassifier.shared

    @State private var locations: [P2PCounterpartyLocation] = []
    @State private var counterpartySummaries: [String: P2PCounterpartySummary] = [:]
    @State private var unmappedCounterparties: [P2PCounterpartySummary] = []
    @State private var selectedCounterparty: String?
    @State private var showSearchSheet = false
    @State private var searchResults: [P2PLocationSearchResult] = []
    @State private var isLoading = true

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -27.0, longitude: 153.0),
            span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
        )
    )

    var body: some View {
        ZStack {
            mapContent

            if isLoading {
                ProgressView("Loading locations...")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle("Buyer Map")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showSearchSheet = true
                    } label: {
                        Label("Add Location", systemImage: "plus")
                    }

                    if !unmappedCounterparties.isEmpty {
                        Divider()
                        Text("\(unmappedCounterparties.count) unmapped")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            counterpartySearchSheet
        }
        .onAppear { loadData() }
    }

    // MARK: - Map Content

    @ViewBuilder
    private var mapContent: some View {
        Map(position: $cameraPosition, selection: $selectedCounterparty) {
            // User's location marker (approximate - Sunshine Coast)
            Annotation("Your System", coordinate: CLLocationCoordinate2D(latitude: -26.65, longitude: 153.05)) {
                ZStack {
                    Circle()
                        .fill(.green)
                        .frame(width: 20, height: 20)
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundColor(.white)
                }
            }

            // Counterparty markers
            ForEach(locations) { location in
                let summary = counterpartySummaries[location.counterpartyName]
                let volume = summary?.totalVolumeKwh ?? 0

                Annotation(location.counterpartyName, coordinate: location.coordinate, anchor: .bottom) {
                    counterpartyMarker(location: location, volume: volume, isVerified: location.isVerified)
                }
                .tag(location.counterpartyName)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .bottom) {
            if let selected = selectedCounterparty,
               let location = locations.first(where: { $0.counterpartyName == selected }),
               let summary = counterpartySummaries[selected] {
                selectedCounterpartyCard(location: location, summary: summary)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) {
            statsOverlay
        }
    }

    // MARK: - Counterparty Marker

    private func counterpartyMarker(location: P2PCounterpartyLocation, volume: Double, isVerified: Bool) -> some View {
        let isSelected = selectedCounterparty == location.counterpartyName

        return VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(markerColor(volume: volume))
                    .frame(width: isSelected ? 36 : 28, height: isSelected ? 36 : 28)
                    .shadow(radius: 2)

                Image(systemName: "building.2.fill")
                    .font(isSelected ? .caption : .caption2)
                    .foregroundColor(.white)
            }

            // Pin tail
            Triangle()
                .fill(markerColor(volume: volume))
                .frame(width: 10, height: 6)
                .rotationEffect(.degrees(180))

            if isVerified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
                    .offset(y: -2)
            }
        }
        .animation(.spring(response: 0.3), value: isSelected)
    }

    private func markerColor(volume: Double) -> Color {
        switch volume {
        case 20...: return .purple
        case 10..<20: return .blue
        case 5..<10: return .cyan
        default: return .gray
        }
    }

    // MARK: - Stats Overlay

    private var statsOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.purple)
                Text("\(locations.count) mapped")
                    .font(.caption.bold())
            }

            if !unmappedCounterparties.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.orange)
                    Text("\(unmappedCounterparties.count) unmapped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Legend
            Divider()
            legendItem(color: .purple, label: "20+ kWh")
            legendItem(color: .blue, label: "10-20 kWh")
            legendItem(color: .cyan, label: "5-10 kWh")
            legendItem(color: .gray, label: "<5 kWh")
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .padding()
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Selected Counterparty Card

    private func selectedCounterpartyCard(location: P2PCounterpartyLocation, summary: P2PCounterpartySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.counterpartyName)
                        .font(.headline)
                        .lineLimit(1)

                    if let address = location.formattedAddress {
                        Text(address)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button {
                    selectedCounterparty = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text(String(format: "%.1f kWh", summary.totalVolumeKwh))
                        .font(.subheadline.bold())
                        .foregroundColor(.purple)
                    Text("volume")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading) {
                    Text(String(format: "$%.2f", summary.totalRevenue))
                        .font(.subheadline.bold())
                        .foregroundColor(.green)
                    Text("revenue")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading) {
                    Text("\(summary.tradeCount)")
                        .font(.subheadline.bold())
                    Text("trades")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !location.isVerified {
                    Button {
                        PowstonDataStore.shared.setLocationVerified(
                            counterpartyName: location.counterpartyName,
                            verified: true
                        )
                        loadLocations()
                    } label: {
                        Label("Verify", systemImage: "checkmark.seal")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                }
            }

            // Actions
            HStack(spacing: 12) {
                Button {
                    openInMaps(location: location)
                } label: {
                    Label("Open in Maps", systemImage: "map")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button {
                    // Re-search this counterparty
                    selectedCounterparty = nil
                    searchForCounterparty(summary)
                } label: {
                    Label("Re-search", systemImage: "magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    PowstonDataStore.shared.deleteCounterpartyLocation(name: location.counterpartyName)
                    selectedCounterparty = nil
                    loadData()
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.ultraThickMaterial)
        .cornerRadius(12)
        .padding()
    }

    // MARK: - Search Sheet (Split Pane)

    private var counterpartySearchSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top pane: Search results
                searchResultsPane
                    .frame(minHeight: 150)

                Divider()

                // Bottom pane: Unmapped counterparties
                unmappedCounterpartiesPane
            }
            .navigationTitle("Match Locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showSearchSheet = false
                        searchResults = []
                        searchingCounterparty = nil
                    }
                }
            }
        }
    }

    // MARK: - Search Results Pane (Top)

    private var searchResultsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with selected counterparty
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.blue)
                if let searching = searchingCounterparty {
                    Text(searching.counterpartyName)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer()
                    Button {
                        searchResults = []
                        searchingCounterparty = nil
                        manualSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Select a counterparty below to search")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))

            // Manual search field (shown when a counterparty is selected)
            if searchingCounterparty != nil {
                HStack(spacing: 8) {
                    TextField("Custom search...", text: $manualSearchText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit {
                            performManualSearch()
                        }

                    Button {
                        performManualSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualSearchText.trimmingCharacters(in: .whitespaces).isEmpty || geocoder.isSearching)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemBackground))
            }

            if geocoder.isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Text("Searching...")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding()
                Spacer()
            } else if searchResults.isEmpty && searchingCounterparty != nil {
                VStack(spacing: 8) {
                    Image(systemName: "mappin.slash")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("No results found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Try typing a shorter name or location above")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if searchResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Tap a counterparty below to search")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(searchResults) { result in
                        Button {
                            selectSearchResult(result)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.name)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text(result.address)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }

            if let error = geocoder.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1))
            }
        }
    }

    // MARK: - Manual Search

    private func performManualSearch() {
        let query = manualSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        Task {
            searchResults = await geocoder.searchBusiness(name: query)

            // If no results, try wider search
            if searchResults.isEmpty {
                searchResults = await geocoder.searchBusinessWide(name: query)
            }
        }
    }

    // MARK: - Unmapped Counterparties Pane (Bottom)

    private var unmappedCounterpartiesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "building.2")
                    .foregroundColor(.orange)
                Text("Unmapped (\(unmappedCounterparties.count))")
                    .font(.subheadline.bold())
                Spacer()

                // Progress indicator
                if !unmappedCounterparties.isEmpty {
                    let total = unmappedCounterparties.count + locations.count
                    let mapped = locations.count
                    Text("\(mapped)/\(total) mapped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))

            if unmappedCounterparties.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.green)
                    Text("All counterparties mapped!")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(unmappedCounterparties) { counterparty in
                        Button {
                            searchForCounterparty(counterparty)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(counterparty.counterpartyName)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(String(format: "%.1f kWh • %d trades", counterparty.totalVolumeKwh, counterparty.tradeCount))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                // Highlight if this is the one being searched
                                if searchingCounterparty?.counterpartyName == counterparty.counterpartyName {
                                    Image(systemName: "magnifyingglass.circle.fill")
                                        .foregroundColor(.blue)
                                } else {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.blue.opacity(0.5))
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        isLoading = true

        // Load counterparty summaries
        if let siteId = api.selectedSite?.id {
            let leaderboard = PowstonDataStore.shared.getP2PCounterpartyLeaderboard(siteId: siteId, limit: 200)

            // Filter to commercial only using classifier
            let commercialLeaderboard = leaderboard.filter { classifier.isCommercial($0.counterpartyName) }

            counterpartySummaries = Dictionary(uniqueKeysWithValues: commercialLeaderboard.map { ($0.counterpartyName, $0) })

            // Load cached locations
            loadLocations()

            // Find unmapped commercial counterparties
            let mappedNames = Set(locations.map { $0.counterpartyName })
            unmappedCounterparties = commercialLeaderboard.filter { !mappedNames.contains($0.counterpartyName) }
        }

        isLoading = false
    }

    private func loadLocations() {
        locations = PowstonDataStore.shared.getAllCounterpartyLocations()

        // Fit map to show all locations if we have any
        if !locations.isEmpty {
            fitMapToLocations()
        }
    }

    private func fitMapToLocations() {
        guard !locations.isEmpty else { return }

        let coordinates = locations.map { $0.coordinate }
        let minLat = coordinates.map { $0.latitude }.min() ?? -27.0
        let maxLat = coordinates.map { $0.latitude }.max() ?? -27.0
        let minLon = coordinates.map { $0.longitude }.min() ?? 153.0
        let maxLon = coordinates.map { $0.longitude }.max() ?? 153.0

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let span = MKCoordinateSpan(
            latitudeDelta: max(0.5, (maxLat - minLat) * 1.5),
            longitudeDelta: max(0.5, (maxLon - minLon) * 1.5)
        )

        cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }

    // MARK: - Search Actions

    @State private var searchingCounterparty: P2PCounterpartySummary?
    @State private var manualSearchText: String = ""

    private func searchForCounterparty(_ counterparty: P2PCounterpartySummary) {
        searchingCounterparty = counterparty
        showSearchSheet = true
        manualSearchText = ""  // Clear any previous manual search

        Task {
            searchResults = await geocoder.searchBusiness(name: counterparty.counterpartyName)

            // If no results, try wider search
            if searchResults.isEmpty {
                searchResults = await geocoder.searchBusinessWide(name: counterparty.counterpartyName)
            }
        }
    }

    private func selectSearchResult(_ result: P2PLocationSearchResult) {
        guard let counterparty = searchingCounterparty else { return }

        PowstonDataStore.shared.saveCounterpartyLocation(
            counterpartyName: counterparty.counterpartyName,
            coordinate: result.coordinate,
            address: result.address,
            locality: result.locality,
            administrativeArea: result.administrativeArea,
            isVerified: false
        )

        // Clear search but stay in sheet to match more
        searchResults = []
        searchingCounterparty = nil
        manualSearchText = ""

        // Refresh the data (updates unmapped list)
        loadData()

        // Note: We don't close the sheet or change map position
        // User can continue matching more counterparties
    }

    private func openInMaps(location: P2PCounterpartyLocation) {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        mapItem.name = location.counterpartyName
        mapItem.openInMaps()
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        P2PCounterpartyMapView()
            .environmentObject(PowstonAPI())
    }
}
