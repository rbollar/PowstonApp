//
//  RetailerComparisonView.swift
//  Powston
//
//  Shows LocalVolts actual costs, Flowpower simulation, and links to Energy Made Easy
//

import SwiftUI

struct RetailerComparisonView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var analysis = RetailerComparisonAnalysis()

    @State private var showingReport = false
    @State private var selectedRegion: NetworkRegion = .nswEndeavour
    @State private var showingLocalVoltsSummary = false
    @State private var localVoltsSummary: LocalVoltsCostSummary?

    var config: AnalysisConfig? {
        guard let site = api.selectedSite else { return nil }
        return AnalysisConfig.from(site: site)
    }

    var flowpowerConfig: FlowpowerConfig {
        FlowpowerConfig.forRegion(selectedRegion)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection

                // LocalVolts Summary Card (always show if available)
                if let summary = localVoltsSummary {
                    localVoltsCostCard(summary)
                }

                // Flowpower Comparison Section
                flowpowerSection

                // Energy Made Easy Link
                energyMadeEasyCard

                // Tips
                tipsCard
            }
            .padding()
        }
        .navigationTitle("Retailer Comparison")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if analysis.result != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingReport = true
                    } label: {
                        Image(systemName: "doc.text")
                    }
                }
            }
        }
        .sheet(isPresented: $showingReport) {
            if let result = analysis.result {
                ReportSheet(report: result.formattedReport)
            }
        }
        .task {
            loadInitialData()
            await loadLocalVoltsSummary()
        }
        .onChange(of: selectedRegion) { _, _ in
            analysis.result = nil
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

    // MARK: - Flowpower Section

    @ViewBuilder
    private var flowpowerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bolt.horizontal.fill")
                    .foregroundColor(.orange)
                Text("Flowpower Simulation")
                    .font(.headline)
                Spacer()
            }

            Text("Simulate what you'd pay on Flowpower's wholesale pass-through tariff")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Network picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Network Region")
                    .font(.subheadline.weight(.medium))

                Picker("Network", selection: $selectedRegion) {
                    ForEach(NetworkRegion.allCases) { region in
                        Text(region.rawValue).tag(region)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)

                Text("Daily: $\(String(format: "%.2f", flowpowerConfig.dailyCharge)) | Base: \(Int(flowpowerConfig.baseImportRate))c/kWh | Export window: \(flowpowerConfig.peakExportWindowDescription)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            if analysis.isAnalyzing {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(analysis.progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if let result = analysis.result {
                flowpowerResultSummary(result)
            } else if let error = analysis.error {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Try Again") {
                        runAnalysis()
                    }
                    .font(.caption)
                }
            } else {
                Button {
                    runAnalysis()
                } label: {
                    Label("Analyze 60 Days", systemImage: "play.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func flowpowerResultSummary(_ result: RetailerComparisonResult) -> some View {
        VStack(spacing: 12) {
            // Winner announcement
            HStack {
                Image(systemName: "trophy.fill")
                    .foregroundColor(.yellow)
                Text("\(result.cheaperRetailer.displayName) saves")
                    .font(.subheadline)
                Text("$\(String(format: "%.0f", result.annualizedDifference))/year")
                    .font(.headline)
                    .foregroundColor(result.cheaperRetailer == .localVolts ? .green : .orange)
            }

            // Side by side comparison
            HStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text("LocalVolts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("$\(String(format: "%.0f", result.localVoltsActual.netCost))")
                        .font(.title3.bold())
                        .foregroundColor(result.cheaperRetailer == .localVolts ? .green : .primary)
                    Text("\(result.periodDays) days")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Text("Flowpower")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("$\(String(format: "%.0f", result.flowpowerSimulated.netCost))")
                        .font(.title3.bold())
                        .foregroundColor(result.cheaperRetailer == .flowpower ? .green : .primary)
                    Text("simulated")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Key metrics
            HStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text("PEA Grade")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(result.flowpowerSimulated.peaDetails.importTimingGrade)
                        .font(.caption.bold())
                        .foregroundColor(gradeColor(result.flowpowerSimulated.peaDetails.importTimingGrade))
                }

                VStack(spacing: 2) {
                    Text("Export Capture")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    let fp = result.flowpowerSimulated
                    let total = fp.peakExportKwh + fp.offPeakExportKwh
                    let capture = total > 0 ? (fp.peakExportKwh / total) * 100 : 0
                    Text("\(Int(capture))%")
                        .font(.caption.bold())
                }

                VStack(spacing: 2) {
                    Text("Effective Rate")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(String(format: "%.1f", result.flowpowerSimulated.effectiveImportRate))c")
                        .font(.caption.bold())
                }
            }

            Button {
                runAnalysis()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
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

    // MARK: - Helpers

    private func loadInitialData() {
        if let site = api.selectedSite {
            let detectedRegion = detectNetworkRegion(state: site.state)
            selectedRegion = detectedRegion
        }

        if let config = config {
            if let cached = analysis.getCachedResult(config: config, flowpowerConfig: flowpowerConfig) {
                analysis.result = cached
            }
        }
    }

    private func loadLocalVoltsSummary() async {
        guard let siteId = api.selectedSiteId else { return }

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        let todayStart = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart),
              let startDate = calendar.date(byAdding: .day, value: -365, to: todayStart) else {
            return
        }

        let dataStore = PowstonDataStore.shared
        let cachedRecords = dataStore.getMeterRecordsLocal(siteId: siteId, from: startDate, to: yesterday)

        guard !cachedRecords.isEmpty else { return }

        var totalImportCost: Double = 0
        var totalExportRevenue: Double = 0
        var totalDailyCharges: Double = 0
        var totalImportKwh: Double = 0
        var totalExportKwh: Double = 0

        for record in cachedRecords {
            // Use same logic as MeterRecord.effectiveImport/effectiveExport
            let importKwh = record.energyImport ?? record.generalKwh ?? 0
            let exportKwh = record.energyExport ?? max(0, record.feedInKwh ?? 0)

            totalImportKwh += importKwh
            totalExportKwh += exportKwh

            if let costs = record.costs {
                totalImportCost += costs
            }
            if let earnings = record.earnings {
                totalExportRevenue += earnings
            }
            if let fixed = record.fixedCosts {
                totalDailyCharges += fixed
            }
        }

        let importCostDollars = totalImportCost / 100.0
        let exportRevenueDollars = totalExportRevenue / 100.0
        let dailyChargesDollars = totalDailyCharges / 100.0
        let netCost = importCostDollars - exportRevenueDollars + dailyChargesDollars

        let avgImportPrice = totalImportKwh > 0 ? totalImportCost / totalImportKwh : 0
        let avgExportPrice = totalExportKwh > 0 ? totalExportRevenue / totalExportKwh : 0

        let dates = cachedRecords.map { $0.intervalTime }
        let minDate = dates.min() ?? startDate
        let maxDate = dates.max() ?? yesterday
        let days = max(1, calendar.dateComponents([.day], from: minDate, to: maxDate).day ?? 1)

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yy"
        formatter.timeZone = powstonTimezone()
        let periodDesc = "\(formatter.string(from: minDate)) - \(formatter.string(from: maxDate))"

        localVoltsSummary = LocalVoltsCostSummary(
            importCost: importCostDollars,
            exportRevenue: exportRevenueDollars,
            dailyCharges: dailyChargesDollars,
            netCost: netCost,
            importKwh: totalImportKwh,
            exportKwh: totalExportKwh,
            avgImportPrice: avgImportPrice,
            avgExportPrice: avgExportPrice,
            days: days,
            periodDescription: periodDesc
        )
    }

    private func detectNetworkRegion(state: String?) -> NetworkRegion {
        guard let state = state?.uppercased() else { return .nswEndeavour }

        switch state {
        case "QLD", "QUEENSLAND":
            return .qldEnergex
        case "VIC", "VICTORIA":
            return .vicCitipower
        case "SA", "SOUTH AUSTRALIA":
            return .saAPD
        default:
            return .nswEndeavour
        }
    }

    private func runAnalysis() {
        guard let config = config else { return }
        Task {
            await analysis.runAnalysis(
                api: api,
                config: config,
                flowpowerConfig: flowpowerConfig
            )
        }
    }

    private func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "A": return .green
        case "B": return .blue
        case "C": return .orange
        default: return .red
        }
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
