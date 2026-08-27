//
//  AmberViews.swift
//  Powston
//
//  Amber Electric UI: setup screen (Settings) and price/usage sections
//  for the Prices tab.
//

import SwiftUI
import Charts

// MARK: - Setup View (Settings)

struct AmberSetupView: View {
    @EnvironmentObject var api: PowstonAPI
    @ObservedObject private var amber = AmberService.shared

    @State private var manualKey: String = ""
    @State private var testResult: TestResult?
    @State private var isTesting = false

    enum TestResult {
        case success(String)
        case failure(String)
    }

    private var powstonProvidedKey: String? {
        guard let key = api.selectedSite?.amberKey, !key.isEmpty else { return nil }
        return key
    }

    private var hasManualKey: Bool {
        guard let siteId = api.selectedSite?.id else { return false }
        return amber.manualKey(forPowstonSite: siteId) != nil
    }

    var body: some View {
        Form {
            Section {
                if powstonProvidedKey != nil {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Key provided by Powston")
                                .fontWeight(.medium)
                            Text("Your Amber API key is configured on your Powston site and is used automatically.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("Powston has no Amber key for this site. Enter your own key from app.amber.com.au/developers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                SecureField("Manual API key (optional override)", text: $manualKey)

                Button {
                    testAndSave()
                } label: {
                    HStack {
                        if isTesting { ProgressView().scaleEffect(0.8) }
                        Text(manualKey.isEmpty ? "Test Connection" : "Test & Save Key")
                    }
                }
                .disabled(isTesting || (manualKey.isEmpty && effectiveKey == nil))

                if hasManualKey {
                    Button(role: .destructive) {
                        if let siteId = api.selectedSite?.id {
                            amber.setManualKey(nil, forPowstonSite: siteId)
                        }
                        manualKey = ""
                        testResult = nil
                    } label: {
                        Text("Remove Manual Key")
                    }
                }

                if let result = testResult {
                    switch result {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("The key is stored per site in the app group settings on this device (not in iCloud, not in the Keychain). Prices and usage are fetched directly from Amber.")
            }

            if !amber.sites.isEmpty {
                Section("Amber Site") {
                    ForEach(amber.sites) { site in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("NMI \(site.nmi)")
                                    .fontWeight(.medium)
                                Spacer()
                                Text(site.status.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundColor(site.status == .active ? .green : .secondary)
                            }
                            Text("\(site.network) • \(site.intervalLength)-minute billing • \(site.channels.map { $0.type.displayName }.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Amber Electric")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let key = effectiveKey {
                let siteId = api.selectedSite?.id
                Task { _ = try? await amber.fetchSites(apiKey: key, forPowstonSite: siteId) }
            }
        }
    }

    private var effectiveKey: String? {
        amber.apiKey(for: api.selectedSite)
    }

    private func testAndSave() {
        let trimmed = manualKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyToTest = trimmed.isEmpty ? effectiveKey : trimmed
        guard let key = keyToTest else { return }
        let siteId = api.selectedSite?.id

        isTesting = true
        testResult = nil
        Task {
            do {
                let description = try await AmberService.shared.testKey(key, forPowstonSite: siteId)
                if !trimmed.isEmpty, let siteId {
                    AmberService.shared.setManualKey(key, forPowstonSite: siteId)
                    manualKey = ""
                }
                testResult = .success(description)
            } catch {
                testResult = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }

    /// Summary badge for the Settings row
    static func summary(site: Site?) -> String {
        AmberService.shared.isConfigured(for: site) ? "Connected" : "Not set up"
    }
}

// MARK: - Prices Tab Section

struct AmberPriceSection: View {
    @EnvironmentObject var api: PowstonAPI
    @ObservedObject private var amber = AmberService.shared

    var body: some View {
        Section {
            if let general = amber.currentGeneral {
                amberBuyRow(general)
            }
            if let feedIn = amber.currentFeedIn {
                amberSellRow(feedIn)
            }
            if let general = amber.currentGeneral {
                HStack {
                    Text("Renewables")
                    Spacer()
                    Text(String(format: "%.0f%%", general.renewables))
                        .foregroundColor(.green)
                }
                if general.spikeStatus != AmberSpikeStatus.none {
                    HStack {
                        Label(
                            general.spikeStatus == .spike ? "Price spike active" : "Potential price spike",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundColor(general.spikeStatus == .spike ? .red : .orange)
                        .font(.caption)
                        Spacer()
                    }
                }
            }

            let forecast = amber.forecast(for: .general)
            if !forecast.isEmpty {
                AmberForecastChart(
                    buyForecast: forecast,
                    sellForecast: amber.forecast(for: .feedIn)
                )
                .frame(height: 140)
                .padding(.vertical, 4)
            }

            if amber.currentPrices.isEmpty {
                if amber.isLoadingPrices {
                    HStack {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading Amber prices...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let error = amber.priceError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        } header: {
            HStack {
                Text("Amber Electric")
                if let general = amber.currentGeneral, general.estimate == true {
                    Text("(estimate)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textCase(nil)
                }
            }
        } footer: {
            if let last = amber.lastFetchTime {
                Text("Direct from Amber API • updated \(last.formatted(date: .omitted, time: .shortened))")
            }
        }
        .task(id: api.selectedSiteId) {
            await amber.fetchCurrentPrices(site: api.selectedSite)
        }
    }

    private func amberBuyRow(_ interval: AmberInterval) -> some View {
        HStack {
            Text("Buy Price")
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f¢/kWh", interval.perKwh))
                    .foregroundColor(interval.descriptor.buyColor)
                Text(interval.descriptor.displayName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Amber feedIn perKwh is negative when the customer is PAID; positive
    /// means paying to export. Convert to earnings and keep the sign visible.
    private func amberSellRow(_ interval: AmberInterval) -> some View {
        let earnings = -interval.perKwh
        return HStack {
            Text("Sell Price")
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f¢/kWh", earnings))
                    .foregroundColor(earnings < 0 ? .red : interval.descriptor.sellColor)
                Text(earnings < 0 ? "You pay to export" : interval.descriptor.displayName)
                    .font(.caption2)
                    .foregroundColor(earnings < 0 ? .red : .secondary)
            }
        }
    }
}

// MARK: - Forecast Chart

struct AmberForecastChart: View {
    let buyForecast: [AmberInterval]
    let sellForecast: [AmberInterval]

    var body: some View {
        Chart {
            ForEach(buyForecast) { interval in
                if let date = interval.nemDate {
                    // Confidence band from advancedPrice
                    if let advanced = interval.advancedPrice {
                        AreaMark(
                            x: .value("Time", date),
                            yStart: .value("Low", advanced.low),
                            yEnd: .value("High", advanced.high)
                        )
                        .foregroundStyle(Color.blue.opacity(0.12))
                    }
                    LineMark(
                        x: .value("Time", date),
                        y: .value("Buy ¢/kWh", interval.perKwh),
                        series: .value("Series", "Buy")
                    )
                    .foregroundStyle(Color.blue)
                }
            }
            ForEach(sellForecast) { interval in
                if let date = interval.nemDate {
                    // Negate feedIn perKwh so the plotted value is earnings;
                    // dips below zero mean paying to export
                    LineMark(
                        x: .value("Time", date),
                        y: .value("Sell ¢/kWh", -interval.perKwh),
                        series: .value("Series", "Sell")
                    )
                    .foregroundStyle(Color.green)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))¢")
                    }
                }
            }
        }
        .environment(\.timeZone, powstonTimezone())
    }
}

// MARK: - Usage Card

struct AmberUsageCard: View {
    @EnvironmentObject var api: PowstonAPI
    @ObservedObject private var amber = AmberService.shared

    var body: some View {
        Section("Amber Usage (last 7 days)") {
            if amber.dailyUsage.isEmpty {
                if amber.isLoadingUsage {
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let error = amber.usageError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else {
                    Text("No billable usage yet — Amber finalizes data about a day behind.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(amber.dailyUsage.suffix(7).reversed()) { day in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day.date)
                                .font(.subheadline)
                            Text(String(format: "↓ %.1f kWh   ↑ %.1f kWh%@",
                                        day.importKwh, day.exportKwh,
                                        day.allBillable ? "" : "  (est.)"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%@$%.2f",
                                    day.netCostDollars <= 0 ? "+" : "-",
                                    abs(day.netCostDollars)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(day.netCostDollars <= 0 ? .green : .primary)
                    }
                }
            }
        }
        .task(id: api.selectedSiteId) {
            let calendar = Calendar.current
            let today = Date()
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
            await amber.fetchUsage(site: api.selectedSite, from: weekAgo, to: today)
        }
    }
}
