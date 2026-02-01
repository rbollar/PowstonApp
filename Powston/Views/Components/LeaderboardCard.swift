//
//  LeaderboardCard.swift
//  Powston
//
//  Leaderboard card for dashboard showing site ranking among all Powston sites
//

import SwiftUI

// MARK: - Data Models

struct RatesSite: Identifiable, Equatable {
    let siteId: Int
    let state: String
    let tariff: String
    let network: String
    let brand: String
    let inverterPower: Int
    let installedSolar: Int
    let installedBattery: Int
    let totalCosts: Double
    let totalEarnings: Double
    let buyRate: Double
    let sellRate: Double
    let expectedBill: Double
    let dailyCosts: Double
    let totalEnergyImported: Double
    let totalEnergyExported: Double
    let startTime: Date
    let endTime: Date
    
    var id: Int { siteId }
    var netBenefit: Double { totalEarnings - totalCosts }
    
    // Format net benefit as currency
    var formattedNetBenefit: String {
        let dollars = netBenefit / 100
        if abs(dollars) >= 1 {
            return String(format: "$%.2f", dollars)
        } else {
            return String(format: "%.1f¢", netBenefit)
        }
    }
    
    // Color for net benefit
    var netBenefitColor: Color {
        netBenefit >= 0 ? .green : .red
    }
}

// MARK: - Leaderboard State

@MainActor
class LeaderboardState: ObservableObject {
    @Published var sites: [RatesSite] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastFetchDate: Date?
    @Published var hasDataForToday = false
    
    private var api: PowstonAPI?
    
    func configure(api: PowstonAPI) {
        self.api = api
    }
    
    var mySiteIds: [Int] {
        api?.sites.map { $0.id } ?? []
    }
    
    var myRank: Int? {
        guard let mySiteId = api?.selectedSiteId else { return nil }
        // Sites are sorted by net benefit descending (best first)
        let sorted = sites.sorted { $0.netBenefit > $1.netBenefit }
        if let index = sorted.firstIndex(where: { $0.siteId == mySiteId }) {
            return index + 1
        }
        return nil
    }
    
    var mySite: RatesSite? {
        guard let mySiteId = api?.selectedSiteId else { return nil }
        return sites.first { $0.siteId == mySiteId }
    }
    
    var totalSites: Int {
        sites.count
    }
    
    func fetchRates(forDate date: Date = Date()) async {
        guard let api = api else { return }
        
        isLoading = true
        error = nil
        
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = powstonTimezone()
            let dateString = formatter.string(from: date)
            
            let urlString = "\(api.baseURL)/api/rates?start_date=\(dateString)&end_date=\(dateString)&direction=ASC&limit=2000"
            guard let url = URL(string: urlString) else {
                throw URLError(.badURL)
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "accept")
            request.setValue("Bearer \(api.apiKey)", forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            
            guard httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            
            // Parse JSON
            let decoded = try JSONDecoder().decode([RatesSiteDTO].self, from: data)
            
            sites = decoded.map { dto in
                RatesSite(
                    siteId: dto.site_id,
                    state: dto.state,
                    tariff: dto.tariff,
                    network: dto.network,
                    brand: dto.brand,
                    inverterPower: dto.inverter_power,
                    installedSolar: dto.installed_solar,
                    installedBattery: dto.installed_battery,
                    totalCosts: dto.total_costs,
                    totalEarnings: dto.total_earnings,
                    buyRate: dto.buy_rate,
                    sellRate: dto.sell_rate,
                    expectedBill: dto.expected_bill,
                    dailyCosts: dto.daily_costs,
                    totalEnergyImported: dto.total_energy_imported,
                    totalEnergyExported: dto.total_energy_exported,
                    startTime: ISO8601DateFormatter().date(from: dto.start_time) ?? Date(),
                    endTime: ISO8601DateFormatter().date(from: dto.end_time) ?? Date()
                )
            }
            
            lastFetchDate = date
            hasDataForToday = !sites.isEmpty
            
        } catch {
            self.error = error.localizedDescription
            hasDataForToday = false
        }
        
        isLoading = false
    }
}

