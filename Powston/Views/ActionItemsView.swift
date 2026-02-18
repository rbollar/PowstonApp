//
//  ActionItemsView.swift
//  Powston
//
//  Unified Action Items view that consolidates recommendations
//  from Scorecard, Peak Analysis, Bargain Hunter, Peer Power, and Decision Efficiency.
//

import SwiftUI

struct ActionItemsView: View {
    @EnvironmentObject var api: PowstonAPI
    @ObservedObject private var engine = ActionItemsEngine.shared
    @AppStorage("optimization_goal") private var optimizationGoalRaw: String = "balanced"
    @AppStorage("p2p_enabled_in_action_items") private var p2pEnabled: Bool = false

    private var goal: UserGoal {
        UserGoal(from: optimizationGoalRaw)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Goal selector header
                    goalHeader

                    if engine.isLoading {
                        loadingView
                    } else if let result = engine.result {
                        if result.items.isEmpty {
                            emptyState
                        } else {
                            actionItemsContent(result)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding()
            }
            .navigationTitle("Action Items")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await refresh(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(engine.isLoading)
                }
            }
            .task {
                await refresh()
            }
            .onChange(of: optimizationGoalRaw) { _, _ in
                Task { await refresh(force: true) }
            }
        }
    }

    // MARK: - Goal Header

    private var goalHeader: some View {
        HStack {
            Menu {
                ForEach(UserGoal.allCases) { userGoal in
                    Button {
                        optimizationGoalRaw = userGoal.rawValue
                    } label: {
                        HStack {
                            Image(systemName: userGoal.icon)
                            Text(userGoal.displayName)
                            if goal == userGoal {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: goal.icon)
                        .foregroundStyle(.blue)
                    Text(goal.displayName)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            if let result = engine.result, !result.items.isEmpty {
                let displayItems = p2pEnabled ? result.items : result.coreItems
                let displayImpact = engine.calculateCombinedImpact(displayItems)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("~$\(Int(displayImpact))/mo")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("realistic")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(engine.loadingProgress)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("All Optimized", systemImage: "checkmark.circle.fill")
        } description: {
            Text("No recommendations at this time. Your system is performing well!")
        } actions: {
            Button("Refresh") {
                Task { await refresh(force: true) }
            }
        }
    }

    // MARK: - Action Items Content

    @ViewBuilder
    private func actionItemsContent(_ result: ActionItemsResult) -> some View {
        // Core strategies (non-P2P) grouped by priority
        if !result.highPriority.isEmpty {
            prioritySection(
                title: "High Priority",
                icon: "exclamationmark.circle.fill",
                color: .red,
                items: result.highPriority
            )
        }

        if !result.mediumPriority.isEmpty {
            prioritySection(
                title: "Consider",
                icon: "circle.fill",
                color: .yellow,
                items: result.mediumPriority
            )
        }

        if !result.lowPriority.isEmpty {
            prioritySection(
                title: "Optional",
                icon: "circle",
                color: .green,
                items: result.lowPriority
            )
        }

        // P2P as a separate additive section with toggle
        if !result.p2pItems.isEmpty {
            p2pSection(result.p2pItems)
        }

        // Combined impact footer
        impactSummary(result)
    }

    // MARK: - Priority Section

    private func prioritySection(
        title: String,
        icon: String,
        color: Color,
        items: [ActionItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
            }

            ForEach(items) { item in
                ActionItemCard(item: item)
            }
        }
    }

    // MARK: - P2P Section

    private func p2pSection(_ items: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with toggle
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.purple)
                Text("P2P Trading")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $p2pEnabled)
                    .labelsHidden()
                    .tint(.purple)
            }

            if p2pEnabled {
                Text("Sell directly to other energy users via LocalVolts. This is additive revenue on top of your existing spot market earnings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(items) { item in
                    ActionItemCard(item: item)
                }
            } else {
                Text("Enable to see P2P trading opportunities. P2P is additive — it doesn't change your existing strategy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.purple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.purple.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Impact Summary

    private func impactSummary(_ result: ActionItemsResult) -> some View {
        // Only include P2P in impact if the user has opted in
        let itemsForImpact = p2pEnabled ? result.items : result.coreItems
        let breakdown = engine.calculateImpactBreakdown(itemsForImpact)
        let combinedImpact = engine.calculateCombinedImpact(itemsForImpact)

        return VStack(spacing: 12) {
            Divider()
                .padding(.vertical, 4)

            // Realistic total
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Realistic Potential")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("$\(Int(combinedImpact))/mo")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.green)
                }

                Spacer()
            }

            // Strategy breakdown
            VStack(alignment: .leading, spacing: 8) {
                if let export = breakdown.bestExportStrategy {
                    strategyRow(
                        label: "Export strategy",
                        item: export,
                        alternatives: breakdown.exportAlternatives,
                        color: .green
                    )
                }

                if let import_ = breakdown.bestImportStrategy {
                    strategyRow(
                        label: "Import strategy",
                        item: import_,
                        alternatives: breakdown.importAlternatives,
                        color: .blue
                    )
                }

                if p2pEnabled, let p2p = breakdown.p2pOpportunity, p2p.potentialImpact > 0 {
                    // If P2P replaced export (no bestExportStrategy), show as revenue strategy
                    // Otherwise show as additive
                    let replacesExport = breakdown.bestExportStrategy == nil
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(replacesExport ? "Revenue strategy" : "P2P")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !replacesExport {
                                    Text("(additive)")
                                        .font(.caption2)
                                        .foregroundStyle(.purple)
                                }
                                if replacesExport && breakdown.exportAlternatives > 0 {
                                    Text("(\(breakdown.exportAlternatives) spot alt\(breakdown.exportAlternatives == 1 ? "" : "s"))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Text(p2p.title)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("+$\(Int(p2p.potentialImpact))")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.purple)
                    }
                }
            }

            // Explanation
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("Strategies in the same category overlap. Showing best option per category.")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)

            if result.conflictsResolved > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                    Text("\(result.conflictsResolved) conflicting item\(result.conflictsResolved == 1 ? "" : "s") filtered for \(result.goal.displayName) goal")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func strategyRow(label: String, item: ActionItem, alternatives: Int, color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if alternatives > 0 {
                        Text("(\(alternatives) alt\(alternatives == 1 ? "" : "s"))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(item.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer()
            Text("+$\(Int(item.potentialImpact))")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(color)
        }
    }

    // MARK: - Refresh

    private func refresh(force: Bool = false) async {
        guard let siteId = api.selectedSiteId else { return }
        await engine.refreshActionItems(
            siteId: siteId,
            goal: goal,
            api: api,
            forceRefresh: force
        )
    }
}

// MARK: - Action Item Card

struct ActionItemCard: View {
    let item: ActionItem
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack {
                // Source icon
                Image(systemName: item.source.icon)
                    .foregroundStyle(sourceColor)
                    .frame(width: 24)

                // Title and source
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(item.source.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Impact
                Text(item.formattedImpact)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(item.potentialImpact >= 0 ? .green : .red)
            }

            // Description (expandable)
            if isExpanded {
                Text(item.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)

                // Confidence indicator
                HStack(spacing: 4) {
                    Text("Confidence:")
                        .font(.caption2)
                    ConfidenceIndicator(confidence: item.confidence)
                }
                .padding(.leading, 32)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    private var sourceColor: Color {
        switch item.source.color {
        case "cyan": return .cyan
        case "orange": return .orange
        case "green": return .green
        case "purple": return .purple
        case "blue": return .blue
        default: return .secondary
        }
    }
}

// MARK: - Confidence Indicator

struct ConfidenceIndicator: View {
    let confidence: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                Circle()
                    .fill(index < filledDots ? Color.blue : Color.gray.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var filledDots: Int {
        Int(ceil(confidence * 5))
    }
}

// MARK: - Dashboard Card (Compact Version)

struct ActionItemsDashboardCard: View {
    @EnvironmentObject var api: PowstonAPI
    @ObservedObject private var engine = ActionItemsEngine.shared
    @AppStorage("optimization_goal") private var optimizationGoalRaw: String = "balanced"
    @AppStorage("p2p_enabled_in_action_items") private var p2pEnabled: Bool = false

    private var goal: UserGoal {
        UserGoal(from: optimizationGoalRaw)
    }

    var body: some View {
        NavigationLink(destination: ActionItemsView()) {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                    Text("Action Items")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if engine.isLoading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Analyzing...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = engine.result, !result.items.isEmpty {
                    let displayItems = p2pEnabled ? result.items : result.coreItems
                    let breakdown = engine.calculateImpactBreakdown(displayItems)
                    let combinedImpact = engine.calculateCombinedImpact(displayItems)

                    // Compact strategy summary
                    HStack(spacing: 12) {
                        // Strategy buckets
                        VStack(alignment: .leading, spacing: 4) {
                            if let export = breakdown.bestExportStrategy {
                                HStack(spacing: 4) {
                                    Circle().fill(Color.green).frame(width: 6, height: 6)
                                    Text("Export: +$\(Int(export.potentialImpact))")
                                        .font(.caption)
                                }
                            }
                            if let import_ = breakdown.bestImportStrategy {
                                HStack(spacing: 4) {
                                    Circle().fill(Color.blue).frame(width: 6, height: 6)
                                    Text("Import: +$\(Int(import_.potentialImpact))")
                                        .font(.caption)
                                }
                            }
                            if p2pEnabled, breakdown.hasP2P, let p2p = breakdown.p2pOpportunity {
                                HStack(spacing: 4) {
                                    Circle().fill(Color.purple).frame(width: 6, height: 6)
                                    Text("P2P: +$\(Int(p2p.potentialImpact))")
                                        .font(.caption)
                                }
                            }
                        }

                        Spacer()

                        // Realistic total
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("~$\(Int(combinedImpact))")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(.green)
                            Text("per month")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Show count if there are alternatives
                    let totalAlts = breakdown.exportAlternatives + breakdown.importAlternatives
                    if totalAlts > 0 {
                        Text("\(displayItems.count) strategies analyzed, showing best per category")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    // No cached results - show teaser instead of triggering analysis
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.yellow)
                        Text("Tap to analyze recommendations")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
