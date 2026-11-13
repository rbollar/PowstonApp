//
//  MarketROIView.swift
//  Powston
//
//  Battery ROI: what the battery earned or saved, split into grid arbitrage,
//  solar time-shift, and self-supply (from /api/market_roi).
//

import SwiftUI

struct MarketROIView: View {
    @EnvironmentObject var api: PowstonAPI

    enum Period: Int, CaseIterable, Identifiable {
        case yesterday = 1
        case week = 7
        case month = 30

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .yesterday: return "Yesterday"
            case .week: return "7 Days"
            case .month: return "30 Days"
            }
        }
    }

    @State private var period: Period = .week
    @State private var roi: MarketROI?
    @State private var message: String?
    @State private var isLoading = false

    /// The ROI endpoint is per inverter; use the site's primary
    private var inverterId: Int? {
        if let primary = api.selectedSite?.primaryInverterId { return primary }
        return api.selectedInverterId != 0 ? api.selectedInverterId : nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { period in
                        Text(period.label).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                if isLoading {
                    ProgressView()
                        .padding(.vertical, 40)
                } else if let roi {
                    totalCard(roi)

                    if let arbitrage = roi.arbitrage {
                        storyCard(
                            icon: "arrow.left.arrow.right",
                            color: .blue,
                            title: "Grid Arbitrage",
                            subtitle: "Bought from the grid, sold back later",
                            dollars: arbitrage.netDollars,
                            rows: [
                                ("Energy", kwh(arbitrage.kwh)),
                                ("Avg buy", cents(arbitrage.buyAvgCentsPerKwh)),
                                ("Avg sell", cents(arbitrage.sellAvgCentsPerKwh)),
                                ("Spread", cents(arbitrage.spreadCentsPerKwh))
                            ]
                        )
                    }

                    if let solarShift = roi.solarShift {
                        storyCard(
                            icon: "sun.max.fill",
                            color: .yellow,
                            title: "Solar Time-Shift",
                            subtitle: "Solar stored, then exported later",
                            dollars: solarShift.revenueDollars,
                            rows: [
                                ("Exported", kwh(solarShift.exportKwh)),
                                ("Avg sell", cents(solarShift.sellAvgCentsPerKwh))
                            ]
                        )
                    }

                    if let selfSupply = roi.selfSupply {
                        storyCard(
                            icon: "house.fill",
                            color: .purple,
                            title: "Self-Supply",
                            subtitle: "Battery energy used by the house",
                            dollars: selfSupply.avoidedDollars,
                            rows: [
                                ("Battery to house", kwh(selfSupply.batteryToHouseKwh)),
                                ("Avg avoided buy", cents(selfSupply.avoidedBuyAvgCentsPerKwh))
                            ]
                        )
                    }

                    if let context = roi.context {
                        contextCard(context)
                    }
                } else if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 40)
                }
            }
            .padding()
        }
        .navigationTitle("Battery ROI")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: period) {
            await load()
        }
    }

    // MARK: - Cards

    private func totalCard(_ roi: MarketROI) -> some View {
        VStack(spacing: 6) {
            Text("Battery Value")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(dollars(roi.totalDollars))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(roi.totalDollars >= 0 ? .green : .red)

            if let start = roi.startDate, let end = roi.endDate {
                Text(start == end ? start : "\(start) to \(end)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let settled = roi.settledPct, settled < 100 {
                Text("\(settled, specifier: "%.0f")% from settled meter data; the rest is estimated")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func storyCard(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        dollars amount: Double?,
        rows: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(dollars(amount ?? 0))
                    .font(.title3.weight(.semibold))
                    .foregroundColor((amount ?? 0) >= 0 ? .green : .red)
            }

            Divider()

            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1)
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func contextCard(_ context: MarketROI.Context) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not Through the Battery")
                .font(.subheadline.weight(.medium))

            HStack {
                Text("Solar exported directly")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(kwh(context.directSolarExportKwh))
                    .font(.caption)
            }

            HStack {
                Text("House imported directly")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(kwh(context.directHouseholdImportKwh))
                    .font(.caption)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Formatting

    private func dollars(_ value: Double) -> String {
        (value < 0 ? "-$" : "$") + String(format: "%.2f", abs(value))
    }

    private func kwh(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f kWh", value)
    }

    private func cents(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f¢/kWh", value)
    }

    // MARK: - Data Loading

    private func load() async {
        guard let inverterId else {
            message = "No inverter found for this site."
            return
        }

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let todayStart = calendar.startOfDay(for: Date())
        guard let endDate = calendar.date(byAdding: .day, value: -1, to: todayStart),
              let startDate = calendar.date(byAdding: .day, value: -period.rawValue, to: todayStart) else {
            return
        }

        isLoading = true
        let result = await api.fetchMarketROI(inverterId: inverterId, startDate: startDate, endDate: endDate)
        guard !Task.isCancelled else { return }
        isLoading = false

        switch result {
        case .success(let loaded):
            roi = loaded
            message = nil
        case .noActivity:
            roi = nil
            message = "No battery activity in this period."
        case .failure(let error):
            roi = nil
            message = "Couldn't load battery ROI: \(error)"
        }
    }
}

#Preview {
    NavigationStack {
        MarketROIView()
            .environmentObject(PowstonAPI())
    }
}
