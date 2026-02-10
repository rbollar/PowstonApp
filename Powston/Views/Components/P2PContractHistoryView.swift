//
//  P2PContractHistoryView.swift
//  Powston
//
//  Contract tracking view showing historical and active P2P contracts
//  with performance metrics, fill rate gauges, and tier breakdowns
//

import SwiftUI

// MARK: - Contract State

enum ContractState {
    case future      // Hasn't started yet
    case active      // Currently in progress
    case completed   // Has ended
    
    var label: String {
        switch self {
        case .future: return "Upcoming"
        case .active: return "Active"
        case .completed: return "Completed"
        }
    }
    
    var color: Color {
        switch self {
        case .future: return .blue
        case .active: return .green
        case .completed: return .secondary
        }
    }
    
    var icon: String {
        switch self {
        case .future: return "calendar.badge.clock"
        case .active: return "bolt.circle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

// MARK: - Contract History View

struct P2PContractHistoryView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var lvService = LocalVoltsService.shared

    /// Filter to show only contracts of this direction (nil = show all)
    var directionFilter: P2PTradeDirection?

    @State private var contracts: [P2PContract] = []
    @State private var performanceCache: [UUID: P2PContractPerformance] = [:]
    @State private var showNewContract = false
    @State private var editingContract: P2PContract?
    @State private var isLoading = true

    // LocalVolts orders (grouped)
    @State private var lvOrders: [LVOrder] = []
    @State private var lvOrderGroups: [LVOrderGroup] = []
    @State private var isLoadingLVOrders = false
    @State private var lvOrdersError: String?
    @State private var lvGroupPerformanceCache: [UUID: P2PContractPerformance] = [:]

    // P2P Export Override tracking
    @State private var p2pParams: TrainingParameters?
    @State private var isLoadingParams = true

    /// Filtered contracts based on direction
    private var filteredContracts: [P2PContract] {
        guard let filter = directionFilter else { return contracts }
        return contracts.filter { $0.direction == filter }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // LocalVolts Orders Section - show if we have credentials OR cached data
                if lvService.hasCredentials || !lvOrderGroups.isEmpty {
                    lvOrdersSection
                }

                if isLoading {
                    ProgressView("Loading contracts...")
                        .padding(.vertical, 40)
                } else if filteredContracts.isEmpty && filteredLVOrderGroups.isEmpty {
                    emptyState
                } else {
                    contractList
                }
            }
            .padding(.horizontal)
        }
        .refreshable {
            await refreshAll()
        }
        .sheet(isPresented: $showNewContract) {
            P2PContractEntryView(
                defaultDirection: directionFilter ?? .sell,
                onSave: { _ in loadContracts() }
            )
        }
        .sheet(item: $editingContract) { contract in
            P2PContractEntryView(
                existingContract: contract,
                onSave: { _ in loadContracts() }
            )
        }
        .onAppear {
            loadContracts()
            loadLVOrders()
            Task { await loadP2PParams() }
        }
    }

    // MARK: - LocalVolts Orders

    /// Filtered LV order groups based on direction
    private var filteredLVOrderGroups: [LVOrderGroup] {
        guard let filter = directionFilter else { return lvOrderGroups }
        let directionStr = filter == .sell ? "Sell" : "Buy"
        return lvOrderGroups.filter { $0.direction == directionStr }
    }

