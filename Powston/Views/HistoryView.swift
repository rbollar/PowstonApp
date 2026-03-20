//
//  HistoryView.swift
//  Powston
//
//  History view with day/week/month/year/custom modes
//  Financial analysis focus - operational detail moved to DecisionsView
//
//  Data Sources & Caching:
//  - day_rates API: Bulk summaries (Aug 2024+), in-memory cache
//  - meter_records API: Interval data via PowstonAPI.fetchMeterRecords()
//    → SQLite cache-through: finalized data (>7 days) served without API calls
//  - fetchDailyBreakdownCumulative: Per-day breakdown via cumulative subtraction
//    → SQLite cache-through: finalized days served from cache
//

import SwiftUI

// Notification for site changes and P2P data updates
extension Notification.Name {
    static let refreshDataNeeded = Notification.Name("refreshDataNeeded")
    static let siteDidChange = Notification.Name("siteDidChange")
    static let p2pDataDidChange = Notification.Name("p2pDataDidChange")
}

extension Double {
    var nonZero: Double? { self != 0 ? self : nil }
}

enum HistoryViewMode: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case year = "Year"
    case custom = "Custom"
}

struct HistoryView: View {
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @StateObject private var orientationManager = OrientationManager.shared
    @StateObject private var weatherService = WeatherService.shared
    
    // Core state
    @State private var records: [MeterRecord] = []
    @State private var isLoading = false
    @State private var loadingProgress: (current: Int, total: Int)? = nil
    @State private var selectedDate: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var showDatePicker = false
    @State private var viewMode: HistoryViewMode = .day
    
    // Centralized loading task management - prevents racing requests
    @State private var loadingTask: Task<Void, Never>?
    
    // Custom date range
    @State private var customStartDate: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEndDate: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @AppStorage("custom_range_start") private var savedCustomStart: Double = Date().addingTimeInterval(-30*24*3600).timeIntervalSince1970
    @AppStorage("custom_range_end") private var savedCustomEnd: Double = Date().addingTimeInterval(-24*3600).timeIntervalSince1970
    
    // Scrub state for multi-day charts
    @State private var monthScrubIndex: Int?
    
    // Day rates summary (available back to Aug 2024)
    @State private var daySummary: DayRateSummary?
    @State private var isLoadingSummary = false
    
    // Tariff rates from API
    @State private var tariffPeriods: [TariffPeriodPerformance] = []
    @State private var tariffDefinitions: [TariffPeriodDefinition] = []
    
    // Historical weather
    @State private var historicalWeather: [HourlyWeather] = []
    @State private var isLoadingWeather = false
    
    @AppStorage("peak_start_hour") private var peakStartHour: Double = 16.0
    
    // Cached computed values
    @State private var cachedDailySummaries: [DailySummary] = []
    @State private var cachedTotalEarnings: Double = 0
    @State private var cachedTotalCosts: Double = 0
    @State private var cachedTotalImport: Double = 0
    @State private var cachedTotalExport: Double = 0
    @State private var cachedSupplyCosts: Double = 0
    @State private var cachedActualNetProfit: Double = 0
    // Day view financial summary (from fetchHourlyDaySummary for accuracy)
    @State private var dayFinancialSummary: (sold: Double, bought: Double, supply: Double, net: Double, importKwh: Double, exportKwh: Double)?
    @State private var dayEmissionsKgCO2e: Double?
    // Rolling average for heatmap color calibration (30-day)
    @State private var rollingAverage: Double = 0
    // Savings analysis (requires complete meter_records with ppvGeneration)
    @State private var savingsAnalysis: SavingsAnalysis?
    
    // P2P Counterparty Detail
    @State private var dayP2PCounterparties: [P2PCounterpartyTrade] = []
    @State private var p2pImportDateRange: String? = nil

    // Year view P2P summary (year view doesn't use SavingsAnalysis)
    @State private var yearP2PData: PowstonDataStore.P2PRangeResult?

    // Data source indicator for summary cards
    @State private var dataSourceLabel: String? = nil
    
    var isLandscape: Bool { verticalSizeClass == .compact }
    
    var cachedNetProfit: Double { cachedTotalEarnings - cachedTotalCosts }
    
    /// Build daily summaries from meter records (same data source as Savings Analysis)
    /// This ensures Daily Net chart matches Day view and Savings Analysis
    private func buildDailySummaries(from records: [MeterRecord]) -> [DailySummary] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        
        let grouped = Dictionary(grouping: records) { record -> String in
            guard let date = record.date else { return "" }
            return dateFormatter.string(from: date)
        }
        
