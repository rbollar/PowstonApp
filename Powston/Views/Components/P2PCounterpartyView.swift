//
//  P2PCounterpartyView.swift
//  Powston
//
//  Counterparty leaderboard and detail views for P2P trading
//  Enables tracking buyer patterns for relationship building
//

import SwiftUI

// MARK: - Counterparty Leaderboard View

struct P2PCounterpartyView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var classifier = P2PCounterpartyClassifier.shared
    @State private var leaderboard: [P2PCounterpartySummary] = []
    @State private var isLoading = true
    @State private var selectedCounterparty: P2PCounterpartySummary?
    @State private var filterMode: FilterMode = .all
    @State private var sortMode: SortMode = .volume
    @State private var bidirectionalNames: Set<String> = []
    @State private var cleanupMessage: String?
    @State private var showCleanupAlert = false
    @State private var includeContracts: Bool = false  // Show only actual trades by default

    /// Filter by trade direction (nil = all)
    var directionFilter: P2PTradeDirection?
    
    enum FilterMode: String, CaseIterable {
        case all = "All"
        case commercial = "Commercial"
        case residential = "Residential"
        case premium = "Premium"
    }
    
    enum SortMode: String, CaseIterable {
        case volume = "Volume"
        case revenue = "Revenue"
        case trades = "Trades"
        case price = "Avg Price"
        case recent = "Recent"
    }
    
    /// Reclassify counterparties using the classifier (picks up manual overrides)
    private func classifiedLeaderboard() -> [P2PCounterpartySummary] {
        leaderboard.map { summary in
            let isCommercial = classifier.isCommercial(summary.counterpartyName)
            // Return updated summary with correct classification
            return P2PCounterpartySummary(
                counterpartyName: summary.counterpartyName,
                totalVolumeKwh: summary.totalVolumeKwh,
                totalRevenue: summary.totalRevenue,
                tradeCount: summary.tradeCount,
                avgPriceCents: summary.avgPriceCents,
                minPriceCents: summary.minPriceCents,
                maxPriceCents: summary.maxPriceCents,
                firstTradeDate: summary.firstTradeDate,
                lastTradeDate: summary.lastTradeDate,
                isCommercial: isCommercial
            )
        }
    }
    
    var filteredAndSorted: [P2PCounterpartySummary] {
        var result = classifiedLeaderboard()
        
        // Apply filter
        switch filterMode {
        case .all:
            break
        case .commercial:
            result = result.filter { $0.isCommercial }
        case .residential:
            result = result.filter { !$0.isCommercial }
        case .premium:
            result = result.filter { $0.avgPriceCents >= 25.0 }
        }
        
        // Apply sort
        switch sortMode {
        case .volume:
            result.sort { $0.totalVolumeKwh > $1.totalVolumeKwh }
        case .revenue:
            result.sort { $0.totalRevenue > $1.totalRevenue }
        case .trades:
            result.sort { $0.tradeCount > $1.tradeCount }
        case .price:
            result.sort { $0.avgPriceCents > $1.avgPriceCents }
        case .recent:
            result.sort { $0.lastTradeDate > $1.lastTradeDate }
        }
        
        return result
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isLoading {
                    ProgressView("Loading counterparties...")
                        .padding(.vertical, 40)
                } else if leaderboard.isEmpty {
                    emptyState
                } else {
                    statsHeader
                    filterControls
                    counterpartyList
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Counterparties")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    NavigationLink {
                        P2PCounterpartyMapView()
                            .environmentObject(api)
                    } label: {
                        Label("View Map", systemImage: "map")
                    }

                    Divider()

                    Button {
                        forceCleanupOrphans()
                    } label: {
                        Label("Cleanup Orphaned Data", systemImage: "trash.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $selectedCounterparty) { counterparty in
            P2PCounterpartyDetailView(counterparty: counterparty, includeContracts: includeContracts)
                .environmentObject(api)
        }
        .onAppear { loadLeaderboard() }
        .refreshable { await refreshLeaderboard() }
        .alert("Cleanup Complete", isPresented: $showCleanupAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(cleanupMessage ?? "Cleanup finished")
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No Counterparty Data")
                .font(.headline)
            
            Text("Import P2P trade data from LocalVolts to see your counterparty breakdown and identify potential partners.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
    
    // MARK: - Stats Header
    
    private var statsHeader: some View {
        let stats = calculateStats()
        
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.purple)
                Text("Overview")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            HStack(spacing: 16) {
                statBox(value: "\(stats.total)", label: "Total", color: .primary)
                statBox(value: "\(stats.commercial)", label: "Commercial", color: .blue)
                statBox(value: "\(stats.residential)", label: "Residential", color: .green)
                statBox(value: "\(stats.premium)", label: "Premium", color: .purple)
            }
            
            if let topCounterparty = leaderboard.first {
                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "crown.fill")
                        .foregroundColor(.yellow)
                    Text(directionFilter == .buy ? "Top seller:" : "Top buyer:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(topCounterparty.counterpartyName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f kWh", topCounterparty.totalVolumeKwh))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.purple)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func statBox(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    private func calculateStats() -> (total: Int, commercial: Int, residential: Int, premium: Int) {
        let commercial = leaderboard.filter { $0.isCommercial }.count
        let residential = leaderboard.count - commercial
        let premium = leaderboard.filter { $0.avgPriceCents >= 25.0 }.count
        return (leaderboard.count, commercial, residential, premium)
    }
    
    // MARK: - Filter Controls

    private var filterControls: some View {
        VStack(spacing: 8) {
            // Actual vs Contracts toggle
            HStack {
                Text("Show:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Trade Type", selection: $includeContracts) {
                    Text("Actual").tag(false)
                    Text("+ Contracts").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                .onChange(of: includeContracts) { _, _ in
                    loadLeaderboard()
                }

                Spacer()
            }

            // Filter picker
            Picker("Filter", selection: $filterMode) {
                ForEach(FilterMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // Sort picker
            HStack {
                Text("Sort by:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Sort", selection: $sortMode) {
                    ForEach(SortMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                Text("\(filteredAndSorted.count) shown")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Counterparty List
    
    private var counterpartyList: some View {
        LazyVStack(spacing: 8) {
            ForEach(Array(filteredAndSorted.enumerated()), id: \.element.id) { index, counterparty in
                counterpartyRow(counterparty, rank: index + 1)
                    .onTapGesture {
                        selectedCounterparty = counterparty
                    }
            }
        }
    }
    
    private func counterpartyRow(_ counterparty: P2PCounterpartySummary, rank: Int) -> some View {
        let hasOverride = classifier.hasManualOverride(counterparty.counterpartyName)
        
        return HStack(spacing: 12) {
            // Rank badge
            ZStack {
                Circle()
                    .fill(rankColor(rank))
                    .frame(width: 28, height: 28)
                Text("\(rank)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
            }
            
            // Name and type
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(counterparty.counterpartyName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if counterparty.isCommercial {
                        Image(systemName: "building.2.fill")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }

                    // Show bidirectional trading indicator (direct negotiation opportunity)
                    if bidirectionalNames.contains(counterparty.counterpartyName) {
                        Image(systemName: "arrow.left.arrow.right.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.purple)
                    }

                    // Show manual override indicator
                    if hasOverride {
                        Image(systemName: "hand.point.up.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                
                HStack(spacing: 8) {
                    Text("\(counterparty.tradeCount) trades")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text(String(format: "%.1f¢ avg", counterparty.avgPriceCents))
                        .font(.caption2)
                        .foregroundColor(counterparty.avgPriceCents >= 25 ? .green : .secondary)
                }
            }
            
            Spacer()
            
            // Volume and revenue
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f kWh", counterparty.totalVolumeKwh))
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundColor(.purple)
                
                Text(formatCurrency(counterparty.totalRevenue))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.green)
            }
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .contextMenu {
            // Classification override options
            Button {
                classifier.setManualOverride(counterparty.counterpartyName, type: .commercial)
            } label: {
                Label("Mark as Commercial", systemImage: "building.2.fill")
            }

            Button {
                classifier.setManualOverride(counterparty.counterpartyName, type: .residential)
            } label: {
                Label("Mark as Residential", systemImage: "person.fill")
            }

            if hasOverride {
                Divider()

                Button(role: .destructive) {
                    classifier.removeManualOverride(counterparty.counterpartyName)
                } label: {
                    Label("Remove Override", systemImage: "xmark.circle")
                }
            }

            Divider()

            // Delete counterparty option
            Button(role: .destructive) {
                deleteCounterparty(counterparty)
            } label: {
                Label("Delete Counterparty", systemImage: "trash")
            }
        }
    }
    
    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .orange
        default: return .secondary.opacity(0.5)
        }
    }
    
    // MARK: - Data Loading
    
    private func loadLeaderboard() {
        guard let siteId = api.selectedSite?.id else {
            isLoading = false
            return
        }

        isLoading = true

        // Deduplicate LV trades first (removes duplicates from floating-point timestamp issues)
        let dupsRemoved = PowstonDataStore.shared.deduplicateLVTrades(siteId: siteId)
        if dupsRemoved > 0 {
            print("🧹 Removed \(dupsRemoved) duplicate LV trades on leaderboard load")
        }

        // Clean up any orphaned counterparty trades (parent trade record was deleted)
        let cleanedUp = PowstonDataStore.shared.cleanupOrphanedCounterpartyTrades(siteId: siteId)
        if cleanedUp > 0 {
            print("🧹 Cleaned up \(cleanedUp) orphaned counterparty trades")
        }

        leaderboard = PowstonDataStore.shared.getP2PCounterpartyLeaderboard(siteId: siteId, limit: 100, direction: directionFilter, includeContracts: includeContracts)
        bidirectionalNames = PowstonDataStore.shared.getBidirectionalCounterparties(siteId: siteId)
        isLoading = false

        // Trigger AI classification for uncertain counterparties (runs in background)
        let names = leaderboard.map { $0.counterpartyName }
        classifier.requestAIClassificationIfNeeded(names)
    }

    private func refreshLeaderboard() async {
        guard let siteId = api.selectedSite?.id else { return }
        leaderboard = PowstonDataStore.shared.getP2PCounterpartyLeaderboard(siteId: siteId, limit: 100, direction: directionFilter, includeContracts: includeContracts)
        bidirectionalNames = PowstonDataStore.shared.getBidirectionalCounterparties(siteId: siteId)

        // Trigger AI classification for uncertain counterparties
        let names = leaderboard.map { $0.counterpartyName }
        classifier.requestAIClassificationIfNeeded(names)
    }

    private func deleteCounterparty(_ counterparty: P2PCounterpartySummary) {
        guard let siteId = api.selectedSite?.id else { return }

        let deleted = PowstonDataStore.shared.deleteCounterparty(siteId: siteId, name: counterparty.counterpartyName)
        if deleted > 0 {
            print("🗑️ Deleted counterparty '\(counterparty.counterpartyName)' (\(deleted) trades)")
            // Refresh the leaderboard
            loadLeaderboard()
        }
    }

    private func forceCleanupOrphans() {
        guard let siteId = api.selectedSite?.id else { return }

        // Run cleanup - this deletes orphaned trades and syncs to iCloud
        let deleted = PowstonDataStore.shared.cleanupOrphanedCounterpartyTrades(siteId: siteId)

        if deleted > 0 {
            cleanupMessage = "Removed \(deleted) orphaned trade\(deleted == 1 ? "" : "s") and synced to iCloud."
            loadLeaderboard()
        } else {
            cleanupMessage = "No orphaned data found. All counterparties have valid trade records."
        }
        showCleanupAlert = true
    }
    
    // MARK: - Helpers
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
}

// MARK: - Counterparty Detail View

struct P2PCounterpartyDetailView: View {
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.dismiss) var dismiss
    @StateObject private var classifier = P2PCounterpartyClassifier.shared

    let counterparty: P2PCounterpartySummary
    let includeContracts: Bool  // Whether to include future contracts or just actual trades

    @State private var tradeHistory: [P2PCounterpartyTradeHistory] = []
    @State private var allTrades: [P2PCounterpartyTrade] = []  // Raw trades for stats
    @State private var lvTrades: [LVIntervalTrade] = []  // Individual interval trades from LocalVolts
    @State private var expandedDays: Set<Date> = []  // Which days are expanded in individual trades view
    @State private var isLoading = true
    @State private var showDeleteConfirmation = false

    init(counterparty: P2PCounterpartySummary, includeContracts: Bool = false) {
        self.counterparty = counterparty
        self.includeContracts = includeContracts
    }

    // MARK: - Computed Stats from Fresh Data

    /// Total volume computed from all trades (not stale leaderboard data)
    private var computedTotalVolume: Double {
        allTrades.reduce(0) { $0 + $1.volumeKwh }
    }

    /// Total revenue computed from all trades
    private var computedTotalRevenue: Double {
        allTrades.reduce(0) { $0 + $1.revenue }
    }

    /// Total trade count
    private var computedTradeCount: Int {
        allTrades.count
    }

    /// Average price (volume-weighted)
    private var computedAvgPrice: Double {
        let totalVolume = computedTotalVolume
        guard totalVolume > 0 else { return 0 }
        let weightedSum = allTrades.reduce(0) { $0 + $1.volumeKwh * $1.priceCents }
        return weightedSum / totalVolume
    }

    /// Price range
    private var computedPriceRange: (min: Double, max: Double) {
        guard !allTrades.isEmpty else { return (0, 0) }
        let prices = allTrades.map { $0.priceCents }
        return (prices.min() ?? 0, prices.max() ?? 0)
    }

    /// First and last trade dates
    private var computedDateRange: (first: Date, last: Date) {
        guard !allTrades.isEmpty else { return (Date(), Date()) }
        let dates = allTrades.map { $0.tradeDate }
        return (dates.min() ?? Date(), dates.max() ?? Date())
    }

    /// Check if this counterparty trades in both directions (buy AND sell)
    private var isBidirectional: Bool {
        let directions = Set(allTrades.map { $0.direction })
        return directions.contains(.sell) && directions.contains(.buy)
    }

    /// Sell trades only
    private var sellTrades: [P2PCounterpartyTrade] {
        allTrades.filter { $0.direction == .sell }
    }

    /// Buy trades only
    private var buyTrades: [P2PCounterpartyTrade] {
        allTrades.filter { $0.direction == .buy }
    }

    /// Get current classification (respects overrides)
    private var currentlyCommercial: Bool {
        classifier.isCommercial(counterparty.counterpartyName)
    }

    private var hasOverride: Bool {
        classifier.hasManualOverride(counterparty.counterpartyName)
    }

    private var classificationSource: String {
        let result = classifier.classify(counterparty.counterpartyName)
        return result.source.rawValue
    }

    /// Unique facilities from LV trades
    private var uniqueFacilities: [String] {
        Array(Set(lvTrades.compactMap { $0.cpFacility })).sorted()
    }

    /// Group trades by facility
    private var tradesByFacility: [String: [LVIntervalTrade]] {
        Dictionary(grouping: lvTrades.filter { $0.cpFacility != nil }) { $0.cpFacility! }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    summaryCard
                    classificationCard
                    statsCard
                    
                    if !tradeHistory.isEmpty {
                        historyCard
                    }

                    // Individual interval trades from LocalVolts WebSocket
                    if !lvTrades.isEmpty {
                        individualTradesCard
                    }

                    // Facility breakdown (if available from LV data)
                    if !uniqueFacilities.isEmpty {
                        facilityBreakdownCard
                    }

                    outreachCard
                }
                .padding()
            }
            .navigationTitle(counterparty.counterpartyName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .alert("Delete Counterparty", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    deleteCounterparty()
                }
            } message: {
                Text("Delete all \(allTrades.count) trades for '\(counterparty.counterpartyName)'? This cannot be undone.")
            }
            .onAppear { loadHistory() }
        }
    }
    
    // MARK: - Summary Card

    private var summaryCard: some View {
        let isUsingLVData = !lvTrades.isEmpty

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                if currentlyCommercial {
                    Image(systemName: "building.2.fill")
                        .foregroundColor(.blue)
                    Text("Commercial Buyer")
                        .font(.headline)
                } else {
                    Image(systemName: "person.fill")
                        .foregroundColor(.green)
                    Text("Residential Buyer")
                        .font(.headline)
                }
                Spacer()

                // Show data source and filter mode
                if isUsingLVData {
                    Text("LocalVolts")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }

                if includeContracts {
                    Text("+ Contracts")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2))
                        .foregroundColor(.purple)
                        .cornerRadius(4)
                } else {
                    Text("Actual")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }

                if hasOverride {
                    Text("Manual")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                }
            }

            // Bidirectional trading opportunity highlight
            if isBidirectional {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .foregroundColor(.purple)
                    Text("Direct Negotiation Opportunity")
                        .font(.subheadline.bold())
                        .foregroundColor(.purple)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.purple.opacity(0.15))
                .cornerRadius(8)

                Text("You both buy from AND sell to this counterparty. Consider a direct P2P contract for better rates.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Use computed stats from fresh trade data
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.2f kWh", computedTotalVolume))
                        .font(.title2.bold())
                        .foregroundColor(.purple)
                    Text("total volume")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(formatCurrency(computedTotalRevenue))
                        .font(.title2.bold())
                        .foregroundColor(.green)
                    Text("total revenue")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            // Show sell/buy breakdown if bidirectional
            if isBidirectional {
                Divider()
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text(String(format: "%.2f kWh", sellTrades.reduce(0) { $0 + $1.volumeKwh }))
                                .font(.subheadline.bold())
                        }
                        Text("sold to them")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text(String(format: "%.2f kWh", buyTrades.reduce(0) { $0 + $1.volumeKwh }))
                                .font(.subheadline.bold())
                        }
                        Text("bought from them")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Classification Card
    
    private var classificationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "tag.fill")
                    .foregroundColor(.purple)
                Text("Classification")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            // Current classification with source
            HStack {
                Text("Type:")
                    .foregroundColor(.secondary)
                Text(currentlyCommercial ? "Commercial" : "Residential")
                    .fontWeight(.medium)
                
                Spacer()
                
                Text("Source: \(classificationSource)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Override buttons
            HStack(spacing: 12) {
                Button {
                    classifier.setManualOverride(counterparty.counterpartyName, type: .commercial)
                } label: {
                    Label("Commercial", systemImage: "building.2.fill")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(currentlyCommercial ? Color.blue : Color.blue.opacity(0.15))
                        .foregroundColor(currentlyCommercial ? .white : .blue)
                        .cornerRadius(8)
                }
                
                Button {
                    classifier.setManualOverride(counterparty.counterpartyName, type: .residential)
                } label: {
                    Label("Residential", systemImage: "person.fill")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(!currentlyCommercial ? Color.green : Color.green.opacity(0.15))
                        .foregroundColor(!currentlyCommercial ? .white : .green)
                        .cornerRadius(8)
                }
            }
            
            // Reset option if manually overridden
            if hasOverride {
                Button {
                    classifier.removeManualOverride(counterparty.counterpartyName)
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset to automatic classification")
                    }
                    .font(.caption)
                    .foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Stats Card

    private var statsCard: some View {
        // Compute values from fresh trade data
        let tradeCount = computedTradeCount
        let avgPrice = computedAvgPrice
        let priceRange = computedPriceRange
        let dateRange = computedDateRange
        let avgPerTrade = tradeCount > 0 ? computedTotalVolume / Double(tradeCount) : 0
        let daysSinceLast = Calendar.current.dateComponents([.day], from: dateRange.last, to: Date()).day ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundColor(.orange)
                Text("Trading Stats")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Stats grid using computed values
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                statItem(label: "Trades", value: "\(tradeCount)")
                statItem(label: "Avg Price", value: String(format: "%.1f¢", avgPrice), color: avgPrice >= 25 ? .green : .orange)
                statItem(label: "Price Range", value: String(format: "%.0f–%.0f¢", priceRange.min, priceRange.max))
                statItem(label: "Avg/Trade", value: String(format: "%.2f kWh", avgPerTrade))
                statItem(label: "First Trade", value: formatDate(dateRange.first))
                statItem(label: "Last Trade", value: formatDate(dateRange.last))
            }

            if daysSinceLast > 14 {
                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundColor(.orange)
                    Text("No trades in \(daysSinceLast) days")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func statItem(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - History Card
    
    private var historyCard: some View {
        let isUsingLVData = !lvTrades.isEmpty
        let totalTrades = tradeHistory.reduce(0) { $0 + $1.tradeCount }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.cyan)
                Text("Trade History")
                    .font(.headline)

                // Show data source indicator
                if isUsingLVData {
                    Text("LV")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }

                Spacer()
                if isUsingLVData {
                    Text("\(totalTrades) intervals in \(tradeHistory.count) days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if totalTrades != tradeHistory.count {
                    Text("\(totalTrades) trades in \(tradeHistory.count) imports")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(tradeHistory.count) imports")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()

            // Header
            HStack {
                Text("")
                    .frame(width: 20)  // Direction icon column
                Text("Date")
                    .frame(width: 60, alignment: .leading)
                Text("kWh")
                    .frame(width: 50, alignment: .trailing)
                Text("Price")
                    .frame(width: 50, alignment: .trailing)
                Text("Revenue")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.secondary)

            ForEach(tradeHistory.prefix(20)) { trade in
                VStack(spacing: 2) {
                    HStack {
                        // Direction indicator
                        Image(systemName: trade.direction == .sell ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundColor(trade.direction == .sell ? .orange : .blue)
                            .font(.caption)
                            .frame(width: 20)

                        // Show import range instead of just trade_date
                        if let rangeStr = trade.importRangeString {
                            Text(rangeStr)
                                .frame(width: 60, alignment: .leading)
                        } else {
                            Text(formatDate(trade.tradeDate))
                                .frame(width: 60, alignment: .leading)
                        }
                        Text(String(format: "%.2f", trade.volumeKwh))
                            .frame(width: 50, alignment: .trailing)
                        Text(String(format: "%.1f¢", trade.priceCents))
                            .frame(width: 50, alignment: .trailing)
                            .foregroundColor(trade.priceCents >= 25 ? .green : .orange)
                        Text(formatCurrency(trade.revenue))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(trade.direction == .sell ? .green : .red)
                    }
                    .font(.caption.monospacedDigit())

                    // Show trade count if multiple trades were combined
                    if trade.tradeCount > 1 {
                        HStack {
                            Spacer().frame(width: 20)
                            Text("(\(trade.tradeCount) trades in this import)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            
            if tradeHistory.count > 20 {
                Text("+ \(tradeHistory.count - 20) more")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Individual Trades Card (LocalVolts interval data)

    private var individualTradesCard: some View {
        let groupedByDay = groupLVTradesByDay()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundColor(.purple)
                Text("Individual Trades")
                    .font(.headline)
                Spacer()
                Text("\(lvTrades.count) intervals")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("5-minute interval trades from LocalVolts")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            ForEach(groupedByDay.keys.sorted(by: >), id: \.self) { day in
                if let dayTrades = groupedByDay[day] {
                    individualTradesDaySection(day: day, trades: dayTrades)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func individualTradesDaySection(day: Date, trades: [LVIntervalTrade]) -> some View {
        let isExpanded = expandedDays.contains(day)
        let dayVolume = trades.reduce(0) { $0 + $1.volumeKwh }
        let dayRevenue = trades.reduce(0) { $0 + $1.revenue }

        return VStack(spacing: 0) {
            // Day header (expandable)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedDays.remove(day)
                    } else {
                        expandedDays.insert(day)
                    }
                }
            }) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 16)

                    Text(formatDayHeader(day))
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Text("\(trades.count) trades")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(String(format: "%.2f kWh", dayVolume))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.purple)

                    Text(formatCurrency(dayRevenue))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.green)
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // Expanded trade list
            if isExpanded {
                VStack(spacing: 4) {
                    // Header row
                    HStack {
                        Text("Time")
                            .frame(width: 50, alignment: .leading)
                        Text("kWh")
                            .frame(width: 50, alignment: .trailing)
                        Text("Price")
                            .frame(width: 50, alignment: .trailing)
                        Text("Type")
                            .frame(width: 30, alignment: .center)
                        Text("Revenue")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)

                    ForEach(trades.sorted(by: { $0.periodStart < $1.periodStart })) { trade in
                        individualTradeRow(trade)
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 8)
            }

            Divider()
        }
    }

    private func individualTradeRow(_ trade: LVIntervalTrade) -> some View {
        HStack {
            Text(formatTradeTime(trade.periodStart))
                .frame(width: 50, alignment: .leading)

            Text(String(format: "%.3f", trade.volumeKwh))
                .frame(width: 50, alignment: .trailing)

            Text(String(format: "%.1f¢", trade.priceCents))
                .frame(width: 50, alignment: .trailing)
                .foregroundColor(trade.priceCents >= 25 ? .green : .orange)

            // Category badge (SC = Smart Contract, SR = Self Referral)
            if let cat = trade.category {
                Text(cat)
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(cat == "SC" ? Color.blue : Color.purple)
                    .cornerRadius(3)
                    .frame(width: 30)
            } else {
                Text("")
                    .frame(width: 30)
            }

            Text(formatCurrency(trade.revenue))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundColor(trade.direction == .sell ? .green : .red)
        }
        .font(.caption.monospacedDigit())
    }

    private func groupLVTradesByDay() -> [Date: [LVIntervalTrade]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!

        return Dictionary(grouping: lvTrades) { trade in
            calendar.startOfDay(for: trade.periodStart)
        }
    }

    // MARK: - Facility Breakdown Card

    private var facilityBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "building.2")
                    .foregroundColor(.orange)
                Text("Facilities")
                    .font(.headline)
                Spacer()
                Text("\(uniqueFacilities.count) location\(uniqueFacilities.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Trading locations for this counterparty")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            ForEach(uniqueFacilities, id: \.self) { facility in
                facilityRow(facility)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func facilityRow(_ facility: String) -> some View {
        let trades = tradesByFacility[facility] ?? []
        let volume = trades.reduce(0) { $0 + $1.volumeKwh }
        let revenue = trades.reduce(0) { $0 + $1.revenue }
        let avgPrice = volume > 0 ? trades.reduce(0) { $0 + $1.volumeKwh * $1.priceCents } / volume : 0

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text(facility)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(trades.count) trades")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text(String(format: "%.2f", volume))
                        .font(.caption.monospacedDigit())
                    Text("kWh")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Text(String(format: "%.1f¢", avgPrice))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.purple)
                    Text("avg")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(formatCurrency(revenue))
                    .font(.caption.bold())
                    .foregroundColor(.green)
            }
            .padding(.leading, 20)

            Divider()
        }
    }

    private func formatDayHeader(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E, MMM d, yyyy"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        return formatter.string(from: date)
    }

    private func formatTradeTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        return formatter.string(from: date)
    }

    // MARK: - Outreach Card

    private var outreachCard: some View {
        // Compute values for factors
        let daysSinceLast = Calendar.current.dateComponents([.day], from: computedDateRange.last, to: Date()).day ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.badge.plus")
                    .foregroundColor(.purple)
                Text("Partnership Potential")
                    .font(.headline)
                Spacer()
            }

            Divider()

            let score = calculatePartnershipScore()

            // Score indicator
            HStack {
                Text("Score:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    ForEach(0..<5) { i in
                        Image(systemName: i < score.stars ? "star.fill" : "star")
                            .foregroundColor(i < score.stars ? .yellow : .secondary.opacity(0.3))
                    }
                }

                Spacer()

                Text(score.label)
                    .font(.subheadline.bold())
                    .foregroundColor(score.color)
            }

            Divider()

            // Factors using computed values
            VStack(alignment: .leading, spacing: 8) {
                factorRow(
                    positive: currentlyCommercial,
                    text: currentlyCommercial ? "Commercial buyer (likely stable demand)" : "Residential buyer (variable demand)"
                )

                factorRow(
                    positive: computedAvgPrice >= 25,
                    text: computedAvgPrice >= 25 ? "Pays premium prices (≥25¢)" : "Bargain hunter (<25¢ avg)"
                )

                factorRow(
                    positive: computedTradeCount >= 5,
                    text: computedTradeCount >= 5 ? "Consistent buyer (\(computedTradeCount) trades)" : "Infrequent buyer"
                )

                factorRow(
                    positive: computedTotalVolume >= 10,
                    text: computedTotalVolume >= 10 ? "High volume (≥10 kWh)" : "Low volume buyer"
                )

                factorRow(
                    positive: daysSinceLast <= 14,
                    text: daysSinceLast <= 14 ? "Recently active" : "Inactive (\(daysSinceLast) days)"
                )

                // Bidirectional factor
                if isBidirectional {
                    factorRow(
                        positive: true,
                        text: "Bidirectional trading (buy AND sell)"
                    )
                }
            }
            
            if score.stars >= 4 {
                Divider()
                
                Text("💡 Consider reaching out to discuss a standing P2P arrangement")
                    .font(.caption)
                    .foregroundColor(.purple)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func factorRow(positive: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: positive ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(positive ? .green : .orange)
                .font(.caption)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
    
    private func calculatePartnershipScore() -> (stars: Int, label: String, color: Color) {
        var score = 0

        // Use computed values from fresh trade data
        let daysSinceLast = Calendar.current.dateComponents([.day], from: computedDateRange.last, to: Date()).day ?? 0

        if currentlyCommercial { score += 1 }
        if computedAvgPrice >= 25 { score += 1 }
        if computedTradeCount >= 5 { score += 1 }
        if computedTotalVolume >= 10 { score += 1 }
        if daysSinceLast <= 14 { score += 1 }

        // Bonus for bidirectional trading
        if isBidirectional { score += 1 }

        switch score {
        case 6: return (5, "Excellent", .green)  // 5 stars max + bidirectional bonus
        case 5: return (5, "Excellent", .green)
        case 4: return (4, "Good", .green)
        case 3: return (3, "Moderate", .orange)
        case 2: return (2, "Low", .orange)
        default: return (1, "Poor", .red)
        }
    }

    // MARK: - Data Loading

    private func loadHistory() {
        guard let siteId = api.selectedSite?.id else {
            isLoading = false
            return
        }

        isLoading = true

        // First, deduplicate any duplicate LV trades (one-time cleanup)
        let dupsRemoved = PowstonDataStore.shared.deduplicateLVTrades(siteId: siteId)
        if dupsRemoved > 0 {
            print("🧹 Removed \(dupsRemoved) duplicate LV trades on counterparty load")
        }

        // Debug: Check for remaining duplicates and volume
        let stats = PowstonDataStore.shared.getLVTradeStats(
            siteId: siteId,
            counterparty: counterparty.counterpartyName
        )
        print("📊 LV stats for '\(counterparty.counterpartyName)': \(stats.count) trades, \(String(format: "%.2f", stats.totalVolumeKwh)) kWh, \(stats.duplicates) duplicates remaining")

        // Load history grouped by import
        tradeHistory = PowstonDataStore.shared.getP2PCounterpartyHistory(
            siteId: siteId,
            counterpartyName: counterparty.counterpartyName,
            includeContracts: includeContracts
        )

        // Also load raw trades for accurate stats computation
        allTrades = PowstonDataStore.shared.getP2PCounterpartyTrades(
            siteId: siteId,
            counterpartyName: counterparty.counterpartyName,
            includeContracts: includeContracts
        )

        // Load individual interval trades from LocalVolts WebSocket data
        lvTrades = PowstonDataStore.shared.getLVIntervalTrades(
            siteId: siteId,
            counterparty: counterparty.counterpartyName,
            includeContracts: includeContracts
        )

        // Debug: Compare raw LV trades with allTrades
        let lvVolume = lvTrades.reduce(0) { $0 + $1.volumeKwh }
        let allTradesVolume = allTrades.reduce(0) { $0 + $1.volumeKwh }
        print("📊 Volume comparison: lvTrades=\(String(format: "%.2f", lvVolume)) kWh (\(lvTrades.count) records), allTrades=\(String(format: "%.2f", allTradesVolume)) kWh (\(allTrades.count) records)")

        isLoading = false
    }

    private func deleteCounterparty() {
        guard let siteId = api.selectedSite?.id else { return }

        let deleted = PowstonDataStore.shared.deleteCounterparty(siteId: siteId, name: counterparty.counterpartyName)
        if deleted > 0 {
            print("🗑️ Deleted counterparty '\(counterparty.counterpartyName)' (\(deleted) trades)")
            dismiss()
        }
    }
    
    // MARK: - Helpers
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
}

// MARK: - Make P2PCounterpartySummary Identifiable for sheet

extension P2PCounterpartySummary: Equatable {
    static func == (lhs: P2PCounterpartySummary, rhs: P2PCounterpartySummary) -> Bool {
        lhs.counterpartyName == rhs.counterpartyName
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        P2PCounterpartyView()
            .environmentObject(PowstonAPI())
    }
}
