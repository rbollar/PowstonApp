//
//  AnalysisSyncProgressView.swift
//  Powston
//
//  Unified loading screen for Profit Intelligence analyses
//  Shows sync progress with educational content while data loads
//

import SwiftUI
import Combine

// MARK: - Educational Tips

struct AnalysisTip: Identifiable {
    let id = UUID()
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
}

private let analysisTips: [AnalysisTip] = [
    AnalysisTip(
        icon: "chart.line.uptrend.xyaxis",
        iconColor: .orange,
        title: "Peak Export Analysis",
        description: "Finds your optimal sell price floor by analyzing which exports were profitable after accounting for replacement costs."
    ),
    AnalysisTip(
        icon: "gauge.with.needle.fill",
        iconColor: .blue,
        title: "Decision Efficiency",
        description: "Measures how well your system captured high sell prices and avoided expensive imports compared to what was available."
    ),
    AnalysisTip(
        icon: "lightbulb.fill",
        iconColor: .yellow,
        title: "Savings Breakdown",
        description: "Separates your total savings into solar value, battery arbitrage, and Powston's intelligent timing optimization."
    ),
    AnalysisTip(
        icon: "tag.fill",
        iconColor: .purple,
        title: "Bargain Hunter",
        description: "Identifies expensive imports that could have been avoided if the system had waited for cheaper prices in the forecast."
    ),
    AnalysisTip(
        icon: "person.2.fill",
        iconColor: .green,
        title: "Peer Power",
        description: "Analyzes P2P trading opportunities by finding price windows where both you and buyers benefit versus grid prices."
    ),
    AnalysisTip(
        icon: "clock.arrow.circlepath",
        iconColor: .cyan,
        title: "60 Days of History",
        description: "All analyses use 60 days of data to identify patterns across different weather, seasons, and price conditions."
    ),
    AnalysisTip(
        icon: "bolt.fill",
        iconColor: .orange,
        title: "5-Minute Resolution",
        description: "Data is captured at AEMO's 5-minute dispatch interval, giving precise insight into every trading decision."
    ),
    AnalysisTip(
        icon: "brain.head.profile",
        iconColor: .purple,
        title: "Forecast Analysis",
        description: "Some analyses compare actual outcomes against what the price forecast predicted to find improvement opportunities."
    )
]

// MARK: - Sync Progress View

struct AnalysisSyncProgressView: View {
    let progress: SyncProgress?
    let isCompact: Bool

    @State private var currentTipIndex = 0
    @State private var tipOpacity: Double = 1.0

    private let tipRotationTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    init(progress: SyncProgress?, isCompact: Bool = false) {
        self.progress = progress
        self.isCompact = isCompact
    }

    var body: some View {
        if isCompact {
            compactView
        } else {
            fullView
        }
    }

    // MARK: - Compact View (for hub banner)

    private var compactView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Syncing Analysis Data")
                        .font(.subheadline.weight(.medium))

                    if let progress = progress {
                        Text(progress.displayText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let progress = progress, progress.totalDays > 0 {
                    Text("\(Int(progress.percentComplete * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = progress, progress.totalDays > 0 {
                ProgressView(value: progress.percentComplete)
                    .progressViewStyle(.linear)
                    .tint(.purple)
            }
        }
        .padding()
        .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Full View (for analysis detail pages)

    private var fullView: some View {
        VStack(spacing: 24) {
            // Progress Section
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.purple.opacity(0.2), lineWidth: 6)
                        .frame(width: 80, height: 80)

                    if let progress = progress, progress.totalDays > 0 {
                        Circle()
                            .trim(from: 0, to: progress.percentComplete)
                            .stroke(Color.purple, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.3), value: progress.percentComplete)
                    }

                    VStack(spacing: 2) {
                        if let progress = progress, progress.totalDays > 0 {
                            Text("\(Int(progress.percentComplete * 100))%")
                                .font(.title3.bold().monospacedDigit())
                        } else {
                            ProgressView()
                        }
                    }
                }

                VStack(spacing: 4) {
                    Text("Syncing Analysis Data")
                        .font(.headline)

                    if let progress = progress {
                        Text(progress.displayText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if progress.recordsFetched > 0 {
                            Text("\(progress.recordsFetched.formatted()) records loaded")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("Checking for missing data...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

            // Educational Tip Section
            tipCard
                .onReceive(tipRotationTimer) { _ in
                    rotateTip()
                }
        }
    }

    // MARK: - Tip Card

    private var tipCard: some View {
        let tip = analysisTips[currentTipIndex]

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.min")
                    .foregroundStyle(.yellow)
                Text("Did You Know?")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                // Tip indicator dots
                HStack(spacing: 4) {
                    ForEach(0..<min(analysisTips.count, 8), id: \.self) { index in
                        Circle()
                            .fill(index == currentTipIndex ? Color.purple : Color.secondary.opacity(0.3))
                            .frame(width: 4, height: 4)
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: tip.icon)
                    .font(.title2)
                    .foregroundStyle(tip.iconColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(tip.title)
                        .font(.subheadline.weight(.semibold))

                    Text(tip.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .opacity(tipOpacity)
    }

    private func rotateTip() {
        withAnimation(.easeOut(duration: 0.2)) {
            tipOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            currentTipIndex = (currentTipIndex + 1) % analysisTips.count
            withAnimation(.easeIn(duration: 0.2)) {
                tipOpacity = 1
            }
        }
    }
}

// MARK: - Hub Sync Status Banner

struct AnalysisSyncStatusBanner: View {
    let syncState: AnalysisSyncState

    var body: some View {
        switch syncState {
        case .idle:
            EmptyView()

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Checking data availability...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

        case .syncing(let progress):
            AnalysisSyncProgressView(progress: progress, isCompact: true)

        case .ready(let recordCount):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Analysis data ready")
                    .font(.caption)
                if recordCount > 0 {
                    Text("(\(recordCount.formatted()) records)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Sync State

enum AnalysisSyncState: Equatable {
    case idle
    case checking
    case syncing(SyncProgress)
    case ready(recordCount: Int)
    case error(String)

    static func == (lhs: AnalysisSyncState, rhs: AnalysisSyncState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.checking, .checking): return true
        case (.syncing(let p1), .syncing(let p2)): return p1 == p2
        case (.ready(let c1), .ready(let c2)): return c1 == c2
        case (.error(let e1), .error(let e2)): return e1 == e2
        default: return false
        }
    }
}

// MARK: - Preview

#Preview("Full Loading") {
    AnalysisSyncProgressView(
        progress: SyncProgress(currentDay: 23, totalDays: 60, recordsFetched: 4320, status: "Fetching day 23")
    )
    .padding()
}

#Preview("Compact Loading") {
    AnalysisSyncProgressView(
        progress: SyncProgress(currentDay: 23, totalDays: 60, recordsFetched: 4320, status: "Fetching day 23"),
        isCompact: true
    )
    .padding()
}

#Preview("Banner States") {
    VStack(spacing: 16) {
        AnalysisSyncStatusBanner(syncState: .checking)
        AnalysisSyncStatusBanner(syncState: .syncing(SyncProgress(currentDay: 23, totalDays: 60, recordsFetched: 4320, status: "Fetching")))
        AnalysisSyncStatusBanner(syncState: .ready(recordCount: 8640))
        AnalysisSyncStatusBanner(syncState: .error("Network unavailable"))
    }
    .padding()
}
