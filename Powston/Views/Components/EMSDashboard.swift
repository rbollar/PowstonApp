//
//  EMSDashboard.swift
//  Powston
//
//  Card-based EMS dashboard style
//

import SwiftUI

struct EMSDashboard: View {
    let data: InverterResponse
    let sites: [Site]
    @EnvironmentObject var api: PowstonAPI
    @State private var analyticsTab: AnalyticsTab = .powerFlow
    
    enum AnalyticsTab: String, CaseIterable {
        case powerFlow = "Power Flow"
        case costs = "Costs"
        case battery = "Battery"
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Card 1: Overview
            overviewCard
            
            // Card 2: System Control
            systemControlCard
            
            // Card 3: Financials
            financialsCard
            
            // Card 4: Battery Status
            batteryStatusCard
        }
        .padding(.horizontal)
    }
    
    // MARK: - Overview Card
    @ViewBuilder
    var overviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Overview")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                // Mode badge
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                    Text(displayAction(data.currentAction).uppercased())
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            
            // 2x2 Grid of stats
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                EMSStatCell(
                    icon: "sun.max.fill",
                    iconColor: .yellow,
                    value: String(format: "%.1f", data.solarKw),
                    label: "Solar (kW)"
                )
                EMSStatCell(
                    icon: "house.fill",
                    iconColor: .blue,
                    value: String(format: "%.1f", data.houseKw),
                    label: "Home (kW)"
                )
                EMSStatCell(
                    icon: "bolt.fill",
                    iconColor: data.gridKw > 0 ? .blue : .green,
                    value: String(format: "%.1f", abs(data.gridKw)),
                    label: data.gridKw > 0 ? "Import (kW)" : "Export (kW)"
                )
                EMSStatCell(
                    icon: data.isCharging ? "battery.100.bolt" : "battery.75",
                    iconColor: data.isCharging ? .green : .orange,
                    value: String(format: "%.1f", abs(data.batteryKw)),
                    label: data.isCharging ? "Charge (kW)" : "Discharge (kW)"
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }
    
    // MARK: - System Control Card
    @ViewBuilder
    var systemControlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Control")
                .font(.headline)
                .fontWeight(.semibold)
            
            // Mode selector pills
            HStack(spacing: 8) {
                ForEach(["Auto", "Eco", "Max", "Set"], id: \.self) { mode in
                    let isSelected = displayAction(data.currentAction) == mode || 
                        (mode == "Auto" && ["Auto", "Hold"].contains(displayAction(data.currentAction)))
                    
                    Text(mode)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundColor(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(isSelected ? Color.gray.opacity(0.15) : Color.clear)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2), lineWidth: isSelected ? 0 : 1)
                        )
                }
            }
            
            // Adjust Schedule button
            NavigationLink(destination: ManualOverrideView()) {
                Text("Adjust Schedule")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.black)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }
    
    // MARK: - Financials Card
    @ViewBuilder
    var financialsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Financials")
                .font(.headline)
                .fontWeight(.semibold)
            
            // Buy / Sell prices
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Buy Price")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f¢", data.buyPrice ?? 0))
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Sell Price")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f¢", data.sellPrice ?? 0))
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(data.sellPrice ?? 0 < 0 ? .red : .green)
                }
            }
            
            // P&L tiles
            HStack(spacing: 12) {
                EMSPLTile(label: "Today", period: .today)
                EMSPLTile(label: "Week", period: .week)
                EMSPLTile(label: "Month", period: .month)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }
    
    // MARK: - Battery Status Card
    @ViewBuilder
    var batteryStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Battery Status")
                .font(.headline)
                .fontWeight(.semibold)
            
            HStack(spacing: 20) {
                // SOC Ring
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.2), lineWidth: 10)
                            .frame(width: 100, height: 100)
                        Circle()
                            .trim(from: 0, to: (data.batterySoc ?? 0) / 100)
                            .stroke(
                                socColor(data.batterySoc ?? 0),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .frame(width: 100, height: 100)
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(Int(data.batterySoc ?? 0))")
                                .font(.title)
                                .fontWeight(.bold)
                            + Text("%")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("SOC")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Charging badge
                    Text(data.isCharging ? "Charging" : "Discharging")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(data.isCharging ? .green : .orange)
                }
                
                Spacer()
                
                // Stats
                VStack(alignment: .leading, spacing: 12) {
                    EMSBatteryStatRow(label: "Capacity", value: formatCapacity())
                    EMSBatteryStatRow(label: "Current Power", value: String(format: "%.1f kW", abs(data.batteryKw)))
                    EMSBatteryStatRow(label: "Time to \(data.isCharging ? "Full" : "Empty")", value: estimateTimeRemaining())
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }
    
    // MARK: - Helpers
    
    func displayAction(_ action: String) -> String {
        let lower = action.lowercased()
        if lower.contains("curtail") { return "Curtail" }
        else if lower.contains("export") { return "Export" }
        else if lower.contains("import") { return "Import" }
        else if lower.contains("charge") { return "Charge" }
        else if lower.contains("discharge") { return "Discharge" }
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
        if let site = sites.first, let capacity = site.installedBattery {
            return String(format: "%.1f kWh", Double(capacity) / 1000)
        }
        return "—"
    }
    
    func estimateTimeRemaining() -> String {
        guard abs(data.batteryKw) > 0.1,
              let site = sites.first,
              let capacityWh = site.installedBattery else {
            return "—"
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
}

// MARK: - EMS Stat Cell
struct EMSStatCell: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(iconColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
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
                    Text("—")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.gray.opacity(0.08))
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
        
        let today = calendar.startOfDay(for: Date())
        let fromDate: Date
        let toDate = today
        
        switch period {
        case .today:
            fromDate = today
        case .week:
            fromDate = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        case .month:
            fromDate = calendar.date(byAdding: .day, value: -30, to: today) ?? today
        }
        
        let records = await api.fetchMeterRecords(fromDate: fromDate, toDate: toDate)
        
        await MainActor.run {
            if !records.isEmpty {
                let earnings = records.compactMap { $0.earnings }.reduce(0, +) / 100.0
                let costs = records.compactMap { $0.costs }.reduce(0, +) / 100.0
                netValue = earnings - costs
            }
            isLoading = false
        }
    }
    
    func formatCurrency(_ value: Double) -> String {
        let absValue = abs(value)
        let prefix = value >= 0 ? "+$" : "-$"
        return prefix + String(format: "%.2f", absValue)
    }
}

// MARK: - EMS Battery Stat Row
struct EMSBatteryStatRow: View {
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
                .fontWeight(.medium)
        }
    }
}