// DTO for JSON decoding
private struct RatesSiteDTO: Codable {
    let site_id: Int
    let state: String
    let tariff: String
    let network: String
    let brand: String
    let inverter_power: Int
    let installed_solar: Int
    let installed_battery: Int
    let total_costs: Double
    let total_earnings: Double
    let buy_rate: Double
    let sell_rate: Double
    let expected_bill: Double
    let daily_costs: Double
    let total_energy_imported: Double
    let total_energy_exported: Double
    let start_time: String
    let end_time: String
}

// MARK: - Dashboard Card

struct LeaderboardCard: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var leaderboard = LeaderboardState()
    @State private var showFullLeaderboard = false
    
    var body: some View {
        Button(action: { showFullLeaderboard = true }) {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    Image(systemName: "trophy.fill")
                        .foregroundColor(.yellow)
                    Text("Leaderboard")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if leaderboard.isLoading {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading rankings...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if !leaderboard.hasDataForToday {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .foregroundColor(.secondary)
                        Text("Waiting for today's data")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if let rank = leaderboard.myRank, let mySite = leaderboard.mySite {
                    // Rank display
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        // Medal for top 3
                        if rank <= 3 {
                            Text(medalEmoji(for: rank))
                                .font(.title2)
                        }
                        
                        Text("#\(rank)")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(rankColor(rank))
                        
                        Text("of \(leaderboard.totalSites)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        // Net benefit
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(mySite.formattedNetBenefit)
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundColor(mySite.netBenefitColor)
                            Text("net benefit")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("Site not ranked today")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }
            }
            .padding()
            .background(Color.yellow.opacity(0.08))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showFullLeaderboard) {
            LeaderboardSheet(leaderboard: leaderboard)
        }
        .task {
            leaderboard.configure(api: api)
            await leaderboard.fetchRates()
        }
    }
    
    func medalEmoji(for rank: Int) -> String {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return ""
        }
    }
    
    func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .orange
        default: return .primary
        }
    }
}

// MARK: - Full Leaderboard Sheet

struct LeaderboardSheet: View {
    @ObservedObject var leaderboard: LeaderboardState
    @Environment(\.dismiss) private var dismiss
    
    // Filters
    @State private var selectedState: String? = nil
    @State private var selectedBrand: String? = nil
    @State private var batteryRangeMin: Int? = nil
    @State private var batteryRangeMax: Int? = nil
    @State private var showFilters = false
    
    var availableStates: [String] {
        Array(Set(leaderboard.sites.map { $0.state })).sorted()
    }
    
    var availableBrands: [String] {
        Array(Set(leaderboard.sites.map { $0.brand })).sorted()
    }
    
    var filteredSites: [RatesSite] {
        var result = leaderboard.sites
        
        if let state = selectedState {
            result = result.filter { $0.state == state }
        }
        if let brand = selectedBrand {
            result = result.filter { $0.brand == brand }
        }
        if let min = batteryRangeMin {
            result = result.filter { $0.installedBattery >= min * 1000 }
        }
        if let max = batteryRangeMax {
            result = result.filter { $0.installedBattery <= max * 1000 }
        }
        
        // Sort by net benefit descending
        return result.sorted { $0.netBenefit > $1.netBenefit }
    }
    
