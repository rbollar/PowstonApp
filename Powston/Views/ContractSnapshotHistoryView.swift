//
//  ContractSnapshotHistoryView.swift
//  Powston
//
//  Shows contract subscription history over time.
//  Displays counterparty commitments, fill rate progression, and change timeline.
//  Uses trade performance data as fallback when snapshot data is not available.
//

import SwiftUI
import Charts

// MARK: - Contract Snapshot History View

struct ContractSnapshotHistoryView: View {
    let group: LVOrderGroup
    let siteId: Int

    @State private var snapshots: [LVContractSnapshot] = []
    @State private var counterpartySnapshots: [String: [LVCounterpartySnapshot]] = [:]
    @State private var performance: P2PContractPerformance?
    @State private var isLoading = true

    private let dataStore = PowstonDataStore.shared

    // Computed properties that use performance as fallback
    private var matchedKwh: Double {
        if let snapshot = snapshots.last, snapshot.subscribedVolumeKwh > 0 {
            return snapshot.subscribedVolumeKwh
        }
        return performance?.totalMatchedKwh ?? 0
    }

    private var settledKwh: Double {
        if let snapshot = snapshots.last, snapshot.settledVolumeKwh > 0 {
            return snapshot.settledVolumeKwh
        }
        // For completed contracts, matched ≈ settled
        return performance?.totalMatchedKwh ?? 0
    }

    private var fillRate: Double {
        guard group.totalVolumeKwh > 0 else { return 0 }
        return (matchedKwh / group.totalVolumeKwh) * 100
    }

    private var counterpartyCount: Int {
        if let snapshot = snapshots.last, snapshot.counterpartyCount > 0 {
            return snapshot.counterpartyCount
        }
        return performance?.counterpartyCount ?? 0
    }

