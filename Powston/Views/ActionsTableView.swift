//
//  ActionsTableView.swift
//  Powston
//
//  Landscape table view showing inverter actions history
//  Designed to replace/complement the Powston web "Inverter Actions Dashboard"
//
//  Uses PowstonDataStore for SQLite cache-through:
//  - Finalized data (>7 days old) served from SQLite without API calls
//  - Recent data fetched from API and cached for future use
//

import SwiftUI
import Combine

// MARK: - Aligned Meter Data
/// Meter data aligned to the interval it actually represents
/// (sourced from the following interval's action record)
struct AlignedMeterData {
    let soc: Double?
    let grid: Double      // watts, absolute value
    let solar: Double     // watts
    let battery: Double   // watts (positive = discharge)
    let home: Double      // watts
    let isGridExporting: Bool
    let calculatedGrid: Double  // watts, signed
    
    var hasData: Bool {
        grid != 0 || solar != 0 || battery != 0 || home != 0
    }
}

// MARK: - Combined Action
// Combined action data for a single timestamp across all inverters
struct CombinedAction: Identifiable {
    let id: Date  // timestamp as ID
    let date: Date
    let leadAction: InverterAction
    let allActions: [Int: InverterAction]  // inverterId -> action
    let expectedInverterCount: Int  // How many inverters should have data
    
    // Aligned meter data (from next interval, representing this interval's actual flow)
    var alignedMeterData: AlignedMeterData? = nil
    
    // Check if any inverters are missing meaningful data
    var hasMissingInverters: Bool {
        // First check: do we have entries for all inverters?
        if allActions.count < expectedInverterCount {
            return true
        }
        // Second check: do any inverters have silent/empty data?
        for action in allActions.values {
            if !action.hasMeaningfulData {
                return true
            }
        }
        return false
    }
    
    // Count of inverters with actual meaningful data
    var invertersWithData: Int {
        allActions.values.filter { $0.hasMeaningfulData }.count
    }
    
    // Combined values
    var displayTime: String { leadAction.displayTime }
    var displayDateTime: String { leadAction.displayDateTime }
    var displayAction: String { leadAction.displayAction }
    var reasonSummary: String { leadAction.reasonSummary }
    var reasonFull: String { leadAction.reasonFull }
    var buyPrice: Double? { leadAction.buyPrice }
    var sellPrice: Double? { leadAction.sellPrice }
    
    var combinedSOC: Double {
        // For now just use lead's SOC - proper weighted would need capacities
        leadAction.batterySoc ?? 0
    }
    
    var combinedGrid: Double {
        allActions.values.compactMap { $0.gridPower }.reduce(0, +)
    }
    
    var combinedSolar: Double {
        allActions.values.compactMap { $0.solarPower }.reduce(0, +)
    }
    
    var combinedBattery: Double {
        allActions.values.compactMap { $0.batteryPower }.reduce(0, +)
    }
    
    var combinedHome: Double {
        allActions.values.compactMap { $0.housePower }.reduce(0, +)
    }
    
    // MARK: - Data availability checks (for N/A display logic)
    var hasSOCData: Bool {
        leadAction.batterySoc != nil
    }
    
    var hasGridData: Bool {
        allActions.values.contains { $0.gridPower != nil }
    }
    
    var hasSolarData: Bool {
        allActions.values.contains { $0.solarPower != nil }
    }
    
    var hasBatteryData: Bool {
        allActions.values.contains { $0.batteryPower != nil }
    }
    
    var hasHomeData: Bool {
        allActions.values.contains { $0.housePower != nil }
    }
    
    // Physics-based grid direction calculation
    // Energy balance: Solar - Battery - Home = Grid
    // (Battery negative = charging = consuming power)
    // Pick the sign of grid that minimizes imbalance
    
    var calculatedGrid: Double {
        // Expected grid from energy balance: Solar - Battery - Home
        // Battery is negative when charging (consuming), positive when discharging (producing)
        // So: Solar + Battery (with sign) - Home = Grid
        let expectedGrid = combinedSolar + combinedBattery - combinedHome
        
        let reportedGridAbs = abs(combinedGrid)
        let positiveError = abs(expectedGrid - reportedGridAbs)
        let negativeError = abs(expectedGrid - (-reportedGridAbs))
        
        // Return the sign that's closest to expected
        return positiveError <= negativeError ? reportedGridAbs : -reportedGridAbs
    }
    
    // True grid direction based on physics calculation
    var isGridExporting: Bool {
        calculatedGrid > 0  // positive = export, negative = import
    }
    
    // The difference between calculated and physics-expected grid (attributed to home measurement noise)
    var homeAdjustment: Double {
        let expectedGrid = combinedSolar + combinedBattery - combinedHome
        return calculatedGrid - expectedGrid
    }
    
    // Adjusted home value for display (absorbs the small measurement variance)
    var adjustedHome: Double {
        combinedHome + homeAdjustment
    }
    
    // Energy balance with corrected grid (should be near zero)
    var energyImbalance: Double {
        // With corrected grid: Solar + Battery - Grid - Home should be ~0
        // (positive grid = export = sink, negative grid = import = source)
        combinedSolar + combinedBattery - calculatedGrid - combinedHome
    }
    
    var energyImbalanceKw: Double {
        energyImbalance / 1000
    }
    
    // Threshold: 3% of total power throughput (accounts for inverter inefficiency/losses)
    var hasSignificantImbalance: Bool {
        let totalPower = abs(combinedSolar) + abs(combinedBattery) + abs(calculatedGrid) + abs(combinedHome)
        let threshold = totalPower * 0.03  // 3%
        return abs(energyImbalance) > max(threshold, 500)  // At least 500W to avoid noise at low power
    }
    
    // MARK: - Revenue Calculation (requires aligned data)
    // Grid values are average power in W; convert to energy for revenue
    var intervalRevenue: Double? {
        guard let meter = alignedMeterData, meter.hasData else { return nil }
        let gridKW = abs(meter.calculatedGrid) / 1000  // W → kW
        let kWh = gridKW * (5.0 / 60.0)  // kW × (5 min / 60 min) = kWh
        
        if meter.isGridExporting {
            return kWh * (sellPrice ?? 0)  // cents earned
        } else {
            return -kWh * (buyPrice ?? 0)  // cents spent
        }
    }
}

