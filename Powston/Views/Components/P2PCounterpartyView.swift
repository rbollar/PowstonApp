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
    @State private var leaderboard: [P2PCounterpartySummary] = []
    @State private var isLoading = true
    @State private var selectedCounterparty: P2PCounterpartySummary?
    @State private var filterMode: FilterMode = .all
    @State private var sortMode: SortMode = .volume
    
    enum FilterMode: String, CaseIterable {
        case all = "All"
        case commercial = "Commercial"
        case residential = "Residential"
        case premium = "Premium (≥25¢)"
    }
    
    enum SortMode: String, CaseIterable {
        case volume = "Volume"
        case revenue = "Revenue"
        case trades = "Trades"
        case price = "Avg Price"
        case recent = "Recent"
    }
    
    var filteredAndSorted: [P2PCounterpartySummary] {
        var result = leaderboard
        
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
        .sheet(item: $selectedCounterparty) { counterparty in
            P2PCounterpartyDetailView(counterparty: counterparty)
                .environmentObject(api)
        }
        .onAppear { loadLeaderboard() }
        .refreshable { await refreshLeaderboard() }
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
            
            if let topBuyer = leaderboard.first {
                Divider()
                
                HStack(spacing: 8) {
                    Image(systemName: "crown.fill")
                        .foregroundColor(.yellow)
                    Text("Top buyer:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(topBuyer.counterpartyName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f kWh", topBuyer.totalVolumeKwh))
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
        HStack(spacing: 12) {
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
        leaderboard = PowstonDataStore.shared.getP2PCounterpartyLeaderboard(siteId: siteId, limit: 100)
        isLoading = false
    }
    
    private func refreshLeaderboard() async {
        guard let siteId = api.selectedSite?.id else { return }
        leaderboard = PowstonDataStore.shared.getP2PCounterpartyLeaderboard(siteId: siteId, limit: 100)
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
    
    let counterparty: P2PCounterpartySummary
    
    @State private var tradeHistory: [P2PCounterpartyTradeHistory] = []
    @State private var isLoading = true
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    summaryCard
                    statsCard
                    
                    if !tradeHistory.isEmpty {
                        historyCard
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
            }
            .onAppear { loadHistory() }
        }
    }
    
    // MARK: - Summary Card
    
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if counterparty.isCommercial {
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
            }
            
            Divider()
            
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.2f kWh", counterparty.totalVolumeKwh))
                        .font(.title2.bold())
                        .foregroundColor(.purple)
                    Text("total volume")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatCurrency(counterparty.totalRevenue))
                        .font(.title2.bold())
                        .foregroundColor(.green)
                    Text("total revenue")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Stats Card
    
    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundColor(.orange)
                Text("Trading Stats")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            // Stats grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                statItem(label: "Trades", value: "\(counterparty.tradeCount)")
                statItem(label: "Avg Price", value: String(format: "%.1f¢", counterparty.avgPriceCents), color: counterparty.avgPriceCents >= 25 ? .green : .orange)
                statItem(label: "Price Range", value: String(format: "%.0f–%.0f¢", counterparty.minPriceCents, counterparty.maxPriceCents))
                statItem(label: "Avg/Trade", value: String(format: "%.2f kWh", counterparty.avgVolumePerTrade))
                statItem(label: "First Trade", value: formatDate(counterparty.firstTradeDate))
                statItem(label: "Last Trade", value: formatDate(counterparty.lastTradeDate))
            }
            
            if counterparty.daysSinceLastTrade > 14 {
                Divider()
                
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundColor(.orange)
                    Text("No trades in \(counterparty.daysSinceLastTrade) days")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.cyan)
                Text("Trade History")
                    .font(.headline)
                Spacer()
                Text("\(tradeHistory.count) periods")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // Header
            HStack {
                Text("Date")
                    .frame(width: 80, alignment: .leading)
                Text("kWh")
                    .frame(width: 60, alignment: .trailing)
                Text("Price")
                    .frame(width: 50, alignment: .trailing)
                Text("Revenue")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
            
            ForEach(tradeHistory.prefix(20)) { trade in
                HStack {
                    Text(formatDate(trade.tradeDate))
                        .frame(width: 80, alignment: .leading)
                    Text(String(format: "%.2f", trade.volumeKwh))
                        .frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.0f¢", trade.priceCents))
                        .frame(width: 50, alignment: .trailing)
                        .foregroundColor(trade.priceCents >= 25 ? .green : .orange)
                    Text(formatCurrency(trade.revenue))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .foregroundColor(.green)
                }
                .font(.caption.monospacedDigit())
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
    
    // MARK: - Outreach Card
    
    private var outreachCard: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            
            // Factors
            VStack(alignment: .leading, spacing: 8) {
                factorRow(
                    positive: counterparty.isCommercial,
                    text: counterparty.isCommercial ? "Commercial buyer (likely stable demand)" : "Residential buyer (variable demand)"
                )
                
                factorRow(
                    positive: counterparty.avgPriceCents >= 25,
                    text: counterparty.avgPriceCents >= 25 ? "Pays premium prices (≥25¢)" : "Bargain hunter (<25¢ avg)"
                )
                
                factorRow(
                    positive: counterparty.tradeCount >= 5,
                    text: counterparty.tradeCount >= 5 ? "Consistent buyer (\(counterparty.tradeCount) trades)" : "Infrequent buyer"
                )
                
                factorRow(
                    positive: counterparty.totalVolumeKwh >= 10,
                    text: counterparty.totalVolumeKwh >= 10 ? "High volume (≥10 kWh)" : "Low volume buyer"
                )
                
                factorRow(
                    positive: counterparty.daysSinceLastTrade <= 14,
                    text: counterparty.daysSinceLastTrade <= 14 ? "Recently active" : "Inactive (\(counterparty.daysSinceLastTrade) days)"
                )
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
        
        if counterparty.isCommercial { score += 1 }
        if counterparty.avgPriceCents >= 25 { score += 1 }
        if counterparty.tradeCount >= 5 { score += 1 }
        if counterparty.totalVolumeKwh >= 10 { score += 1 }
        if counterparty.daysSinceLastTrade <= 14 { score += 1 }
        
        switch score {
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
        tradeHistory = PowstonDataStore.shared.getP2PCounterpartyHistory(
            siteId: siteId,
            counterpartyName: counterparty.counterpartyName
        )
        isLoading = false
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