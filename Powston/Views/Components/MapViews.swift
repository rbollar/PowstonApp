//
//  MapViews.swift
//  Powston
//

import SwiftUI
import MapKit

// MARK: - Site Detail View
struct SiteDetailView: View {
    let site: Site
    @State private var position: MapCameraPosition
    
    init(site: Site) {
        self.site = site
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: site.latitude ?? -26.5,
                longitude: site.longitude ?? 153.0
            ),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )))
    }
    
    var body: some View {
        List {
            if site.latitude != nil && site.longitude != nil {
                Section {
                    Map(position: $position) {
                        Marker(site.displayName ?? site.name, coordinate: CLLocationCoordinate2D(
                            latitude: site.latitude!,
                            longitude: site.longitude!
                        ))
                        .tint(.green)
                    }
                    .frame(height: 200)
                    .cornerRadius(12)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle(site.displayName ?? site.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - All Sites Map View
struct AllSitesMapView: View {
    let sites: [Site]
    @State private var position: MapCameraPosition
    @State private var selectedSite: Site?
    
    init(sites: [Site]) {
        self.sites = sites
        
        let validSites = sites.filter { $0.latitude != nil && $0.longitude != nil }
        
        if validSites.isEmpty {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: -25.0, longitude: 135.0),
                span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)
            )))
        } else if validSites.count == 1 {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: validSites[0].latitude!,
                    longitude: validSites[0].longitude!
                ),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )))
        } else {
            let lats = validSites.compactMap { $0.latitude }
            let lons = validSites.compactMap { $0.longitude }
            
            let minLat = lats.min()!, maxLat = lats.max()!
            let minLon = lons.min()!, maxLon = lons.max()!
            
            let centerLat = (minLat + maxLat) / 2
            let centerLon = (minLon + maxLon) / 2
            let spanLat = (maxLat - minLat) * 1.5 + 0.1
            let spanLon = (maxLon - minLon) * 1.5 + 0.1
            
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: max(spanLat, 0.05), longitudeDelta: max(spanLon, 0.05))
            )))
        }
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $position) {
                ForEach(sites.filter { $0.latitude != nil && $0.longitude != nil }) { site in
                    Annotation(site.displayName ?? site.name, coordinate: CLLocationCoordinate2D(
                        latitude: site.latitude!,
                        longitude: site.longitude!
                    )) {
                        SiteMapPin(site: site, isSelected: selectedSite?.id == site.id)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if selectedSite?.id == site.id {
                                        selectedSite = nil
                                    } else {
                                        selectedSite = site
                                    }
                                }
                            }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
            
            if let site = selectedSite {
                SiteInfoCard(site: site, onClose: { selectedSite = nil })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding()
            }
            
            if selectedSite == nil {
                VStack {
                    Spacer()
                    SitesLegend(sites: sites)
                        .padding()
                }
            }
        }
        .navigationTitle("All Sites")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: fitAllSites) {
                        Label("Fit All Sites", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Divider()
                    ForEach(sites.filter { $0.latitude != nil }) { site in
                        Button(action: { zoomToSite(site) }) {
                            Label(site.displayName ?? site.name, systemImage: "mappin")
                        }
                    }
                } label: {
                    Image(systemName: "location.magnifyingglass")
                }
            }
        }
    }
    
    func fitAllSites() {
        let validSites = sites.filter { $0.latitude != nil && $0.longitude != nil }
        guard !validSites.isEmpty else { return }
        
        let lats = validSites.compactMap { $0.latitude }
        let lons = validSites.compactMap { $0.longitude }
        
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let spanLat = (maxLat - minLat) * 1.5 + 0.1
        let spanLon = (maxLon - minLon) * 1.5 + 0.1
        
        withAnimation {
            position = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: max(spanLat, 0.05), longitudeDelta: max(spanLon, 0.05))
            ))
        }
    }
    
    func zoomToSite(_ site: Site) {
        guard let lat = site.latitude, let lon = site.longitude else { return }
        withAnimation {
            position = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
            selectedSite = site
        }
    }
}

// MARK: - Site Map Pin
struct SiteMapPin: View {
    let site: Site
    let isSelected: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(brandColor.opacity(0.2))
                    .frame(width: isSelected ? 50 : 40, height: isSelected ? 50 : 40)
                
                Circle()
                    .fill(brandColor)
                    .frame(width: isSelected ? 36 : 28, height: isSelected ? 36 : 28)
                    .shadow(color: .black.opacity(0.2), radius: 3)
                