// Singleton to persist actions data across view recreation during rotation
class ActionsDataStore: ObservableObject {
    static let shared = ActionsDataStore()
    
    @Published var combinedActions: [CombinedAction] = []
    @Published var isLoading = false
    @Published var selectedDate: Date = Date()
    @Published var currentPage: Int = 1
    @Published var hasMoreData: Bool = true
    @Published var isLoadingMore: Bool = false
    @Published var lastLoadedSiteId: Int = 0
    
    private init() {}
    
    func needsLoad(siteId: Int) -> Bool {
        return combinedActions.isEmpty || lastLoadedSiteId != siteId
    }
}

struct ActionsTableView: View {
    @EnvironmentObject var api: PowstonAPI
    @ObservedObject private var store = ActionsDataStore.shared
    @State private var showDatePicker = false
    @State private var selectedCombinedAction: CombinedAction?
    
    // For multi-inverter sites
    var siteInverters: [Inverter] {
        guard let siteId = api.selectedSiteId else { return [] }
        return api.inverters.filter { $0.siteId == siteId }
    }
    
    var isMultiInverterSite: Bool {
        siteInverters.count > 1
    }
    
    var leadInverterId: Int? {
        guard let siteId = api.selectedSiteId else { return nil }
        return api.leadInverter(forSiteId: siteId)?.id
    }
    
    // Sorted by time descending, filtering out incomplete current interval
    var displayActions: [CombinedAction] {
        store.combinedActions
            .filter { $0.alignedMeterData != nil }  // Only show rows with complete meter data
            .sorted { $0.date > $1.date }
    }
    
    // Daily revenue total - only for selected date
    var dailyRevenue: Double {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: store.selectedDate)
        return store.combinedActions
            .filter { calendar.startOfDay(for: $0.date) == selectedDay }
            .compactMap { $0.intervalRevenue }
            .reduce(0, +)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Sticky column headers (always visible)
            columnHeaders
            
            Divider()
            
            if store.isLoading && store.combinedActions.isEmpty {
                Spacer()
                ProgressView("Loading actions...")
                Spacer()
            } else if displayActions.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No actions for this date")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                // Scrollable content with header inside
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Collapsible header (scrolls away)
                        headerView
                            .padding(.bottom, 8)
                        
                        // Action rows with date separators
                        ForEach(Array(displayActions.enumerated()), id: \.offset) { index, combined in
                            // Show date separator when crossing into a new day
                            if index == 0 || !isSameDay(combined.date, displayActions[index - 1].date) {
                                DateSeparatorRow(date: combined.date, isSelectedDate: isSameDay(combined.date, store.selectedDate))
                            }
                            
                            CombinedActionRow(combined: combined)
                                .onTapGesture {
                                    selectedCombinedAction = combined
                                }
                            
                            Divider()
                                .padding(.leading)
                        }
                        