        return grouped.compactMap { (dateStr, dayRecords) -> DailySummary? in
            guard !dateStr.isEmpty, let date = dateFormatter.date(from: dateStr) else { return nil }
            let earnings = dayRecords.compactMap { $0.earnings }.reduce(0, +) / 100.0
            let costs = dayRecords.compactMap { $0.costs }.reduce(0, +) / 100.0
            return DailySummary(
                date: date,
                totalImport: dayRecords.compactMap { $0.energyImport }.reduce(0, +),
                totalExport: dayRecords.compactMap { $0.energyExport }.reduce(0, +),
                totalEarnings: earnings,
                totalCosts: costs,
                avgSoc: 0,
                recordCount: dayRecords.count,
                netProfit: earnings - costs
            )
        }.sorted { $0.date < $1.date }
    }
    
    /// Fill gaps in daily summaries with LV settlement data
    /// When Powston data covers only part of the date range, days before data started
    /// (or any missing days) can be filled from LV cashflow if available.
    /// LV settlement data already includes P2P — do NOT pass these through adjustDailySummariesForP2P.
    private func fillGapsWithLVSettlement(_ summaries: [DailySummary], siteId: Int, from: Date, to: Date) -> [DailySummary] {
        guard LocalVoltsService.shared.hasCredentials else { return summaries }

        var cal = Calendar.current
        cal.timeZone = powstonTimezone()

        // Build set of dates that already have summaries
        let existingDates = Set(summaries.map { cal.startOfDay(for: $0.date) })

        // Find missing dates in range
        var missingDates: [Date] = []
        var checkDate = cal.startOfDay(for: from)
        let endDate = cal.startOfDay(for: to)
        while checkDate <= endDate {
            if !existingDates.contains(checkDate) {
                missingDates.append(checkDate)
            }
            checkDate = cal.date(byAdding: .day, value: 1, to: checkDate)!
        }

        guard !missingDates.isEmpty else { return summaries }

        // Get LV cashflow for the full range (already cached from earlier fetchOnDemand)
        let lvSummaries = PowstonDataStore.shared.getLVCashflowSummaries(siteId: siteId, from: from, to: to)
        guard !lvSummaries.isEmpty else { return summaries }

        let lvByDate: [String: LVCashflowSummary] = Dictionary(
            uniqueKeysWithValues: lvSummaries.map { (String($0.date.prefix(10)), $0) }
        )

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()

        var merged = summaries
        for date in missingDates {
            let dateStr = dateFormatter.string(from: date)
            if let lv = lvByDate[dateStr], let daily = lv.toDailySummary() {
                merged.append(daily)
            }
        }

        return merged.sorted { $0.date < $1.date }
    }

    /// Adjust daily summaries with per-day P2P premium for charts
    /// P2P premium is NOT included in Powston API earnings — add it per day
    private func adjustDailySummariesForP2P(_ summaries: [DailySummary], siteId: Int) -> [DailySummary] {
        return summaries.map { summary in
            if let p2p = PowstonDataStore.shared.calculateP2PPremium(siteId: siteId, date: summary.date) {
                let sellPremium = p2p.sellRevenue - p2p.sellSpotEquivalent
                let buySavings = p2p.buySpotEquivalent - p2p.buyCost
                let adjustment = sellPremium + buySavings
                if abs(adjustment) > 0.001 {
                    return DailySummary(
                        date: summary.date,
                        totalImport: summary.totalImport,
                        totalExport: summary.totalExport,
                        totalEarnings: summary.totalEarnings + sellPremium,
                        totalCosts: summary.totalCosts - buySavings,
                        avgSoc: summary.avgSoc,
                        recordCount: summary.recordCount,
                        netProfit: summary.netProfit + adjustment
                    )
                }
            }
            return summary
        }
    }

    /// Build price lookup dictionary from action records for a date range
    /// This ensures hypothetical scenarios use actual TOU prices, not flat defaults
    private func buildPricesByInterval(siteId: Int, from startDate: Date, to endDate: Date) -> [String: (buy: Double, sell: Double)] {
        // Align to midnight boundaries
        let alignedStart = calendar.startOfDay(for: startDate)
        let alignedEnd = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate)
        
        print("📅 buildPricesByInterval: \(alignedStart) to \(alignedEnd)")
        let actions = PowstonDataStore.shared.fetchActions(siteId: siteId, from: alignedStart, to: alignedEnd)
        
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        
        var pricesByInterval: [String: (buy: Double, sell: Double)] = [:]
        for action in actions {
            var key = isoFormatter.string(from: action.intervalTime)
            // Normalize to Z format to match record.intervalTime normalization
            key = key.replacingOccurrences(of: "+00:00", with: "Z")
            if let buy = action.buyPrice, let sell = action.sellPrice {
                pricesByInterval[key] = (buy: buy, sell: sell)
            }
        }
        
        return pricesByInterval
    }
    
    // MARK: - Number Formatting Helpers
    
    /// Format currency with thousands separator
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        
        let absValue = abs(value)
        return formatter.string(from: NSNumber(value: absValue)) ?? String(format: "$%.2f", absValue)
    }
    
    /// Format energy with thousands separator (integer for large values)
    private func formatEnergy(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        // Show as integer for values >= 1000, otherwise 2 decimal places
        if abs(value) >= 1000 {
            formatter.maximumFractionDigits = 0
            formatter.minimumFractionDigits = 0
        } else {
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
        }
        return (formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)) + " kWh"
    }
    
    // Data availability checks
    var hasEnergyData: Bool {
        cachedTotalImport > 0 || cachedTotalExport > 0
    }
    var hasDailyEnergyData: Bool { cachedDailySummaries.contains { $0.totalImport > 0 || $0.totalExport > 0 } }
    
    /// Smart error message for day view when meter_records unavailable but day_rates exists
    var intervalDataMessage: String? {
        if viewMode == .day && records.isEmpty && daySummary != nil && !isToday && dataSourceLabel != "LV Settlement" {
            return "5-minute interval data not available for this date. Summary data shown above."
        }
        return nil
    }
    
    var calendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = powstonTimezone()
        return cal
    }
    
    // MARK: - SOC Summary from meter_records
    
    var socSummary: (min: Double, max: Double, end: Double)? {
        let socValues = records.compactMap { $0.startBatterySoc }
        guard !socValues.isEmpty else { return nil }
        let endSoc = records.last?.endBatterySoc ?? records.last?.startBatterySoc ?? socValues.last!
        return (socValues.min()!, socValues.max()!, endSoc)
    }
    
    // MARK: - Weather Summary
    
    var weatherSummary: (tempMin: Double, tempMax: Double, cloudIcon: String, cloudDesc: String, solarKWh: Double)? {
        guard !historicalWeather.isEmpty else { return nil }
        let temps = historicalWeather.map { $0.temperature }
        let clouds = historicalWeather.map { $0.cloudCover }
        let avgCloud = clouds.reduce(0, +) / max(1, clouds.count)
        let totalRadiation = historicalWeather.map { $0.totalRadiation }.reduce(0, +)
        // Convert W/m² hourly samples to approximate kWh/m² (1 hour each sample)
        let solarKWh = totalRadiation / 1000.0
        
        let cloudIcon: String
        let cloudDesc: String
        if avgCloud < 20 { cloudIcon = "sun.max.fill"; cloudDesc = "Clear" }
        else if avgCloud < 50 { cloudIcon = "cloud.sun.fill"; cloudDesc = "Partly cloudy" }
        else if avgCloud < 80 { cloudIcon = "cloud.fill"; cloudDesc = "Cloudy" }
        else { cloudIcon = "smoke.fill"; cloudDesc = "Overcast" }
        
        return (temps.min()!, temps.max()!, cloudIcon, cloudDesc, solarKWh)
    }
    
    // MARK: - Date Calculations
    
    var weekStart: Date {
        calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDate)) ?? selectedDate
    }
    var weekEnd: Date { calendar.date(byAdding: .day, value: 6, to: weekStart) ?? selectedDate }
    var currentWeekStart: Date {
        calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
    }
    var lastCompleteWeekStart: Date { calendar.date(byAdding: .day, value: -7, to: currentWeekStart) ?? Date() }
    
    var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate)) ?? selectedDate
    }
    var monthEnd: Date {
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return selectedDate }
        return calendar.date(byAdding: .day, value: -1, to: nextMonth) ?? selectedDate
    }
    var currentMonthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
    }
    var isCurrentMonth: Bool { calendar.isDate(monthStart, inSameDayAs: currentMonthStart) }
    
    var yearStart: Date {
        calendar.date(from: DateComponents(year: calendar.component(.year, from: selectedDate), month: 1, day: 1)) ?? selectedDate
    }
    var currentYearStart: Date {
        calendar.date(from: DateComponents(year: calendar.component(.year, from: Date()), month: 1, day: 1)) ?? Date()
    }
    var isCurrentYear: Bool { calendar.component(.year, from: selectedDate) == calendar.component(.year, from: Date()) }
    
    var customRangeDays: Int { (calendar.dateComponents([.day], from: customStartDate, to: customEndDate).day ?? 0) + 1 }
    
    // MARK: - Formatted Strings
    
    var formattedSelectedDate: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; f.timeZone = powstonTimezone()
        return f.string(from: selectedDate)
    }
    var formattedWeekRange: String {
        let f = DateFormatter(); f.timeZone = powstonTimezone(); f.dateFormat = "MMM d"
        return "\(f.string(from: weekStart)) – \(f.string(from: weekEnd))"
    }
    var formattedMonth: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; f.timeZone = powstonTimezone()
        return f.string(from: monthStart)
    }
    var formattedYear: String {
        let f = DateFormatter(); f.dateFormat = "yyyy"; f.timeZone = powstonTimezone()
        return f.string(from: yearStart)
    }
    var formattedCustomRange: String {
        let f = DateFormatter(); f.timeZone = powstonTimezone(); f.dateFormat = "MMM d"
        return "\(f.string(from: customStartDate)) – \(f.string(from: customEndDate))"
    }
    var formattedDateDisplay: String {
        switch viewMode {
        case .day: return formattedSelectedDate
        case .week: return formattedWeekRange
        case .month: return formattedMonth
        case .year: return formattedYear
        case .custom: return formattedCustomRange
        }
    }
    
    var isToday: Bool { calendar.isDateInToday(selectedDate) }
    var isYesterday: Bool { calendar.isDateInYesterday(selectedDate) }
    var isLastCompleteWeek: Bool { calendar.isDate(weekStart, inSameDayAs: lastCompleteWeekStart) }
    var isCurrentWeek: Bool { calendar.isDate(weekStart, inSameDayAs: currentWeekStart) }

    /// The latest date we can navigate to (based on data availability)
    /// Defaults to day-before-yesterday until refreshLatestCompleteDataDate() confirms yesterday is finalized
    var latestNavigableDate: Date {
        api.latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -2, to: Date()) ?? Date()
    }

    /// Check if selected date is at or past the latest available data
    var isAtOrPastLatestData: Bool {
        let selectedDay = calendar.startOfDay(for: selectedDate)
        let latestDay = calendar.startOfDay(for: latestNavigableDate)
        return selectedDay >= latestDay
    }

    var canAdvance: Bool {
        let latestDay = calendar.startOfDay(for: latestNavigableDate)
        switch viewMode {
        case .day:
            // Can only advance if we haven't reached the latest complete data date
            let selectedDay = calendar.startOfDay(for: selectedDate)
            return selectedDay < latestDay
        case .week:
            // Can advance if the next week's start is <= latestNavigableDate
            guard let nextWeekStart = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return false }
            return nextWeekStart <= latestDay && !isCurrentWeek
        case .month:
            // Can advance if the next month contains any finalized days
            guard let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return false }
            return nextMonthStart <= latestDay && !isCurrentMonth
        case .year: return !isCurrentYear
        case .custom:
            return customEndDate < latestDay
        }
    }
    
    var jumpButtonTitle: String {
        switch viewMode {
        case .day:
            if calendar.isDateInToday(latestNavigableDate) { return "Today" }
            return calendar.isDateInYesterday(latestNavigableDate) ? "Yesterday" : "Latest"
        case .week: return "Latest"
        case .month: return "Latest"
        case .year: return "This Year"
        case .custom: return "Latest"
        }
    }
    
    var isAtLatest: Bool {
        switch viewMode {
        case .day:
            // At latest if we're on the latest complete data date
            return calendar.isDate(selectedDate, inSameDayAs: latestNavigableDate)
        case .week:
            // At latest if the week contains the latest navigable date
            let latestDay = calendar.startOfDay(for: latestNavigableDate)
            return weekStart <= latestDay && weekEnd >= latestDay
        case .month:
            // At latest if the month contains the latest navigable date
            let latestDay = calendar.startOfDay(for: latestNavigableDate)
            return monthStart <= latestDay && monthEnd >= latestDay
        case .year: return isCurrentYear
        case .custom:
            return calendar.isDate(customEndDate, inSameDayAs: latestNavigableDate)
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    viewModePicker
                    dateSelector
                    mainContent
                }
            }
            .refreshable {
                loadingTask?.cancel()
                await loadHistory(forceRefresh: true)
            }
            .background(Color.gray.opacity(0.02))
            .navigationTitle(api.isDemoMode ? "History (Demo)" : "History")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(jumpButtonTitle) {
                        jumpToLatest()
                        triggerLoad()
                    }
                    .disabled(isAtLatest)
                }
                ToolbarItem(placement: .topBarTrailing) { SiteIndicatorPill() }
            }
            .sheet(isPresented: $showDatePicker) { datePickerSheet }
            .task {
                if records.isEmpty && daySummary == nil {
                    // Ensure we start with a date that has finalized data
                    // Uses day_rates as a reliable canary for data availability
                    await api.refreshLatestCompleteDataDate()
                    let targetDate = calendar.startOfDay(for: selectedDate)
                    let latestDay = calendar.startOfDay(for: latestNavigableDate)
                    if targetDate > latestDay {
                        // Selected date doesn't have data yet, adjust to latest available
                        selectedDate = latestNavigableDate
                    }
                    triggerLoad()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .siteDidChange)) { _ in handleSiteChange() }
            .onReceive(NotificationCenter.default.publisher(for: .p2pDataDidChange)) { _ in
                // Reload when P2P data is imported/deleted to update P2P display
                triggerLoad(forceRefresh: true)
            }
        }
        .onAppear { orientationManager.lockToPortrait() }
        .onDisappear { orientationManager.lockToPortrait() }
    }
    
    // MARK: - Subviews
    
    private var viewModePicker: some View {
        Picker("View Mode", selection: $viewMode) {
            ForEach(HistoryViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 8)
        .onChange(of: viewMode) { _, newValue in
            if newValue == .custom {
                customStartDate = Date(timeIntervalSince1970: savedCustomStart)
                customEndDate = Date(timeIntervalSince1970: savedCustomEnd)
            }
            triggerLoad()
        }
    }
    
    private var dateSelector: some View {
        HStack(spacing: 12) {
            Button(action: { changeDate(by: dateStep(forward: false)) }) {
                Image(systemName: "chevron.left").font(.title2).foregroundColor(isLoading ? .gray : .blue)
            }
            .disabled(isLoading)
            
            Button(action: { showDatePicker = true }) {
                HStack(spacing: 8) {
                    if isLoading && loadingProgress == nil { ProgressView().scaleEffect(0.8) }
                    else { Image(systemName: "calendar") }
                    Text(formattedDateDisplay).fontWeight(.medium)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.gray.opacity(0.1)).cornerRadius(8)
            }
            .buttonStyle(.plain).disabled(isLoading)
            
            Button(action: { changeDate(by: dateStep(forward: true)) }) {
                Image(systemName: "chevron.right").font(.title2)
                    .foregroundColor(canAdvance && !isLoading ? .blue : .gray)
            }
            .disabled(!canAdvance || isLoading)
        }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        if isLoading || isLoadingSummary { loadingView }
        else if api.isDemoMode { demoModeView }
        else if records.isEmpty && daySummary == nil && cachedDailySummaries.isEmpty && tariffPeriods.isEmpty && dayFinancialSummary == nil { emptyStateView }
        else { dataContent }
    }
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            if let progress = loadingProgress {
                Text("Loading week \(progress.current) of \(progress.total)...").font(.subheadline).foregroundColor(.secondary)
            } else {
                Text("Loading history...").font(.subheadline).foregroundColor(.secondary)
            }
        }
        .padding(.top, 60)
    }
    
    private var demoModeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "theatermasks.fill").font(.largeTitle).foregroundColor(.orange)
            Text("History not available in Demo").font(.headline).foregroundColor(.secondary)
            Text("Connect your Powston account to view historical data")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 60).padding(.horizontal, 40)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundColor(.secondary)
            Text("No history for this \(viewMode.rawValue.lowercased())").font(.headline).foregroundColor(.secondary)
        }
        .padding(.top, 60)
    }
    
    private var dataContent: some View {
        VStack(spacing: 20) {
            summaryCardsSection

            // Operational context for day view (compact summary)
            if viewMode == .day {
                operationalSummarySection
            }
            
            chartsSection
            tariffSection
            footerSection
            Spacer(minLength: 20)
        }
    }

    private var summaryCardsSection: some View {
            VStack {
                // Day view: use dayFinancialSummary for accurate single-day financials
                if viewMode == .day && (dayFinancialSummary != nil || !tariffPeriods.isEmpty) {
                    daySummarySummaryCards
                } else if viewMode == .day && daySummary != nil {
                    // Fallback to daySummary if other data unavailable (but note: may show 2 days due to API bug)
                    daySummaryFallbackCards
                } else {
                    standardSummaryCards
                }
                if let label = dataSourceLabel, !isLoadingSummary, !isLoading {
                    Text(label)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 4)
                }
            }
            .padding(.horizontal)
        }
    
    /// Day view summary cards using fetchHourlyDaySummary (matches Scorecard and Powston web)
        private var daySummarySummaryCards: some View {
            VStack(spacing: 12) {
                if let fin = dayFinancialSummary {
                    // Use API-sourced financials for accuracy
                    HStack(spacing: 8) {
                        SummaryCard(title: "Sold", value: formatCurrency(fin.sold), icon: "arrow.up.circle.fill", color: .green)
                        SummaryCard(title: "Bought", value: formatCurrency(fin.bought), icon: "arrow.down.circle.fill", color: .red)
                        SummaryCard(title: "Supply", value: formatCurrency(fin.supply), icon: "minus.circle.fill", color: .orange)
                        SummaryCard(title: "Net", value: formatCurrency(abs(fin.net)),
                                   icon: fin.net >= 0 ? "plus.circle.fill" : "minus.circle.fill",
                                   color: fin.net >= 0 ? .green : .red)
                    }
                    
                    // Energy summary
                    if fin.importKwh > 0 || fin.exportKwh > 0 {
                        HStack(spacing: 12) {
                            EnergySummaryCard(title: "Imported", value: formatEnergy(fin.importKwh), color: .red)
                            EnergySummaryCard(title: "Exported", value: formatEnergy(fin.exportKwh), color: .green)
                        }
                    }
                } else if !tariffPeriods.isEmpty {
                    // Fallback to tariff periods if fetchHourlyDaySummary failed
                    let sold = tariffPeriods.map { $0.earnings }.reduce(0, +) / 100.0
                    let bought = tariffPeriods.map { $0.costs }.reduce(0, +) / 100.0  // Use 'costs' (energy only)
                    let netBill = tariffPeriods.map { $0.expectedBill }.reduce(0, +) / 100.0
                    let net = -netBill
                    let supply = sold - bought - net
                    
                    HStack(spacing: 8) {
                        SummaryCard(title: "Sold", value: formatCurrency(sold), icon: "arrow.up.circle.fill", color: .green)
                        SummaryCard(title: "Bought", value: formatCurrency(bought), icon: "arrow.down.circle.fill", color: .red)
                        SummaryCard(title: "Supply", value: formatCurrency(supply), icon: "minus.circle.fill", color: .orange)
                        SummaryCard(title: "Net", value: formatCurrency(abs(net)),
                                   icon: net >= 0 ? "plus.circle.fill" : "minus.circle.fill",
                                   color: net >= 0 ? .green : .red)
                    }
                    
                    // Energy from tariff periods
                    let imported = tariffPeriods.map { $0.energyImport }.reduce(0, +)
                    let exported = tariffPeriods.map { $0.energyExport }.reduce(0, +)
                    if imported > 0 || exported > 0 {
                        HStack(spacing: 12) {
                            EnergySummaryCard(title: "Imported", value: formatEnergy(imported), color: .red)
                            EnergySummaryCard(title: "Exported", value: formatEnergy(exported), color: .green)
                        }
                    }
                }
            }
        }
    
    /// Fallback day view cards using daySummary (may be inaccurate due to API 2-day bug)
    private var daySummaryFallbackCards: some View {
        VStack(spacing: 12) {
            let sold = daySummary?.earningsDollars ?? 0
            let bought = daySummary?.rateCostsDollars ?? 0
            let net = daySummary?.netProfitDollars ?? 0
            let supply = sold - bought - net  // Derived to always reconcile
            
            HStack(spacing: 8) {
                SummaryCard(title: "Sold", value: formatCurrency(sold), icon: "arrow.up.circle.fill", color: .green)
                SummaryCard(title: "Bought", value: formatCurrency(bought), icon: "arrow.down.circle.fill", color: .red)
                SummaryCard(title: "Supply", value: formatCurrency(supply), icon: "minus.circle.fill", color: .orange)
                SummaryCard(title: "Net", value: formatCurrency(abs(net)),
                           icon: net >= 0 ? "plus.circle.fill" : "minus.circle.fill",
                           color: net >= 0 ? .green : .red)
            }
            
            if let s = daySummary, (s.totalEnergyImported > 0 || s.totalEnergyExported > 0) {
                HStack(spacing: 12) {
                    EnergySummaryCard(title: "Imported", value: formatEnergy(s.totalEnergyImported), color: .red)
                    EnergySummaryCard(title: "Exported", value: formatEnergy(s.totalEnergyExported), color: .green)
                }
            }
        }
    }
    
    private var standardSummaryCards: some View {
        VStack(spacing: 12) {
            if viewMode == .day {
                // Fallback: day view without daySummary (meter_records only, rare)
                HStack(spacing: 12) {
                    SummaryCard(title: "Earnings", value: formatCurrency(cachedTotalEarnings), icon: "arrow.up.circle.fill", color: .green)
                    SummaryCard(title: "Costs", value: formatCurrency(cachedTotalCosts), icon: "arrow.down.circle.fill", color: .red)
                    SummaryCard(title: "Net", value: formatCurrency(abs(cachedNetProfit)),
                               icon: cachedNetProfit >= 0 ? "plus.circle.fill" : "minus.circle.fill",
                               color: cachedNetProfit >= 0 ? .green : .red)
                }
            } else {
                // Week/Month/Year/Custom: 4-card layout from bulk API
                HStack(spacing: 8) {
                    SummaryCard(title: "Sold", value: formatCurrency(cachedTotalEarnings), icon: "arrow.up.circle.fill", color: .green)
                    SummaryCard(title: "Bought", value: formatCurrency(cachedTotalCosts), icon: "arrow.down.circle.fill", color: .red)
                    SummaryCard(title: "Supply", value: formatCurrency(cachedSupplyCosts), icon: "minus.circle.fill", color: .orange)
                    SummaryCard(title: "Net", value: formatCurrency(abs(cachedActualNetProfit)),
                               icon: cachedActualNetProfit >= 0 ? "plus.circle.fill" : "minus.circle.fill",
                               color: cachedActualNetProfit >= 0 ? .green : .red)
                }
            }
            if hasEnergyData { energySummaryRow }
        }
    }
    
    private var energySummaryRow: some View {
        HStack(spacing: 12) {
            EnergySummaryCard(title: "Imported", value: formatEnergy(cachedTotalImport), color: .red)
            EnergySummaryCard(title: "Exported", value: formatEnergy(cachedTotalExport), color: .green)
        }
    }
    
    // MARK: - Battery Day Arc

    struct BatteryDayArc: View {
        let startSoc: Double
        let peakSoc: Double
        let endSoc: Double
        
        var body: some View {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                
                // Arc positioning with padding for labels
                let arcInsetX: CGFloat = 16
                let arcTop: CGFloat = 24
                let arcBottom: CGFloat = height - 14
                
                let startPoint = CGPoint(x: arcInsetX, y: arcBottom)
                let peakPoint = CGPoint(x: width / 2, y: arcTop)
                let endPoint = CGPoint(x: width - arcInsetX, y: arcBottom)
                
                ZStack {
                    // Smooth bezier arc with gradient stroke
                    Path { path in
                        path.move(to: startPoint)
                        path.addCurve(
                            to: endPoint,
                            control1: CGPoint(x: startPoint.x + 10, y: arcTop),
                            control2: CGPoint(x: endPoint.x - 10, y: arcTop)
                        )
                    }
                    .stroke(
                        LinearGradient(
                            colors: [.green, .yellow, .orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    
                    // Anchor dots
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                        .position(startPoint)
                    
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                        .position(endPoint)
                    
                    // Peak percentage label (above curve)
                    Text("\(Int(peakSoc))%")
                        .font(.caption.monospacedDigit().bold())
                        .position(x: peakPoint.x, y: peakPoint.y - 8)
                    
                    // Battery icon (below curve)
                    Image(systemName: batteryIcon(for: peakSoc))
                        .font(.system(size: 22))
                        .foregroundColor(.green)
                        .position(x: peakPoint.x, y: peakPoint.y + 42)
                    
                    // Start SOC label
                    Text("\(Int(startSoc))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.green)
                        .position(x: startPoint.x, y: startPoint.y + 10)
                    
                    // End SOC label
                    Text("\(Int(endSoc))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.orange)
                        .position(x: endPoint.x, y: endPoint.y + 10)
                }
            }
            .frame(height: 90)
        }
        
        private func batteryIcon(for soc: Double) -> String {
            switch soc {
            case 0..<13: return "battery.0percent"
            case 13..<38: return "battery.25percent"
            case 38..<63: return "battery.50percent"
            case 63..<88: return "battery.75percent"
            default: return "battery.100percent"
            }
        }
    }

    // MARK: - Operational Summary Card

    struct OperationalSummaryCard: View {
        let socSummary: (min: Double, max: Double, end: Double)?
        let gridImport: Double
        let gridExport: Double
        let weatherSummary: (tempMin: Double, tempMax: Double, cloudIcon: String, cloudDesc: String, solarKWh: Double)?
        let isLoadingWeather: Bool
        var emissionsKgCO2e: Double? = nil
        
        var body: some View {
            HStack(alignment: .bottom, spacing: 40) {
                // Left: Battery Day Arc
                if let soc = socSummary {
                    BatteryDayArc(startSoc: soc.min, peakSoc: soc.max, endSoc: soc.end)
                        .frame(maxWidth: .infinity)
                }
                
                // Right: Weather stack
                weatherSection
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color.gray.opacity(0.08))
            .cornerRadius(10)
        }
        
        @ViewBuilder
        private var weatherSection: some View {
            if isLoadingWeather {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading weather...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let weather = weatherSummary {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        Image(systemName: "thermometer.medium")
                            .foregroundColor(.orange)
                            .frame(width: 14)
                        Text("\(Int(weather.tempMin))–\(Int(weather.tempMax))°C")
                            .font(.subheadline)
                    }
                    
                    HStack(spacing: 12) {
                        Image(systemName: weather.cloudIcon)
                            .foregroundColor(weather.cloudIcon.contains("sun") ? .yellow : .gray)
                            .frame(width: 14)
                        Text(weather.cloudDesc)
                            .font(.subheadline)
                    }
                    
                    HStack(spacing: 12) {
                        Image(systemName: "sun.max.fill")
                            .foregroundColor(.yellow)
                            .frame(width: 14)
                        Text(String(format: "%.1f kWh/m²", weather.solarKWh))
                            .font(.subheadline.monospacedDigit())
                    }

                    if let co2e = emissionsKgCO2e, co2e > 0 {
                        HStack(spacing: 12) {
                            Image(systemName: "leaf.fill")
                                .foregroundColor(.green)
                                .frame(width: 14)
                            Text(String(format: "%.1f kg CO₂e", co2e))
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                }
            } else {
                EmptyView()
            }
        }
    }
    
    // MARK: - Operational Summary (Day View Context)
    
    @ViewBuilder
    private var operationalSummarySection: some View {
        let hasSoc = socSummary != nil
        let hasWeather = weatherSummary != nil
        
        if hasSoc || hasWeather || !records.isEmpty {
            OperationalSummaryCard(
                socSummary: socSummary,
                gridImport: cachedTotalImport,
                gridExport: cachedTotalExport,
                weatherSummary: weatherSummary,
                isLoadingWeather: isLoadingWeather,
                emissionsKgCO2e: dayEmissionsKgCO2e
            )
            .padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private var chartsSection: some View {
        // Smart error message for old dates with summary but no interval data
        if let message = intervalDataMessage {
            DataNotAvailableCard(title: "Interval Data", message: message).padding(.horizontal)
        }
        
        if viewMode == .year { yearCharts }
        else if viewMode == .month || viewMode == .week || viewMode == .custom { monthCustomCharts }
        // Day view no longer shows SOC/GridFlow charts - that's in Decisions
        
        // Savings analysis card (day/week/month/custom when data available)
                if viewMode != .year, let analysis = savingsAnalysis {
                    SavingsAnalysisCard(
                        analysis: analysis,
                        networkName: api.selectedSite?.network,
                        importTariff: api.selectedSite?.tariff,
                        exportTariff: api.selectedSite?.exportTariff,
                        site: api.selectedSite,
                        p2pCounterparties: dayP2PCounterparties,
                        p2pImportDateRange: p2pImportDateRange
                    )
                    .padding(.horizontal)
                } else if viewMode != .year && !dayP2PCounterparties.isEmpty {
                    // P2P counterparty detail when savings analysis unavailable
                    P2PCounterpartySummaryCard(
                        counterparties: dayP2PCounterparties,
                        importDateRange: p2pImportDateRange
                    )
                    .padding(.horizontal)
                }

    }
    
    @ViewBuilder
    private var yearCharts: some View {
        if !cachedDailySummaries.isEmpty {
            // Year calendar heatmap with monthly cells
            let yearlyTotal = cachedDailySummaries.reduce(0) { $0 + $1.netProfit }
            let monthCount = cachedDailySummaries.count
            let yearlyAverage = monthCount > 0 ? yearlyTotal / Double(monthCount) : 0
            
            YearCalendarHeatmap(
                year: calendar.component(.year, from: selectedDate),
                monthlySummaries: cachedDailySummaries,
                yearlyAverage: yearlyAverage,
                onSelectMonth: navigateToMonth,
                overrideTotal: cachedActualNetProfit
            )
            .padding(.horizontal)
            
            ChartSection(title: "Monthly Energy") {
                MonthlyEnergyChart(summaries: cachedDailySummaries, scrubIndex: monthScrubIndex, onScrub: { monthScrubIndex = $0 })
                    .frame(height: 200)
            }
            ChartSection(title: "Monthly Net") {
                MonthlyProfitChart(summaries: cachedDailySummaries, scrubIndex: monthScrubIndex, onScrub: { monthScrubIndex = $0 })
                    .frame(height: 150)
            }
            if let summary = daySummary {
                YearInsightsCard(summary: summary, monthlySummaries: cachedDailySummaries).padding(.horizontal)
            }

            // P2P summary for year view
            if let p2p = yearP2PData, p2p.sellKwh > 0 || p2p.buyKwh > 0 {
                P2PYearSummaryCard(data: p2p).padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var monthCustomCharts: some View {
        // Calendar heatmap for week/month navigation
        if viewMode == .week {
            WeekCalendarHeatmap(
                weekStart: weekStart,
                dailySummaries: cachedDailySummaries,
                rollingAverage: rollingAverage,
                selectedDate: nil,
                onSelectDate: navigateToDay,
                overrideTotal: cachedActualNetProfit
            )
            .padding(.horizontal)
        } else if viewMode == .month {
            MonthCalendarHeatmap(
                monthStart: monthStart,
                dailySummaries: cachedDailySummaries,
                rollingAverage: rollingAverage,
                selectedDate: nil,
                onSelectDate: navigateToDay,
                overrideTotal: cachedActualNetProfit
            )
            .padding(.horizontal)
        }
        
        // Rolling average context (for week/month)
        if (viewMode == .week || viewMode == .month) && abs(rollingAverage) > 0.01 {
            let periodNet = cachedDailySummaries.reduce(0) { $0 + $1.netProfit }
            let periodDays = cachedDailySummaries.count
            let periodAvg = periodDays > 0 ? periodNet / Double(periodDays) : 0
            
            RollingAverageCard(
                currentNet: periodAvg,
                rollingAverage: rollingAverage,
                days: 30
            )
            .padding(.horizontal)
        }
        
        // Daily bar charts
        if hasDailyEnergyData {
            ChartSection(title: "Daily Energy") {
                DailyEnergyChart(summaries: cachedDailySummaries, scrubIndex: monthScrubIndex, onScrub: { monthScrubIndex = $0 })
                    .frame(height: 200)
            }
        } else {
            DataNotAvailableCard(title: "Daily Energy", message: "Retailer not configured for interval data").padding(.horizontal)
        }
        ChartSection(title: "Daily Net") {
            DailyProfitChart(summaries: cachedDailySummaries, scrubIndex: monthScrubIndex, onScrub: { monthScrubIndex = $0 })
                .frame(height: 150)
        }
    }
    
    @ViewBuilder
    private var tariffSection: some View {
        // Use API tariff data if available, otherwise fall back to meter_records analysis
        if !tariffPeriods.isEmpty && !(viewMode == .day && isToday) && viewMode != .year && viewMode != .month {
            TariffPeriodSection(periods: tariffPeriods, definitions: tariffDefinitions, isLandscape: isLandscape)
                .padding(.horizontal)
        } else if !records.isEmpty && !(viewMode == .day && isToday) && viewMode != .year {
            TariffAnalysisSection(records: records, peakStartHour: peakStartHour).padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private var footerSection: some View {
        if let earliest = api.earliestRecordDate {
            Text("Earliest data: \(formatEarliestDate(earliest))")
                .font(.caption2).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private var datePickerSheet: some View {
        if viewMode == .custom {
            CustomDateRangeSheet(startDate: $customStartDate, endDate: $customEndDate, minDate: api.earliestRecordDate) {
                savedCustomStart = customStartDate.timeIntervalSince1970
                savedCustomEnd = customEndDate.timeIntervalSince1970
                showDatePicker = false
                triggerLoad()
            }
        } else {
            DatePickerSheet(selectedDate: $selectedDate, viewMode: viewMode, minDate: api.earliestRecordDate, maxDate: latestNavigableDate) {
                showDatePicker = false
                triggerLoad()
            }
        }
    }
    
    // MARK: - Data Loading
    
    private func handleSiteChange() {
        viewMode = .day
        // Default to yesterday, but actual load will validate data availability
        selectedDate = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        records = []; daySummary = nil; historicalWeather = []
        tariffPeriods = []; tariffDefinitions = []
        dayFinancialSummary = nil
        dayEmissionsKgCO2e = nil
        savingsAnalysis = nil
        dayP2PCounterparties = []
        p2pImportDateRange = nil
        yearP2PData = nil
        // Use task to check data availability before loading
        Task {
            await api.refreshLatestCompleteDataDate()
            let targetDate = calendar.startOfDay(for: selectedDate)
            let latestDay = calendar.startOfDay(for: latestNavigableDate)
            if targetDate > latestDay {
                await MainActor.run {
                    selectedDate = latestNavigableDate
                }
            }
            triggerLoad()
        }
    }
    
    /// Convert LVCashflowSummary to dayFinancialSummary tuple
    private func cashflowToFinancialSummary(_ cf: LVCashflowSummary) -> (sold: Double, bought: Double, supply: Double, net: Double, importKwh: Double, exportKwh: Double) {
        let sold = cf.totalSales
        let supply = cf.networkAccessCost + cf.localvoltsFee
        let bought = cf.spotEnergyCost + cf.networkEnergyCost + cf.certificatesCost
        let net = -cf.netCosts
        return (
            sold: ((sold) * 100).rounded() / 100,
            bought: ((bought) * 100).rounded() / 100,
            supply: ((supply) * 100).rounded() / 100,
            net: ((net) * 100).rounded() / 100,
            importKwh: cf.energyPurchasedKwh,
            exportKwh: cf.energySoldTotalKwh
        )
    }

    /// Centralized load trigger - cancels any in-flight load before starting new one
    private func triggerLoad(forceRefresh: Bool = false) {
        loadingTask?.cancel()
        loadingTask = Task {
            await loadHistory(forceRefresh: forceRefresh)
        }
    }
    
    @MainActor
    func loadHistory(forceRefresh: Bool = false) async {
        // Check for cancellation at start
        guard !Task.isCancelled else { return }

        isLoading = true
        dataSourceLabel = nil
        daySummary = nil
        tariffPeriods = []
        tariffDefinitions = []
        historicalWeather = []

        // Ensure we know the latest finalized date before loading any view mode
        await api.refreshLatestCompleteDataDate()

        await Task.yield()

        var fetchedRecords: [MeterRecord] = []

        switch viewMode {
        case .day:
            // Check for cancellation before API calls
            guard !Task.isCancelled else { isLoading = false; return }
            
            // Calculate day boundaries for queries
            let dayStart = calendar.startOfDay(for: selectedDate)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            
            // CRITICAL: Use fetchHourlyDaySummary for accurate single-day financials
            // fetchCustomRangeSummary has a bug that returns 2 days for single-day queries
            dayFinancialSummary = nil
        dayEmissionsKgCO2e = nil
            if let hourlySum = await api.fetchHourlyDaySummary(date: selectedDate) {
                guard !Task.isCancelled else { isLoading = false; return }
                dayFinancialSummary = (
                    sold: hourlySum.totalEarnings,
                    bought: hourlySum.totalCosts,
                    supply: hourlySum.fixedCosts,
                    net: hourlySum.netProfit,
                    importKwh: hourlySum.totalImport,
                    exportKwh: hourlySum.totalExport
                )
            }
            
            guard !Task.isCancelled else { isLoading = false; return }
            
            // Also fetch day_rates summary for any other uses (e.g., rates display)
            daySummary = await api.fetchDaySummary(date: selectedDate)
            
            guard !Task.isCancelled else { isLoading = false; return }
            
            // Fetch meter_records for the full day (dayStart to dayEnd)
            // Using dayEnd (next day) ensures we get all 288 intervals
            fetchedRecords = await api.fetchMeterRecords(fromDate: dayStart, toDate: dayEnd, forceRefresh: forceRefresh)
            
            guard !Task.isCancelled else { isLoading = false; return }
            
            // Fetch tariff rates from API for the Tariff Periods section breakdown
            if let rates = await api.fetchTariffRates(startDate: dayStart, endDate: dayEnd) {
                tariffPeriods = rates.data
                tariffDefinitions = rates.periodDefinitions
            }
            
            guard !Task.isCancelled else { isLoading = false; return }
            
            // Fetch historical weather for context
            await loadHistoricalWeather(for: selectedDate)
            
            guard !Task.isCancelled else { isLoading = false; return }
            
            // Calculate savings analysis if we have complete data
                        savingsAnalysis = nil
                        dayP2PCounterparties = []
                        p2pImportDateRange = nil
                        if !fetchedRecords.isEmpty, let site = api.selectedSite, let fin = dayFinancialSummary {
                let batteryCapacity = Double(site.installedBattery ?? 0) / 1000.0  // Wh to kWh
                let supplyCost = dayFinancialSummary?.supply ?? 0
                let actualNet = dayFinancialSummary?.net ?? 0
                let siteId = site.id
                
                // Build price lookup from actions for accurate TOU-based hypotheticals
                let pricesByInterval = buildPricesByInterval(siteId: siteId, from: dayStart, to: dayEnd)
                
                // Get P2P data (NOT included in Powston API earnings — added by calculator and summary cards)
                var p2pRevenue: Double = 0
                var p2pSpotEquivalent: Double = 0
                var p2pSellRevenue: Double = 0
                var p2pSellKwh: Double = 0
                var p2pSellSpotEquivalent: Double = 0
                var p2pBuyCost: Double = 0
                var p2pBuyKwh: Double = 0
                var p2pBuySpotEquivalent: Double = 0
                var p2pNTB: Double = 0

                // Get P2P data if available (now includes separate sell/buy)
                if let p2pData = PowstonDataStore.shared.calculateP2PPremium(siteId: siteId, date: selectedDate) {
                    p2pRevenue = p2pData.p2pRevenue
                    p2pSpotEquivalent = p2pData.spotEquivalent
                    p2pSellRevenue = p2pData.sellRevenue
                    p2pSellKwh = p2pData.sellKwh
                    p2pSellSpotEquivalent = p2pData.sellSpotEquivalent
                    p2pBuyCost = p2pData.buyCost
                    p2pBuyKwh = p2pData.buyKwh
                    p2pBuySpotEquivalent = p2pData.buySpotEquivalent
                    p2pNTB = p2pData.ntb
                }

                // Use LV settlement data if available (authoritative source)
                // Falls back to P2P premium imputation if no settlement data
                // Fetch on demand if missing or recent (last 3 days may have incomplete data)
                let recentCutoff = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: Date())) ?? Date()
                let isRecentDay = dayStart >= recentCutoff
                if (isRecentDay || PowstonDataStore.shared.getLVCashflowSummary(siteId: siteId, date: selectedDate) == nil),
                   LocalVoltsService.shared.hasCredentials {
                    _ = await LocalVoltsService.shared.fetchSettlementOnDemand(
                        siteId: siteId, from: dayStart, to: dayEnd)
                    // Recalculate P2P from freshly fetched trade data
                    if let p2pData = PowstonDataStore.shared.calculateP2PPremium(siteId: siteId, date: selectedDate) {
                        p2pRevenue = p2pData.p2pRevenue
                        p2pSpotEquivalent = p2pData.spotEquivalent
                        p2pSellRevenue = p2pData.sellRevenue
                        p2pSellKwh = p2pData.sellKwh
                        p2pSellSpotEquivalent = p2pData.sellSpotEquivalent
                        p2pBuyCost = p2pData.buyCost
                        p2pBuyKwh = p2pData.buyKwh
                        p2pBuySpotEquivalent = p2pData.buySpotEquivalent
                        p2pNTB = p2pData.ntb
                    }
                }
                if PowstonDataStore.shared.getLVCashflowSummary(siteId: siteId, date: selectedDate) != nil {
                    // Always recompute from accumulated intervals (stored lv_daily_cashflow
                    // may be stale — only reflects last Identity batch, not full accumulation)
                    let intFormatter = DateFormatter()
                    intFormatter.dateFormat = "yyyy-MM-dd"
                    intFormatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
                    let intDateStr = intFormatter.string(from: selectedDate)
                    let allIntervals = PowstonDataStore.shared.getSettlementIntervals(siteId: siteId, date: intDateStr)

                    if !allIntervals.isEmpty {
                        let allCashflow = allIntervals.cashflowSummary()
                        dayFinancialSummary = cashflowToFinancialSummary(allCashflow)
                        dayEmissionsKgCO2e = allCashflow.emissions > 0 ? allCashflow.emissions : nil
                        dataSourceLabel = "LV Settlement"
                    } else {
                        dataSourceLabel = "LV Settlement"
                    }
                } else {
                    // Fallback: adjust Powston API data with P2P premium imputation
                    let p2pSellPremium = p2pSellRevenue - p2pSellSpotEquivalent
                    let p2pBuySavings = p2pBuySpotEquivalent - p2pBuyCost
                    let p2pAdj = p2pSellPremium + p2pBuySavings
                    if abs(p2pAdj) > 0.001 {
                        let newSold = ((fin.sold + p2pSellPremium) * 100).rounded() / 100
                        let newBought = ((fin.bought - p2pBuySavings) * 100).rounded() / 100
                        let newNet = ((fin.net + p2pAdj) * 100).rounded() / 100
                        dayFinancialSummary = (
                            sold: newSold,
                            bought: newBought,
                            supply: newSold - newBought - newNet,
                            net: newNet,
                            importKwh: fin.importKwh,
                            exportKwh: fin.exportKwh
                        )
                    }
                    dataSourceLabel = "Powston estimate"
                }

                // Load P2P counterparties for disclosure (from both CSV imports and LV API)
                dayP2PCounterparties = PowstonDataStore.shared.getP2PCounterpartyTrades(
                    siteId: siteId,
                    from: dayStart,
                    to: dayEnd
                )

                // Check if any CSV import spans multiple days (for date range display)
                p2pImportDateRange = nil
                let p2pRecords = PowstonDataStore.shared.getP2PTradeRecords(siteId: siteId, from: dayStart, to: dayStart)
                for record in p2pRecords {
                    if record.dayCount > 1 && p2pImportDateRange == nil {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "MMM d"
                        formatter.timeZone = powstonTimezone()
                        p2pImportDateRange = "\(formatter.string(from: record.startDate))-\(formatter.string(from: record.endDate))"
                    }
                }

                let calculator = SavingsAnalysisCalculator()
                savingsAnalysis = calculator.calculateForPeriod(
                                        records: fetchedRecords,
                                        pricesByInterval: pricesByInterval,
                                        batteryCapacityKwh: batteryCapacity,
                                        supplyCost: supplyCost,
                                        totalImportKwh: fin.importKwh,
                                        totalExportKwh: fin.exportKwh,
                                        actualNetFromAPI: actualNet,
                                        flatBuyRate: UserDefaults.standard.double(forKey: "comparison_buy_rate").nonZero ?? 33.0,
                                        flatSellRate: UserDefaults.standard.double(forKey: "comparison_sell_rate").nonZero ?? 5.0,
                                        inverterLimitKw: Double(site.inverterPower ?? 10000) / 1000.0,
                                        p2pRevenue: p2pRevenue,
                                        p2pSpotEquivalent: p2pSpotEquivalent,
                                        p2pSellRevenue: p2pSellRevenue,
                                        p2pSellKwh: p2pSellKwh,
                                        p2pSellSpotEquivalent: p2pSellSpotEquivalent,
                                        p2pBuyCost: p2pBuyCost,
                                        p2pBuyKwh: p2pBuyKwh,
                                        p2pBuySpotEquivalent: p2pBuySpotEquivalent,
                                        p2pNTB: p2pNTB
                                    )

                // Override actualCost with LV settlement data if available
                // Prefer recomputed from intervals (stored cashflow may be stale)
                if let sa = savingsAnalysis {
                    let saFormatter = DateFormatter()
                    saFormatter.dateFormat = "yyyy-MM-dd"
                    saFormatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
                    let saDateStr = saFormatter.string(from: selectedDate)
                    let saIntervals = PowstonDataStore.shared.getSettlementIntervals(siteId: siteId, date: saDateStr)
                    if !saIntervals.isEmpty {
                        savingsAnalysis = sa.withActualCost(saIntervals.cashflowSummary().netCosts)
                    } else if let lvCashflow = PowstonDataStore.shared.getLVCashflowSummary(siteId: siteId, date: selectedDate) {
                        savingsAnalysis = sa.withActualCost(lvCashflow.netCosts)
                    }
                }
            }

            // LV-only fallback: Powston API had no data for this date, use LV settlement
            if dayFinancialSummary == nil, let siteId = api.selectedSite?.id,
               let site = api.selectedSite,
               LocalVoltsService.shared.hasCredentials {
                // Fetch on demand if not already persisted, or if recent (may be incomplete)
                let fallbackRecentCutoff = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: Date())) ?? Date()
                let fallbackIsRecent = dayStart >= fallbackRecentCutoff
                if fallbackIsRecent || PowstonDataStore.shared.getLVCashflowSummary(siteId: siteId, date: selectedDate) == nil {
                    _ = await LocalVoltsService.shared.fetchSettlementOnDemand(
                        siteId: siteId, from: dayStart, to: dayEnd)
                }
                if PowstonDataStore.shared.getLVCashflowSummary(siteId: siteId, date: selectedDate) != nil {
                    // Always recompute from accumulated intervals — stored lv_daily_cashflow
                    // may be stale (only reflects last Identity batch, not full accumulation)
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
                    let dateStr = formatter.string(from: selectedDate)
                    let intervals = PowstonDataStore.shared.getSettlementIntervals(siteId: siteId, date: dateStr)

                    if !intervals.isEmpty {
                        let allCashflow = intervals.cashflowSummary()
                        dayFinancialSummary = cashflowToFinancialSummary(allCashflow)
                        dayEmissionsKgCO2e = allCashflow.emissions > 0 ? allCashflow.emissions : nil
                        dataSourceLabel = "LV Settlement"

                        // Build savings analysis from intervals + recomputed cashflow
                        let batteryCapacity = Double(site.installedBattery ?? 0) / 1000.0
                        let calculator = SavingsAnalysisCalculator()
                        savingsAnalysis = calculator.calculateFromLVSettlement(
                            intervals: intervals,
                            cashflow: allCashflow,
                            batteryCapacityKwh: batteryCapacity,
                            flatBuyRate: UserDefaults.standard.double(forKey: "comparison_buy_rate").nonZero ?? 33.0,
                            flatSellRate: UserDefaults.standard.double(forKey: "comparison_sell_rate").nonZero ?? 5.0,
                            inverterLimitKw: Double(site.inverterPower ?? 10000) / 1000.0
                        )
                    }

                    // Load P2P counterparties for disclosure
                    dayP2PCounterparties = PowstonDataStore.shared.getP2PCounterpartyTrades(
                        siteId: siteId,
                        from: dayStart,
                        to: dayEnd
                    )
                }
            }

        case .week:
            guard !Task.isCancelled else { isLoading = false; return }
            
            isLoading = false; isLoadingSummary = true
            
            // Fetch bulk summary for accurate totals
            if let weekSummary = await api.fetchWeekSummary(containing: selectedDate) {
                guard !Task.isCancelled else { isLoadingSummary = false; return }
                cachedTotalEarnings = weekSummary.earningsDollars
                cachedTotalCosts = weekSummary.rateCostsDollars
                cachedTotalImport = weekSummary.totalEnergyImported
                cachedTotalExport = weekSummary.totalEnergyExported
                cachedActualNetProfit = weekSummary.netProfitDollars
                cachedSupplyCosts = weekSummary.earningsDollars - weekSummary.rateCostsDollars - weekSummary.netProfitDollars
            }
            
            guard !Task.isCancelled else { isLoadingSummary = false; return }
            
            // Fetch tariff rates for the Tariff Periods section
            let today = Date()
            let tariffEndDate: Date
            if weekEnd < calendar.startOfDay(for: today) {
                tariffEndDate = weekEnd
            } else {
                let maxDate = api.latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: today)!
                tariffEndDate = min(weekEnd, maxDate)
            }
            
            if tariffEndDate >= weekStart {
                let tariffEndParam = calendar.date(byAdding: .day, value: 1, to: tariffEndDate) ?? tariffEndDate
                if let rates = await api.fetchTariffRates(startDate: weekStart, endDate: tariffEndParam) {
                    tariffPeriods = rates.data
                    tariffDefinitions = rates.periodDefinitions
                }
            }
            
            guard !Task.isCancelled else { isLoadingSummary = false; return }
            
            // Load rolling average for heatmap
            await loadRollingAverage()
            
            guard !Task.isCancelled else { isLoadingSummary = false; return }
            
            // Fetch meter_records for savings analysis AND daily summaries
            savingsAnalysis = nil
            cachedDailySummaries = []
            dayP2PCounterparties = []
            p2pImportDateRange = nil

            if let site = api.selectedSite {
                let weekEndPlusOne = calendar.date(byAdding: .day, value: 1, to: weekEnd) ?? weekEnd
                let weekRecords = await api.fetchMeterRecords(fromDate: weekStart, toDate: weekEndPlusOne, forceRefresh: forceRefresh)
                
                guard !Task.isCancelled else { isLoadingSummary = false; return }
                
                if !weekRecords.isEmpty {
                    // Build daily summaries from meter records (same source as savings analysis)
                    cachedDailySummaries = buildDailySummaries(from: weekRecords)
                    
                    let batteryCapacity = Double(site.installedBattery ?? 0) / 1000.0
                    let supplyCost = cachedSupplyCosts
                    let actualNet = cachedActualNetProfit
                    let siteId = site.id
                    
                    // Build price lookup from actions for accurate TOU-based hypotheticals
                    let pricesByInterval = buildPricesByInterval(siteId: siteId, from: weekStart, to: weekEndPlusOne)
                    
                    // Get P2P data (NOT included in Powston API earnings — added by calculator and summary cards)
                    var p2pRevenue: Double = 0
                    var p2pSpotEquivalent: Double = 0
                    var p2pSellRevenue: Double = 0
                    var p2pSellKwh: Double = 0
                    var p2pSellSpotEquivalent: Double = 0
                    var p2pBuyCost: Double = 0
                    var p2pBuyKwh: Double = 0
                    var p2pBuySpotEquivalent: Double = 0
                    var p2pNTB: Double = 0

                    let weekEndInclusive = calendar.date(byAdding: .day, value: 1, to: weekEnd)?.addingTimeInterval(-1) ?? weekEnd
                    let lvCutoff = api.latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: Date()))!
                    if let p2pData = PowstonDataStore.shared.calculateP2PPremiumForRangeDetailed(
                        siteId: siteId, from: weekStart, to: weekEndInclusive, settlementCutoff: lvCutoff) {
                        p2pRevenue = p2pData.p2pRevenue
                        p2pSpotEquivalent = p2pData.spotEquivalent
                        p2pSellRevenue = p2pData.sellRevenue
                        p2pSellKwh = p2pData.sellKwh
                        p2pSellSpotEquivalent = p2pData.sellSpotEquivalent
                        p2pBuyCost = p2pData.buyCost
                        p2pBuyKwh = p2pData.buyKwh
                        p2pBuySpotEquivalent = p2pData.buySpotEquivalent
                        p2pNTB = p2pData.ntb
                    }

                    // Use LV settlement data through the latest finalized day (lvCutoff defined above)
                    let lvEndDate = min(weekEnd, calendar.startOfDay(for: lvCutoff))
                    let hasLVData = await populateCardsFromLVCashflow(siteId: siteId, from: weekStart, to: lvEndDate, fetchOnDemand: true)
                    dataSourceLabel = hasLVData ? "LV Settlement" : "Powston estimate"
                    if !hasLVData {
                        // Fallback: adjust Powston API data with P2P premium imputation
                        let p2pSellPremium = p2pSellRevenue - p2pSellSpotEquivalent
                        let p2pBuySavings = p2pBuySpotEquivalent - p2pBuyCost
                        let p2pAdj = p2pSellPremium + p2pBuySavings
                        if abs(p2pAdj) > 0.001 {
                            cachedTotalEarnings = ((cachedTotalEarnings + p2pSellPremium) * 100).rounded() / 100
                            cachedTotalCosts = ((cachedTotalCosts - p2pBuySavings) * 100).rounded() / 100
                            cachedActualNetProfit = ((cachedActualNetProfit + p2pAdj) * 100).rounded() / 100
                            cachedSupplyCosts = cachedTotalEarnings - cachedTotalCosts - cachedActualNetProfit
                        }
                    }

                    // Adjust daily summaries with per-day P2P premium for charts
                    cachedDailySummaries = adjustDailySummariesForP2P(cachedDailySummaries, siteId: siteId)

                    // Load P2P counterparties for disclosure (aggregated across the week)
                    dayP2PCounterparties = PowstonDataStore.shared.getP2PCounterpartyTrades(
                        siteId: siteId,
                        from: weekStart,
                        to: weekEndInclusive
                    )
                    p2pImportDateRange = nil  // Not relevant for week view

                    let calculator = SavingsAnalysisCalculator()
                    savingsAnalysis = calculator.calculateForPeriod(
                                            records: weekRecords,
                                            pricesByInterval: pricesByInterval,
                                            batteryCapacityKwh: batteryCapacity,
                                            supplyCost: supplyCost,
                                            totalImportKwh: cachedTotalImport,
                                            totalExportKwh: cachedTotalExport,
                                            actualNetFromAPI: actualNet,
                                            inverterLimitKw: Double(site.inverterPower ?? 10000) / 1000.0,
                                            p2pRevenue: p2pRevenue,
                                            p2pSpotEquivalent: p2pSpotEquivalent,
                                            p2pSellRevenue: p2pSellRevenue,
                                            p2pSellKwh: p2pSellKwh,
                                            p2pSellSpotEquivalent: p2pSellSpotEquivalent,
                                            p2pBuyCost: p2pBuyCost,
                                            p2pBuyKwh: p2pBuyKwh,
                                            p2pBuySpotEquivalent: p2pBuySpotEquivalent,
                                            p2pNTB: p2pNTB
                                        )
                } else if LocalVoltsService.shared.hasCredentials {
                    // LV-only fallback: no meter records, use LV settlement + trade data
                    let siteId = site.id
                    let hasLVData = await populateCardsFromLVCashflow(siteId: siteId, from: weekStart, to: weekEnd, fetchOnDemand: true, requireComplete: false)
                    if hasLVData {
                        dataSourceLabel = "LV Settlement"
                    }

                    // Load P2P counterparties even without meter records
                    dayP2PCounterparties = PowstonDataStore.shared.getP2PCounterpartyTrades(
                        siteId: siteId,
                        from: weekStart,
                        to: weekEnd
                    )
                    p2pImportDateRange = nil
                }
            }

            guard !Task.isCancelled else { isLoadingSummary = false; return }

            // Fallback to API if no meter records available
            if cachedDailySummaries.isEmpty {
                cachedDailySummaries = await api.fetchWeekDailyBreakdownCumulative(containing: selectedDate)
            }

            // Fill gaps with LV settlement data for dates missing from Powston
            if let siteId = api.selectedSite?.id {
                let effectiveEnd = min(weekEnd, calendar.startOfDay(for: latestNavigableDate))
                cachedDailySummaries = fillGapsWithLVSettlement(cachedDailySummaries, siteId: siteId, from: weekStart, to: effectiveEnd)
            }

            // Exclude days past the latest finalized date
            let weekCutoff = calendar.startOfDay(for: latestNavigableDate)
            cachedDailySummaries = cachedDailySummaries.filter { calendar.startOfDay(for: $0.date) <= weekCutoff }

            isLoadingSummary = false; records = []
            return

        case .month:
            guard !Task.isCancelled else { isLoading = false; return }
            
            isLoading = false; isLoadingSummary = true
            let year = calendar.component(.year, from: selectedDate)
            let month = calendar.component(.month, from: selectedDate)
            
            // Fetch bulk summary for accurate totals
            if let monthSummary = await api.fetchMonthSummary(year: year, month: month) {
                guard !Task.isCancelled else { isLoadingSummary = false; return }
                cachedTotalEarnings = monthSummary.earningsDollars
                cachedTotalCosts = monthSummary.rateCostsDollars
                cachedTotalImport = monthSummary.totalEnergyImported
                cachedTotalExport = monthSummary.totalEnergyExported
                cachedActualNetProfit = monthSummary.netProfitDollars
                cachedSupplyCosts = monthSummary.earningsDollars - monthSummary.rateCostsDollars - monthSummary.netProfitDollars
            }
            
            guard !Task.isCancelled else { isLoadingSummary = false; return }
            
            // Load rolling average for heatmap
            await loadRollingAverage()
            
            guard !Task.isCancelled else { isLoadingSummary = false; return }
            
            // Fetch meter_records for savings analysis AND daily summaries
            savingsAnalysis = nil
            cachedDailySummaries = []
            dayP2PCounterparties = []
            p2pImportDateRange = nil

            if let site = api.selectedSite {
                let monthEndPlusOne = calendar.date(byAdding: .day, value: 1, to: monthEnd) ?? monthEnd
                let monthRecords = await api.fetchMonthRecords(monthStart: monthStart, monthEnd: monthEnd, forceRefresh: forceRefresh)
                
                guard !Task.isCancelled else { isLoadingSummary = false; return }
                
                if !monthRecords.isEmpty {
                    // Build daily summaries from meter records (same source as savings analysis)
                    cachedDailySummaries = buildDailySummaries(from: monthRecords)
                    
                    let batteryCapacity = Double(site.installedBattery ?? 0) / 1000.0
                    let supplyCost = cachedSupplyCosts
                    let actualNet = cachedActualNetProfit
                    let siteId = site.id
                    
                    // Build price lookup from actions for accurate TOU-based hypotheticals
                    let pricesByInterval = buildPricesByInterval(siteId: siteId, from: monthStart, to: monthEndPlusOne)

                    // Get P2P data (NOT included in Powston API earnings — added by calculator and summary cards)
                    var p2pRevenue: Double = 0
                    var p2pSpotEquivalent: Double = 0
                    var p2pSellRevenue: Double = 0
                    var p2pSellKwh: Double = 0
                    var p2pSellSpotEquivalent: Double = 0
                    var p2pBuyCost: Double = 0
                    var p2pBuyKwh: Double = 0
                    var p2pBuySpotEquivalent: Double = 0
                    var p2pNTB: Double = 0

                    let monthEndInclusive = calendar.date(byAdding: .day, value: 1, to: monthEnd)?.addingTimeInterval(-1) ?? monthEnd
                    let lvCutoff = api.latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: Date()))!
                    if let p2pData = PowstonDataStore.shared.calculateP2PPremiumForRangeDetailed(
                        siteId: siteId, from: monthStart, to: monthEndInclusive, settlementCutoff: lvCutoff) {
                        p2pRevenue = p2pData.p2pRevenue
                        p2pSpotEquivalent = p2pData.spotEquivalent
                        p2pSellRevenue = p2pData.sellRevenue
                        p2pSellKwh = p2pData.sellKwh
                        p2pSellSpotEquivalent = p2pData.sellSpotEquivalent
                        p2pBuyCost = p2pData.buyCost
                        p2pBuyKwh = p2pData.buyKwh
                        p2pBuySpotEquivalent = p2pData.buySpotEquivalent
                        p2pNTB = p2pData.ntb
                    }

                    // Use LV settlement data through the latest finalized day (lvCutoff defined above)
                    let lvEndDate = min(monthEnd, calendar.startOfDay(for: lvCutoff))
                    let hasLVData = await populateCardsFromLVCashflow(siteId: siteId, from: monthStart, to: lvEndDate, fetchOnDemand: true)
                    dataSourceLabel = hasLVData ? "LV Settlement" : "Powston estimate"
                    if !hasLVData {
                        // Fallback: adjust Powston API data with P2P premium imputation
                        let p2pSellPremium = p2pSellRevenue - p2pSellSpotEquivalent
                        let p2pBuySavings = p2pBuySpotEquivalent - p2pBuyCost
                        let p2pAdj = p2pSellPremium + p2pBuySavings
                        if abs(p2pAdj) > 0.001 {
                            cachedTotalEarnings = ((cachedTotalEarnings + p2pSellPremium) * 100).rounded() / 100
                            cachedTotalCosts = ((cachedTotalCosts - p2pBuySavings) * 100).rounded() / 100
                            cachedActualNetProfit = ((cachedActualNetProfit + p2pAdj) * 100).rounded() / 100
                            cachedSupplyCosts = cachedTotalEarnings - cachedTotalCosts - cachedActualNetProfit
                        }
                    }

                    // Always filter records to finalized dates to exclude incomplete days
                    // (today, yesterday) — independent of LV data availability
                    let cutoffDate = calendar.date(byAdding: .day, value: 1, to: lvEndDate) ?? lvEndDate
                    let effectiveRecords = monthRecords.filter { record in
                        guard let recordDate = record.date else { return false }
                        return recordDate < cutoffDate
                    }
                    if effectiveRecords.count < monthRecords.count {
                        cachedDailySummaries = buildDailySummaries(from: effectiveRecords)
                    }

                    // Adjust daily summaries with per-day P2P premium for charts
                    cachedDailySummaries = adjustDailySummariesForP2P(cachedDailySummaries, siteId: siteId)

                    // Load P2P counterparties for disclosure (aggregated across the month)
                    dayP2PCounterparties = PowstonDataStore.shared.getP2PCounterpartyTrades(
                        siteId: siteId,
                        from: monthStart,
                        to: monthEndInclusive
                    )
                    p2pImportDateRange = nil  // Not relevant for month view

                    let calculator = SavingsAnalysisCalculator()
                    var sa = calculator.calculateForPeriod(
                                            records: effectiveRecords,
                                            pricesByInterval: pricesByInterval,
                                            batteryCapacityKwh: batteryCapacity,
                                            supplyCost: hasLVData ? cachedSupplyCosts : supplyCost,
                                            totalImportKwh: cachedTotalImport,
                                            totalExportKwh: cachedTotalExport,
                                            actualNetFromAPI: actualNet,
                                            inverterLimitKw: Double(site.inverterPower ?? 10000) / 1000.0,
                                            p2pRevenue: p2pRevenue,
                                            p2pSpotEquivalent: p2pSpotEquivalent,
                                            p2pSellRevenue: p2pSellRevenue,
                                            p2pSellKwh: p2pSellKwh,
                                            p2pSellSpotEquivalent: p2pSellSpotEquivalent,
                                            p2pBuyCost: p2pBuyCost,
                                            p2pBuyKwh: p2pBuyKwh,
                                            p2pBuySpotEquivalent: p2pBuySpotEquivalent,
                                            p2pNTB: p2pNTB
                                        )
                    // Override actual cost with LV settlement data when available
                    if hasLVData, let saUnwrapped = sa {
                        let lvForOverride = PowstonDataStore.shared.getLVCashflowSummaries(siteId: siteId, from: monthStart, to: lvEndDate)
                        if !lvForOverride.isEmpty {
                            let lvAgg = lvForOverride.aggregated()
                            sa = saUnwrapped.withActualCost(lvAgg.netCosts)
                        }
                    }
                    savingsAnalysis = sa
                }
            }

            guard !Task.isCancelled else { isLoadingSummary = false; return }

            // Fallback to API if no meter records available
            if cachedDailySummaries.isEmpty {
                cachedDailySummaries = await api.fetchMonthDailyBreakdownCumulative(year: year, month: month)
            }

            // LV settlement fallback: if still no data, try LV cashflow for this month
            if cachedDailySummaries.isEmpty,
               let siteId = api.selectedSite?.id,
               LocalVoltsService.shared.hasCredentials {

                // Check if we have LV data cached for this month
                let lvSummaries = PowstonDataStore.shared.getLVCashflowSummaries(
                    siteId: siteId, from: monthStart, to: monthEnd)

                if lvSummaries.isEmpty {
                    // Fetch on demand from LV WebSocket
                    let fetched = await LocalVoltsService.shared.fetchSettlementOnDemand(
                        siteId: siteId, from: monthStart, to: monthEnd)
                    if fetched > 0 {
                        // Re-query after fetch
                        let freshLV = PowstonDataStore.shared.getLVCashflowSummaries(
                            siteId: siteId, from: monthStart, to: monthEnd)
                        cachedDailySummaries = freshLV.compactMap { $0.toDailySummary() }
                    }
                } else {
                    cachedDailySummaries = lvSummaries.compactMap { $0.toDailySummary() }
                }

                // Populate summary cards from LV data if Powston API had nothing
                if !cachedDailySummaries.isEmpty && cachedTotalEarnings == 0 && cachedTotalCosts == 0 {
                    _ = await populateCardsFromLVCashflow(siteId: siteId, from: monthStart, to: monthEnd, requireComplete: false)
                    dataSourceLabel = "LV Settlement"
                }
            }

            // Fill gaps with LV settlement data for dates missing from Powston
            if let siteId = api.selectedSite?.id {
                let effectiveEnd = min(monthEnd, calendar.startOfDay(for: latestNavigableDate))
                cachedDailySummaries = fillGapsWithLVSettlement(cachedDailySummaries, siteId: siteId, from: monthStart, to: effectiveEnd)
            }

            // Exclude days past the latest finalized date
            let monthCutoff = calendar.startOfDay(for: latestNavigableDate)
            cachedDailySummaries = cachedDailySummaries.filter { calendar.startOfDay(for: $0.date) <= monthCutoff }

            isLoadingSummary = false; records = []
            return

        case .year:
            guard !Task.isCancelled else { isLoading = false; return }
            
            isLoading = false; isLoadingSummary = true
            let year = calendar.component(.year, from: selectedDate)
            
            // Fetch bulk summary for accurate totals (also used for YearInsightsCard)
            daySummary = await api.fetchYearSummary(year: year)
            
            guard !Task.isCancelled else { isLoadingSummary = false; return }
            
            if let yearSummary = daySummary {
                cachedTotalEarnings = yearSummary.earningsDollars
                cachedTotalCosts = yearSummary.rateCostsDollars  // Use rate costs to match web
                cachedTotalImport = yearSummary.totalEnergyImported
                cachedTotalExport = yearSummary.totalEnergyExported
                cachedActualNetProfit = yearSummary.netProfitDollars
                // Derive Supply to always reconcile: Sold - Bought - Net = Supply
                cachedSupplyCosts = yearSummary.earningsDollars - yearSummary.rateCostsDollars - yearSummary.netProfitDollars
            }
            
            guard !Task.isCancelled else { isLoadingSummary = false; return }
            
            // Fetch monthly breakdown for charts (use full costs so totals tie)
            let monthlyData = await api.fetchYearMonthlyBreakdown(year: year)
            
            guard !Task.isCancelled else { isLoadingSummary = false; return }
            
            // Use endTime to determine month - startTime may be end of previous month
            // endTime format: "2024-06-30 23:59:59" or similar
            cachedDailySummaries = monthlyData.compactMap { s in
                            // Parse "YYYY-MM-DD" from endTime string
                            let parts = s.endTime.prefix(10).split(separator: "-")
                            guard parts.count >= 2, let monthNum = Int(parts[1]) else { return nil as DailySummary? }
                            guard let date = calendar.date(from: DateComponents(year: year, month: monthNum, day: 1)) else { return nil as DailySummary? }

                            return DailySummary(
                                date: date,
                                totalImport: s.totalEnergyImported, totalExport: s.totalEnergyExported,
                                totalEarnings: s.earningsDollars, totalCosts: s.costsDollars, avgSoc: 0, recordCount: s.recordCount,
                                netProfit: s.netProfitDollars  // Use authoritative value from expectedBill
                            )
                        }

            // Replace Powston data with LV settlement data where available (LV is authoritative)
            var lvMonthsUsed = Set<Int>()
            if let siteId = api.selectedSite?.id,
               LocalVoltsService.shared.hasCredentials {

                // Get LV monthly summaries already persisted locally
                let lvMonthlySummaries = PowstonDataStore.shared.getLVMonthlySummaries(siteId: siteId, year: year)
                let lvMonthEntries = lvMonthlySummaries.isEmpty ? [] : LVCashflowSummary.monthlyAggregates(from: lvMonthlySummaries, year: year)
                let lvByMonth = Dictionary(uniqueKeysWithValues: lvMonthEntries.map { (calendar.component(.month, from: $0.date), $0) })

                // Replace Powston months with LV data where available
                for i in cachedDailySummaries.indices {
                    let m = calendar.component(.month, from: cachedDailySummaries[i].date)
                    if let lvEntry = lvByMonth[m] {
                        cachedDailySummaries[i] = lvEntry
                        lvMonthsUsed.insert(m)
                    }
                }
                // Add LV months that Powston didn't have at all
                let existingMonths = Set(cachedDailySummaries.map { calendar.component(.month, from: $0.date) })
                for (m, entry) in lvByMonth where !existingMonths.contains(m) {
                    cachedDailySummaries.append(entry)
                    lvMonthsUsed.insert(m)
                }
                cachedDailySummaries.sort { $0.date < $1.date }

                guard !Task.isCancelled else { isLoadingSummary = false; return }

                // Determine which months still need LV data — fetch on demand
                let currentMonth = calendar.component(.month, from: Date())
                let maxMonth = isCurrentYear ? currentMonth : 12
                let earliestLVKey = "lv_earliest_settlement_date_\(siteId)"
                let earliestLVDateStr = UserDefaults.standard.string(forKey: earliestLVKey)
                let earliestLVMonth: Int
                if let dateStr = earliestLVDateStr,
                   let earliestYear = Int(dateStr.prefix(4)),
                   let earliestMo = Int(dateStr.dropFirst(5).prefix(2)) {
                    if earliestYear > year {
                        earliestLVMonth = 13
                    } else if earliestYear == year {
                        earliestLVMonth = earliestMo
                    } else {
                        earliestLVMonth = 1
                    }
                } else {
                    earliestLVMonth = 1
                }

                let monthsNeedingLV = earliestLVMonth <= maxMonth
                    ? (earliestLVMonth...maxMonth).filter { !lvMonthsUsed.contains($0) }
                    : []

                if !monthsNeedingLV.isEmpty, let firstMissing = monthsNeedingLV.first, let lastMissing = monthsNeedingLV.last {
                    dataSourceLabel = "Downloading LV data\u{2026}"
                    isLoadingSummary = false  // Show Powston data while downloading

                    let fetchFrom = calendar.date(from: DateComponents(year: year, month: firstMissing, day: 1)) ?? yearStart
                    let fetchToMonth = calendar.date(from: DateComponents(year: year, month: lastMissing, day: 1)) ?? yearStart
                    let fetchTo = calendar.date(byAdding: .month, value: 1, to: fetchToMonth) ?? fetchToMonth

                    let fetched = await LocalVoltsService.shared.fetchSettlementOnDemand(
                        siteId: siteId, from: fetchFrom, to: fetchTo)

                    isLoadingSummary = true  // Resume loading state for final update

                    if let earliest = PowstonDataStore.shared.getEarliestSettlementDate(siteId: siteId) {
                        UserDefaults.standard.set(earliest, forKey: earliestLVKey)
                    } else if fetched == 0 && earliestLVDateStr == nil {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd"
                        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
                        UserDefaults.standard.set(formatter.string(from: Date()), forKey: earliestLVKey)
                    }

                    if fetched > 0 {
                        // Reload and replace with fresh LV data
                        let freshLV = PowstonDataStore.shared.getLVMonthlySummaries(siteId: siteId, year: year)
                        let freshEntries = LVCashflowSummary.monthlyAggregates(from: freshLV, year: year)
                        let freshByMonth = Dictionary(uniqueKeysWithValues: freshEntries.map { (calendar.component(.month, from: $0.date), $0) })

                        for i in cachedDailySummaries.indices {
                            let m = calendar.component(.month, from: cachedDailySummaries[i].date)
                            if let lvEntry = freshByMonth[m], !lvMonthsUsed.contains(m) {
                                cachedDailySummaries[i] = lvEntry
                                lvMonthsUsed.insert(m)
                            }
                        }
                        let freshExisting = Set(cachedDailySummaries.map { calendar.component(.month, from: $0.date) })
                        for (m, entry) in freshByMonth where !freshExisting.contains(m) {
                            cachedDailySummaries.append(entry)
                            lvMonthsUsed.insert(m)
                        }
                        cachedDailySummaries.sort { $0.date < $1.date }
                    }
                }

                // Recompute summary card totals from final monthly data
                cachedTotalEarnings = cachedDailySummaries.reduce(0.0) { $0 + (($1.totalEarnings * 100).rounded() / 100) }
                cachedTotalCosts = cachedDailySummaries.reduce(0.0) { $0 + (($1.totalCosts * 100).rounded() / 100) }
                cachedActualNetProfit = cachedDailySummaries.reduce(0.0) { $0 + (($1.netProfit * 100).rounded() / 100) }
                cachedTotalImport = cachedDailySummaries.reduce(0.0) { $0 + $1.totalImport }
                cachedTotalExport = cachedDailySummaries.reduce(0.0) { $0 + $1.totalExport }
                cachedSupplyCosts = cachedTotalEarnings - cachedTotalCosts - cachedActualNetProfit
            }

            guard !Task.isCancelled else { isLoadingSummary = false; return }

            // Load P2P data and adjust only months still using Powston API data
            yearP2PData = nil
            if let siteId = api.selectedSite?.id {
                let yearEndDate: Date
                if isCurrentYear {
                    yearEndDate = Date()
                } else {
                    yearEndDate = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? Date()
                }
                // Only apply P2P adjustment if some months still use Powston data
                let powstonOnlyMonths = cachedDailySummaries.compactMap { s -> Int? in
                    let m = calendar.component(.month, from: s.date)
                    return lvMonthsUsed.contains(m) ? nil : m
                }
                if !powstonOnlyMonths.isEmpty {
                    let lvCutoff = api.latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: Date()))!
                    yearP2PData = PowstonDataStore.shared.calculateP2PPremiumForRangeDetailed(
                        siteId: siteId, from: yearStart, to: yearEndDate, settlementCutoff: lvCutoff)
                    if let p2p = yearP2PData {
                        let p2pSellPremium = p2p.sellRevenue - p2p.sellSpotEquivalent
                        let p2pBuySavings = p2p.buySpotEquivalent - p2p.buyCost
                        let p2pAdj = p2pSellPremium + p2pBuySavings
                        if abs(p2pAdj) > 0.001 {
                            cachedTotalEarnings = ((cachedTotalEarnings + p2pSellPremium) * 100).rounded() / 100
                            cachedTotalCosts = ((cachedTotalCosts - p2pBuySavings) * 100).rounded() / 100
                            cachedActualNetProfit = ((cachedActualNetProfit + p2pAdj) * 100).rounded() / 100
                            cachedSupplyCosts = cachedTotalEarnings - cachedTotalCosts - cachedActualNetProfit
                        }
                    }
                }
            }

            // Set data source label based on coverage
            let allMonthsLV = cachedDailySummaries.allSatisfy { lvMonthsUsed.contains(calendar.component(.month, from: $0.date)) }
            if allMonthsLV && !cachedDailySummaries.isEmpty {
                dataSourceLabel = "LV Settlement"
            } else if !lvMonthsUsed.isEmpty {
                dataSourceLabel = "Powston + LV Settlement"
            } else {
                dataSourceLabel = "Powston estimate"
            }
            isLoadingSummary = false; records = []
            return

        case .custom:
            guard !Task.isCancelled else { isLoading = false; return }
            
            isLoading = false; isLoadingSummary = true
            
            // Fetch bulk summary for accurate totals
            if let customSummary = await api.fetchCustomRangeSummary(startDate: customStartDate, endDate: customEndDate) {
                guard !Task.isCancelled else { isLoadingSummary = false; return }
                cachedTotalEarnings = customSummary.earningsDollars
                cachedTotalCosts = customSummary.rateCostsDollars
                cachedTotalImport = customSummary.totalEnergyImported
                cachedTotalExport = customSummary.totalEnergyExported
                cachedActualNetProfit = customSummary.netProfitDollars
                cachedSupplyCosts = customSummary.earningsDollars - customSummary.rateCostsDollars - customSummary.netProfitDollars
            }
            
            guard !Task.isCancelled else { isLoadingSummary = false; return }
            
            // Fetch tariff rates for the Tariff Periods section
            let today = Date()
            let tariffEndDate: Date
            if customEndDate < calendar.startOfDay(for: today) {
                tariffEndDate = customEndDate
            } else {
                let maxDate = api.latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: today)!
                tariffEndDate = min(customEndDate, maxDate)
            }
            
            if tariffEndDate >= customStartDate {
                let tariffEndParam = calendar.date(byAdding: .day, value: 1, to: tariffEndDate) ?? tariffEndDate
                if let rates = await api.fetchTariffRates(startDate: customStartDate, endDate: tariffEndParam) {
                    tariffPeriods = rates.data
                    tariffDefinitions = rates.periodDefinitions
                }
            }
            
            guard !Task.isCancelled else { isLoadingSummary = false; return }
            
            // Load rolling average for heatmap
            await loadRollingAverage()
            
            guard !Task.isCancelled else { isLoadingSummary = false; return }
            
            // Fetch meter_records for savings analysis AND daily summaries
            savingsAnalysis = nil
            cachedDailySummaries = []
            dayP2PCounterparties = []
            p2pImportDateRange = nil

            if let site = api.selectedSite {
                let customEndPlusOne = calendar.date(byAdding: .day, value: 1, to: customEndDate) ?? customEndDate
                let customRecords = await api.fetchMeterRecords(fromDate: customStartDate, toDate: customEndPlusOne, forceRefresh: forceRefresh)
                
                guard !Task.isCancelled else { isLoadingSummary = false; return }
                
                if !customRecords.isEmpty {
                    // Build daily summaries from meter records (same source as savings analysis)
                    cachedDailySummaries = buildDailySummaries(from: customRecords)
                    
                    let batteryCapacity = Double(site.installedBattery ?? 0) / 1000.0
                    let supplyCost = cachedSupplyCosts
                    let actualNet = cachedActualNetProfit
                    let siteId = site.id
                    
                    // Build price lookup from actions for accurate TOU-based hypotheticals
                    let pricesByInterval = buildPricesByInterval(siteId: siteId, from: customStartDate, to: customEndPlusOne)

                    // Get P2P data (NOT included in Powston API earnings — added by calculator and summary cards)
                    var p2pRevenue: Double = 0
                    var p2pSpotEquivalent: Double = 0
                    var p2pSellRevenue: Double = 0
                    var p2pSellKwh: Double = 0
                    var p2pSellSpotEquivalent: Double = 0
                    var p2pBuyCost: Double = 0
                    var p2pBuyKwh: Double = 0
                    var p2pBuySpotEquivalent: Double = 0
                    var p2pNTB: Double = 0

                    let lvCutoff = api.latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: Date()))!
                    if let p2pData = PowstonDataStore.shared.calculateP2PPremiumForRangeDetailed(
                        siteId: siteId, from: customStartDate, to: customEndDate, settlementCutoff: lvCutoff) {
                        p2pRevenue = p2pData.p2pRevenue
                        p2pSpotEquivalent = p2pData.spotEquivalent
                        p2pSellRevenue = p2pData.sellRevenue
                        p2pSellKwh = p2pData.sellKwh
                        p2pSellSpotEquivalent = p2pData.sellSpotEquivalent
                        p2pBuyCost = p2pData.buyCost
                        p2pBuyKwh = p2pData.buyKwh
                        p2pBuySpotEquivalent = p2pData.buySpotEquivalent
                        p2pNTB = p2pData.ntb
                    }

                    // Use LV settlement data through the latest finalized day (lvCutoff defined above)
                    let lvEndDate = min(customEndDate, calendar.startOfDay(for: lvCutoff))
                    let hasLVData = await populateCardsFromLVCashflow(siteId: siteId, from: customStartDate, to: lvEndDate)
                    dataSourceLabel = hasLVData ? "LV Settlement" : "Powston estimate"
                    if !hasLVData {
                        // Fallback: adjust Powston API data with P2P premium imputation
                        let p2pSellPremium = p2pSellRevenue - p2pSellSpotEquivalent
                        let p2pBuySavings = p2pBuySpotEquivalent - p2pBuyCost
                        let p2pAdj = p2pSellPremium + p2pBuySavings
                        if abs(p2pAdj) > 0.001 {
                            cachedTotalEarnings = ((cachedTotalEarnings + p2pSellPremium) * 100).rounded() / 100
                            cachedTotalCosts = ((cachedTotalCosts - p2pBuySavings) * 100).rounded() / 100
                            cachedActualNetProfit = ((cachedActualNetProfit + p2pAdj) * 100).rounded() / 100
                            cachedSupplyCosts = cachedTotalEarnings - cachedTotalCosts - cachedActualNetProfit
                        }
                    }

                    // Adjust daily summaries with per-day P2P premium for charts
                    cachedDailySummaries = adjustDailySummariesForP2P(cachedDailySummaries, siteId: siteId)

                    // Load P2P counterparties for disclosure (aggregated across the custom range)
                    dayP2PCounterparties = PowstonDataStore.shared.getP2PCounterpartyTrades(
                        siteId: siteId,
                        from: customStartDate,
                        to: customEndDate
                    )
                    p2pImportDateRange = nil  // Not relevant for custom view

                    let calculator = SavingsAnalysisCalculator()
                    savingsAnalysis = calculator.calculateForPeriod(
                                            records: customRecords,
                                            pricesByInterval: pricesByInterval,
                                            batteryCapacityKwh: batteryCapacity,
                                            supplyCost: supplyCost,
                                            totalImportKwh: cachedTotalImport,
                                            totalExportKwh: cachedTotalExport,
                                            actualNetFromAPI: actualNet,
                                            inverterLimitKw: Double(site.inverterPower ?? 10000) / 1000.0,
                                            p2pRevenue: p2pRevenue,
                                            p2pSpotEquivalent: p2pSpotEquivalent,
                                            p2pSellRevenue: p2pSellRevenue,
                                            p2pSellKwh: p2pSellKwh,
                                            p2pSellSpotEquivalent: p2pSellSpotEquivalent,
                                            p2pBuyCost: p2pBuyCost,
                                            p2pBuyKwh: p2pBuyKwh,
                                            p2pBuySpotEquivalent: p2pBuySpotEquivalent,
                                            p2pNTB: p2pNTB
                                        )
                }
            }

            guard !Task.isCancelled else { isLoadingSummary = false; return }

            // Fallback to API if no meter records available
            if cachedDailySummaries.isEmpty {
                cachedDailySummaries = await api.fetchDailyBreakdownCumulative(startDate: customStartDate, endDate: customEndDate)
            }

            // Fill gaps with LV settlement data for dates missing from Powston
            if let siteId = api.selectedSite?.id {
                let effectiveEnd = min(customEndDate, calendar.startOfDay(for: latestNavigableDate))
                cachedDailySummaries = fillGapsWithLVSettlement(cachedDailySummaries, siteId: siteId, from: customStartDate, to: effectiveEnd)
            }

            // Exclude days past the latest finalized date
            let customCutoff = calendar.startOfDay(for: latestNavigableDate)
            cachedDailySummaries = cachedDailySummaries.filter { calendar.startOfDay(for: $0.date) <= customCutoff }

            isLoadingSummary = false; records = []
            return
        }
        
        // Final cancellation check before updating UI state
        guard !Task.isCancelled else { isLoading = false; return }
        
        updateCachedValues(from: fetchedRecords)
        records = fetchedRecords.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        isLoading = false
    }
    
    private func loadHistoricalWeather(for date: Date) async {
        // Check cancellation first
        guard !Task.isCancelled else { return }
        
        // Get site coordinates
        guard let site = api.sites.first(where: { $0.id == api.selectedSiteId }),
              let lat = site.latitude, let lon = site.longitude else {
            return
        }
        
        isLoadingWeather = true
        
        if let weather = await weatherService.fetchHistoricalWeather(latitude: lat, longitude: lon, date: date) {
            // Check cancellation before updating state
            guard !Task.isCancelled else {
                isLoadingWeather = false
                return
            }
            historicalWeather = weather
        }
        
        isLoadingWeather = false
    }
    
    private func updateCachedValues(from records: [MeterRecord]) {
        cachedTotalEarnings = records.compactMap { $0.earnings }.reduce(0, +) / 100.0
        cachedTotalCosts = records.compactMap { $0.costs }.reduce(0, +) / 100.0
        cachedTotalImport = records.compactMap { $0.energyImport }.reduce(0, +)
        cachedTotalExport = records.compactMap { $0.energyExport }.reduce(0, +)
        
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = powstonTimezone()
        let grouped = Dictionary(grouping: records) { r -> String in
            guard let d = r.date else { return "" }; return f.string(from: d)
        }
        cachedDailySummaries = grouped.compactMap { (dateStr, recs) -> DailySummary? in
            guard !dateStr.isEmpty, let date = f.date(from: dateStr) else { return nil }
            return DailySummary(
                date: date,
                totalImport: recs.compactMap { $0.energyImport }.reduce(0, +),
                totalExport: recs.compactMap { $0.energyExport }.reduce(0, +),
                totalEarnings: recs.compactMap { $0.earnings }.reduce(0, +) / 100.0,
                totalCosts: recs.compactMap { $0.costs }.reduce(0, +) / 100.0,
                avgSoc: recs.compactMap { $0.endBatterySoc }.reduce(0, +) / Double(max(1, recs.compactMap { $0.endBatterySoc }.count)),
                recordCount: recs.count
            )
        }.sorted { $0.date < $1.date }
    }
    
    /// Populate summary cards from aggregated LV cashflow data
    /// Returns true if LV data was available and cards were populated
    private func populateCardsFromLVCashflow(siteId: Int, from: Date, to: Date, fetchOnDemand: Bool = false, requireComplete: Bool = true) async -> Bool {
        var lvSummaries = PowstonDataStore.shared.getLVCashflowSummaries(siteId: siteId, from: from, to: to)
        let expectedDays = calendar.dateComponents([.day], from: from, to: to).day! + 1

        // On-demand fetch if data is missing
        if fetchOnDemand && lvSummaries.count < expectedDays && expectedDays > 0 && LocalVoltsService.shared.hasCredentials {
            let fetched = await LocalVoltsService.shared.fetchSettlementOnDemand(siteId: siteId, from: from, to: to)
            if fetched > 0 {
                lvSummaries = PowstonDataStore.shared.getLVCashflowSummaries(siteId: siteId, from: from, to: to)
            }
        }

        if requireComplete {
            guard lvSummaries.count >= expectedDays && expectedDays > 0 else { return false }
        } else {
            guard !lvSummaries.isEmpty else { return false }
        }

        let agg = lvSummaries.aggregated()
        cachedTotalEarnings = ((agg.totalSales) * 100).rounded() / 100
        cachedTotalCosts = ((agg.spotEnergyCost + agg.networkEnergyCost + agg.certificatesCost) * 100).rounded() / 100
        cachedSupplyCosts = ((agg.networkAccessCost + agg.localvoltsFee) * 100).rounded() / 100
        cachedActualNetProfit = ((-agg.netCosts) * 100).rounded() / 100
        cachedTotalImport = agg.energyPurchasedKwh
        cachedTotalExport = agg.energySoldTotalKwh

        return true
    }

    /// Compute totals from cachedDailySummaries for consistency between summary cards and charts
    private func updateCachedTotalsFromDailySummaries() {
        cachedTotalEarnings = cachedDailySummaries.reduce(0) { $0 + $1.totalEarnings }
        cachedTotalCosts = cachedDailySummaries.reduce(0) { $0 + $1.totalCosts }
        cachedTotalImport = cachedDailySummaries.reduce(0) { $0 + $1.totalImport }
        cachedTotalExport = cachedDailySummaries.reduce(0) { $0 + $1.totalExport }
    }
    
    /// Navigate to a specific date (used by heatmap tap)
    func navigateToDay(_ date: Date) {
        viewMode = .day
        selectedDate = date
        triggerLoad()
    }
    
    /// Navigate to a specific month (used by year heatmap tap)
    func navigateToMonth(_ month: Int) {
        let year = calendar.component(.year, from: selectedDate)
        if let monthDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)) {
            viewMode = .month
            selectedDate = monthDate
            triggerLoad()
        }
    }
    
    /// Fetch 30-day rolling average for heatmap color calibration
    /// Calculated as 30 days ending at the start of the viewed period
    @MainActor
    private func loadRollingAverage() async {
        // Calculate date range: 30 days ending before the viewed period
        let referenceDate: Date
        switch viewMode {
        case .day:
            referenceDate = selectedDate
        case .week:
            referenceDate = weekStart
        case .month:
            referenceDate = monthStart
        case .custom:
            referenceDate = customStartDate
        case .year:
            return  // Year view doesn't use rolling average
        }
        
        // 30 days ending the day before the viewed period
        let endDate = calendar.date(byAdding: .day, value: -1, to: referenceDate) ?? referenceDate
        guard let startDate = calendar.date(byAdding: .day, value: -29, to: endDate) else { return }
        
        // Use the API's custom range summary which is more efficient
        if let summary = await api.fetchCustomRangeSummary(startDate: startDate, endDate: endDate) {
            let netDollars = summary.earningsDollars - summary.costsDollars
            rollingAverage = netDollars / 30.0
        }
    }
    
    // MARK: - Navigation
    
    func dateStep(forward: Bool) -> Int {
        let d = forward ? 1 : -1
        switch viewMode {
        case .day: return d
        case .week: return d * 7
        case .month: return d * 30
        case .year: return d * 365
        case .custom: return d * customRangeDays
        }
    }
    
    func jumpToLatest() {
        switch viewMode {
        case .day:
            // Jump to the latest complete data date
            selectedDate = latestNavigableDate
        case .week:
            // Jump to the week containing the latest finalized date
            selectedDate = latestNavigableDate
        case .month:
            // Jump to the month containing the latest finalized date
            let latest = latestNavigableDate
            selectedDate = calendar.date(from: calendar.dateComponents([.year, .month], from: latest)) ?? latest
        case .year: selectedDate = currentYearStart
        case .custom:
            customEndDate = latestNavigableDate
            customStartDate = calendar.date(byAdding: .day, value: -(customRangeDays - 1), to: latestNavigableDate) ?? latestNavigableDate
            savedCustomStart = customStartDate.timeIntervalSince1970
            savedCustomEnd = customEndDate.timeIntervalSince1970
        }
    }
    
    func changeDate(by days: Int) {
        if viewMode == .month {
            if let newDate = calendar.date(byAdding: .month, value: days > 0 ? 1 : -1, to: selectedDate) {
                let newMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: newDate)) ?? newDate
                // Only advance if the new month contains finalized data
                let latestDay = calendar.startOfDay(for: latestNavigableDate)
                if newMonthStart <= latestDay {
                    selectedDate = newDate
                    triggerLoad()
                }
            }
            return
        }
        if viewMode == .year {
            if let newDate = calendar.date(byAdding: .year, value: days > 0 ? 1 : -1, to: selectedDate) {
                if calendar.component(.year, from: newDate) <= calendar.component(.year, from: Date()) {
                    selectedDate = newDate
                    triggerLoad()
                }
            }
            return
        }
        if viewMode == .custom {
            if let newStart = calendar.date(byAdding: .day, value: days, to: customStartDate),
               let newEnd = calendar.date(byAdding: .day, value: days, to: customEndDate) {
                // Cap at latestNavigableDate instead of today
                let latestDay = calendar.startOfDay(for: latestNavigableDate)
                if newEnd <= latestDay {
                    customStartDate = newStart
                    customEndDate = newEnd
                    savedCustomStart = customStartDate.timeIntervalSince1970
                    savedCustomEnd = customEndDate.timeIntervalSince1970
                    triggerLoad()
                }
            }
            return
        }
        if let newDate = calendar.date(byAdding: .day, value: days, to: selectedDate) {
            if viewMode == .day {
                let newDateOnly = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: newDate)) ?? newDate
                // Cap at latestNavigableDate instead of today
                let latestDay = calendar.startOfDay(for: latestNavigableDate)
                if newDateOnly <= latestDay {
                    selectedDate = newDate
                    triggerLoad()
                }
            } else {
                // Week: only advance if the new week contains finalized data
                let newWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: newDate)) ?? newDate
                let latestDay = calendar.startOfDay(for: latestNavigableDate)
                if newWeekStart <= latestDay {
                    selectedDate = newDate
                    triggerLoad()
                }
            }
        }
    }
    
    func formatEarliestDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; f.timeZone = powstonTimezone()
        return f.string(from: date)
    }
}