    var myRankInFiltered: Int? {
        guard let mySiteId = leaderboard.mySite?.siteId else { return nil }
        if let index = filteredSites.firstIndex(where: { $0.siteId == mySiteId }) {
            return index + 1
        }
        return nil
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter bar
                filterBar
                
                if leaderboard.isLoading {
                    Spacer()
                    ProgressView("Loading leaderboard...")
                    Spacer()
                } else if filteredSites.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "trophy")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No sites match filters")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    // Header row
                    HStack {
                        Text("Rank")
                            .frame(width: 50, alignment: .leading)
                        Text("Site")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Net Benefit")
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    
                    // Sites list
                    ScrollViewReader { proxy in
                        List {
                            ForEach(Array(filteredSites.enumerated()), id: \.element.id) { index, site in
                                LeaderboardRow(
                                    rank: index + 1,
                                    site: site,
                                    isMysite: leaderboard.mySiteIds.contains(site.siteId)
                                )
                                .id(site.siteId)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }
                        }
                        .listStyle(.plain)
                        .onAppear {
                            // Scroll to my site
                            if let mySite = leaderboard.mySite {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    withAnimation {
                                        proxy.scrollTo(mySite.siteId, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Leaderboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let rank = myRankInFiltered {
                        Text("#\(rank) of \(filteredSites.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    @ViewBuilder
    var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // State filter
                Menu {
                    Button("All States") { selectedState = nil }
                    Divider()
                    ForEach(availableStates, id: \.self) { state in
                        Button(state) { selectedState = state }
                    }
                } label: {
                    FilterChip(
                        label: selectedState ?? "State",
                        isActive: selectedState != nil
                    )
                }
                
                // Brand filter
                Menu {
                    Button("All Brands") { selectedBrand = nil }
                    Divider()
                    ForEach(availableBrands, id: \.self) { brand in
                        Button(brand) { selectedBrand = brand }
                    }
                } label: {
                    FilterChip(
                        label: selectedBrand ?? "Brand",
                        isActive: selectedBrand != nil
                    )
                }
                
                // Battery size presets
                Menu {
                    Button("Any Size") {
                        batteryRangeMin = nil
                        batteryRangeMax = nil
                    }
                    Divider()
                    Button("< 20 kWh") {
                        batteryRangeMin = nil
                        batteryRangeMax = 20
                    }
                    Button("20-50 kWh") {
                        batteryRangeMin = 20
                        batteryRangeMax = 50
                    }
                    Button("50-100 kWh") {
                        batteryRangeMin = 50
                        batteryRangeMax = 100
                    }
                    Button("> 100 kWh") {
                        batteryRangeMin = 100
                        batteryRangeMax = nil
                    }
                } label: {
                    FilterChip(
                        label: batteryRangeLabel,
                        isActive: batteryRangeMin != nil || batteryRangeMax != nil
                    )
                }
                
                // Clear all
                if selectedState != nil || selectedBrand != nil || batteryRangeMin != nil || batteryRangeMax != nil {
                    Button {
                        selectedState = nil
                        selectedBrand = nil
                        batteryRangeMin = nil
                        batteryRangeMax = nil
                    } label: {
                        Text("Clear")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color.gray.opacity(0.05))
    }
    
    var batteryRangeLabel: String {
        if let min = batteryRangeMin, let max = batteryRangeMax {
            return "\(min)-\(max) kWh"
        } else if let min = batteryRangeMin {
            return "> \(min) kWh"
        } else if let max = batteryRangeMax {
            return "< \(max) kWh"
        }
        return "Battery"
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let isActive: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.blue.opacity(0.15) : Color.gray.opacity(0.1))
        .foregroundColor(isActive ? .blue : .primary)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isActive ? Color.blue : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Leaderboard Row

struct LeaderboardRow: View {
    let rank: Int
    let site: RatesSite
    let isMysite: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Rank with medal
            HStack(spacing: 4) {
                if rank <= 3 {
                    Text(medalEmoji(for: rank))
                        .font(.body)
                }
                Text("#\(rank)")
                    .font(.subheadline)
                    .fontWeight(isMysite ? .bold : .regular)
                    .foregroundColor(rankColor)
            }
            .frame(width: 50, alignment: .leading)
            
            // Site info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(site.siteId)")
                        .font(.subheadline)
                        .fontWeight(isMysite ? .bold : .medium)
                    Text(site.state)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(4)
                    if isMysite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }
                }
                HStack(spacing: 8) {
                    Text(site.brand)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(site.installedBattery / 1000) kWh")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Net benefit
            Text(site.formattedNetBenefit)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(site.netBenefitColor)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .background(isMysite ? Color.yellow.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }
    
    func medalEmoji(for rank: Int) -> String {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return ""
        }
    }
    
    var rankColor: Color {
        if isMysite { return .primary }
        switch rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .orange
        default: return .primary
        }
    }
}

// MARK: - Preview

#Preview("Leaderboard Card") {
    VStack {
        LeaderboardCard()
            .padding()
    }
    .environmentObject(PowstonAPI())
}

#Preview("Leaderboard Sheet") {
    let state = LeaderboardState()
    // Add mock data
    return LeaderboardSheet(leaderboard: state)
}