                        // Load more indicator / trigger
                        if store.hasMoreData {
                            HStack {
                                Spacer()
                                if store.isLoadingMore {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Loading more...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Button(action: { Task { await loadMoreActions() } }) {
                                        Text("Load earlier actions")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .onAppear {
                                // Auto-load when scrolled to bottom
                                Task { await loadMoreActions() }
                            }
                        }
                    }
                }
                .refreshable {
                    await loadActions()
                }
            }
        }
        .sheet(item: $selectedCombinedAction) { combined in
            CombinedActionDetailSheet(
                combined: combined,
                siteInverters: siteInverters,
                leadInverterId: leadInverterId
            )
            .environmentObject(api)
        }
        .sheet(isPresented: $showDatePicker) {
            ActionsDatePickerSheet(selectedDate: $store.selectedDate, onDismiss: {
                showDatePicker = false
                Task { await loadActions() }
            })
        }
        .onAppear {
            // Load if empty OR if site changed
            if let siteId = api.selectedSiteId, store.needsLoad(siteId: siteId) {
                Task { await loadActions() }
            }
        }
        .onChange(of: api.selectedSiteId) { _, _ in
            // Reload when site changes
            Task { await loadActions() }
        }
    }
    
    // MARK: - Header View
    var headerView: some View {
        HStack(spacing: 12) {
            // Date navigation
            HStack(spacing: 8) {
                Button(action: { changeDate(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                .disabled(store.isLoading)
                
                Button(action: { showDatePicker = true }) {
                    Text(formattedDate)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                
                Button(action: { changeDate(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                }
                .disabled(store.isLoading || Calendar.current.isDateInToday(store.selectedDate))
            }
            
            Spacer()
            
            // Daily revenue total with estimate disclaimer
            if dailyRevenue != 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: dailyRevenue >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundColor(dailyRevenue >= 0 ? .green : .red)
                        Text(formatDailyRevenue(dailyRevenue))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundColor(dailyRevenue >= 0 ? .green : .red)
                    }
                    Text("Estimate · not settlement")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
            }
            
            // Inverter count indicator (if multi-inverter site)
            if isMultiInverterSite {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.horizontal.fill")
                        .font(.caption2)
                    Text("\(siteInverters.count)")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
            }
            
            // Record count
            Text("\(displayActions.count)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    // MARK: - Column Headers
    var columnHeaders: some View {
        HStack(spacing: 0) {
            Text("TIME")
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Text("ACTION")
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Text("SOC")
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            Text("GRID")
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            Text("SOLAR")
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            Text("BATT")
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            Text("HOME")
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            Text("BUY")
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            Text("SELL")
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            Text("REV")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(.primary.opacity(0.6))
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.08))
    }
    
    // MARK: - Helpers
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: store.selectedDate)
    }
    
    func changeDate(by days: Int) {
        if let newDate = Calendar.current.date(byAdding: .day, value: days, to: store.selectedDate) {
            store.selectedDate = newDate
            Task { await loadActions() }
        }
    }
    
    func formatDailyRevenue(_ cents: Double) -> String {
        let dollars = cents / 100
        if abs(dollars) >= 1 {
            return String(format: "%+.2f", dollars)
        }
        return String(format: "%+.0f¢", cents)
    }
    
    func isSameDay(_ date1: Date, _ date2: Date) -> Bool {
        Calendar.current.isDate(date1, inSameDayAs: date2)
    }
    
    func loadActions() async {
        guard !store.isLoading else { return }
        guard let siteId = api.selectedSiteId else { return }
        
        store.isLoading = true
        defer { store.isLoading = false }
        
        store.currentPage = 1
        store.hasMoreData = true
        store.lastLoadedSiteId = siteId
        
        // Trigger background sync if needed (non-blocking)
        let inverterIds = siteInverters.map { $0.id }
        PowstonDataStore.shared.scheduleBackgroundSyncIfNeeded(siteId: siteId, inverterIds: inverterIds)
        
        let combined = await fetchCombinedActions(for: store.selectedDate)
        store.combinedActions = combined
        store.hasMoreData = combined.count >= 288
    }
    
    func loadMoreActions() async {
        guard store.hasMoreData, !store.isLoadingMore else { return }
        
        store.isLoadingMore = true
        store.currentPage += 1
        
        guard let previousDate = Calendar.current.date(byAdding: .day, value: -(store.currentPage - 1), to: store.selectedDate) else {
            store.isLoadingMore = false
            return
        }
        
        let moreActions = await fetchCombinedActions(for: previousDate)
        
        if moreActions.isEmpty {
            store.hasMoreData = false
        } else {
            // Deduplicate by date before appending
            let existingDates = Set(store.combinedActions.map { $0.date })
            let newActions = moreActions.filter { !existingDates.contains($0.date) }
            store.combinedActions.append(contentsOf: newActions)
        }
        
        if store.currentPage >= 3 {
            store.hasMoreData = false
        }
        
        store.isLoadingMore = false
    }
    
    func fetchCombinedActions(for date: Date) async -> [CombinedAction] {
        // Fetch actions for all inverters using cache-through
        // Finalized data (>7 days old) served from SQLite without API calls
        var allActions: [Int: [InverterAction]] = [:]
        
        guard let siteId = api.selectedSiteId else { return [] }
        let dataStore = PowstonDataStore.shared
        
        for inverter in siteInverters {
            // Use DataStore cache-through: finalized data from SQLite, recent from API
            let actionRecords = await dataStore.fetchActionsForDay(
                siteId: siteId,
                inverterId: inverter.id,
                date: date
            )
            // Convert ActionRecords to InverterActions for display
            allActions[inverter.id] = actionRecords.map { $0.toInverterAction() }
        }
        
        // Group by timestamp and combine
        var actionsByTime: [Date: [Int: InverterAction]] = [:]
        
        for (inverterId, actions) in allActions {
            for action in actions {
                guard let actionDate = action.date else { continue }
                if actionsByTime[actionDate] == nil {
                    actionsByTime[actionDate] = [:]
                }
                actionsByTime[actionDate]?[inverterId] = action
            }
        }
        
        // Sort timestamps chronologically for alignment
        let sortedTimes = actionsByTime.keys.sorted()
        
        // Create combined actions with aligned meter data
        var combined: [CombinedAction] = []
        let leadId = leadInverterId ?? siteInverters.first?.id ?? 0
        let expectedCount = siteInverters.count
        
        for (index, date) in sortedTimes.enumerated() {
            guard let actionsDict = actionsByTime[date] else { continue }
            
            // Use lead inverter's action, or first available
            let leadAction = actionsDict[leadId] ?? actionsDict.values.first
            guard let lead = leadAction else { continue }
            
            // Get aligned meter data from NEXT interval (if available)
            // This represents what actually happened DURING this interval
            var alignedMeter: AlignedMeterData? = nil
            if index + 1 < sortedTimes.count {
                let nextTime = sortedTimes[index + 1]
                if let nextActions = actionsByTime[nextTime] {
                    // Sum meter values from all inverters in next interval
                    let nextSolar = nextActions.values.compactMap { $0.solarPower }.reduce(0, +)
                    let nextBattery = nextActions.values.compactMap { $0.batteryPower }.reduce(0, +)
                    let nextHome = nextActions.values.compactMap { $0.housePower }.reduce(0, +)
                    let nextGrid = nextActions.values.compactMap { $0.gridPower }.reduce(0, +)
                    let nextSOC = nextActions[leadId]?.batterySoc ?? nextActions.values.first?.batterySoc
                    
                    // Physics-based grid direction (same logic as existing)
                    let expectedGrid = nextSolar + nextBattery - nextHome
                    let reportedGridAbs = abs(nextGrid)
                    let positiveError = abs(expectedGrid - reportedGridAbs)
                    let negativeError = abs(expectedGrid - (-reportedGridAbs))
                    let calculatedGrid = positiveError <= negativeError ? reportedGridAbs : -reportedGridAbs
                    
                    alignedMeter = AlignedMeterData(
                        soc: nextSOC,
                        grid: reportedGridAbs,
                        solar: nextSolar,
                        battery: nextBattery,
                        home: nextHome,
                        isGridExporting: calculatedGrid > 0,
                        calculatedGrid: calculatedGrid
                    )
                }
            }
            
            var combinedAction = CombinedAction(
                id: date,
                date: date,
                leadAction: lead,
                allActions: actionsDict,
                expectedInverterCount: expectedCount
            )
            combinedAction.alignedMeterData = alignedMeter
            
            combined.append(combinedAction)
        }
        
        return combined
    }
}

// MARK: - Combined Action Row (shows combined values from all inverters)
struct CombinedActionRow: View {
    let combined: CombinedAction
    
    var body: some View {
        HStack(spacing: 0) {
            // Time
            Text(combined.displayTime)
                .font(.system(size: 16, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Imbalance indicator + Action badge
            HStack(spacing: 3) {
                if combined.hasSignificantImbalance {
                    Image(systemName: "plusminus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
                ActionBadge(action: combined.displayAction, isMissing: combined.hasMissingInverters)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // SOC (aligned)
            Text(socText)
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(socColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            // Grid (aligned)
            Text(gridText)
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(gridColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            // Solar (aligned)
            Text(solarText)
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            // Battery (aligned)
            Text(batteryText)
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(batteryColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            // Home (aligned)
            Text(homeText)
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(.purple)
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            // Buy price
            Text(buyText)
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(.blue)
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            // Sell price
            Text(sellText)
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(sellColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
            
            // Revenue
            Text(revenueText)
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(revenueColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
    
    // MARK: - Text computed properties using aligned meter data when available
    
    var socText: String {
        if let alignedSOC = combined.alignedMeterData?.soc {
            return String(format: "%.0f%%", alignedSOC)
        }
        guard let soc = combined.leadAction.batterySoc else { return "N/A" }
        return String(format: "%.0f%%", soc)
    }
    
    var socColor: Color {
        let soc = combined.alignedMeterData?.soc ?? combined.leadAction.batterySoc
        guard let s = soc else { return .secondary }
        if s >= 80 { return .green }
        if s >= 40 { return .yellow }
        if s >= 20 { return .orange }
        return .red
    }
    
    var gridText: String {
        if let meter = combined.alignedMeterData, meter.hasData {
            return String(format: "%.1f", abs(meter.calculatedGrid) / 1000)
        }
        guard combined.hasGridData else { return "N/A" }
        return String(format: "%.1f", abs(combined.calculatedGrid) / 1000)
    }
    
    var gridColor: Color {
        if let meter = combined.alignedMeterData, meter.hasData {
            return meter.isGridExporting ? .green : .blue
        }
        guard combined.hasGridData else { return .secondary }
        return combined.isGridExporting ? .green : .blue
    }
    
    var solarText: String {
        if let meter = combined.alignedMeterData, meter.hasData {
            return String(format: "%.1f", meter.solar / 1000)
        }
        guard combined.hasSolarData else { return "N/A" }
        return String(format: "%.1f", combined.combinedSolar / 1000)
    }
    
    var batteryText: String {
        if let meter = combined.alignedMeterData, meter.hasData {
            return String(format: "%.1f", abs(meter.battery) / 1000)
        }
        guard combined.hasBatteryData else { return "N/A" }
        return String(format: "%.1f", abs(combined.combinedBattery) / 1000)
    }
    
    var batteryColor: Color {
        if let meter = combined.alignedMeterData, meter.hasData {
            return meter.battery > 0 ? .orange : .green
        }
        guard combined.hasBatteryData else { return .secondary }
        return combined.combinedBattery > 0 ? .orange : .green
    }
    
    var homeText: String {
        if let meter = combined.alignedMeterData, meter.hasData {
            return String(format: "%.1f", abs(meter.home) / 1000)
        }
        guard combined.hasHomeData else { return "N/A" }
        return String(format: "%.1f", abs(combined.adjustedHome) / 1000)
    }
    
    var buyText: String {
        if let price = combined.buyPrice {
            return PriceFormat.format(price)
        }
        return "N/A"
    }
    
    var sellText: String {
        if let price = combined.sellPrice {
            return PriceFormat.format(price)
        }
        return "N/A"
    }
    
    var buyColor: Color {
        guard let price = combined.buyPrice else { return .secondary }
        return PriceColors.buyColor(price)
    }
    
    var sellColor: Color {
        guard let price = combined.sellPrice else { return .secondary }
        return PriceColors.sellColor(price)
    }
    
    var revenueText: String {
        guard let rev = combined.intervalRevenue else { return "N/A" }
        let absCents = abs(rev)
        if absCents >= 100 {
            return String(format: "$%.2f", rev / 100)
        }
        return String(format: "%.1f¢", rev)
    }
    
    var revenueColor: Color {
        guard let rev = combined.intervalRevenue else { return .secondary }
        return rev >= 0 ? .green : .red
    }
}

// MARK: - Date Separator Row
struct DateSeparatorRow: View {
    let date: Date
    let isSelectedDate: Bool
    
    var body: some View {
        HStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
                .frame(maxWidth: 40)
            
            Text(formattedDate)
                .font(.caption.weight(.semibold))
                .foregroundColor(isSelectedDate ? .primary : .secondary)
            
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
            
            if !isSelectedDate {
                Text("↑ scroll")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.05))
    }
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
}

// MARK: - Action Row
struct ActionRow: View {
    let action: InverterAction
    let showInverter: Bool
    
    var body: some View {
        HStack(spacing: 0) {
            // Time
            Text(action.displayTime)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 58, alignment: .leading)
            
            // Inverter (if multi-inverter mode)
            if showInverter {
                Text(inverterLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
            
            // Action badge
            ActionBadge(action: action.displayAction)
                .frame(width: 68, alignment: .leading)
            
            // SOC
            Text(socText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(socColor)
                .frame(width: 44, alignment: .trailing)
            
            // Grid - positive = export, negative = import
            Text(gridText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(gridColor)
                .frame(width: 48, alignment: .trailing)
            
            // Solar
            Text(solarText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.orange)  // Better contrast than yellow in light mode
                .frame(width: 48, alignment: .trailing)
            
            // Battery - positive = discharge, negative = charge
            Text(batteryText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(batteryColor)
                .frame(width: 48, alignment: .trailing)
            
            // Home power
            Text(homeText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.purple)
                .frame(width: 48, alignment: .trailing)
            
            // Buy price
            Text(buyText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.blue)
                .frame(width: 44, alignment: .trailing)
            
            // Sell price
            Text(sellText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(sellColor)
                .frame(width: 44, alignment: .trailing)
            
            // Reason (truncated - tap row for full details)
            Text(action.reasonSummary)
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.7))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        }
        .padding(.horizontal)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
    
    var inverterLabel: String {
        if let serial = action.inverterSerial {
            return String(serial.suffix(4))
        }
        return "N/A"
    }
    
    var socText: String {
        if let soc = action.batterySoc {
            return String(format: "%.0f%%", soc)
        }
        return "N/A"
    }
    
    var socColor: Color {
        guard let soc = action.batterySoc else { return .secondary }
        if soc >= 80 { return .green }
        if soc >= 40 { return .yellow }
        if soc >= 20 { return .orange }
        return .red
    }
    
    var gridText: String {
        guard let grid = action.gridPower else { return "N/A" }
        let kw = abs(grid) / 1000
        return String(format: "%.1f", kw)
    }
    
    var gridColor: Color {
        guard let grid = action.gridPower else { return .secondary }
        return grid > 0 ? .orange : .blue  // positive = export (orange), negative = import (blue)
    }
    
    var solarText: String {
        guard let solar = action.solarPower else { return "N/A" }
        let kw = solar / 1000
        return String(format: "%.1f", kw)
    }
    
    var batteryText: String {
        guard let battery = action.batteryPower else { return "N/A" }
        let kw = abs(battery) / 1000
        return String(format: "%.1f", kw)
    }
    
    var batteryColor: Color {
        guard let battery = action.batteryPower else { return .secondary }
        return battery > 0 ? .orange : .green  // positive = discharge (orange), negative = charge (green)
    }
    
    var homeText: String {
        guard let home = action.housePower else { return "N/A" }
        let kw = home / 1000
        return String(format: "%.1f", kw)
    }
    
    var buyText: String {
        if let price = action.buyPrice {
            return PriceFormat.format(price)
        }
        return "N/A"
    }
    
    var sellText: String {
        if let price = action.sellPrice {
            return PriceFormat.format(price)
        }
        return "N/A"
    }
    
    var buyColor: Color {
        guard let price = action.buyPrice else { return .secondary }
        return PriceColors.buyColor(price)
    }
    
    var sellColor: Color {
        guard let price = action.sellPrice else { return .secondary }
        return PriceColors.sellColor(price)
    }
}

// MARK: - Action Badge
struct ActionBadge: View {
    let action: String
    var isMissing: Bool = false
    
    var body: some View {
        Text(displayText)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor.opacity(0.15))
            .foregroundColor(backgroundColor)
            .cornerRadius(4)
    }
    
    var displayText: String {
        isMissing ? "Missing" : action
    }
    
    var backgroundColor: Color {
        if isMissing { return .orange }
        switch action.lowercased() {
        case "import": return .blue
        case "export": return .green
        case "charge": return .yellow
        case "curtail": return .orange
        case "auto": return .gray
        case "silent": return .gray
        case "missing": return .orange
        default: return .gray
        }
    }
}

// MARK: - Combined Action Detail Sheet (uses pre-fetched data)
struct CombinedActionDetailSheet: View {
    let combined: CombinedAction
    let siteInverters: [Inverter]
    let leadInverterId: Int?
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.dismiss) var dismiss
    @State private var selectedValuesAction: InverterAction?  // For values explorer
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header with timestamp and prices
                    headerSection
                    
                    Divider()
                    
                    // Combined summary
                    combinedSummarySection
                    
                    Divider()
                    
                    // Individual inverter rows
                    individualInvertersSection
                    
                    Divider()
                    
                    // Reasons section
                    reasonsSection
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Action Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    // MARK: - Header Section
    var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text(combined.displayDateTime)
                    .font(.headline)
                Spacer()
                
                // Revenue badge
                if let rev = combined.intervalRevenue {
                    Text(formatRevenue(rev))
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundColor(rev >= 0 ? .green : .red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background((rev >= 0 ? Color.green : Color.red).opacity(0.15))
                        .cornerRadius(6)
                }
            }
            
            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text("Buy")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(PriceFormat.formatFull(combined.buyPrice ?? 0))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(PriceColors.buyColor(combined.buyPrice ?? 0))
                }
                
                VStack(alignment: .leading) {
                    Text("Sell")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(PriceFormat.formatFull(combined.sellPrice ?? 0))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(PriceColors.sellColor(combined.sellPrice ?? 0))
                }
                
                Spacer()
            }
        }
    }
    
    func formatRevenue(_ cents: Double) -> String {
        let absCents = abs(cents)
        if absCents >= 100 {
            return String(format: "%+.2f", cents / 100)
        }
        return String(format: "%+.1f¢", cents)
    }
    
    // MARK: - Combined Summary Section
    var combinedSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Text(combined.displayAction.uppercased())
                    .font(.headline.weight(.bold))
                    .foregroundColor(actionColor(for: combined.displayAction))
                
                // Use aligned meter data if available
                let meter = combined.alignedMeterData
                let isExporting = meter?.isGridExporting ?? combined.isGridExporting
                let gridVal = meter?.calculatedGrid ?? combined.calculatedGrid
                let solarVal = meter?.solar ?? combined.combinedSolar
                let batteryVal = meter?.battery ?? combined.combinedBattery
                let homeVal = meter?.home ?? combined.adjustedHome
                
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Text(isExporting ? "Export" : "Import")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", abs(gridVal) / 1000))
                            .foregroundColor(isExporting ? .green : .blue)
                    }
                    
                    HStack(spacing: 2) {
                        Text("Solar")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", solarVal / 1000))
                            .foregroundColor(.orange)
                    }
                    
                    HStack(spacing: 2) {
                        Text(batteryVal > 0 ? "Dchg" : "Chg")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", abs(batteryVal) / 1000))
                            .foregroundColor(batteryVal > 0 ? .orange : .green)
                    }
                    
                    HStack(spacing: 2) {
                        Text("Home")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", abs(homeVal) / 1000))
                            .foregroundColor(.purple)
                    }
                }
                .font(.subheadline)
                
                Spacer()
                
                let socVal = meter?.soc ?? combined.combinedSOC
                Text(String(format: "%.0f%%", socVal))
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.green)
            }
            
            // Energy balance row (always shown)
            energyBalanceRow
            
            // Note when grid flow contradicts action
            if hasGridFlowContradiction {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text(gridContradictionExplanation)
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
    
    // Check if grid flow contradicts the commanded action
    var hasGridFlowContradiction: Bool {
        let action = combined.displayAction.lowercased()
        let isExporting = combined.alignedMeterData?.isGridExporting ?? combined.isGridExporting
        
        // Import action but actually exporting
        if action == "import" && isExporting { return true }
        // Export action but actually importing
        if action == "export" && !isExporting { return true }
        
        return false
    }
    
    var gridContradictionExplanation: String {
        let action = combined.displayAction.lowercased()
        let isExporting = combined.alignedMeterData?.isGridExporting ?? combined.isGridExporting
        
        if action == "import" && isExporting {
            return "Solar exceeds battery + home capacity, excess must export"
        } else if action == "export" && !isExporting {
            return "Battery/solar insufficient to meet home load, must import"
        }
        return ""
    }
    
    // MARK: - Energy Balance Row
    var energyBalanceRow: some View {
        let imbalance = combined.energyImbalanceKw
        let isSignificant = combined.hasSignificantImbalance
        
        return HStack(spacing: 8) {
            Image(systemName: "plusminus")
                .font(.caption)
                .foregroundColor(isSignificant ? .orange : .secondary)
            
            Text("Balance")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(String(format: "%+.2f kW", imbalance))
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundColor(isSignificant ? .orange : .secondary)
            
            Spacer()
            
            Text(imbalance > 0 ? "unmetered gen (added to Home)" : "unmetered load (added to Home)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.top, 6)
    }
    
    // MARK: - Individual Inverters Section
    var individualInvertersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Raw Inverter Data")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            
            HStack(spacing: 0) {
                Text("Action")
                    .frame(width: 65, alignment: .leading)
                Text("SOC")
                    .frame(width: 45, alignment: .trailing)
                Text("Grid")
                    .frame(width: 50, alignment: .trailing)
                Text("Solar")
                    .frame(width: 50, alignment: .trailing)
                Text("Batt")
                    .frame(width: 50, alignment: .trailing)
                Text("Home")
                    .frame(width: 50, alignment: .trailing)
                Text("Inv")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2.weight(.medium))
            .foregroundColor(.secondary)
            
            ForEach(sortedInverters, id: \.id) { inverter in
                inverterRow(for: inverter)
            }
        }
    }
    
    func inverterRow(for inverter: Inverter) -> some View {
        let invAction = combined.allActions[inverter.id]
        let isLead = inverter.id == leadInverterId
        let serial = String(inverter.serialNumber.suffix(4))
        let isMissing = invAction == nil || !(invAction?.hasMeaningfulData ?? false)

        // For non-lead inverters, try to get values from nestedInverterData
        // The nested data is keyed by the full serial number (e.g., "A23B0200864")
        let nestedData = invAction?.nestedInverterData?[inverter.serialNumber]

        // Use nested data for non-lead inverters when available, otherwise fall back to action values
        // For lead inverter, always use top-level values (they're the same as what's in runtime_params)
        let displaySOC: Double? = isLead ? invAction?.batterySoc : (nestedData?.batterySoc ?? invAction?.batterySoc)
        let displayGrid: Double? = isLead ? invAction?.gridPower : (nestedData?.gridPower ?? 0)  // Follower has no grid meter
        let displaySolar: Double? = isLead ? invAction?.solarPower : (nestedData?.solarPower ?? invAction?.solarPower)
        let displayBattery: Double? = isLead ? invAction?.batteryPower : (nestedData?.batteryPower ?? invAction?.batteryPower)
        // Home power is only meaningful for lead inverter (it's a calculated value from grid meter)
        let displayHome: Double? = isLead ? invAction?.housePower : nil

        return HStack(spacing: 0) {
            Text(isMissing ? "Missing" : (invAction?.displayAction ?? "N/A"))
                .font(.subheadline.weight(.medium))
                .foregroundColor(isMissing ? .orange : actionColor(for: invAction?.displayAction ?? ""))
                .frame(width: 65, alignment: .leading)

            Text(displaySOC != nil ? String(format: "%.0f%%", displaySOC!) : "N/A")
                .font(.system(size: 16))
                .foregroundColor(isMissing ? .secondary : .green)
                .frame(width: 48, alignment: .trailing)

            if isLead, let grid = displayGrid {
                Text(String(format: "%.1f", abs(grid) / 1000))
                    .font(.system(size: 16))
                    .foregroundColor(combined.isGridExporting ? .green : .blue)
                    .frame(width: 52, alignment: .trailing)
            } else if !isLead {
                // Follower inverter doesn't have grid meter - show dash
                Text("–")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)
            } else {
                Text("N/A").font(.system(size: 16)).foregroundColor(.secondary).frame(width: 52, alignment: .trailing)
            }

            if let solar = displaySolar {
                Text(String(format: "%.1f", solar / 1000))
                    .font(.system(size: 16))
                    .foregroundColor(.orange)
                    .frame(width: 52, alignment: .trailing)
            } else {
                Text("N/A").font(.system(size: 16)).foregroundColor(.secondary).frame(width: 52, alignment: .trailing)
            }

            if let battery = displayBattery {
                Text(String(format: "%.1f", abs(battery) / 1000))
                    .font(.system(size: 16))
                    .foregroundColor(battery > 0 ? .orange : .green)
                    .frame(width: 52, alignment: .trailing)
            } else {
                Text("N/A").font(.system(size: 16)).foregroundColor(.secondary).frame(width: 52, alignment: .trailing)
            }

            if isLead, let home = displayHome {
                Text(String(format: "%.1f", abs(home) / 1000))
                    .font(.system(size: 16))
                    .foregroundColor(.purple)
                    .frame(width: 52, alignment: .trailing)
            } else if !isLead {
                // Follower doesn't have meaningful home power (derived from grid meter)
                Text("–")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)
            } else {
                Text("N/A").font(.system(size: 16)).foregroundColor(.secondary).frame(width: 52, alignment: .trailing)
            }

            HStack(spacing: 2) {
                if isLead {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                }
                Text(serial)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
    
    // MARK: - Reasons Section
    var reasonsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Decision Reasons")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("Tap for details")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            ForEach(sortedInverters, id: \.id) { inverter in
                let invAction = combined.allActions[inverter.id]
                let serial = String(inverter.serialNumber.suffix(4))
                let isLead = inverter.id == leadInverterId
                let isMissing = invAction == nil || !(invAction?.hasMeaningfulData ?? false)
                
                Button(action: {
                    if let action = invAction {
                        selectedValuesAction = action
                    }
                }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            if isLead {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                            }
                            Text(serial)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            if invAction?.valuesJSON != nil {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Text((invAction?.reasonFull ?? "Missing").formattedDecisionTrace)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(isMissing ? .orange : .secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(invAction?.valuesJSON == nil)
            }
        }
        .sheet(item: $selectedValuesAction) { action in
            if let valuesJSON = action.valuesJSON {
                ActionValuesExplorer(
                    valuesJSON: valuesJSON,
                    inverterSerial: siteInverters.first { $0.id == action.inverterId }?.serialNumber ?? "Unknown"
                )
            } else {
                VStack {
                    Text("No values data available")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    var sortedInverters: [Inverter] {
        siteInverters.sorted { inv1, inv2 in
            if inv1.id == leadInverterId { return true }
            if inv2.id == leadInverterId { return false }
            return inv1.serialNumber < inv2.serialNumber
        }
    }
    
    func actionColor(for actionStr: String) -> Color {
        switch actionStr.lowercased() {
        case "import": return .blue
        case "export": return .green
        case "charge": return .yellow
        case "curtail": return .orange
        case "auto": return .gray
        default: return .gray
        }
    }
}

// MARK: - Action Detail Sheet (Multi-Inverter)
struct ActionDetailSheet: View {
    let action: InverterAction
    let siteInverters: [Inverter]
    let leadInverterId: Int?
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.dismiss) var dismiss
    
    @State private var allInverterActions: [Int: InverterAction] = [:]  // inverterId -> action
    @State private var isLoading = true
    @State private var selectedValuesAction: InverterAction?  // For values explorer
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header with timestamp and prices
                    headerSection
                    
                    Divider()
                    
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView("Loading inverter data...")
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    } else {
                        // Combined summary
                        combinedSummarySection
                        
                        Divider()
                        
                        // Individual inverter rows
                        individualInvertersSection
                        
                        Divider()
                        
                        // Reasons section
                        reasonsSection
                    }
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Action Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadAllInverterActions()
            }
        }
    }
    
    // MARK: - Header Section
    var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Timestamp
            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text(action.displayDateTime)
                    .font(.headline)
                Spacer()
            }
            
            // Prices (same for all inverters)
            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text("Buy")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(PriceFormat.formatFull(action.buyPrice ?? 0))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(PriceColors.buyColor(action.buyPrice ?? 0))
                }
                
                VStack(alignment: .leading) {
                    Text("Sell")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(PriceFormat.formatFull(action.sellPrice ?? 0))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(PriceColors.sellColor(action.sellPrice ?? 0))
                }
                
                Spacer()
            }
        }
    }
    
    // MARK: - Combined Summary Section
    var combinedSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                // Lead inverter action
                Text(leadAction.uppercased())
                    .font(.headline.weight(.bold))
                    .foregroundColor(actionColor(for: leadAction))
                
                // Power stats inline
                HStack(spacing: 8) {
                    // Lead inverter grid
                    HStack(spacing: 2) {
                        Text(isGridExporting ? "Export" : "Import")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", abs(calculatedGrid) / 1000))
                            .foregroundColor(isGridExporting ? .green : .blue)
                    }
                    
                    // Combined solar
                    HStack(spacing: 2) {
                        Text("Solar")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", combinedSolar / 1000))
                            .foregroundColor(.orange)
                    }
                    
                    // Combined battery
                    HStack(spacing: 2) {
                        Text(combinedBattery > 0 ? "Dchg" : "Chg")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", abs(combinedBattery) / 1000))
                            .foregroundColor(combinedBattery > 0 ? .orange : .green)
                    }
                    
                    // Combined home (adjusted for balance)
                    HStack(spacing: 2) {
                        Text("Home")
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", adjustedHome / 1000))
                            .foregroundColor(.purple)
                    }
                }
                .font(.subheadline)
                
                Spacer()
                
                // Combined SOC (weighted)
                Text(String(format: "%.0f%%", combinedSOC))
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.green)
            }
            
            // Energy balance row
            if abs(homeAdjustment) > 100 {  // Only show if significant (>100W)
                HStack(spacing: 8) {
                    Image(systemName: "plusminus")
                        .font(.caption)
                        .foregroundColor(.orange)
                    
                    Text("Balance")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(String(format: "%+.2f kW", homeAdjustment / 1000))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundColor(.orange)
                    
                    Spacer()
                    
                    Text(homeAdjustment > 0 ? "unmetered gen (added to Home)" : "unmetered load (added to Home)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 6)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
    
    // MARK: - Individual Inverters Section
    var individualInvertersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Raw Inverter Data")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            
            // Header row
            HStack(spacing: 0) {
                Text("Action")
                    .frame(width: 65, alignment: .leading)
                Text("SOC")
                    .frame(width: 45, alignment: .trailing)
                Text("Grid")
                    .frame(width: 50, alignment: .trailing)
                Text("Solar")
                    .frame(width: 50, alignment: .trailing)
                Text("Batt")
                    .frame(width: 50, alignment: .trailing)
                Text("Home")
                    .frame(width: 50, alignment: .trailing)
                Text("Inv")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2.weight(.medium))
            .foregroundColor(.secondary)
            
            // Inverter rows
            ForEach(sortedInverters, id: \.id) { inverter in
                inverterRow(for: inverter)
            }
        }
    }
    
    func inverterRow(for inverter: Inverter) -> some View {
        let invAction = allInverterActions[inverter.id] ?? action
        let isLead = inverter.id == leadInverterId
        let serial = String(inverter.serialNumber.suffix(4))

        // For non-lead inverters, try to get values from nestedInverterData
        let nestedData = invAction.nestedInverterData?[inverter.serialNumber]

        // Use nested data for non-lead inverters when available
        let displaySOC: Double? = isLead ? invAction.batterySoc : (nestedData?.batterySoc ?? invAction.batterySoc)
        let displayGrid: Double? = isLead ? invAction.gridPower : (nestedData?.gridPower ?? 0)  // Follower has no grid meter
        let displaySolar: Double? = isLead ? invAction.solarPower : (nestedData?.solarPower ?? invAction.solarPower)
        let displayBattery: Double? = isLead ? invAction.batteryPower : (nestedData?.batteryPower ?? invAction.batteryPower)
        let displayHome: Double? = isLead ? invAction.housePower : nil  // Only lead has meaningful home power

        return HStack(spacing: 0) {
            // Action
            Text(invAction.displayAction)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(actionColor(for: invAction.displayAction))
                .frame(width: 65, alignment: .leading)

            // SOC
            Text(displaySOC != nil ? String(format: "%.0f%%", displaySOC!) : "N/A")
                .font(.system(size: 16))
                .foregroundColor(.green)
                .frame(width: 48, alignment: .trailing)

            // Grid - only lead inverter has grid meter
            if isLead, let grid = displayGrid {
                Text(String(format: "%.1f", abs(grid) / 1000))
                    .font(.system(size: 16))
                    .foregroundColor(isGridExporting ? .green : .blue)
                    .frame(width: 52, alignment: .trailing)
            } else if !isLead {
                Text("–")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)
            } else {
                Text("N/A")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }

            // Solar
            if let solar = displaySolar {
                Text(String(format: "%.1f", solar / 1000))
                    .font(.system(size: 16))
                    .foregroundColor(.orange)
                    .frame(width: 52, alignment: .trailing)
            } else {
                Text("N/A")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }

            // Battery
            if let battery = displayBattery {
                Text(String(format: "%.1f", abs(battery) / 1000))
                    .font(.system(size: 16))
                    .foregroundColor(battery > 0 ? .orange : .green)
                    .frame(width: 52, alignment: .trailing)
            } else {
                Text("N/A")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }

            // Home - only lead inverter has meaningful home power
            if isLead, let home = displayHome {
                Text(String(format: "%.1f", home / 1000))
                    .font(.system(size: 16))
                    .foregroundColor(.purple)
                    .frame(width: 52, alignment: .trailing)
            } else if !isLead {
                Text("–")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)
            } else {
                Text("N/A")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            
            // Inverter identifier
            HStack(spacing: 2) {
                if isLead {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                }
                Text(serial)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
    
    // MARK: - Reasons Section
    var reasonsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Decision Reasons")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("Tap for details")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            ForEach(sortedInverters, id: \.id) { inverter in
                let invAction = allInverterActions[inverter.id] ?? action
                let serial = String(inverter.serialNumber.suffix(4))
                let isLead = inverter.id == leadInverterId
                
                Button(action: {
                    selectedValuesAction = invAction
                }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            if isLead {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                            }
                            Text(serial)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Text(invAction.reasonFull)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $selectedValuesAction) { action in
            if let valuesJSON = action.valuesJSON {
                ActionValuesExplorer(
                    valuesJSON: valuesJSON,
                    inverterSerial: siteInverters.first { $0.id == action.inverterId }?.serialNumber ?? "Unknown"
                )
            } else {
                VStack {
                    Text("No values data available")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    var sortedInverters: [Inverter] {
        siteInverters.sorted { inv1, inv2 in
            // Lead inverter first
            if inv1.id == leadInverterId { return true }
            if inv2.id == leadInverterId { return false }
            return inv1.serialNumber < inv2.serialNumber
        }
    }
    
    var leadAction: String {
        if let leadId = leadInverterId, let leadAct = allInverterActions[leadId] {
            return leadAct.displayAction
        }
        return action.displayAction
    }
    
    var combinedGrid: Double {
        var total: Double = 0
        for inverter in siteInverters {
            if let invAction = allInverterActions[inverter.id] {
                total += invAction.gridPower ?? 0
            }
        }
        return total != 0 ? total : (action.gridPower ?? 0)
    }
    
    // Physics-based grid direction calculation
    var calculatedGrid: Double {
        let expectedGrid = combinedSolar + combinedBattery - combinedHome
        let reportedGridAbs = abs(combinedGrid)
        let positiveError = abs(expectedGrid - reportedGridAbs)
        let negativeError = abs(expectedGrid - (-reportedGridAbs))
        return positiveError <= negativeError ? reportedGridAbs : -reportedGridAbs
    }
    
    var isGridExporting: Bool {
        calculatedGrid > 0  // positive = export, negative = import
    }
    
    var homeAdjustment: Double {
        let expectedGrid = combinedSolar + combinedBattery - combinedHome
        return calculatedGrid - expectedGrid
    }
    
    var adjustedHome: Double {
        combinedHome + homeAdjustment
    }
    
    var combinedSOC: Double {
        // Weighted average by battery capacity
        var totalCapacity: Double = 0
        var weightedSOC: Double = 0
        
        for inverter in siteInverters {
            let capacity = Double(inverter.batteryCapacity ?? 0)
            let soc: Double
            if let invAction = allInverterActions[inverter.id] {
                soc = invAction.batterySoc ?? 0
            } else if inverter.id == (siteInverters.first { allInverterActions[$0.id] != nil }?.id ?? 0) {
                soc = action.batterySoc ?? 0
            } else {
                continue
            }
            totalCapacity += capacity
            weightedSOC += soc * capacity
        }
        
        return totalCapacity > 0 ? weightedSOC / totalCapacity : (action.batterySoc ?? 0)
    }
    
    var combinedSolar: Double {
        var total: Double = 0
        for inverter in siteInverters {
            if let invAction = allInverterActions[inverter.id] {
                total += invAction.solarPower ?? 0
            }
        }
        return total > 0 ? total : (action.solarPower ?? 0)
    }
    
    var combinedBattery: Double {
        var total: Double = 0
        for inverter in siteInverters {
            if let invAction = allInverterActions[inverter.id] {
                total += invAction.batteryPower ?? 0
            }
        }
        return total != 0 ? total : (action.batteryPower ?? 0)
    }
    
    var combinedHome: Double {
        // House power is calculated per-inverter - sum them for total
        var total: Double = 0
        for inverter in siteInverters {
            if let invAction = allInverterActions[inverter.id] {
                total += invAction.housePower ?? 0
            }
        }
        return total != 0 ? total : (action.housePower ?? 0)
    }
    
    func actionColor(for actionStr: String) -> Color {
        switch actionStr.lowercased() {
        case "import": return .blue
        case "export": return .green
        case "charge": return .yellow
        case "curtail": return .orange
        case "auto": return .gray
        default: return .gray
        }
    }
    
    // MARK: - Data Loading
    func loadAllInverterActions() async {
        guard let actionDate = action.date else {
            isLoading = false
            return
        }
        
        guard let siteId = api.selectedSiteId else {
            isLoading = false
            return
        }
        
        // Fetch actions for all inverters using cache-through
        // Finalized data (>7 days old) served from SQLite without API calls
        var results: [Int: InverterAction] = [:]
        let dataStore = PowstonDataStore.shared
        
        for inverter in siteInverters {
            let actionRecords = await dataStore.fetchActionsForDay(
                siteId: siteId,
                inverterId: inverter.id,
                date: actionDate
            )
            
            // Convert to InverterAction and find matching timestamp
            let actions = actionRecords.map { $0.toInverterAction() }
            if let matching = actions.first(where: { $0.date == actionDate }) {
                results[inverter.id] = matching
            }
        }
        
        await MainActor.run {
            allInverterActions = results
            isLoading = false
        }
    }
}


// MARK: - Actions Date Picker Sheet
struct ActionsDatePickerSheet: View {
    @Binding var selectedDate: Date
    let onDismiss: () -> Void
    
    var body: some View {
        NavigationStack {
            DatePicker(
                "Select Date",
                selection: $selectedDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("Select Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ActionsTableView()
        .environmentObject(PowstonAPI())
}