// MARK: - P2P Year Summary Card

struct P2PYearSummaryCard: View {
    let data: PowstonDataStore.P2PRangeResult

    private func formatCurrency(_ value: Double) -> String {
        String(format: "$%.2f", abs(value))
    }

    private func formatKwh(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.0f kWh", value)
        }
        return String(format: "%.1f kWh", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.2.fill")
                    .foregroundColor(.purple)
                Text("P2P Trading Summary")
                    .font(.headline)
                Spacer()
            }

            if data.sellKwh > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("P2P Sold")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(formatCurrency(data.sellRevenue))
                            .font(.title3.monospacedDigit().bold())
                            .foregroundColor(.green)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Volume")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(formatKwh(data.sellKwh))
                            .font(.subheadline.monospacedDigit())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("vs Spot")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        let sellPremium = data.sellRevenue - data.sellSpotEquivalent
                        Text(sellPremium >= 0 ? "+\(formatCurrency(sellPremium))" : "-\(formatCurrency(abs(sellPremium)))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(sellPremium >= 0 ? .green : .red)
                    }
                }
            }

            if data.buyKwh > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("P2P Bought")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(formatCurrency(data.buyCost))
                            .font(.title3.monospacedDigit().bold())
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Volume")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(formatKwh(data.buyKwh))
                            .font(.subheadline.monospacedDigit())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("vs Spot")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        let buySavings = data.buySpotEquivalent - data.buyCost
                        Text(buySavings >= 0 ? "+\(formatCurrency(buySavings))" : "-\(formatCurrency(abs(buySavings)))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(buySavings >= 0 ? .green : .red)
                    }
                }
            }

            // Net P2P premium/savings
            if data.sellKwh > 0 || data.buyKwh > 0 {
                Divider()
                let sellPremium = data.sellRevenue - data.sellSpotEquivalent
                let buySavings = data.buySpotEquivalent - data.buyCost
                let netBenefit = sellPremium + buySavings
                HStack {
                    Text("Net P2P Benefit")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(netBenefit >= 0 ? "+\(formatCurrency(netBenefit))" : "-\(formatCurrency(abs(netBenefit)))")
                        .font(.headline.monospacedDigit())
                        .foregroundColor(netBenefit >= 0 ? .green : .red)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.08))
        .cornerRadius(12)
    }
}