    private var totalRevenue: Double {
        performance?.totalRevenue ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Contract header
                contractHeader

                // Current status summary
                currentStatusCard

                // Fill rate chart (if multiple snapshots)
                if snapshots.count > 1 {
                    fillRateChart
                }

                // Counterparty breakdown
                counterpartyBreakdown

                // Snapshot timeline (only if we have snapshots)
                if !snapshots.isEmpty {
                    snapshotTimeline
                }
            }
            .padding()
        }
        .navigationTitle("Contract History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadData() }
    }

    // MARK: - Contract Header

    private var contractHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: group.isSell ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(group.isSell ? .green : .orange)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.isSell ? "Sell" : "Buy") Contract")
                        .font(.headline)
                    Text(formatDateRange(from: group.dateFrom, to: group.dateTo))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f kWh", group.totalVolumeKwh))
                        .font(.headline)
                    Text(group.priceRangeString)
                        .font(.subheadline)
                        .foregroundColor(.purple)
                }
            }

            // Contract state
            let state = getContractState()
            HStack {
                Image(systemName: state.icon)
                    .foregroundColor(state.color)
                Text(state.label)
                    .font(.caption)
                    .foregroundColor(state.color)

                Spacer()

                Text("Orders: \(group.orderIds.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Current Status Card

    private var currentStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(getContractState() == .completed ? "Final Results" : "Current Status")
                .font(.headline)

            HStack(spacing: 20) {
                // Fill rate gauge
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(Color(.tertiarySystemBackground), lineWidth: 8)
                            .frame(width: 60, height: 60)
                        Circle()
                            .trim(from: 0, to: min(1, fillRate / 100))
                            .stroke(fillRateColor(fillRate), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .frame(width: 60, height: 60)
                            .rotationEffect(.degrees(-90))
                        Text(String(format: "%.0f%%", fillRate))
                            .font(.caption.bold())
                    }
                    Text("Fill Rate")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Stats
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Matched", systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.1f kWh", matchedKwh))
                            .font(.caption.bold())
                    }

                    if totalRevenue > 0 {
                        HStack {
                            Label(group.isSell ? "Revenue" : "Cost", systemImage: "dollarsign.circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatCurrency(totalRevenue))
                                .font(.caption.bold())
                                .foregroundColor(group.isSell ? .green : .orange)
                        }
                    }

                    HStack {
                        Label(group.isSell ? "Buyers" : "Sellers", systemImage: "person.2.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(counterpartyCount)")
                            .font(.caption.bold())
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Data source indicator
            if snapshots.isEmpty && performance != nil {
                Text("Based on trade data")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if let latest = snapshots.last {
                Text("Updated \(formatRelativeTime(latest.snapshotTime))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Fill Rate Chart

    @ViewBuilder
    private var fillRateChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fill Rate Over Time")
                .font(.headline)

            if #available(iOS 16.0, *) {
                Chart(snapshots) { snapshot in
                    let snapshotFillRate = group.totalVolumeKwh > 0
                        ? (snapshot.subscribedVolumeKwh / group.totalVolumeKwh) * 100
                        : 0

                    LineMark(
                        x: .value("Time", snapshot.snapshotTime),
                        y: .value("Fill %", snapshotFillRate)
                    )
                    .foregroundStyle(Color.blue)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", snapshot.snapshotTime),
                        y: .value("Fill %", snapshotFillRate)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Time", snapshot.snapshotTime),
                        y: .value("Fill %", snapshotFillRate)
                    )
                    .foregroundStyle(Color.blue)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text("\(v)%")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 150)
            } else {
                // Fallback for iOS 15
                Text("Chart requires iOS 16+")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Counterparty Breakdown

    private var counterpartyBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.isSell ? "Buyer Breakdown" : "Seller Breakdown")
                .font(.headline)

            // Get counterparties from snapshots or performance
            let counterparties = getAllCounterparties()

            if counterparties.isEmpty {
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                    Text("No \(group.isSell ? "buyers" : "sellers") recorded")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(counterparties.sorted { $0.totalVolume > $1.totalVolume }, id: \.name) { cp in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cp.name)
                                .font(.subheadline)
                            if let matchTime = cp.matchTime {
                                Text("Matched \(formatRelativeTime(matchTime))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f kWh", cp.totalVolume))
                                .font(.subheadline.bold())

                            let percentage = group.totalVolumeKwh > 0
                                ? (cp.totalVolume / group.totalVolumeKwh) * 100
                                : 0
                            Text(String(format: "%.1f%%", percentage))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    if cp.name != counterparties.sorted(by: { $0.totalVolume > $1.totalVolume }).last?.name {
                        Divider()
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Snapshot Timeline

    private var snapshotTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Snapshot History")
                    .font(.headline)
                Spacer()
                Text("\(snapshots.count) snapshots")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(snapshots.reversed()) { snapshot in
                HStack(alignment: .top, spacing: 12) {
                    // Timeline dot
                    VStack {
                        Circle()
                            .fill(snapshot == snapshots.last ? Color.blue : Color.gray)
                            .frame(width: 10, height: 10)
                        if snapshot != snapshots.first {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 2, height: 30)
                        }
                    }

                    // Snapshot info
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatDateTime(snapshot.snapshotTime))
                            .font(.caption.bold())

                        let snapshotFillRate = group.totalVolumeKwh > 0
                            ? (snapshot.subscribedVolumeKwh / group.totalVolumeKwh) * 100
                            : 0

                        HStack(spacing: 12) {
                            Label(String(format: "%.1f kWh", snapshot.subscribedVolumeKwh), systemImage: "bolt.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text(String(format: "%.0f%%", snapshotFillRate))
                                .font(.caption.bold())
                                .foregroundColor(fillRateColor(snapshotFillRate))

                            Label("\(snapshot.counterpartyCount)", systemImage: "person.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Data Loading

    private func loadData() {
        isLoading = true

        // Load trade performance (works for all contracts)
        let contract = group.toP2PContract()
        performance = dataStore.getP2PContractPerformance(contract)

        // Debug: Log what we got
        print("📊 ContractHistory: Loading for \(group.direction) \(formatDateRange(from: group.dateFrom, to: group.dateTo))")
        print("   └─ siteId=\(contract.siteId), direction=\(contract.direction)")
        if let perf = performance {
            print("   └─ Performance: \(String(format: "%.1f", perf.totalMatchedKwh)) kWh, \(perf.counterpartyCount) counterparties, $\(String(format: "%.2f", perf.totalRevenue))")
            print("   └─ counterpartyBreakdown: \(perf.counterpartyBreakdown.count) items")
            for cp in perf.counterpartyBreakdown.prefix(5) {
                print("      • \(cp.counterpartyName): \(String(format: "%.1f", cp.matchedKwh)) kWh")
            }
        } else {
            print("   └─ Performance: nil")
        }

        // Load snapshots for all orders in the group
        var allSnapshots: [LVContractSnapshot] = []
        var allCounterpartiesDict: [String: [LVCounterpartySnapshot]] = [:]

        for orderId in group.orderIds {
            let orderSnapshots = dataStore.getContractSnapshots(orderId: orderId)
            allSnapshots.append(contentsOf: orderSnapshots)

            let cpSnapshots = dataStore.getCounterpartySnapshots(orderId: orderId)
            allCounterpartiesDict[orderId] = cpSnapshots
        }

        // Sort by time and deduplicate by time (keep highest subscribed)
        let groupedByTime = Dictionary(grouping: allSnapshots) { snapshot in
            Calendar.current.startOfDay(for: snapshot.snapshotTime)
        }

        snapshots = groupedByTime.values.compactMap { daySnapshots in
            daySnapshots.max { $0.subscribedVolumeKwh < $1.subscribedVolumeKwh }
        }.sorted { $0.snapshotTime < $1.snapshotTime }

        counterpartySnapshots = allCounterpartiesDict
        isLoading = false
    }

    // MARK: - Helpers

    private struct CounterpartySummary: Identifiable {
        let name: String
        let totalVolume: Double
        let matchTime: Date?

        var id: String { name }
    }

    private func getAllCounterparties() -> [CounterpartySummary] {
        var counterpartyMap: [String: (volume: Double, matchTime: Date?)] = [:]

        // First try to get from snapshots
        for (_, cpSnapshots) in counterpartySnapshots {
            for cp in cpSnapshots {
                let existing = counterpartyMap[cp.counterpartyName]
                let newVolume = cp.dealtVolumeKwh + cp.settledVolumeKwh

                // Keep the highest volume and earliest match time
                if existing == nil || newVolume > existing!.volume {
                    counterpartyMap[cp.counterpartyName] = (newVolume, cp.matchTime ?? existing?.matchTime)
                }
            }
        }

        // Check if snapshot data has any actual volume
        let snapshotTotalVolume = counterpartyMap.values.reduce(0.0) { $0 + $1.volume }
        print("   🔍 getAllCounterparties: snapshotMap=\(counterpartyMap.count), snapshotVol=\(String(format: "%.1f", snapshotTotalVolume))")

        // If no snapshot data OR snapshot has 0 volume, use performance counterparty data
        if (counterpartyMap.isEmpty || snapshotTotalVolume == 0), let perf = performance {
            print("   🔍 Falling back to performance: \(perf.counterpartyBreakdown.count) counterparties")
            counterpartyMap.removeAll()  // Clear any 0-volume entries
            for cp in perf.counterpartyBreakdown {
                counterpartyMap[cp.counterpartyName] = (cp.matchedKwh, nil)
            }
        } else if counterpartyMap.isEmpty && performance == nil {
            print("   🔍 No data: counterpartyMap empty AND performance is nil")
        } else {
            print("   🔍 Using snapshot data (not falling back)")
        }

        print("   🔍 Final counterpartyMap: \(counterpartyMap.count) entries")
        return counterpartyMap.map { name, data in
            CounterpartySummary(name: name, totalVolume: data.volume, matchTime: data.matchTime)
        }
    }

    private func getContractState() -> ContractState {
        let today = Calendar.current.startOfDay(for: Date())
        let startDay = Calendar.current.startOfDay(for: group.dateFrom)
        let endDay = Calendar.current.startOfDay(for: group.dateTo)

        if today < startDay {
            return .future
        } else if today > endDay {
            return .completed
        } else {
            return .active
        }
    }

    private func fillRateColor(_ rate: Double) -> Color {
        if rate >= 75 { return .green }
        if rate >= 40 { return .orange }
        return .red
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

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        return formatter.string(from: date)
    }

    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
}

// MARK: - LVContractSnapshot Identifiable Extension

extension LVContractSnapshot: Equatable {
    static func == (lhs: LVContractSnapshot, rhs: LVContractSnapshot) -> Bool {
        lhs.id == rhs.id
    }
}
