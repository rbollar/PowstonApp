//
//  LVMarketOverviewView.swift
//  Powston
//
//  Market overview for LocalVolts platform-wide P2P trading activity
//  Shows today's trading stats, price distribution, and seller leaderboard
//

import SwiftUI
import Charts

// MARK: - Main View

struct LVMarketOverviewView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var localVoltsService = LocalVoltsService.shared
    @StateObject private var analysis = LVMarketAnalysis.shared
    @StateObject private var opportunityAnalysis = UnfilledOpportunityAnalysis.shared

    @State private var contracts: [LVMarketContract] = []
    @State private var allContracts: [LVMarketContract] = []  // All historical data
    @State private var isLoading = false
    @State private var error: String?
    @State private var selectedRegion: String?
    @State private var lastRefresh: Date?
    @State private var dataDateRange: (start: Date?, end: Date?) = (nil, nil)
    @State private var daysOfData: Int = 0
    @State private var viewMode: ViewMode = .yesterday  // Default to yesterday for complete data
    @State private var hourlyChartFilter: HourlyChartFilter = .all  // Filter for price by time chart
    @State private var selectedPriceBin: LVMarketAnalysis.PriceBin?  // Selected price distribution bin
    @State private var selectedHourlyStat: LVMarketAnalysis.LVHourlyPriceStat?  // Selected hourly stat

    // Main view mode toggle
    enum ViewMode: String, CaseIterable {
        case yesterday = "Yesterday"  // Settled contracts only (complete day)
        case today = "Today"          // All contracts including pending
        case allData = "All Data"     // Historical data
    }

    // Filter options for hourly price chart
    enum HourlyChartFilter: String, CaseIterable {
        case all = "All"
        case settled = "Settled"
        case pending = "Pending"
    }

    // User's seller name for position comparison
    private var userSellerName: String? {
        localVoltsService.storedUsername
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isLoading {
                    loadingView
                } else if let error = error {
                    errorView(error)
                } else if contracts.isEmpty {
                    emptyStateView
                } else {
                    marketContent
                }
            }
            .padding()
        }
        .refreshable {
            await refreshMarketData()
        }
        .onAppear {
            loadCachedOrFetch()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading market data...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                Task { await refreshMarketData() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Market Data")
                .font(.headline)

            Text("Connect to LocalVolts to see platform-wide P2P trading activity.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if !localVoltsService.hasCredentials {
                NavigationLink(destination: LocalVoltsSetupView()) {
                    Label("Connect LocalVolts", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Fetch Market Data") {
                    Task { await refreshMarketData() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - Market Content

    private var marketContent: some View {
        VStack(spacing: 16) {
            // Data collection info card
            dataCollectionCard

            // View toggle: Today vs Historical
            viewToggle

            // Summary card
            if let summary = analysis.summary {
                summaryCard(summary)
            }

            // Unfilled opportunity alert (if any)
            if let alert = opportunityAnalysis.currentAlert {
                UnfilledOpportunityCard(alert: alert)
            }

            // Region filter (if multiple regions)
            let regions = analysis.getAvailableRegions(displayContracts)
            if regions.count > 1 {
                regionPicker(regions: regions)
            }

            // Price distribution chart
            priceDistributionCard

            // Hourly price chart (buy/sell with percentile ranges)
            hourlyPriceCard

            // Historical price trend (only in historical view)
            if showHistorical {
                historicalTrendCard
            }

            // User position (if known)
            if let userPos = analysis.calculateUserPosition(contracts: filteredContracts, userSeller: userSellerName ?? "") {
                userPositionCard(userPos)
            }

            // Top sellers
            if let summary = analysis.summary, !summary.topSellers.isEmpty {
                sellerLeaderboardCard(summary.topSellers)
            }

            // Footer
            footerView
        }
    }

    /// Contracts to display based on view mode
    private var displayContracts: [LVMarketContract] {
        switch viewMode {
        case .yesterday:
            // Yesterday's complete data from historical database
            return yesterdayContracts
        case .today:
            // All contracts from today's fetch including pending
            return contracts
        case .allData:
            // All historical data
            return allContracts
        }
    }

    /// Yesterday's contracts from historical data (complete 24-hour day)
    private var yesterdayContracts: [LVMarketContract] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = powstonTimezone()
        let today = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return []
        }
        // Filter allContracts to yesterday's trade date
        return allContracts.filter { contract in
            calendar.isDate(contract.tradeDate, inSameDayAs: yesterday)
        }
    }

    private var showHistorical: Bool {
        viewMode == .allData
    }

    private var filteredContracts: [LVMarketContract] {
        analysis.filterByRegion(displayContracts, region: selectedRegion)
    }

    // MARK: - Data Collection Card

    private var dataCollectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .foregroundColor(.blue)
                Text("Market Data Collection")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            if daysOfData > 0 {
                Text("\(daysOfData) days of agreed contracts collected")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let start = dataDateRange.start, let end = dataDateRange.end {
                    Text("From \(start, format: .dateTime.month().day()) to \(end, format: .dateTime.month().day())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Progress towards 60 days
                let progress = min(Double(daysOfData) / 60.0, 1.0)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(progress >= 1.0 ? .green : .blue)

                Text(daysOfData >= 60 ? "Full 60-day market picture available" : "Collecting data... \(60 - daysOfData) more days for complete picture")
                    .font(.caption2)
                    .foregroundColor(daysOfData >= 60 ? .green : .secondary)
            } else {
                Text("No historical data yet. Market data accumulates daily.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(10)
    }

    // MARK: - View Toggle

    private var viewToggle: some View {
        Picker("View", selection: $viewMode) {
            Text("Yesterday").tag(ViewMode.yesterday)
            Text("Today").tag(ViewMode.today)
            Text("All (\(daysOfData)d)").tag(ViewMode.allData)
        }
        .pickerStyle(.segmented)
        .onChange(of: viewMode) { _, _ in
            reanalyzeForViewMode()
        }
    }

    // MARK: - Historical Trend Card

    private var historicalTrendCard: some View {
        let priceHistory = PowstonDataStore.shared.getLVMarketPriceHistory(days: 60)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(.green)
                Text("Price Trend")
                    .font(.headline)
                Spacer()
                Text("\(priceHistory.count) days")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if priceHistory.count < 2 {
                Text("Not enough data for trend analysis yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                Chart(priceHistory, id: \.date) { stat in
                    LineMark(
                        x: .value("Date", stat.date),
                        y: .value("Avg", stat.avgSellPrice)
                    )
                    .foregroundStyle(Color.green)

                    AreaMark(
                        x: .value("Date", stat.date),
                        yStart: .value("P25", stat.p25Price),
                        yEnd: .value("P75", stat.p75Price)
                    )
                    .foregroundStyle(Color.green.opacity(0.2))
                }
                .frame(height: 150)
                .chartYAxisLabel("Sell Price (¢/kWh)")

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Avg Sell Price")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        let avgPrice = priceHistory.map { $0.avgSellPrice }.reduce(0, +) / Double(max(priceHistory.count, 1))
                        Text(String(format: "%.1f¢", avgPrice))
                            .font(.caption.bold())
                            .foregroundColor(.green)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Total Contracts")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        let totalContracts = priceHistory.reduce(0) { $0 + $1.tradeCount }
                        Text("\(totalContracts.formatted())")
                            .font(.caption.bold())
                            .foregroundColor(.purple)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Summary Card

    private func summaryCard(_ summary: LVMarketSummary) -> some View {
        let summaryTitle: String = {
            switch viewMode {
            case .yesterday: return "Yesterday's Contracts"
            case .today: return "Today's Contracts"
            case .allData: return "All Agreed Contracts"
            }
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.purple)
                Text(summaryTitle)
                    .font(.headline)
                Spacer()

                if viewMode != .allData, let lastRefresh = lastRefresh {
                    Text(lastRefresh, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Stats grid
            HStack(spacing: 0) {
                statItem(
                    value: "\(summary.totalTrades.formatted())",
                    label: "Contracts",
                    color: .primary
                )
                // Show settled/pending breakdown
                let settledCount = displayContracts.filter { $0.isSettled }.count
                let pendingCount = displayContracts.filter { $0.isPending }.count
                statItem(
                    value: "\(settledCount)/\(pendingCount)",
                    label: "Settled/Pending",
                    color: .purple
                )
            }

            HStack(spacing: 0) {
                statItem(
                    value: String(format: "%.1f¢", summary.avgPriceCents),
                    label: "Avg Sell Price",
                    color: .green
                )
                statItem(
                    value: String(format: "%.0f-%.0f¢", summary.minPriceCents, summary.maxPriceCents),
                    label: "Range",
                    color: .secondary
                )
            }

            // Matching fee info
            let avgMatchingFee = displayContracts.isEmpty ? 0 :
                displayContracts.map { $0.matchingFeeCents }.reduce(0, +) / Double(displayContracts.count)
            let avgMatchingFeePercent = displayContracts.isEmpty ? 0 :
                displayContracts.map { $0.matchingFeePercent }.reduce(0, +) / Double(displayContracts.count)

            if avgMatchingFee > 0 {
                HStack(spacing: 0) {
                    statItem(
                        value: String(format: "%.2f¢", avgMatchingFee),
                        label: "LV Fee (avg)",
                        color: .orange
                    )
                    statItem(
                        value: String(format: "%.1f%%", avgMatchingFeePercent),
                        label: "Fee %",
                        color: .orange
                    )
                }
            }

            Divider()

            HStack {
                Label("\(summary.uniqueSellers) sellers", systemImage: "arrow.up.circle")
                    .font(.caption)
                    .foregroundColor(.green)
                Spacer()
                Label("\(summary.uniqueBuyers) buyers", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func statItem(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Region Picker

    private func regionPicker(regions: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                regionButton(label: "All", isSelected: selectedRegion == nil) {
                    selectedRegion = nil
                }

                ForEach(regions, id: \.self) { region in
                    regionButton(label: region, isSelected: selectedRegion == region) {
                        selectedRegion = region
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func regionButton(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.purple : Color(.tertiarySystemBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
    }

    // MARK: - Price Distribution Card

    private var priceDistributionCard: some View {
        let histogram = analysis.generatePriceHistogram(contracts: filteredContracts, binCount: 15)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar")
                    .foregroundColor(.cyan)
                Text("Price Distribution")
                    .font(.headline)
                Spacer()
                if selectedPriceBin != nil {
                    Button("Clear") {
                        selectedPriceBin = nil
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            if histogram.isEmpty {
                Text("No data available")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                Chart(histogram) { bin in
                    BarMark(
                        x: .value("Price", bin.minPrice),
                        y: .value("Contracts", bin.count)
                    )
                    .foregroundStyle(selectedPriceBin?.id == bin.id ? Color.cyan : Color.cyan.opacity(0.6))
                }
                .frame(height: 150)
                .chartXAxisLabel("Sell Price (¢/kWh)")
                .chartYAxisLabel("Contracts")
                .chartXSelection(value: $selectedPriceBinPrice)
                .onChange(of: selectedPriceBinPrice) { _, newValue in
                    if let price = newValue {
                        // Find the bin containing this price
                        selectedPriceBin = histogram.first { bin in
                            price >= bin.minPrice && price < bin.maxPrice
                        }
                    }
                }

                // Selected bin detail
                if let bin = selectedPriceBin {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Selected Range")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.0f–%.0f¢", bin.minPrice, bin.maxPrice))
                                .font(.subheadline.bold())
                                .foregroundColor(.cyan)
                        }
                        Spacer()
                        VStack(alignment: .center, spacing: 2) {
                            Text("Contracts")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(bin.count)")
                                .font(.subheadline.bold())
                                .foregroundColor(.purple)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Volume")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.1f kWh", bin.totalVolume))
                                .font(.subheadline.bold())
                                .foregroundColor(.green)
                        }
                    }
                    .padding(10)
                    .background(Color.cyan.opacity(0.15))
                    .cornerRadius(8)
                } else {
                    // Percentiles
                    if let dist = analysis.summary?.priceDistribution {
                        HStack(spacing: 16) {
                            percentileLabel("P25", value: dist.percentiles[25] ?? 0)
                            percentileLabel("P50", value: dist.percentiles[50] ?? 0)
                            percentileLabel("P75", value: dist.percentiles[75] ?? 0)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("VWAP")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f¢", dist.volumeWeightedAvgPrice))
                                    .font(.caption.bold())
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }

                Text("Tap a bar for details")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    @State private var selectedPriceBinPrice: Double?

    private func percentileLabel(_ label: String, value: Double) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(String(format: "%.0f¢", value))
                .font(.caption.monospaced())
        }
    }

    // MARK: - Hourly Price Card (Sell Price with Percentile Ranges)

    @State private var selectedHour: Int?

    private var hourlyPriceCard: some View {
        // Filter contracts based on selection
        let contractsForChart: [LVMarketContract]
        let settledOnly: Bool

        switch hourlyChartFilter {
        case .all:
            contractsForChart = filteredContracts
            settledOnly = false
        case .settled:
            contractsForChart = filteredContracts.filter { $0.isSettled }
            settledOnly = false  // Already filtered
        case .pending:
            contractsForChart = filteredContracts.filter { $0.isPending }
            settledOnly = false  // Already filtered
        }

        let hourlyStats = analysis.calculateHourlyPriceStats(contracts: contractsForChart, settledOnly: settledOnly)

        return VStack(alignment: .leading, spacing: 10) {
            // Title row
            HStack {
                Image(systemName: "clock.arrow.2.circlepath")
                    .foregroundColor(.indigo)
                Text("Hourly Prices")
                    .font(.headline)
                Spacer()
                if selectedHourlyStat != nil {
                    Button("Clear") {
                        selectedHourlyStat = nil
                        selectedHour = nil
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            // Filter picker on its own row
            Picker("Filter", selection: $hourlyChartFilter) {
                ForEach(HourlyChartFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            // Chart color based on filter mode
            let chartColor: Color = {
                switch hourlyChartFilter {
                case .all: return .cyan
                case .settled: return .green
                case .pending: return .orange
                }
            }()

            if hourlyStats.isEmpty {
                Text({
                    switch hourlyChartFilter {
                    case .all: return "No contracts for this period"
                    case .settled: return "No settled contracts yet"
                    case .pending: return "No pending contracts"
                    }
                }())
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            } else {

                // Candlestick-style chart: P10-P90 whiskers, P25-P75 body, median + VWAP
                Chart {
                    ForEach(hourlyStats) { stat in
                        let isSelected = selectedHourlyStat?.hour == stat.hour

                        // P10-P90 whisker (thin line)
                        RectangleMark(
                            x: .value("Hour", stat.hour),
                            yStart: .value("P10", stat.p10SellPrice),
                            yEnd: .value("P90", stat.p90SellPrice),
                            width: .fixed(2)
                        )
                        .foregroundStyle(isSelected ? chartColor.opacity(0.5) : chartColor.opacity(0.25))

                        // P25-P75 range as vertical bar (candlestick body)
                        RectangleMark(
                            x: .value("Hour", stat.hour),
                            yStart: .value("P25", stat.p25SellPrice),
                            yEnd: .value("P75", stat.p75SellPrice),
                            width: .fixed(12)
                        )
                        .foregroundStyle(isSelected ? chartColor.opacity(0.7) : chartColor.opacity(0.4))

                        // Median line (P50) - the "close" equivalent
                        RectangleMark(
                            x: .value("Hour", stat.hour),
                            yStart: .value("Mid", stat.p50SellPrice - 0.3),
                            yEnd: .value("Mid", stat.p50SellPrice + 0.3),
                            width: .fixed(12)
                        )
                        .foregroundStyle(isSelected ? chartColor : chartColor.opacity(0.8))

                        // VWAP dot (when it differs from median)
                        if stat.hasVolumeWeighting {
                            PointMark(
                                x: .value("Hour", stat.hour),
                                y: .value("VWAP", stat.vwapSellPrice)
                            )
                            .symbolSize(20)
                            .foregroundStyle(.yellow)
                        }
                    }
                }
                .frame(height: 200)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisValueLabel {
                            if let hour = value.as(Int.self) {
                                Text("\(hour):00")
                                    .font(.caption2)
                            }
                        }
                        AxisGridLine()
                    }
                }
                .chartYAxisLabel("¢/kWh")
                .chartXSelection(value: $selectedHour)
                .onChange(of: selectedHour) { _, newValue in
                    if let hour = newValue {
                        selectedHourlyStat = hourlyStats.first { $0.hour == hour }
                    }
                }

                // Selected hour detail
                if let stat = selectedHourlyStat {
                    VStack(spacing: 8) {
                        HStack {
                            Text(String(format: "%d:00–%d:00", stat.hour, (stat.hour + 1) % 24))
                                .font(.subheadline.bold())
                                .foregroundColor(chartColor)
                            Spacer()
                            Text("\(stat.tradeCount) contracts")
                                .font(.caption)
                                .foregroundColor(.purple)
                        }
                        // Row 1: Median, VWAP, Volume
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Median")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f¢", stat.p50SellPrice))
                                    .font(.subheadline.bold())
                                    .foregroundColor(chartColor)
                            }
                            Spacer()
                            VStack(alignment: .center, spacing: 2) {
                                Text("VWAP")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f¢", stat.vwapSellPrice))
                                    .font(.subheadline.bold())
                                    .foregroundColor(stat.hasVolumeWeighting ? .yellow : .secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Volume")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f kWh", stat.totalVolume))
                                    .font(.subheadline.bold())
                                    .foregroundColor(.green)
                            }
                        }
                        // Row 2: Percentile spread
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("P10–P90")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.0f–%.0f¢", stat.p10SellPrice, stat.p90SellPrice))
                                    .font(.caption.bold())
                            }
                            Spacer()
                            VStack(alignment: .center, spacing: 2) {
                                Text("P25–P75")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.0f–%.0f¢", stat.p25SellPrice, stat.p75SellPrice))
                                    .font(.caption.bold())
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("LV Fee")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.2f¢", stat.matchingFee))
                                    .font(.caption.bold())
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(10)
                    .background(chartColor.opacity(0.15))
                    .cornerRadius(8)
                } else {
                    // Legend
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Rectangle()
                                .fill(chartColor)
                                .frame(width: 12, height: 3)
                            Text("Median")
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 4) {
                            Rectangle()
                                .fill(chartColor.opacity(0.4))
                                .frame(width: 12, height: 10)
                                .cornerRadius(2)
                            Text("P25–P75")
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 4) {
                            Rectangle()
                                .fill(chartColor.opacity(0.25))
                                .frame(width: 2, height: 14)
                            Text("P10–P90")
                                .foregroundColor(.secondary)
                        }
                        if hourlyStats.contains(where: { $0.hasVolumeWeighting }) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.yellow)
                                    .frame(width: 6, height: 6)
                                Text("VWAP")
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .font(.caption2)

                    // Summary stats
                    if let peakHour = hourlyStats.max(by: { $0.p50SellPrice < $1.p50SellPrice }),
                       let lowHour = hourlyStats.min(by: { $0.p50SellPrice < $1.p50SellPrice }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Peak: \(peakHour.hour):00")
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f¢", peakHour.p50SellPrice))
                                    .foregroundColor(chartColor)
                                    .fontWeight(.medium)
                            }
                            Spacer()
                            VStack(alignment: .center, spacing: 2) {
                                Text("LV Fee")
                                    .foregroundColor(.secondary)
                                let avgFee = hourlyStats.map { $0.matchingFee }.reduce(0, +) / Double(hourlyStats.count)
                                Text(String(format: "~%.2f¢", avgFee))
                                    .foregroundColor(.orange)
                                    .fontWeight(.medium)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Low: \(lowHour.hour):00")
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f¢", lowHour.p50SellPrice))
                                    .foregroundColor(.blue)
                                    .fontWeight(.medium)
                            }
                        }
                        .font(.caption)
                    }

                    Text("Tap a bar for details")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - User Position Card

    private func userPositionCard(_ position: LVMarketUserPosition) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundColor(.blue)
                Text("Your Position")
                    .font(.headline)
                Spacer()
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your avg:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f¢", position.userAvgPriceCents))
                        .font(.title3.bold())
                        .foregroundColor(.blue)
                }

                Spacer()

                VStack(alignment: .center, spacing: 4) {
                    Text("vs Market:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f¢", position.marketAvgPriceCents))
                        .font(.title3.bold())
                        .foregroundColor(.green)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Difference:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(position.pricePositionDescription)
                        .font(.caption.bold())
                        .foregroundColor(position.pricePositionPercent >= 0 ? .green : .orange)
                }
            }

            if position.marketSharePercent > 0.1 {
                Divider()
                HStack {
                    Text("Market share:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.2f%%", position.marketSharePercent))
                        .font(.caption.bold())
                    Text("(\(position.userTradeCount) of \(position.marketTradeCount) trades)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Seller Leaderboard Card

    private func sellerLeaderboardCard(_ sellers: [LVMarketSellerRank]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "trophy.fill")
                    .foregroundColor(.yellow)
                Text("Top Sellers")
                    .font(.headline)
                Spacer()
            }

            Divider()

            ForEach(sellers.prefix(10)) { seller in
                sellerRow(seller)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func sellerRow(_ seller: LVMarketSellerRank) -> some View {
        let isUser = seller.seller == userSellerName

        return HStack(spacing: 8) {
            // Rank badge
            ZStack {
                Circle()
                    .fill(rankColor(seller.rank))
                    .frame(width: 24, height: 24)
                Text("\(seller.rank)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
            }

            // Seller name
            HStack(spacing: 4) {
                Text(seller.seller)
                    .font(.subheadline)
                    .lineLimit(1)

                if isUser {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }

            Spacer()

            // Stats - show contract count and avg price
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(seller.tradeCount) contracts")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.purple)
                Text(String(format: "%.1f¢", seller.avgPriceCents))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 4)
        .background(isUser ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(6)
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .orange
        default: return .secondary.opacity(0.5)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: 8) {
            Text("Shows agreed P2P contracts on LocalVolts. Prices show what sellers receive vs buyers pay. The spread is LocalVolts' matching fee.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("Yesterday = settled (complete) • Today = all • All = historical")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if viewMode != .allData, let lastRefresh = lastRefresh {
                Text("Last updated: \(lastRefresh, style: .relative) ago")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text("Collect 30-60 days of data for complete market picture")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }

    // MARK: - Data Loading

    private func loadCachedOrFetch() {
        // Load historical data
        loadHistoricalData()

        // Try cached data for today first
        let cached = localVoltsService.getMarketContractsForToday()
        if !cached.isEmpty {
            contracts = cached
            reanalyzeForViewMode()
            lastRefresh = localVoltsService.lastMarketFetchTime

            // Refresh if stale
            if localVoltsService.needsMarketRefresh() {
                Task { await refreshMarketData() }
            }
        } else if localVoltsService.hasCredentials {
            Task { await refreshMarketData() }
        }
    }

    /// Re-analyze contracts based on current view mode
    private func reanalyzeForViewMode() {
        _ = analysis.analyze(contracts: displayContracts, userSeller: userSellerName)
    }

    private func loadHistoricalData() {
        // Get all dates with data
        let dates = PowstonDataStore.shared.getLVMarketContractDates()
        daysOfData = dates.count

        if let earliest = dates.last, let latest = dates.first {
            dataDateRange = (earliest, latest)
        }

        // Load all historical contracts (last 60 days)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = powstonTimezone()
        let sixtyDaysAgo = calendar.date(byAdding: .day, value: -60, to: Date())!
        allContracts = PowstonDataStore.shared.getLVMarketContracts(from: sixtyDaysAgo, to: Date())
    }

    private func refreshMarketData() async {
        guard let site = api.selectedSite else { return }

        isLoading = true
        error = nil

        do {
            let fetched = try await localVoltsService.fetchMarketContracts(siteId: site.id)
            contracts = fetched
            reanalyzeForViewMode()
            lastRefresh = Date()

            // Reload historical data after fetching new data
            loadHistoricalData()

            // Run unfilled opportunity analysis
            analyzeUnfilledOpportunities()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Analyze unfilled orders vs market conditions
    private func analyzeUnfilledOpportunities() {
        guard let siteId = api.selectedSite?.id else { return }

        // Get current spot price from inverter data (RRP is in $/MWh)
        let spotPriceCents = (api.data?.rrp ?? 0) / 10  // Convert $/MWh to ¢/kWh

        // Get active sell orders from LocalVolts service
        let orders = localVoltsService.getActiveOrders(siteId: siteId, direction: "Sell")

        guard !orders.isEmpty, !contracts.isEmpty else { return }

        // For now, use empty fills (we'd need TradeDetail to get actual fill status)
        // This will show all unfilled orders - conservative approach
        let fills: [String: Double] = [:]

        opportunityAnalysis.analyze(
            orders: orders,
            fills: fills,
            marketContracts: contracts,
            spotPriceCents: spotPriceCents
        )
    }
}