                Image(systemName: brandIcon)
                    .font(isSelected ? .body : .caption)
                    .foregroundColor(.white)
            }
            
            Triangle()
                .fill(brandColor)
                .frame(width: 12, height: 8)
                .offset(y: -2)
            
            if isSelected {
                Text(site.displayName ?? site.name)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemBackground))
                    .cornerRadius(4)
                    .shadow(color: .black.opacity(0.1), radius: 2)
                    .offset(y: 4)
            }
        }
    }
    
    var brandColor: Color {
        switch site.brand?.uppercased() {
        case "SUNGROW": return .orange
        case "GOODWE": return .blue
        case "FRONIUS": return .red
        case "TESLA": return .gray
        case "ENPHASE": return .orange
        case "SOLAREDGE": return .green
        case "DEYE": return .purple
        default: return .green
        }
    }
    
    var brandIcon: String {
        switch site.brand?.uppercased() {
        case "SUNGROW": return "sun.max.fill"
        case "TESLA": return "bolt.fill"
        default: return "bolt.fill"
        }
    }
}

// MARK: - Site Info Card
struct SiteInfoCard: View {
    let site: Site
    let onClose: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.displayName ?? site.name)
                        .font(.headline)
                    Text(site.location ?? "\(site.state)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            HStack(spacing: 16) {
                StatPill(icon: "bolt.fill", label: site.brand ?? "Unknown", color: .orange)
                StatPill(icon: "network", label: site.network.capitalized, color: .blue)
                StatPill(icon: retailerIcon, label: detectedRetailer, color: .green)
            }
            
            HStack(spacing: 20) {
                if let solar = site.installedSolar {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Solar")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(formatPower(solar))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.yellow)
                    }
                }
                
                if let battery = site.installedBattery {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Battery")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(formatEnergy(battery))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    }
                }
                
                if let gridLimit = site.gridPowerLimit {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grid Limit")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(formatPower(gridLimit))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                    }
                }
                
                Spacer()
            }
            
            HStack(spacing: 12) {
                if site.controlled == true {
                    StatusBadge(text: "Controlled", color: .green)
                }
                if site.haPublish == true {
                    StatusBadge(text: "HA", color: .blue)
                }
                if site.pvoutputSiteId != nil {
                    StatusBadge(text: "PVOutput", color: .orange)
                }
                Spacer()
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.15), radius: 10)
    }
    
    var detectedRetailer: String {
        if site.localvoltsKey != nil || site.localvoltsPartnerId != nil {
            return "LocalVolts"
        } else if site.amberKey != nil || site.amberSiteId != nil {
            return "Amber"
        } else {
            return "Unknown"
        }
    }
    
    var retailerIcon: String {
        if site.localvoltsKey != nil || site.localvoltsPartnerId != nil {
            return "bolt.circle"
        } else if site.amberKey != nil || site.amberSiteId != nil {
            return "leaf.circle"
        } else {
            return "questionmark.circle"
        }
    }
    
    func formatPower(_ watts: Int) -> String {
        if watts >= 1000 {
            return String(format: "%.1f kW", Double(watts) / 1000)
        }
        return "\(watts) W"
    }
    
    func formatEnergy(_ wattHours: Int) -> String {
        if wattHours >= 1000 {
            return String(format: "%.1f kWh", Double(wattHours) / 1000)
        }
        return "\(wattHours) Wh"
    }
}

// MARK: - Sites Legend
struct SitesLegend: View {
    let sites: [Site]
    
    var body: some View {
        HStack(spacing: 12) {
            let brands = Dictionary(grouping: sites, by: { $0.brand ?? "Unknown" })
            
            ForEach(Array(brands.keys.sorted()), id: \.self) { brand in
                HStack(spacing: 4) {
                    Circle()
                        .fill(brandColor(brand))
                        .frame(width: 10, height: 10)
                    Text("\(brand): \(brands[brand]?.count ?? 0)")
                        .font(.caption2)
                }
            }
            
            Spacer()
            
            Text("\(sites.count) sites")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
    }
    
    func brandColor(_ brand: String) -> Color {
        switch brand.uppercased() {
        case "SUNGROW": return .orange
        case "GOODWE": return .blue
        case "FRONIUS": return .red
        case "TESLA": return .gray
        case "ENPHASE": return .orange
        case "SOLAREDGE": return .green
        case "DEYE": return .purple
        default: return .green
        }
    }
}
