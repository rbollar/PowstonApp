//
//  UnfilledOpportunityCard.swift
//  Powston
//
//  Alert card for unfilled P2P sell orders that could be repriced
//  to capture value vs exporting at spot
//

import SwiftUI

struct UnfilledOpportunityCard: View {
    let alert: OpportunityAlert

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with urgency indicator
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(urgencyColor)
                Text("Repricing Opportunity")
                    .font(.headline)
                Spacer()
                urgencyBadge
            }

            Divider()

            // Main message
            Text(alert.headline)
                .font(.subheadline.weight(.medium))

            // Price comparison
            HStack(spacing: 16) {
                priceColumn(label: "Spot", value: alert.spotPriceCents, color: .red)
                if let clearing = alert.marketClearingCents {
                    priceColumn(label: "Market", value: clearing, color: .green)
                }
                priceColumn(label: "Your Offer", value: alert.yourAvgOfferCents, color: .blue)
            }

            // Recommendation
            VStack(alignment: .leading, spacing: 4) {
                Text("Consider lowering your offer to capture this volume before it exports at spot.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let clearing = alert.marketClearingCents,
                   let suggested = alert.opportunities.first?.suggestedPriceCents {
                    Text("Suggested price: \(String(format: "%.1f¢", suggested)) (just below market clearing)")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.green)
                }
            }

            // Expand to show individual opportunities
            if alert.opportunities.count > 1 {
                Button(action: { withAnimation { isExpanded.toggle() } }) {
                    HStack {
                        Text(isExpanded ? "Hide details" : "Show \(alert.opportunities.count) opportunities")
                            .font(.caption)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .foregroundColor(.accentColor)
                }

                if isExpanded {
                    VStack(spacing: 8) {
                        ForEach(alert.opportunities) { opp in
                            opportunityRow(opp)
                        }
                    }
                    .padding(.top, 4)
                }
            }

            // Action hint
            HStack {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                Text("Adjust in LocalVolts portal")
                    .font(.caption)
                Spacer()
                if let lastOpp = alert.opportunities.first {
                    Text(lastOpp.urgency.rawValue)
                        .font(.caption.bold())
                        .foregroundColor(urgencyColor)
                }
            }
            .foregroundColor(.secondary)
        }
        .padding()
        .background(urgencyColor.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(urgencyColor.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private var urgencyColor: Color {
        guard let urgency = alert.opportunities.first?.urgency else { return .orange }
        switch urgency {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .green
        }
    }

    private var urgencyBadge: some View {
        let urgency = alert.opportunities.first?.urgency ?? .medium
        return Text(urgency.rawValue)
            .font(.caption2.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(urgencyColor)
            .cornerRadius(8)
    }

    private func priceColumn(label: String, value: Double, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(String(format: "%.1f¢", value))
                .font(.subheadline.bold().monospacedDigit())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
    }

    private func opportunityRow(_ opp: UnfilledOpportunity) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")

        return HStack {
            Text("\(formatter.string(from: opp.periodStart))–\(formatter.string(from: opp.periodEnd))")
                .font(.caption.monospacedDigit())
            Spacer()
            Text(String(format: "%.1f kWh", opp.unfilledKwh))
                .font(.caption.monospacedDigit())
            Spacer()
            Text(String(format: "@ %.1f¢", opp.yourOfferCents))
                .font(.caption.monospacedDigit())
                .foregroundColor(.blue)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(6)
    }
}

// MARK: - Compact Version for Banners

struct UnfilledOpportunityBanner: View {
    let alert: OpportunityAlert
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.headline)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.primary)
                    Text("Spot: \(String(format: "%.1f¢", alert.spotPriceCents)) — tap to review")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}
