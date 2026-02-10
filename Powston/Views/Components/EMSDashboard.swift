//
//  EMSDashboard.swift
//  Powston
//
//  Card-based EMS dashboard style - matching Powston web design
//

import SwiftUI

struct EMSDashboard: View {
    let data: InverterResponse
    @EnvironmentObject var api: PowstonAPI
    
    var body: some View {
        VStack(spacing: 16) {
            // Card 1: Power Flows
            powerFlowsCard
            
            // Card 2: Battery Status
            batteryStatusCard
            
            // Card 3: Financials
            financialsCard
        }
        .padding(.horizontal)
    }
    
    // MARK: - Power Flows Card
    @ViewBuilder
    var powerFlowsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Text("Power Flows")
                        .font(.title3)
                        .fontWeight(.semibold)
                    if let intervalTime = data.intervalTime {
                        Text("• \(formatIntervalTime(intervalTime))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                // Mode badge - tappable to go to controls
                NavigationLink(destination: ManualOverrideView()) {
                    HStack(spacing: 6) {
                        if api.hasPendingOverride {
                            ProgressView()
                                .controlSize(.mini)
                            Text("PENDING")
                                .font(.caption)
                                .fontWeight(.medium)
                        } else if api.hasActiveOverride, let firstActive = api.currentOverrides.first {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                            Text("MANUAL: \(firstActive.action.uppercased())")
                                .font(.caption)
                                .fontWeight(.medium)
                        } else if api.hasScheduledOverride, let firstScheduled = api.scheduledOverrides.first {
                            Image(systemName: "clock.fill")
                                .font(.caption)
                            Text("SCHED: \(firstScheduled.action.uppercased()) \(firstScheduled.formattedStartsIn)")
                                .font(.caption)
                                .fontWeight(.medium)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption)
                            Text(displayAction(data.currentAction).uppercased() + " MODE")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(api.hasActiveOverride ? .orange : ((api.hasPendingOverride || api.hasScheduledOverride) ? .blue : .secondary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(api.hasActiveOverride ? Color.orange.opacity(0.15) : ((api.hasPendingOverride || api.hasScheduledOverride) ? Color.blue.opacity(0.15) : Color(.systemGray6)))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(modeBadgeAccessibilityLabel)
                .accessibilityHint("Double tap to open manual controls")
            }
            
            // 2x2 Grid of stats
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 20) {
                PowerFlowCell(
                    icon: "sun.max.fill",
                    iconBackground: .yellow.opacity(0.15),
                    iconColor: .yellow,
                    value: data.solarKw,
                    label: "Solar (kW)",
                    onTap: { TabSelection.shared.selectedTab = .decisions }
                )
                .accessibilityLabel("Solar power: \(String(format: "%.1f", data.solarKw)) kilowatts")
                
                PowerFlowCell(
                    icon: "house.fill",
                    iconBackground: .purple.opacity(0.15),
                    iconColor: .purple,
                    value: data.displayHouseKw,
                    label: "Home (kW)",
                    showBadge: data.hasSignificantImbalance,
                    onTap: { TabSelection.shared.selectedTab = .decisions }
                )
                .accessibilityLabel("Home consumption: \(String(format: "%.1f", data.displayHouseKw)) kilowatts")
                
                PowerFlowCell(
                    icon: "bolt.fill",
                    iconBackground: (data.isGridExporting ? Color.green : Color.blue).opacity(0.15),
                    iconColor: data.isGridExporting ? .green : .blue,
                    value: abs(data.gridKw),
                    label: data.isGridExporting ? "Export (kW)" : "Import (kW)",
                    onTap: { TabSelection.shared.selectedTab = .decisions }
                )
                .accessibilityLabel("Grid \(data.isGridExporting ? "export" : "import"): \(String(format: "%.1f", abs(data.gridKw))) kilowatts")
                
                PowerFlowCell(
                    icon: "battery.100.bolt",
                    iconBackground: (data.isCharging ? Color.green : Color.orange).opacity(0.15),
                    iconColor: data.isCharging ? .green : .orange,
                    value: abs(data.batteryKw),
                    label: data.isCharging ? "Charge (kW)" : "Discharge (kW)",
                    onTap: { TabSelection.shared.selectedTab = .decisions }
                )
                .accessibilityLabel("Battery \(data.isCharging ? "charging" : "discharging"): \(String(format: "%.1f", abs(data.batteryKw))) kilowatts")
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Power Flows")
    }
    
    var modeBadgeAccessibilityLabel: String {
        if api.hasPendingOverride {
            return "Override pending"
        } else if api.hasActiveOverride, let firstActive = api.currentOverrides.first {
            return "Manual override active: \(firstActive.action)"
        } else if api.hasScheduledOverride, let firstScheduled = api.scheduledOverrides.first {
            return "Scheduled override: \(firstScheduled.action), starts \(firstScheduled.formattedStartsIn)"
        } else {
            return "Current mode: \(displayAction(data.currentAction))"
        }
    }
    
    // MARK: - Battery Status Card
    @ViewBuilder
    var batteryStatusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Battery Status")
                .font(.title3)
                .fontWeight(.semibold)
            
            HStack(alignment: .center, spacing: 24) {
                // Left: SOC Ring
                VStack(spacing: 12) {
                    ZStack {
                        // Background track
                        Circle()
                            .stroke(Color(.systemGray5), lineWidth: 10)
                            .frame(width: 110, height: 110)
                        
                        // Progress arc
                        Circle()
                            .trim(from: 0, to: (data.batterySoc ?? 0) / 100)
                            .stroke(
                                socColor(data.batterySoc ?? 0),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .frame(width: 110, height: 110)
                            .rotationEffect(.degrees(-90))
                        
                        // Center text
                        VStack(spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text("\(Int(data.batterySoc ?? 0))")
                                    .font(.system(size: 32, weight: .bold))
                                Text("%")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            Text("SOC")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Battery state of charge: \(Int(data.batterySoc ?? 0)) percent")
                    
                    // Charging/Discharging badge
                    Text(data.isCharging ? "Charging" : "Discharging")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(data.isCharging ? .green : .orange)
                        .accessibilityLabel("Battery is \(data.isCharging ? "charging" : "discharging")")
                }
                
                // Right: Stats
                VStack(alignment: .leading, spacing: 14) {
                    BatteryStatRow(label: "Capacity", value: formatCapacity())
                        .accessibilityLabel("Battery capacity: \(formatCapacity())")
                    BatteryStatRow(label: "Current Power", value: String(format: "%.1f kW", abs(data.batteryKw)))
                        .accessibilityLabel("Current power: \(String(format: "%.1f", abs(data.batteryKw))) kilowatts")
                    BatteryStatRow(label: "Time to \(data.isCharging ? "Full" : "Empty")", value: estimateTimeRemaining())
                        .accessibilityLabel("Time to \(data.isCharging ? "full" : "empty"): \(estimateTimeRemaining())")
                }
                
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Battery Status")
    }
    
    // MARK: - Financials Card
    @ViewBuilder
    var financialsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pricing")
                .font(.title3)
                .fontWeight(.semibold)
            
            // Buy / Sell prices in a row
            HStack(spacing: 16) {
                // Buy price
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(PriceColors.buyColor(data.buyPrice ?? 0).opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(PriceColors.buyColor(data.buyPrice ?? 0))
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Buy")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(PriceFormat.format(data.buyPrice ?? 0))
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(PriceColors.buyColor(data.buyPrice ?? 0))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Buy price: \(PriceFormat.format(data.buyPrice ?? 0)) per kilowatt hour")
                
                Spacer()
                
                // Sell price
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(PriceColors.sellColor(data.sellPrice ?? 0).opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(PriceColors.sellColor(data.sellPrice ?? 0))
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sell")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(PriceFormat.format(data.sellPrice ?? 0))
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(PriceColors.sellColor(data.sellPrice ?? 0))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sell price: \(PriceFormat.format(data.sellPrice ?? 0)) per kilowatt hour")
                
                Spacer()
            }
            
            Divider()
                .accessibilityHidden(true)
            
            // P&L summary row (yesterday, last 7 days, last 30 days)
            HStack(spacing: 12) {
                EMSPLTile(label: "Yesterday", period: .today)
                EMSPLTile(label: "7 Days", period: .week)
                EMSPLTile(label: "30 Days", period: .month)
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pricing")
    }
    
    // MARK: - Helpers
    
    func displayAction(_ action: String) -> String {
        let lower = action.lowercased()
        if lower.contains("curtail") { return "Curtail" }
        else if lower.contains("export") { return "Export" }
        else if lower.contains("import") { return "Import" }
        else if lower.contains("discharge") { return "Discharge" }
        else if lower.contains("charge") { return "Charge" }
        else if lower.contains("auto") || lower.contains("hold") { return "Auto" }
        return action
    }
    
    func socColor(_ soc: Double) -> Color {
        if soc >= 80 { return .green }
        else if soc >= 40 { return .yellow }
        else if soc >= 20 { return .orange }
        else { return .red }
    }
    
    func formatCapacity() -> String {
        // Sum battery capacity from all inverters for this site
        if let siteId = api.selectedSiteId {
            let siteInverters = api.inverters.filter { $0.siteId == siteId }
            let totalCapacityWh = siteInverters.compactMap { $0.batteryCapacity }.reduce(0, +)
            if totalCapacityWh > 0 {
                return String(format: "%.1f kWh", Double(totalCapacityWh) / 1000)
            }
        }
        // Fallback to site-level field
        if let site = api.selectedSite, let capacity = site.installedBattery {
            return String(format: "%.1f kWh", Double(capacity) / 1000)
        }
        return "–"
    }
    
    func estimateTimeRemaining() -> String {
        guard abs(data.batteryKw) > 0.1,
              let site = api.selectedSite,
              let capacityWh = site.installedBattery else {
            return "–"
        }
        
        let capacityKwh = Double(capacityWh) / 1000
        let currentSoc = data.batterySoc ?? 0
        let powerKw = abs(data.batteryKw)
        
        let remainingKwh: Double
        if data.isCharging {
            remainingKwh = capacityKwh * (100 - currentSoc) / 100
        } else {
            remainingKwh = capacityKwh * currentSoc / 100
        }
        
        let hours = remainingKwh / powerKw
        
        if hours < 1 {
            return String(format: "%.0fm", hours * 60)
        } else if hours < 24 {
            let h = Int(hours)
            let m = Int((hours - Double(h)) * 60)
            return "\(h)h \(m)m"
        } else {
            return "> 24h"
        }
    }
    
    func formatIntervalTime(_ str: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: str) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            timeFormatter.timeZone = powstonTimezone()
            return timeFormatter.string(from: date)
        }
        
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: str) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            timeFormatter.timeZone = powstonTimezone()
            return timeFormatter.string(from: date)
        }
        
        return str
    }
}

// MARK: - Power Flow Cell
struct PowerFlowCell: View {
    let icon: String
    let iconBackground: Color
    let iconColor: Color
    let value: Double
    let label: String
    var showBadge: Bool = false
    var onTap: (() -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon in colored background
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconBackground)
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(iconColor)
                }
                
                if showBadge {
                    Image(systemName: "plusminus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .offset(x: 4, y: -4)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f", value))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(String(format: "%.1f", value))\(showBadge ? ", includes unmetered load" : "")")
    }
}

// MARK: - Battery Stat Row
struct BatteryStatRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }
}

// MARK: - EMS P&L Tile
struct EMSPLTile: View {
    let label: String
    let period: PLPeriod
    