    private var lvOrdersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with sync button
            HStack {
                Image(systemName: "bolt.circle.fill")
                    .foregroundColor(.purple)
                Text("LocalVolts Orders")
                    .font(.headline)
                Spacer()

                if isLoadingLVOrders || lvService.isLoadingOrders {
                    ProgressView()
                        .controlSize(.small)
                } else if lvService.hasCredentials {
                    Button(action: syncLVOrders) {
                        Label("Sync", systemImage: "arrow.clockwise")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.purple)
                            .cornerRadius(6)
                    }
                }
            }

            // Credentials missing warning (when we have data but no creds)
            if !lvService.hasCredentials && !lvOrderGroups.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.key")
                        .foregroundColor(.orange)
                    Text("Reconnect LocalVolts to sync updates")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // Last sync time
            if let lastSync = lvService.lastOrdersFetchTime {
                HStack {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("Last synced: \(formatRelativeTime(lastSync))")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }

            // Error message
            if let error = lvOrdersError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // Show LV orders if we have any
            if !filteredLVOrderGroups.isEmpty {
                Divider()
                lvOrderGroupsList
            } else if !isLoadingLVOrders && lvOrderGroups.isEmpty && lvService.hasCredentials {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("No orders found. Tap Sync to fetch from LocalVolts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var lvOrderGroupsList: some View {
        let grouped = groupedLVOrderGroups
        let siteId = api.selectedSite?.id ?? 0

        return VStack(spacing: 12) {
            // Active groups
            ForEach(grouped.active) { group in
                NavigationLink {
                    ContractSnapshotHistoryView(group: group, siteId: siteId)
                } label: {
                    lvOrderGroupCard(group, state: .active)
                }
                .buttonStyle(.plain)
            }

            // Future groups
            ForEach(grouped.future) { group in
                NavigationLink {
                    ContractSnapshotHistoryView(group: group, siteId: siteId)
                } label: {
                    lvOrderGroupCard(group, state: .future)
                }
                .buttonStyle(.plain)
            }

            // Completed groups (collapsed)
            if !grouped.completed.isEmpty {
                DisclosureGroup {
                    ForEach(grouped.completed) { group in
                        NavigationLink {
                            ContractSnapshotHistoryView(group: group, siteId: siteId)
                        } label: {
                            lvOrderGroupCard(group, state: .completed)
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    HStack {
                        Text("Completed (\(grouped.completed.count))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    private var groupedLVOrderGroups: (future: [LVOrderGroup], active: [LVOrderGroup], completed: [LVOrderGroup]) {
        var future: [LVOrderGroup] = []
        var active: [LVOrderGroup] = []
        var completed: [LVOrderGroup] = []

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        for group in filteredLVOrderGroups {
            let startDay = calendar.startOfDay(for: group.dateFrom)
            let endDay = calendar.startOfDay(for: group.dateTo)

            if group.status == "Cancelled" {
                completed.append(group)
            } else if today < startDay {
                future.append(group)
            } else if today > endDay {
                completed.append(group)
            } else {
                active.append(group)
            }
        }

        future.sort { $0.dateFrom < $1.dateFrom }
        active.sort { $0.dateFrom < $1.dateFrom }
        completed.sort { $0.dateTo > $1.dateTo }

        return (future, active, completed)
    }

    private func lvOrderGroupCard(_ group: LVOrderGroup, state: ContractState) -> some View {
        let perf = lvGroupPerformanceCache[group.id]
        let tierCount = group.tiers.count

        return VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: state.icon)
                    .foregroundColor(state.color)
                Text("\(state.label) \(group.direction)")
                    .font(.subheadline.bold())
                if tierCount > 1 {
                    Text("(\(tierCount) tiers)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if group.status == "Cancelled" {
                    Text("Cancelled")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                } else if let perf = perf, perf.totalMatchedKwh > 0 {
                    // Show fill rate badge
                    Text(String(format: "%.0f%%", perf.overallFillRate))
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(lvFillRateColor(perf.overallFillRate))
                        .cornerRadius(4)
                }
            }

            // Date range and hours
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatDateRange(from: group.dateFrom, to: group.dateTo))
                        .font(.caption)
                    if let timeWindow = group.timeWindowString {
                        Text(timeWindow)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f kWh", group.totalVolumeKwh))
                        .font(.caption.bold())
                    Text(group.priceRangeString)
                        .font(.caption)
                        .foregroundColor(.purple)
                }
            }

            // Tier breakdown (for multi-tier groups)
            if tierCount > 1 {
                Divider()
                lvOrderTierBreakdown(group, perf: perf, state: state)
            }

            // Performance metrics (if available) - show for both sells and buys
            if let perf = perf, perf.totalMatchedKwh > 0 {
                if tierCount <= 1 {
                    Divider()
                }
                let isSell = group.isSell
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Matched")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f kWh", perf.totalMatchedKwh))
                            .font(.caption.bold())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isSell ? "Revenue" : "Cost")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(formatLVCurrency(perf.totalRevenue))
                            .font(.caption.bold())
                            .foregroundColor(isSell ? .green : .orange)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(isSell ? "Buyers" : "Sellers")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(perf.counterpartyCount)")
                            .font(.caption.bold())
                    }
                }
            }

            // Pre-commitment status for future contracts (especially buy contracts)
            if state == .future {
                lvOrderPreCommitmentStatus(group: group, perf: perf)
            }

            // Progress and pace for active groups
            if state == .active, let dayProgress = group.dayProgress {
                lvOrderPaceIndicator(group: group, perf: perf, dayProgress: dayProgress)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(state.color.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    /// Show tier breakdown with fill rates for multi-tier groups
    /// For future contracts, uses pre-commitment data from snapshots
    /// For active/completed contracts, uses actual trade performance
    private func lvOrderTierBreakdown(_ group: LVOrderGroup, perf: P2PContractPerformance?, state: ContractState? = nil) -> some View {
        // For future contracts, get pre-commitment fill rate from snapshots
        let preCommitFillRate: Double? = {
            guard state == .future else { return nil }
            let commitment = getGroupCommitmentSummary(group)
            guard group.totalVolumeKwh > 0, commitment.subscribedKwh > 0 else { return nil }
            return (commitment.subscribedKwh / group.totalVolumeKwh) * 100
        }()

        return VStack(spacing: 6) {
            ForEach(Array(group.tiers.enumerated()), id: \.offset) { index, tier in
                let tierPerf = perf?.tierPerformance.first { $0.tier.priceCents == tier.priceCents }

                // Use tier performance for active/completed, or pre-commitment for future
                // For future contracts, tierPerf may exist with 0 fill rate - use preCommit instead
                let tierFillRate = tierPerf?.fillRate ?? 0
                let fillRate: Double? = (tierFillRate > 0) ? tierFillRate : preCommitFillRate

                HStack(spacing: 4) {
                    // Price - fixed width for alignment
                    // Show "Mkt" for market-price tiers (0¢) instead of misleading "0¢"
                    let priceLabel = tier.priceCents > 0 ? String(format: "%.0f¢", tier.priceCents) : "Mkt"
                    Text(priceLabel)
                        .font(.caption2.bold())
                        .foregroundColor(tier.priceCents > 0 ? .purple : .blue)
                        .frame(width: 28, alignment: .leading)
                        .lineLimit(1)

                    // Volume - wider frame for 3-digit numbers
                    Text(String(format: "%.0f", tier.volumeKwh))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 36, alignment: .trailing)
                        .lineLimit(1)

                    // Mini fill gauge
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(.tertiarySystemBackground))
                                .frame(height: 6)
                            if let fillRate = fillRate, fillRate > 0 {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(lvFillRateColor(fillRate))
                                    .frame(width: geo.size.width * min(1, fillRate / 100), height: 6)
                            }
                        }
                    }
                    .frame(height: 6)

                    // Fill rate percentage
                    if let fillRate = fillRate {
                        Text(String(format: "%.0f%%", fillRate))
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundColor(lvFillRateColor(fillRate))
                            .frame(width: 36, alignment: .trailing)
                            .lineLimit(1)
                    } else {
                        Text("0%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Show pace indicator for active LV order groups
    private func lvOrderPaceIndicator(group: LVOrderGroup, perf: P2PContractPerformance?, dayProgress: Int) -> some View {
        let totalDays = group.durationDays
        let completedDays = max(0, dayProgress - 1)  // Days fully completed (not including today)
        let expectedProgress = Double(completedDays) / Double(totalDays)
        let expectedKwh = group.totalVolumeKwh * expectedProgress
        let actualKwh = perf?.totalMatchedKwh ?? 0

        // Calculate pace ratio
        let paceRatio: Double
        if completedDays == 0 {
            paceRatio = 1.0  // Just started, assume on pace
        } else {
            paceRatio = expectedKwh > 0 ? actualKwh / expectedKwh : 0
        }

        let paceLabel: String
        let paceColor: Color
        if completedDays == 0 {
            paceLabel = "Just started"
            paceColor = .blue
        } else if paceRatio >= 0.9 {
            paceLabel = "On pace"
            paceColor = .green
        } else if paceRatio >= 0.6 {
            paceLabel = "Slightly behind"
            paceColor = .orange
        } else {
            paceLabel = "Behind pace"
            paceColor = .red
        }

        return VStack(spacing: 4) {
            // Progress bar with expected marker
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(.tertiarySystemBackground))
                        .frame(height: 6)

                    // Actual fill
                    let fillRate = perf?.overallFillRate ?? 0
                    RoundedRectangle(cornerRadius: 3)
                        .fill(paceColor)
                        .frame(width: geo.size.width * min(1, fillRate / 100), height: 6)

                    // Expected progress marker (vertical line)
                    if completedDays > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 2, height: 10)
                            .offset(x: geo.size.width * CGFloat(expectedProgress) - 1, y: -2)
                    }
                }
            }
            .frame(height: 6)

            HStack(spacing: 4) {
                Text("Day \(dayProgress) of \(totalDays)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(paceColor)
                        .frame(width: 6, height: 6)
                    Text(paceLabel)
                        .font(.caption2)
                        .foregroundColor(paceColor)
                        .lineLimit(1)
                }

                if completedDays > 0 {
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f/%.0f", actualKwh, expectedKwh))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func lvFillRateColor(_ rate: Double) -> Color {
        if rate >= 75 { return .green }
        if rate >= 40 { return .orange }
        return .red
    }

    /// Show pre-commitment status for future LV order groups
    /// Uses contract snapshot data to show committed volume (from TradeDetail API)
    @ViewBuilder
    private func lvOrderPreCommitmentStatus(group: LVOrderGroup, perf: P2PContractPerformance?) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDay = calendar.startOfDay(for: group.dateFrom)
        let daysUntilStart = calendar.dateComponents([.day], from: today, to: startDay).day ?? 0

        // Try to get commitment data from snapshots (more accurate for future contracts)
        // Use aggregation for groups with multiple orders (Market + priced tier)
        let commitmentSummary = getGroupCommitmentSummary(group)
        let snapshot = getLatestSnapshotForGroup(group)

        Divider()
        VStack(alignment: .leading, spacing: 8) {
            // Days until start
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .font(.caption)
                    .foregroundColor(.blue)
                if daysUntilStart == 0 {
                    Text("Starts today")
                        .font(.caption)
                        .foregroundColor(.blue)
                } else if daysUntilStart == 1 {
                    Text("Starts tomorrow")
                        .font(.caption)
                        .foregroundColor(.blue)
                } else {
                    Text("Starts in \(daysUntilStart) days")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                Spacer()
            }

            // Pre-commitment info from snapshot (preferred) or performance data
            // Use aggregated data from group, falling back to snapshot, then performance
            let subscribedKwh = commitmentSummary.subscribedKwh > 0
                ? commitmentSummary.subscribedKwh
                : (snapshot?.subscribedVolumeKwh ?? perf?.totalMatchedKwh ?? 0)
            let counterparties = commitmentSummary.counterpartyCount > 0
                ? commitmentSummary.counterpartyCount
                : (snapshot?.counterpartyCount ?? perf?.counterpartyCount ?? 0)


            if subscribedKwh > 0 || counterparties > 0 {
                let preCommitPercent = group.totalVolumeKwh > 0
                    ? (subscribedKwh / group.totalVolumeKwh) * 100
                    : 0
                let isSell = group.isSell

                HStack {
                    Image(systemName: "bolt.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)
                    Text("Pre-Committed")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                    Text(String(format: "%.0f%%", preCommitPercent))
                        .font(.caption.bold())
                        .foregroundColor(preCommitPercent >= 50 ? .green : .orange)
                }

                HStack {
                    Text(String(format: "%.1f / %.0f kWh matched", subscribedKwh, group.totalVolumeKwh))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(counterparties) \(isSell ? "buyer" : "seller")\(counterparties == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Show projected cost/revenue based on blended price
                let blendedPrice = group.blendedPriceCents
                if blendedPrice > 0 {
                    let projectedValue = subscribedKwh * blendedPrice / 100.0
                    HStack {
                        Text(isSell ? "Projected revenue:" : "Projected cost:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(formatLVCurrency(projectedValue))
                            .font(.caption2.bold())
                            .foregroundColor(isSell ? .green : .orange)
                        Spacer()
                    }
                }
            } else {
                // No pre-commitments yet
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(group.isSell ? "Waiting for buyer matches..." : "Waiting for seller matches...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }

    /// Get aggregated snapshot data for a group
    /// For groups with Market + priced orders, aggregate the fills across all orders
    /// Returns the snapshot with the highest subscribed volume (avoids double-counting)
    private func getLatestSnapshotForGroup(_ group: LVOrderGroup) -> LVContractSnapshot? {
        var bestSnapshot: LVContractSnapshot? = nil
        var highestSubscribed: Double = 0

        // Check each order in the group for snapshot data
        for orderId in group.orderIds {
            let snapshots = PowstonDataStore.shared.getContractSnapshots(orderId: orderId)
            if let latest = snapshots.last {
                // Use the snapshot with the most subscribed volume
                // For Market + priced orders, the Market order typically has the full fills
                if latest.subscribedVolumeKwh > highestSubscribed {
                    highestSubscribed = latest.subscribedVolumeKwh
                    bestSnapshot = latest
                }
            }
        }

        return bestSnapshot
    }

    /// Get total commitment across all orders in a group
    /// This aggregates fills data from all orders, handling Market + priced tier patterns
    private func getGroupCommitmentSummary(_ group: LVOrderGroup) -> (subscribedKwh: Double, counterpartyCount: Int) {
        var allCounterparties: Set<String> = []
        var totalSubscribed: Double = 0

        // For groups with Market component, the Market order shows total volume
        // and fills are distributed across orders
        for orderId in group.orderIds {
            let snapshots = PowstonDataStore.shared.getContractSnapshots(orderId: orderId)
            if let latest = snapshots.last {
                // Track highest subscribed (avoid double-counting same volume)
                if latest.subscribedVolumeKwh > totalSubscribed {
                    totalSubscribed = latest.subscribedVolumeKwh
                }
            }

            // Get counterparty snapshots for unique counterparty counting
            let counterpartySnapshots = PowstonDataStore.shared.getCounterpartySnapshots(orderId: orderId)
            for cp in counterpartySnapshots {
                allCounterparties.insert(cp.counterpartyName)
            }
        }

        return (totalSubscribed, allCounterparties.count)
    }

    private func formatLVCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    private func formatDateRange(from: Date, to: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        return "\(formatter.string(from: from)) – \(formatter.string(from: to))"
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func loadLVOrders() {
        guard let siteId = api.selectedSite?.id else { return }
        lvOrders = lvService.getOrders(siteId: siteId)

        // Group orders by contract (same date range + close trade times)
        lvOrderGroups = LVOrder.groupByContract(lvOrders)

        // Load performance for each group
        Task { @MainActor in
            for group in lvOrderGroups {
                let contract = group.toP2PContract()
                let perf = PowstonDataStore.shared.getP2PContractPerformance(contract)
                lvGroupPerformanceCache[group.id] = perf
            }
        }
    }

    private func syncLVOrders() {
        guard let siteId = api.selectedSite?.id else { return }

        isLoadingLVOrders = true
        lvOrdersError = nil

        Task {
            do {
                let orders = try await lvService.fetchOrders(siteId: siteId)
                await MainActor.run {
                    lvOrders = orders

                    // Group orders by contract
                    lvOrderGroups = LVOrder.groupByContract(orders)
                    isLoadingLVOrders = false

                    // Load performance for each group
                    for group in lvOrderGroups {
                        let contract = group.toP2PContract()
                        let perf = PowstonDataStore.shared.getP2PContractPerformance(contract)
                        lvGroupPerformanceCache[group.id] = perf
                    }
                }
            } catch {
                await MainActor.run {
                    lvOrdersError = error.localizedDescription
                    isLoadingLVOrders = false
                }
            }
        }
    }

    private func refreshAll() async {
        await refreshContracts()

        // Also refresh LV orders if credentials are available
        if lvService.hasCredentials, let siteId = api.selectedSite?.id {
            do {
                let orders = try await lvService.fetchOrders(siteId: siteId)
                lvOrders = orders

                // Group orders by contract
                lvOrderGroups = LVOrder.groupByContract(orders)

                // Load performance for each group
                for group in lvOrderGroups {
                    let contract = group.toP2PContract()
                    let perf = PowstonDataStore.shared.getP2PContractPerformance(contract)
                    lvGroupPerformanceCache[group.id] = perf
                }
            } catch {
                lvOrdersError = error.localizedDescription
            }
        }
    }

    // MARK: - Load P2P Export Parameters

    private func loadP2PParams() async {
        guard let siteId = api.selectedSite?.id else {
            isLoadingParams = false
            return
        }
        let params = await api.fetchTrainingParameters(siteId: siteId)
        await MainActor.run {
            p2pParams = params
            isLoadingParams = false
        }
    }

    // MARK: - Export Override Validation

    /// Validation result for P2P export override vs contract
    struct ExportOverrideValidation {
        var isConfigured: Bool = false      // Is P2P export override set?
        var hoursMatch: Bool = false        // Do hours match contract?
        var powerSufficient: Bool = false   // Is power enough for contract?

        var overrideStartHour: Int?
        var overrideEndHour: Int?
        var overridePowerW: Int?

        var contractStartHour: Int = 0
        var contractEndHour: Int = 0
        var requiredPowerW: Int = 0

        var hasIssues: Bool {
            guard isConfigured else { return true }  // Not configured is an issue
            return !hoursMatch || !powerSufficient
        }

        var issues: [String] {
            var result: [String] = []

            if !isConfigured {
                result.append("P2P export override not configured")
            } else {
                if !hoursMatch {
                    let currentWindow = "\(overrideStartHour ?? 0):00–\(overrideEndHour ?? 0):00"
                    let contractWindow = "\(contractStartHour):00–\(contractEndHour):00"
                    result.append("Hours mismatch: override is \(currentWindow), contract is \(contractWindow)")
                }
                if !powerSufficient {
                    let currentKW = Double(overridePowerW ?? 0) / 1000.0
                    let requiredKW = Double(requiredPowerW) / 1000.0
                    result.append("Power too low: \(String(format: "%.1f", currentKW)) kW configured, need \(String(format: "%.1f", requiredKW)) kW")
                }
            }

            return result
        }
    }

    /// Validate P2P export override against an active sell contract
    private func validateExportOverride(for contract: P2PContract) -> ExportOverrideValidation {
        var validation = ExportOverrideValidation()

        // Only validate sell contracts
        guard contract.direction == .sell else {
            validation.isConfigured = true
            validation.hoursMatch = true
            validation.powerSufficient = true
            return validation
        }

        validation.contractStartHour = contract.startHour
        validation.contractEndHour = contract.endHour

        // Calculate required power: dailyVolumeKwh / hoursPerDay * 1000 = Watts
        let hoursPerDay = contract.hoursPerDay
        guard hoursPerDay > 0 else {
            validation.requiredPowerW = 0
            return validation
        }
        let requiredKW = contract.dailyVolumeKwh / Double(hoursPerDay)
        validation.requiredPowerW = Int(requiredKW * 1000)

        // Check P2P export override settings
        guard let params = p2pParams else {
            return validation  // Not loaded yet, assume not configured
        }

        let power = params.p2pExportPower ?? 0
        let startHour = params.p2pExportStartHour
        let endHour = params.p2pExportEndHour

        validation.overridePowerW = power
        validation.overrideStartHour = startHour
        validation.overrideEndHour = endHour

        // Is it configured? (power > 0 and hours set)
        validation.isConfigured = power > 0 && startHour != nil && endHour != nil

        // Do hours match exactly?
        validation.hoursMatch = startHour == contract.startHour && endHour == contract.endHour

        // Is power sufficient? (at least as much as required)
        validation.powerSufficient = power >= validation.requiredPowerW

        return validation
    }

    // MARK: - Contract State Helper
    
    private func contractState(_ contract: P2PContract) -> ContractState {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfContractStart = calendar.startOfDay(for: contract.startDate)
        let startOfContractEnd = calendar.startOfDay(for: contract.endDate)
        
        if startOfToday < startOfContractStart {
            return .future
        } else if startOfToday > startOfContractEnd {
            return .completed
        } else {
            return .active
        }
    }
    
    // MARK: - Grouped Contracts
    
    private var groupedContracts: (future: [P2PContract], active: [P2PContract], completed: [P2PContract]) {
        var future: [P2PContract] = []
        var active: [P2PContract] = []
        var completed: [P2PContract] = []

        for contract in filteredContracts {
            switch contractState(contract) {
            case .future: future.append(contract)
            case .active: active.append(contract)
            case .completed: completed.append(contract)
            }
        }
        
        // Sort: future by start date ascending, active by start date, completed by end date descending
        future.sort { $0.startDate < $1.startDate }
        active.sort { $0.startDate < $1.startDate }
        completed.sort { $0.endDate > $1.endDate }
        
        return (future, active, completed)
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        let isSelling = directionFilter == .sell || directionFilter == nil
        let directionText = directionFilter == .sell ? "Sell" : directionFilter == .buy ? "Buy" : ""

        return VStack(spacing: 16) {
            Image(systemName: isSelling ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(isSelling ? .green.opacity(0.5) : .orange.opacity(0.5))

            Text("No \(directionText) Contracts Yet")
                .font(.headline)

            Text(isSelling
                ? "Track your P2P sell contracts to monitor fill rates, tier performance, and revenue vs forecast."
                : "Track your P2P buy contracts to monitor fill rates, pricing protection, and cost savings.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: { showNewContract = true }) {
                Label("Add \(directionText) Contract", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isSelling ? Color.green : Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding()
    }
    
    // MARK: - Contract List
    
    private var contractList: some View {
        let grouped = groupedContracts

        return VStack(spacing: 16) {
            // P2P Export Configuration Card (always show for sell contracts)
            if directionFilter == .sell || directionFilter == nil {
                p2pExportConfigCard(activeContract: grouped.active.first, upcomingContract: grouped.future.first)
            }

            // Active contracts (should typically be 0 or 1)
            ForEach(grouped.active) { contract in
                activeContractCard(contract)
            }
            
            // Future contracts
            ForEach(grouped.future) { contract in
                futureContractCard(contract)
            }
            
            // Add new contract button
            Button(action: { showNewContract = true }) {
                let isSelling = directionFilter == .sell || directionFilter == nil
                Label(
                    "New \(directionFilter?.displayName ?? "") Contract",
                    systemImage: "plus.circle.fill"
                )
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding()
                .background((isSelling ? Color.green : Color.orange).opacity(0.15))
                .foregroundColor(isSelling ? .green : .orange)
                .cornerRadius(12)
            }
            
            // Completed contracts with aggregate insights
            if !grouped.completed.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Completed")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    // Aggregate price insights across all completed contracts
                    aggregatePriceInsights(grouped.completed)

                    ForEach(grouped.completed) { contract in
                        completedContractCard(contract)
                    }
                }
            }
        }
    }
    
    // MARK: - P2P Export Config Card

    private func p2pExportConfigCard(activeContract: P2PContract?, upcomingContract: P2PContract?) -> some View {
        // Determine recommended settings from active or upcoming contract
        let contract = activeContract ?? upcomingContract

        return VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "bolt.circle.fill")
                    .foregroundColor(.purple)
                Text("Powston P2P Export")
                    .font(.subheadline.bold())
                Spacer()
                if let site = api.selectedSite {
                    NavigationLink(destination: TrainingParametersView(siteId: site.id, siteName: site.name)) {
                        Text("Configure")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.purple)
                            .cornerRadius(6)
                    }
                }
            }

            if isLoadingParams {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let params = p2pParams {
                let isEnabled = (params.p2pExportPower ?? 0) > 0
                let power = params.p2pExportPower ?? 0
                let startHour = params.p2pExportStartHour ?? 17
                let endHour = params.p2pExportEndHour ?? 20

                // Current status
                HStack {
                    Circle()
                        .fill(isEnabled ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    if isEnabled {
                        Text("\(formatPowerKw(power)) from \(formatHour(startHour)) to \(formatHour(endHour))")
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                    } else {
                        Text("Not configured")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                // Recommendation based on contract
                if let contract = contract {
                    let requiredPowerW = calculateRequiredPower(for: contract)
                    let needsUpdate = !isEnabled ||
                        startHour != contract.startHour ||
                        endHour != contract.endHour ||
                        abs(power - requiredPowerW) > 500

                    if needsUpdate {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                Text("Recommended for contract:")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            HStack(spacing: 12) {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock")
                                        .font(.caption2)
                                    Text("\(formatHour(contract.startHour))–\(formatHour(contract.endHour))")
                                        .font(.caption.bold().monospacedDigit())
                                }
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt")
                                        .font(.caption2)
                                    Text("\(formatPowerKw(requiredPowerW))+")
                                        .font(.caption.bold().monospacedDigit())
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                            Text("Configured for current contract")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    // No contract - show general guidance
                    Text("Configure to enable daily P2P exports during contract window")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Supply/demand insight
                if let _ = contract {
                    Divider()
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                        Text("7pm+ is premium — supply drops while demand stays steady")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("Unable to load P2P settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func calculateRequiredPower(for contract: P2PContract) -> Int {
        let hoursPerDay = contract.hoursPerDay
        guard hoursPerDay > 0 else { return 0 }
        let dailyKwh = contract.dailyVolumeKwh
        let requiredKw = dailyKwh / Double(hoursPerDay)
        return Int(requiredKw * 1000)  // Convert to watts
    }

    private func formatPowerKw(_ watts: Int) -> String {
        let kw = Double(watts) / 1000.0
        return String(format: "%.1f kW", kw)
    }

    private func formatHour(_ hour: Int) -> String {
        if hour == 0 { return "12am" }
        if hour == 12 { return "12pm" }
        if hour < 12 { return "\(hour)am" }
        return "\(hour - 12)pm"
    }

    // MARK: - Active Contract Card

    private func activeContractCard(_ contract: P2PContract) -> some View {
        let perf = performanceCache[contract.id]
        let validation = validateExportOverride(for: contract)

        return VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "bolt.circle.fill")
                    .foregroundColor(.green)
                Text("Active \(contract.direction.displayName) Contract")
                    .font(.headline)
                Spacer()
                Button(action: { editingContract = contract }) {
                    Image(systemName: "pencil.circle")
                        .foregroundColor(.secondary)
                }
            }

            // Export Override Warning (sell contracts only)
            if contract.direction == .sell && validation.hasIssues && !isLoadingParams {
                exportOverrideWarning(validation, contract: contract)
            }

            Divider()

            // Contract terms
            contractTermsRow(contract)

            // Pace indicator (active)
            activePaceIndicator(contract)

            // Tier fill rates
            if let perf = perf {
                Divider()
                tierFillGauges(perf)

                Divider()
                performanceSummary(perf, contract: contract)
            } else {
                loadingPerformance
            }

            // Renewal info
            renewalInfo(contract)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
    }
    
    // MARK: - Future Contract Card
    
    private func futureContractCard(_ contract: P2PContract) -> some View {
        let perf = performanceCache[contract.id]
        let validation = validateExportOverride(for: contract)

        return VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .foregroundColor(.blue)
                Text("Upcoming \(contract.direction.displayName) Contract")
                    .font(.headline)
                Spacer()
                Button(action: { editingContract = contract }) {
                    Image(systemName: "pencil.circle")
                        .foregroundColor(.secondary)
                }
            }

            // Export Override Warning (sell contracts only)
            if contract.direction == .sell && validation.hasIssues && !isLoadingParams {
                exportOverrideWarning(validation, contract: contract)
            }

            Divider()

            // Contract terms
            contractTermsRow(contract)

            // Days until start
            futurePaceIndicator(contract)

            // Pre-match status
            if let perf = perf {
                Divider()
                preMatchStatus(perf, contract: contract)

                Divider()
                tierFillGauges(perf)
            } else {
                loadingPerformance
            }

            // Renewal info
            renewalInfo(contract)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
    }
    
    // MARK: - Completed Contract Card

    private func completedContractCard(_ contract: P2PContract) -> some View {
        let perf = performanceCache[contract.id]
        let hasProvisional = perf?.hasProvisionalData ?? false

        return VStack(alignment: .leading, spacing: 10) {
            // Header row with summary
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(contract.dateRangeString)
                            .font(.subheadline.bold())
                        // Warning badge if still has forecast data
                        if hasProvisional {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    Text(contract.hoursString + " AEST")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let perf = perf {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.0f%%", perf.overallFillRate))
                            .font(.subheadline.bold())
                            .foregroundColor(hasProvisional ? .orange : fillRateColor(perf.overallFillRate))
                        Text(hasProvisional ? "forecast" : "fill rate")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Button(action: { editingContract = contract }) {
                    Image(systemName: "pencil.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Forecast data warning for completed contracts
            if hasProvisional {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                    Text("Contains forecast data — import actuals from LocalVolts to finalize")
                        .font(.caption)
                }
                .foregroundColor(.orange)
                .padding(.vertical, 4)
            }

            // Compact tier gauges (always visible)
            if let perf = perf {
                HStack(spacing: 8) {
                    ForEach(perf.tierPerformance) { tierPerf in
                        compactTierGauge(tierPerf)
                    }
                }

                HStack {
                    Text(formatCurrency(perf.totalRevenue))
                        .font(.caption.bold())
                        .foregroundColor(hasProvisional ? .orange : .green)
                    Text("of")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatCurrency(contract.estimatedRevenue))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("forecast")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("\(perf.counterpartyCount) counterparties")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Expandable detail section
            if let perf = perf {
                completedContractDetail(contract: contract, perf: perf)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .overlay(
            hasProvisional ?
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1) : nil
        )
        .cornerRadius(12)
    }

    // MARK: - Completed Contract Detail (Expandable)

    @ViewBuilder
    private func completedContractDetail(contract: P2PContract, perf: P2PContractPerformance) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Divider()

                // Full tier fill rates (same as active/future)
                tierFillGauges(perf)

                Divider()

                // Performance summary
                performanceSummary(perf, contract: contract)

                // Price distribution note
                if !perf.tierPerformance.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Price Attribution")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        Text("Trades are attributed to tiers using midpoint boundaries. A trade at 23¢ between tiers at 20¢ and 26¢ would be assigned to the 20¢ tier (midpoint = 23¢).")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }

                // Renewal info if applicable
                renewalInfo(contract)
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "info.circle")
                    .font(.caption)
                Text("Show details")
                    .font(.caption)
            }
            .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Shared Components
    
    private func contractTermsRow(_ contract: P2PContract) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: contract.direction.icon)
                        .font(.caption)
                        .foregroundColor(contract.direction == .sell ? .green : .orange)
                    Text(contract.dateRangeString)
                        .font(.subheadline.bold())
                }
                Text(contract.hoursString + " AEST")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f kWh", contract.totalVolumeKwh))
                    .font(.subheadline.bold())
                Text(String(format: "%.1f¢ blended", contract.blendedPriceCents))
                    .font(.caption)
                    .foregroundColor(.purple)
            }
        }
    }
    
    private var loadingPerformance: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading performance...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    private func renewalInfo(_ contract: P2PContract) -> some View {
        Group {
            if let days = contract.renewalDays {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Renews every \(days) days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Export Override Warning

    @ViewBuilder
    private func exportOverrideWarning(_ validation: ExportOverrideValidation, contract: P2PContract) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Export Override Issue")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.orange)
            }

            ForEach(validation.issues, id: \.self) { issue in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(issue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Show what's needed
            VStack(alignment: .leading, spacing: 4) {
                Text("To fulfill this contract, configure:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("\(contract.startHour):00–\(contract.endHour):00")
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundColor(.primary)

                    HStack(spacing: 4) {
                        Image(systemName: "bolt")
                            .font(.caption2)
                        Text("\(String(format: "%.1f", Double(validation.requiredPowerW) / 1000.0)) kW+")
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundColor(.primary)
                }
            }
            .padding(.top, 4)

            // Link to settings
            if let site = api.selectedSite {
                NavigationLink(destination: TrainingParametersView(siteId: site.id, siteName: site.name)) {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Configure P2P Export")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundColor(.orange)
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
    
    // MARK: - Active Pace Indicator
    
    private func activePaceIndicator(_ contract: P2PContract) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.startOfDay(for: contract.startDate)
        let end = calendar.startOfDay(for: contract.endDate)

        let totalDays = max(1, calendar.dateComponents([.day], from: start, to: end).day! + 1)
        // Completed days = days before today (excluding current incomplete day)
        let rawElapsed = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        let completedDays = max(0, min(totalDays - 1, rawElapsed))
        // For progress calculation, use completed days ratio
        let progress = Double(completedDays) / Double(totalDays)

        let perf = performanceCache[contract.id]
        let matchedKwh = perf?.totalMatchedKwh ?? 0
        let expectedAtPace = contract.totalVolumeKwh * progress
        let paceRatio = expectedAtPace > 0 ? matchedKwh / expectedAtPace : (completedDays == 0 ? 1.0 : 0)

        let paceLabel: String
        let paceColor: Color
        if completedDays == 0 {
            paceLabel = "Just started"
            paceColor = .blue
        } else if paceRatio >= 0.8 {
            paceLabel = "On pace"
            paceColor = .green
        } else if paceRatio >= 0.5 {
            paceLabel = "Below pace"
            paceColor = .orange
        } else {
            paceLabel = "Behind"
            paceColor = .red
        }

        return VStack(spacing: 6) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.tertiarySystemBackground))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(paceColor)
                        .frame(width: max(0, geo.size.width * min(1, progress)), height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                // Show completed days (excluding current incomplete day)
                if completedDays == 0 {
                    Text("Day 1 of \(totalDays) (in progress)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(completedDays) of \(totalDays) days complete")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(paceColor)
                        .frame(width: 6, height: 6)
                    Text(paceLabel)
                        .font(.caption2)
                        .foregroundColor(paceColor)
                }

                if perf != nil {
                    Spacer()
                    Text(String(format: "%.0f / %.0f kWh", matchedKwh, contract.totalVolumeKwh))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Future Pace Indicator
    
    private func futurePaceIndicator(_ contract: P2PContract) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.startOfDay(for: contract.startDate)
        
        let daysUntilStart = calendar.dateComponents([.day], from: today, to: start).day ?? 0
        
        let statusText: String
        if daysUntilStart == 0 {
            statusText = "Starts today"
        } else if daysUntilStart == 1 {
            statusText = "Starts tomorrow"
        } else {
            statusText = "Starts in \(daysUntilStart) days"
        }
        
        return HStack {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundColor(.blue)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.blue)
            Spacer()
        }
    }
    
    // MARK: - Pre-Match Status
    
    private func preMatchStatus(_ perf: P2PContractPerformance, contract: P2PContract) -> some View {
        let preMatchPercent = contract.totalVolumeKwh > 0
            ? (perf.totalMatchedKwh / contract.totalVolumeKwh) * 100
            : 0
        
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundColor(.yellow)
                Text("Pre-Committed")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", preMatchPercent))
                    .font(.caption.bold())
                    .foregroundColor(preMatchPercent >= 50 ? .green : .orange)
            }
            
            HStack {
                Text(String(format: "%.1f kWh already matched", perf.totalMatchedKwh))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(perf.counterpartyCount) counterparties")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if preMatchPercent >= 50 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text("Strong pre-commitment — consider posting earlier next time")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Tier Fill Gauges
    
    private func tierFillGauges(_ perf: P2PContractPerformance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tier Fill Rates")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                // Legend when provisional data exists
                if perf.hasProvisionalData {
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.green)
                                .frame(width: 10, height: 6)
                            Text("Actual")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.orange.opacity(0.6))
                                .frame(width: 10, height: 6)
                            Text("Forecast")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            ForEach(perf.tierPerformance) { tierPerf in
                tierFillRow(tierPerf)
            }
        }
    }
    
    private func tierFillRow(_ tierPerf: P2PTierPerformance) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("\(Int(tierPerf.tier.priceCents))¢")
                    .font(.caption.bold())
                    .foregroundColor(.purple)
                    .frame(width: 35, alignment: .leading)

                // Fill gauge - stacked bars for actual (left) + provisional (right)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(.tertiarySystemBackground))
                            .frame(height: 8)

                        // Actual data bar (solid color)
                        if tierPerf.actualKwh > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(fillRateColor(tierPerf.fillRate))
                                .frame(width: max(0, geo.size.width * min(1, tierPerf.actualFillRate / 100)), height: 8)
                        }

                        // Provisional data bar (striped/lighter, stacked after actual)
                        if tierPerf.provisionalKwh > 0 {
                            let actualWidth = geo.size.width * min(1, tierPerf.actualFillRate / 100)
                            let provisionalWidth = geo.size.width * min(1 - tierPerf.actualFillRate / 100, tierPerf.provisionalFillRate / 100)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.orange.opacity(0.6))
                                .frame(width: max(0, provisionalWidth), height: 8)
                                .offset(x: actualWidth)
                        }
                    }
                }
                .frame(height: 8)

                Text(String(format: "%.0f%%", tierPerf.fillRate))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(fillRateColor(tierPerf.fillRate))
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Spacer()
                    .frame(width: 35)
                if tierPerf.hasProvisionalData {
                    // Show breakdown when provisional data exists
                    HStack(spacing: 4) {
                        Text(String(format: "%.1f", tierPerf.actualKwh))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("+")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", tierPerf.provisionalKwh))
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text(String(format: "/ %.1f kWh", tierPerf.tier.volumeKwh))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(String(format: "%.1f / %.1f kWh", tierPerf.matchedKwh, tierPerf.tier.volumeKwh))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }
    
    private func compactTierGauge(_ tierPerf: P2PTierPerformance) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(tierPerf.tier.priceCents))¢")
                .font(.caption2.bold())
                .foregroundColor(.purple)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(height: 6)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Actual data bar
                        if tierPerf.actualKwh > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(fillRateColor(tierPerf.fillRate))
                                .frame(width: max(0, geo.size.width * min(1, tierPerf.actualFillRate / 100)), height: 6)
                        }

                        // Provisional data bar (stacked)
                        if tierPerf.provisionalKwh > 0 {
                            let actualWidth = geo.size.width * min(1, tierPerf.actualFillRate / 100)
                            let provisionalWidth = geo.size.width * min(1 - tierPerf.actualFillRate / 100, tierPerf.provisionalFillRate / 100)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.orange.opacity(0.6))
                                .frame(width: max(0, provisionalWidth), height: 6)
                                .offset(x: actualWidth)
                        }
                    }
                }
                .frame(height: 6)
            }

            Text(String(format: "%.0f%%", tierPerf.fillRate))
                .font(.caption2.monospacedDigit())
                .foregroundColor(tierPerf.hasProvisionalData ? .orange : fillRateColor(tierPerf.fillRate))
        }
    }
    
    // MARK: - Performance Summary
    
    private func performanceSummary(_ perf: P2PContractPerformance, contract: P2PContract) -> some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Matched")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if perf.hasProvisionalData {
                        HStack(spacing: 2) {
                            Text(String(format: "%.1f", perf.actualKwh))
                                .font(.subheadline.bold())
                            Text("+")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.1f", perf.provisionalKwh))
                                .font(.subheadline.bold())
                                .foregroundColor(.orange)
                            Text("kWh")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(String(format: "%.1f kWh", perf.totalMatchedKwh))
                            .font(.subheadline.bold())
                    }
                }

                Spacer()

                VStack(alignment: .center, spacing: 2) {
                    Text("Revenue")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if perf.hasProvisionalData {
                        HStack(spacing: 2) {
                            Text(formatCurrency(perf.actualRevenue))
                                .font(.subheadline.bold())
                                .foregroundColor(.green)
                            Text("+")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(formatCurrency(perf.provisionalRevenue))
                                .font(.subheadline.bold())
                                .foregroundColor(.orange)
                        }
                    } else {
                        Text(formatCurrency(perf.totalRevenue))
                            .font(.subheadline.bold())
                            .foregroundColor(.green)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Fill Rate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f%%", perf.overallFillRate))
                        .font(.subheadline.bold())
                        .foregroundColor(perf.hasProvisionalData ? .orange : fillRateColor(perf.overallFillRate))
                }
            }

            // Provisional data note
            if perf.hasProvisionalData {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("Includes forecast data — replace with actual when available")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Spacer()
                }
            }

            // Revenue vs forecast
            HStack(spacing: 6) {
                Image(systemName: perf.revenueVsForecast >= 80 ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundColor(perf.revenueVsForecast >= 80 ? .green : .orange)
                    .font(.caption)
                Text(String(format: "%.0f%% of %@ forecast", perf.revenueVsForecast, formatCurrency(contract.estimatedRevenue)))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(perf.counterpartyCount) counterparties")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Aggregate Price Insights

    private func aggregatePriceInsights(_ contracts: [P2PContract]) -> some View {
        // Collect all tier performance data across contracts
        let allTierPerf = contracts.compactMap { performanceCache[$0.id] }
            .flatMap { $0.tierPerformance }

        // Group by rounded price (5¢ buckets)
        let priceGroups = buildPriceGroups(from: allTierPerf)
        let sortedBuckets = priceGroups.keys.sorted()
        let hasProvisional = contracts.contains { performanceCache[$0.id]?.hasProvisionalData ?? false }

        return Group {
            if allTierPerf.isEmpty {
                EmptyView()
            } else {
                aggregatePriceInsightsContent(
                    allTierPerf: allTierPerf,
                    priceGroups: priceGroups,
                    sortedBuckets: sortedBuckets,
                    hasProvisional: hasProvisional
                )
            }
        }
    }

    private func buildPriceGroups(from allTierPerf: [P2PTierPerformance]) -> [Int: (offered: Double, matched: Double, count: Int)] {
        var priceGroups: [Int: (offered: Double, matched: Double, count: Int)] = [:]
        for tierPerf in allTierPerf {
            let bucket = Int((tierPerf.tier.priceCents / 5).rounded()) * 5
            let existing = priceGroups[bucket] ?? (offered: 0, matched: 0, count: 0)
            priceGroups[bucket] = (
                offered: existing.offered + tierPerf.tier.volumeKwh,
                matched: existing.matched + tierPerf.matchedKwh,
                count: existing.count + 1
            )
        }
        return priceGroups
    }

    private func aggregatePriceInsightsContent(
        allTierPerf: [P2PTierPerformance],
        priceGroups: [Int: (offered: Double, matched: Double, count: Int)],
        sortedBuckets: [Int],
        hasProvisional: Bool
    ) -> some View {

        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("Fill rates by price cluster across all completed contracts. Useful when running multiple contracts simultaneously.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                ForEach(sortedBuckets, id: \.self) { bucket in
                    if let data = priceGroups[bucket] {
                        let fillRate = data.offered > 0 ? (data.matched / data.offered) * 100 : 0
                        HStack {
                            Text("\(bucket)–\(bucket + 4)¢")
                                .font(.caption.bold())
                                .foregroundColor(.purple)
                                .frame(width: 60, alignment: .leading)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(.tertiarySystemBackground))
                                        .frame(height: 8)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(fillRateColor(fillRate))
                                        .frame(width: max(0, geo.size.width * min(1, fillRate / 100)), height: 8)
                                }
                            }
                            .frame(height: 8)

                            Text(String(format: "%.0f%%", fillRate))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(fillRateColor(fillRate))
                                .frame(width: 40, alignment: .trailing)
                        }

                        HStack {
                            Spacer()
                                .frame(width: 60)
                            Text(String(format: "%.1f / %.1f kWh", data.matched, data.offered))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("(\(data.count) tier\(data.count == 1 ? "" : "s"))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }

                // Insight summary
                if let bestBucket = sortedBuckets.max(by: {
                    let r1 = priceGroups[$0]!.offered > 0 ? priceGroups[$0]!.matched / priceGroups[$0]!.offered : 0
                    let r2 = priceGroups[$1]!.offered > 0 ? priceGroups[$1]!.matched / priceGroups[$1]!.offered : 0
                    return r1 < r2
                }), let bestData = priceGroups[bestBucket] {
                    let bestRate = bestData.offered > 0 ? (bestData.matched / bestData.offered) * 100 : 0
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                        Text("Best fill rate at **\(bestBucket)–\(bestBucket + 4)¢** (\(String(format: "%.0f", bestRate))%)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if hasProvisional {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                        Text("Some contracts contain forecast data")
                            .font(.caption2)
                    }
                    .foregroundColor(.orange)
                }
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.caption)
                Text("Price Cluster Analysis")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(allTierPerf.count) tiers")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.purple)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private func fillRateColor(_ rate: Double) -> Color {
        if rate >= 75 { return .green }
        if rate >= 40 { return .orange }
        return .red
    }
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
    
    // MARK: - Data Loading
    
    func loadContracts() {
        guard let siteId = api.selectedSite?.id else {
            isLoading = false
            return
        }
        
        isLoading = true
        
        contracts = PowstonDataStore.shared.getP2PContracts(siteId: siteId)
        
        // Load performance for each contract
        Task { @MainActor in
            for contract in contracts {
                let perf = PowstonDataStore.shared.getP2PContractPerformance(contract)
                performanceCache[contract.id] = perf
            }
            isLoading = false
        }
    }
    
    private func refreshContracts() async {
        guard let siteId = api.selectedSite?.id else { return }
        
        contracts = PowstonDataStore.shared.getP2PContracts(siteId: siteId)
        
        for contract in contracts {
            let perf = PowstonDataStore.shared.getP2PContractPerformance(contract)
            performanceCache[contract.id] = perf
        }
    }
}

// MARK: - Preview

#Preview {
    P2PContractHistoryView(directionFilter: .sell)
        .environmentObject(PowstonAPI())
}