// MARK: - Date Picker Sheet

struct DatePickerSheet: View {
    @Binding var selectedDate: Date
    var viewMode: HistoryViewMode = .day
    var minDate: Date? = nil
    var maxDate: Date? = nil
    let onDismiss: () -> Void

    var dateRange: ClosedRange<Date> {
        let min = minDate ?? Date.distantPast
        let max = maxDate ?? Date()
        let effectiveMin = min <= max ? min : Date.distantPast
        return effectiveMin...max
    }
    
    var body: some View {
        NavigationStack {
            DatePicker("Select Date", selection: $selectedDate, in: dateRange, displayedComponents: .date)
                .datePickerStyle(.graphical).padding()
                .navigationTitle(viewMode == .day ? "Select Date" : viewMode == .week ? "Select Week" : viewMode == .month ? "Select Month" : "Select Year")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { onDismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Custom Date Range Sheet

struct CustomDateRangeSheet: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    var minDate: Date? = nil
    let onDismiss: () -> Void
    
    var calendar: Calendar { var c = Calendar.current; c.timeZone = powstonTimezone(); return c }
    var dayCount: Int { (calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0) + 1 }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("\(dayCount) day\(dayCount == 1 ? "" : "s")").font(.subheadline).foregroundColor(.secondary)
                VStack(spacing: 16) {
                    DatePicker("Start", selection: $startDate, in: (minDate ?? Date.distantPast)...endDate, displayedComponents: .date)
                    DatePicker("End", selection: $endDate, in: startDate...Date(), displayedComponents: .date)
                }
                .padding(.horizontal)
                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Select Date Range").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { onDismiss() } } }
        }
        .presentationDetents([.height(250)])
    }
}