    @EnvironmentObject var api: PowstonAPI
    @State private var netValue: Double?
    @State private var isLoading = false
    
    enum PLPeriod {
        case today, week, month
    }
    
    var body: some View {
        Button(action: {
            TabSelection.shared.selectedTab = .history
        }) {
            VStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(height: 24)
                } else if let net = netValue {
                    Text(formatCurrency(net))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(net >= 0 ? .green : .red)
                } else {
                    Text("–")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.systemGray6))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .task {
            await loadPL()
        }
    }
    
    func loadPL() async {
        guard !api.isDemoMode else {
            switch period {
            case .today: netValue = -0.91
            case .week: netValue = -4.20
            case .month: netValue = -12.50
            }
            return
        }
        
        isLoading = true
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        // Use yesterday as the reference point (last complete day)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        
        switch period {
        case .today:
            // Yesterday (last complete day) - use day_rates API
            if let summary = await api.fetchDaySummary(date: yesterday) {
                await MainActor.run {
                    netValue = summary.earningsDollars - summary.costsDollars
                    isLoading = false
                }
            } else {
                await MainActor.run { isLoading = false }
            }
            
        case .week:
            // Last 7 complete days ending yesterday - use week breakdown
            let weekData = await api.fetchWeekDailyBreakdown(containing: yesterday)
            await MainActor.run {
                if !weekData.isEmpty {
                    let earnings = weekData.reduce(0) { $0 + $1.earningsDollars }
                    let costs = weekData.reduce(0) { $0 + $1.costsDollars }
                    netValue = earnings - costs
                }
                isLoading = false
            }
            
        case .month:
            // Last 30 complete days ending yesterday - use custom range summary
            let startDate = calendar.date(byAdding: .day, value: -29, to: yesterday) ?? yesterday
            if let summary = await api.fetchCustomRangeSummary(startDate: startDate, endDate: yesterday) {
                await MainActor.run {
                    netValue = summary.earningsDollars - summary.costsDollars
                    isLoading = false
                }
            } else {
                await MainActor.run { isLoading = false }
            }
        }
    }
    
    func formatCurrency(_ value: Double) -> String {
        let absValue = abs(value)
        return String(format: "$%.2f", absValue)
    }
}
