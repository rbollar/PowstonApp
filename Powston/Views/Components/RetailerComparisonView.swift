//
//  RetailerComparisonView.swift
//  Powston
//
//  Shows LocalVolts actual costs and links to Energy Made Easy
//

import SwiftUI

struct RetailerComparisonView: View {
    @EnvironmentObject var api: PowstonAPI

    @State private var localVoltsSummary: LocalVoltsCostSummary?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection

                // LocalVolts Summary Card
                if let summary = localVoltsSummary {
                    localVoltsCostCard(summary)
                }

                // Energy Made Easy Link
                energyMadeEasyCard

                // Tips
                tipsCard
            }
            .padding()
        }
        .navigationTitle("Retailer Comparison")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadLocalVoltsSummary()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "building.2")
                .font(.system(size: 40))
                .foregroundStyle(.teal)

            Text("Retailer Comparison")
                .font(.title2.bold())

            Text("Compare your LocalVolts costs with other retailers")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }

    // MARK: - LocalVolts Cost Card

    private func localVoltsCostCard(_ summary: LocalVoltsCostSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundColor(.yellow)
                Text("Your LocalVolts Costs")
                    .font(.headline)
                Spacer()
                Text(summary.periodDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Net cost highlight
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Net Cost")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summary.netCost >= 0 ? "$\(String(format: "%.0f", summary.netCost))" : "-$\(String(format: "%.0f", abs(summary.netCost)))")
                        .font(.title.bold())
                        .foregroundColor(summary.netCost < 0 ? .green : .primary)
                }

                Spacer()

                if summary.days >= 30 {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Projected Annual")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let annualized = (summary.netCost / Double(summary.days)) * 365
                        Text(annualized >= 0 ? "$\(String(format: "%.0f", annualized))" : "-$\(String(format: "%.0f", abs(annualized)))")
                            .font(.title3.bold())
                            .foregroundColor(annualized < 0 ? .green : .primary)
                    }
                }
            }

            // Breakdown row
            HStack(spacing: 16) {
                VStack(alignment: .center, spacing: 2) {
                    Text("\(String(format: "%.0f", summary.importKwh))")
                        .font(.subheadline.weight(.medium))
                    Text("kWh In")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .center, spacing: 2) {
                    Text("\(String(format: "%.0f", summary.exportKwh))")
                        .font(.subheadline.weight(.medium))
                    Text("kWh Out")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .center, spacing: 2) {
                    Text("\(String(format: "%.1f", summary.avgImportPrice))c")
                        .font(.subheadline.weight(.medium))
                    Text("Avg Buy")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .center, spacing: 2) {
                    Text("\(String(format: "%.1f", summary.avgExportPrice))c")
                        .font(.subheadline.weight(.medium))
                    Text("Avg Sell")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Energy Made Easy Card

    private var energyMadeEasyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "building.columns.fill")
                    .foregroundColor(.blue)
                Text("Compare All Retailers")
                    .font(.headline)
                Spacer()
            }

            Text("The Australian Government's Energy Made Easy website compares 20+ retailers using your actual smart meter data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: "https://www.energymadeeasy.gov.au")!) {
                HStack {
                    Image(systemName: "arrow.up.right.square")
                    Text("Open Energy Made Easy")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .padding()
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 10))
            }

            Text("You'll need your NMI (National Meter Identifier) from your electricity bill.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Tips Card

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("Comparison Tips")
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                tipRow(
                    icon: "bolt.circle",
                    title: "LocalVolts isn't on EME",
                    description: "Wholesale/P2P pricing doesn't fit EME's comparison format"
                )

                tipRow(
                    icon: "person.2.circle",
                    title: "P2P revenue matters",
                    description: "Traditional retailers don't offer P2P trading"
                )

                tipRow(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Wholesale volatility",
                    description: "LocalVolts costs vary with spot prices; EME assumes stable rates"
                )
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func tipRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Data Loading

    private func loadLocalVoltsSummary() async {
        guard let siteId = api.selectedSiteId else { return }

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        let todayStart = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart),
              let startDate = calendar.date(byAdding: .day, value: -365, to: todayStart) else {
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yy"
        formatter.timeZone = powstonTimezone()

        // Try LV settlement data first (authoritative, correctly aggregated)
        let lvSummaries = PowstonDataStore.shared.getLVCashflowSummaries(siteId: siteId, from: startDate, to: yesterday)
        if !lvSummaries.isEmpty {
            let agg = lvSummaries.aggregated()
            let days = lvSummaries.count

            let netCost = agg.netCosts  // positive = cost to user
            let avgImportPrice = agg.energyPurchasedKwh > 0 ? (agg.totalPurchases / agg.energyPurchasedKwh) * 100 : 0
            let avgExportPrice = agg.energySoldTotalKwh > 0 ? (agg.totalSales / agg.energySoldTotalKwh) * 100 : 0

            // Parse date range from LV summaries
            let dateParser = DateFormatter()
            dateParser.dateFormat = "yyyy-MM-dd"
            dateParser.timeZone = powstonTimezone()
            let firstDate = dateParser.date(from: String(lvSummaries.first!.date.prefix(10))) ?? startDate
            let lastDate = dateParser.date(from: String(lvSummaries.last!.date.prefix(10))) ?? yesterday
            let periodDesc = "\(formatter.string(from: firstDate)) - \(formatter.string(from: lastDate))"

            localVoltsSummary = LocalVoltsCostSummary(
                importCost: agg.totalPurchases,
                exportRevenue: agg.totalSales,
                dailyCharges: agg.networkAccessCost + agg.localvoltsFee,
                netCost: netCost,
                importKwh: agg.energyPurchasedKwh,
                exportKwh: agg.energySoldTotalKwh,
                avgImportPrice: avgImportPrice,
                avgExportPrice: avgExportPrice,
                days: days,
                periodDescription: periodDesc
            )
            return
        }

        // Fall back to Powston API summary (aggregated, handles multi-inverter correctly)
        guard let summary = await api.fetchCustomRangeSummary(startDate: startDate, endDate: yesterday) else { return }

        let sold = summary.earningsDollars
        let bought = summary.rateCostsDollars
        let supply = sold - bought - summary.netProfitDollars
        var netCost = -summary.netProfitDollars  // positive = cost to user

        // P2P premium is NOT included in Powston API earnings — add it
        if let p2pData = PowstonDataStore.shared.calculateP2PPremiumForRangeDetailed(
            siteId: siteId, from: startDate, to: yesterday) {
            let p2pSellPremium = p2pData.sellRevenue - p2pData.sellSpotEquivalent
            netCost -= p2pSellPremium
        }

        let avgImportPrice = summary.totalEnergyImported > 0 ? (bought / summary.totalEnergyImported) * 100 : 0
        let avgExportPrice = summary.totalEnergyExported > 0 ? (sold / summary.totalEnergyExported) * 100 : 0
        let days = max(1, calendar.dateComponents([.day], from: startDate, to: yesterday).day ?? 1)
        let periodDesc = "\(formatter.string(from: startDate)) - \(formatter.string(from: yesterday))"

        localVoltsSummary = LocalVoltsCostSummary(
            importCost: bought,
            exportRevenue: sold,
            dailyCharges: supply,
            netCost: netCost,
            importKwh: summary.totalEnergyImported,
            exportKwh: summary.totalEnergyExported,
            avgImportPrice: avgImportPrice,
            avgExportPrice: avgExportPrice,
            days: days,
            periodDescription: periodDesc
        )
    }
}

// MARK: - LocalVolts Cost Summary

struct LocalVoltsCostSummary {
    let importCost: Double
    let exportRevenue: Double
    let dailyCharges: Double
    let netCost: Double
    let importKwh: Double
    let exportKwh: Double
    let avgImportPrice: Double
    let avgExportPrice: Double
    let days: Int
    let periodDescription: String
}

#Preview {
    NavigationStack {
        RetailerComparisonView()
            .environmentObject(PowstonAPI())
    }
}
