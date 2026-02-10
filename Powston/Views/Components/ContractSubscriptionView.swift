//
//  ContractSubscriptionView.swift
//  Powston
//
//  Displays contract subscription tracking history - how counterparty
//  commitments change over time for your P2P contracts.
//

import SwiftUI
import Charts

// MARK: - Main Subscription Tracking View

struct ContractSubscriptionView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var tracker = ContractSubscriptionTracker.shared

    @State private var summaries: [LVContractSubscriptionSummary] = []
    @State private var selectedContract: LVContractSubscriptionSummary?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            headerSection

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if summaries.isEmpty {
                emptyStateView
            } else {
                // Contract list
                contractList

                // Selected contract detail
                if let selected = selectedContract {
                    contractDetailView(selected)
                }
            }
        }
        .onAppear { loadData() }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundColor(.purple)
                    Text("Subscription Tracking")
                        .font(.headline)
                }

                if let lastTime = tracker.lastTrackingTime {
                    Text("Last updated: \(lastTime, style: .relative) ago")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if tracker.trackedContracts > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(tracker.trackedContracts)")
                        .font(.title3.bold())
                        .foregroundColor(.purple)
                    Text("tracked")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.largeTitle)
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Tracked Contracts")
                .font(.subheadline.weight(.medium))

            Text("When you sync your LocalVolts orders, subscription changes will be tracked automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // MARK: - Contract List

    private var contractList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Contracts")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)

            ForEach(summaries) { summary in
                contractRow(summary)
            }
        }
    }

    private func contractRow(_ summary: LVContractSubscriptionSummary) -> some View {
        let isSelected = selectedContract?.id == summary.id

        return Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedContract = isSelected ? nil : summary
            }
        }) {
            HStack(spacing: 12) {
                // Fill rate indicator
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: summary.currentFillRate)
                        .stroke(fillRateColor(summary.currentFillRate), lineWidth: 3)
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String(format: "%.0f%%", summary.currentFillRate * 100))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.primary)
                )

                // Contract info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let price = summary.priceCents {
                            Text(String(format: "%.0f¢", price))
                                .font(.subheadline.bold())
                        } else {
                            Text("Market")
                                .font(.subheadline.bold())
                        }

                        if summary.hadCancellations {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }

                        if summary.isClosed {
                            Text("Closed")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }

                    Text("\(summary.dateFrom, format: .dateTime.month().day()) - \(summary.dateTo, format: .dateTime.month().day())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Stats
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f kWh", summary.currentSubscribedKwh))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.green)

                    Text("\(summary.currentCounterparties) buyer\(summary.currentCounterparties == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isSelected ? 90 : 0))
            }
            .padding(12)
            .background(isSelected ? Color.purple.opacity(0.1) : Color(.tertiarySystemBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Contract Detail

    private func contractDetailView(_ summary: LVContractSubscriptionSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // Snapshot chart
            snapshotChart(orderId: summary.orderId)

            // Change history
            changeHistory(orderId: summary.orderId)
        }
        .padding(.top, 8)
    }

    private func snapshotChart(orderId: String) -> some View {
        let snapshots = tracker.getSnapshots(orderId: orderId)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Subscription Over Time")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            if snapshots.count < 2 {
                Text("More data points needed for chart")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                Chart {
                    ForEach(snapshots) { snapshot in
                        LineMark(
                            x: .value("Time", snapshot.snapshotTime),
                            y: .value("Subscribed", snapshot.subscribedVolumeKwh)
                        )
                        .foregroundStyle(Color.green)

                        AreaMark(
                            x: .value("Time", snapshot.snapshotTime),
                            y: .value("Subscribed", snapshot.subscribedVolumeKwh)
                        )
                        .foregroundStyle(Color.green.opacity(0.2))
                    }

                    // Offered volume as reference line
                    if let first = snapshots.first {
                        RuleMark(y: .value("Offered", first.offeredVolumeKwh))
                            .foregroundStyle(Color.gray.opacity(0.5))
                            .lineStyle(StrokeStyle(dash: [5, 3]))
                    }
                }
                .frame(height: 120)
                .chartYAxisLabel("kWh")
            }
        }
    }

    private func changeHistory(orderId: String) -> some View {
        let changes = tracker.getSubscriptionHistory(orderId: orderId)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Change History")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(changes.count) events")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if changes.isEmpty {
                Text("No changes recorded yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ForEach(changes.suffix(5)) { change in
                    changeRow(change)
                }

                if changes.count > 5 {
                    Text("+ \(changes.count - 5) more events")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func changeRow(_ change: LVSubscriptionChange) -> some View {
        HStack(spacing: 8) {
            Image(systemName: change.isPositive ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundColor(change.isPositive ? .green : .orange)
                .font(.caption)

            Text(change.description)
                .font(.caption)
                .foregroundColor(.primary)

            Spacer()

            Text(change.changeTime, style: .relative)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func fillRateColor(_ rate: Double) -> Color {
        if rate >= 0.8 { return .green }
        if rate >= 0.5 { return .yellow }
        if rate >= 0.2 { return .orange }
        return .red
    }

    private func loadData() {
        guard let siteId = api.selectedSiteId else { return }

        isLoading = true
        summaries = tracker.getTrackedContractSummaries(siteId: siteId)
        isLoading = false
    }
}

// MARK: - Compact Card for Dashboard

struct ContractSubscriptionCard: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var tracker = ContractSubscriptionTracker.shared

    @State private var latestSnapshots: [LVContractSnapshot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(.purple)
                Text("Subscription Tracking")
                    .font(.headline)
                Spacer()

                if tracker.changesDetected > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundColor(.orange)
                        Text("\(tracker.changesDetected)")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                    }
                }
            }

            if latestSnapshots.isEmpty {
                Text("No contracts being tracked")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                // Show top 3 active contracts
                ForEach(latestSnapshots.prefix(3)) { snapshot in
                    snapshotRow(snapshot)
                }

                if latestSnapshots.count > 3 {
                    Text("+ \(latestSnapshots.count - 3) more contracts")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .onAppear { loadData() }
    }

    private func snapshotRow(_ snapshot: LVContractSnapshot) -> some View {
        HStack(spacing: 8) {
            // Fill indicator
            let fillRate = snapshot.fillRate
            Circle()
                .fill(fillRate > 0.5 ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            // Price
            if let price = snapshot.priceCents {
                Text(String(format: "%.0f¢", price))
                    .font(.caption.bold())
            }

            // Date range
            Text("\(snapshot.dateFrom, format: .dateTime.month().day())")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            // Fill rate
            Text(snapshot.fillRateString)
                .font(.caption.monospacedDigit())
                .foregroundColor(fillRate > 0.5 ? .green : .orange)

            Text("filled")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func loadData() {
        guard let siteId = api.selectedSiteId else { return }
        latestSnapshots = tracker.getLatestSnapshots(siteId: siteId, activeOnly: true)
    }
}

// MARK: - Preview

#Preview {
    ContractSubscriptionView()
        .environmentObject(PowstonAPI())
        .padding()
}
