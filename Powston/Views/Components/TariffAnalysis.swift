//
//  TariffAnalysis.swift
//  Powston
//
//  Tariff period analysis based on InverterAction data
//  Inspired by Powston web UI rates/tariff view
//

import SwiftUI

// MARK: - Tariff Period Definition

enum TariffPeriod: String, CaseIterable, Identifiable {
    case evening = "Evening"
    case overnight = "Overnight"
    case day = "Day"
    
    var id: String { rawValue }
    
    var color: Color {
        switch self {
        case .evening: return .red
        case .overnight: return .blue
        case .day: return .green
        }
    }
    
    var icon: String {
        switch self {
        case .evening: return "sunset.fill"
        case .overnight: return "moon.stars.fill"
        case .day: return "sun.max.fill"
        }
    }
    
    /// Determine tariff period for a given hour (0-23)
    /// Uses user's peak settings: Evening = peakStart→21:00, Overnight = 21:00→11:00, Day = 11:00→peakStart
    static func forHour(_ hour: Int, peakStartHour: Double) -> TariffPeriod {
        let peakStart = Int(peakStartHour)
        
        // Evening: peakStart (e.g., 16) to 21 (9pm)
        if hour >= peakStart && hour < 21 {
            return .evening
        }
        // Overnight: 21 (9pm) to 11 (11am) - crosses midnight
        if hour >= 21 || hour < 11 {
            return .overnight
        }
        // Day: 11 (11am) to peakStart
        return .day
    }
    
    /// Time range description
    func timeRange(peakStartHour: Double) -> String {
        let peakStart = Int(peakStartHour)
        switch self {
        case .evening: return "\(formatHour(peakStart)) – 9pm"
        case .overnight: return "9pm – 11am"
        case .day: return "11am – \(formatHour(peakStart))"
        }
    }
    
    private func formatHour(_ hour: Int) -> String {
        if hour == 0 { return "12am" }
        if hour == 12 { return "12pm" }
        if hour < 12 { return "\(hour)am" }
        return "\(hour - 12)pm"
    }
}

// MARK: - Tariff Period Summary

struct TariffPeriodSummary: Identifiable {
    let id = UUID()
    let period: TariffPeriod
    let peakStartHour: Double
    
    // Energy totals (kWh)
    var importKWh: Double = 0
    var exportKWh: Double = 0
    
    // Financial totals ($)
    var costs: Double = 0
    var earnings: Double = 0
    
    // Rate averages (¢/kWh) - weighted by energy volume
    var avgBuyRate: Double = 0
    var avgSellRate: Double = 0
    
    // Action counts
    var actionCount: Int = 0
    
    var netValue: Double { earnings - costs }
    
    var timeRange: String { period.timeRange(peakStartHour: peakStartHour) }
    
    /// Build summaries from InverterAction array
    static func fromActions(_ actions: [InverterAction], peakStartHour: Double) -> [TariffPeriodSummary] {
        var summaries: [TariffPeriod: TariffPeriodSummary] = [:]
        
        // Initialize all periods
        for period in TariffPeriod.allCases {
            summaries[period] = TariffPeriodSummary(period: period, peakStartHour: peakStartHour)
        }
        
        // Accumulators for weighted averages
        var buyRateSum: [TariffPeriod: Double] = [:]
        var sellRateSum: [TariffPeriod: Double] = [:]
        var importVolume: [TariffPeriod: Double] = [:]
        var exportVolume: [TariffPeriod: Double] = [:]
        
        for action in actions {
            guard let date = action.date else { continue }
            
            // Get hour in site timezone
            var calendar = Calendar.current
            calendar.timeZone = powstonTimezone()
            let hour = calendar.component(.hour, from: date)
            
            let period = TariffPeriod.forHour(hour, peakStartHour: peakStartHour)
            
            // Calculate energy for this 5-minute interval
            // gridPower is in Watts, interval is 5 minutes
            // kWh = W * (5/60) / 1000
            let intervalHours = 5.0 / 60.0
            let gridPower = action.gridPower ?? 0
            
            // Positive gridPower = export, negative = import (based on ActionsTableView convention)
            // But need to verify - some systems are opposite
            let intervalKWh = abs(gridPower) * intervalHours / 1000.0
            
            let buyPrice = action.buyPrice ?? 0
            let sellPrice = action.sellPrice ?? 0
            
            if gridPower < 0 {
                // Importing from grid
                summaries[period]?.importKWh += intervalKWh
                summaries[period]?.costs += intervalKWh * buyPrice / 100.0  // ¢ to $
                
                // Track for weighted average
                importVolume[period, default: 0] += intervalKWh
                buyRateSum[period, default: 0] += buyPrice * intervalKWh
            } else if gridPower > 0 {
                // Exporting to grid
                summaries[period]?.exportKWh += intervalKWh
                summaries[period]?.earnings += intervalKWh * sellPrice / 100.0  // ¢ to $
                
                // Track for weighted average
                exportVolume[period, default: 0] += intervalKWh
                sellRateSum[period, default: 0] += sellPrice * intervalKWh
            }
            
            summaries[period]?.actionCount += 1
        }
        
        // Calculate weighted average rates
        for period in TariffPeriod.allCases {
            if let impVol = importVolume[period], impVol > 0 {
                summaries[period]?.avgBuyRate = (buyRateSum[period] ?? 0) / impVol
            }
            if let expVol = exportVolume[period], expVol > 0 {
                summaries[period]?.avgSellRate = (sellRateSum[period] ?? 0) / expVol
            }
        }
        
        // Return in display order: Evening, Overnight, Day
        return TariffPeriod.allCases.compactMap { summaries[$0] }
    }
}

// MARK: - Tariff Analysis Section (for HistoryView)

struct TariffAnalysisSection: View {
    let actions: [InverterAction]
    let peakStartHour: Double
    @State private var isExpanded = false
    
    var summaries: [TariffPeriodSummary] {
        TariffPeriodSummary.fromActions(actions, peakStartHour: peakStartHour)
    }
    
    var totalEarnings: Double {
        summaries.reduce(0) { $0 + $1.earnings }
    }
    
    var totalCosts: Double {
        summaries.reduce(0) { $0 + $1.costs }
    }
    
    var netValue: Double {
        totalEarnings - totalCosts
    }
    
    var hasData: Bool {
        summaries.contains { $0.importKWh > 0 || $0.exportKWh > 0 }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Tariff Periods")
                    .font(.headline)
                Spacer()
                if hasData {
                    Text(String(format: "Net: %@$%.2f", netValue >= 0 ? "+" : "", abs(netValue)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(netValue >= 0 ? .green : .red)
                }
            }
            
            if hasData {
                // Period cards (horizontal scroll on iPhone, fit on iPad)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(summaries) { summary in
                            TariffPeriodCard(summary: summary)
                        }
                    }
                    .padding(.horizontal, 1) // Prevent clipping
                }
                
                // Expandable breakdown
                DisclosureGroup(isExpanded: $isExpanded) {
                    TariffBreakdownTable(summaries: summaries)
                        .padding(.top, 8)
                } label: {
                    Text("Show breakdown")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
            } else {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("No grid activity data for tariff analysis")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Tariff Period Card

struct TariffPeriodCard: View {
    let summary: TariffPeriodSummary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with period name and icon
            HStack {
                Image(systemName: summary.period.icon)
                    .foregroundColor(summary.period.color)
                Text(summary.period.rawValue)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if summary.avgSellRate > 0 {
                    Text(String(format: "%.1f¢", summary.avgSellRate))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            
            // Time range
            Text(summary.timeRange)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            // Import/Export
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f kWh", summary.importKWh))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.blue)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f kWh", summary.exportKWh))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.green)
                }
            }
            
            // Cost/Earnings
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cost")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "$%.2f", summary.costs))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.red)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Earn")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "$%.2f", summary.earnings))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.green)
                }
            }
        }
        .padding(12)
        .frame(width: 140)
        .background(summary.period.color.opacity(0.08))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(summary.period.color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Tariff Breakdown Table

struct TariffBreakdownTable: View {
    let summaries: [TariffPeriodSummary]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                Text("Period")
                    .frame(width: 70, alignment: .leading)
                Text("Import")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("Export")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("Buy ¢")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("Sell ¢")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("Net")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
            
            Divider()
            
            // Data rows
            ForEach(summaries) { summary in
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(summary.period.color)
                            .frame(width: 8, height: 8)
                        Text(summary.period.rawValue)
                    }
                    .frame(width: 70, alignment: .leading)
                    
                    Text(String(format: "%.1f", summary.importKWh))
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    
                    Text(String(format: "%.1f", summary.exportKWh))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    
                    Text(summary.avgBuyRate > 0 ? String(format: "%.1f", summary.avgBuyRate) : "–")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    
                    Text(summary.avgSellRate > 0 ? String(format: "%.1f", summary.avgSellRate) : "–")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    
                    Text(String(format: "%@$%.2f", summary.netValue >= 0 ? "+" : "", abs(summary.netValue)))
                        .foregroundColor(summary.netValue >= 0 ? .green : .red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .padding(.vertical, 6)
                
                Divider()
            }
            
            // Totals row
            HStack(spacing: 0) {
                Text("Total")
                    .fontWeight(.semibold)
                    .frame(width: 70, alignment: .leading)
                
                Text(String(format: "%.1f", summaries.reduce(0) { $0 + $1.importKWh }))
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                
                Text(String(format: "%.1f", summaries.reduce(0) { $0 + $1.exportKWh }))
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                
                Text("–")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                
                Text("–")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                
                let totalNet = summaries.reduce(0) { $0 + $1.netValue }
                Text(String(format: "%@$%.2f", totalNet >= 0 ? "+" : "", abs(totalNet)))
                    .foregroundColor(totalNet >= 0 ? .green : .red)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Bar Chart for Period Comparison

struct TariffPeriodBarChart: View {
    let summaries: [TariffPeriodSummary]
    
    var maxEnergy: Double {
        let maxImport = summaries.map { $0.importKWh }.max() ?? 1
        let maxExport = summaries.map { $0.exportKWh }.max() ?? 1
        return max(maxImport, maxExport, 1)
    }
    
    var body: some View {
        HStack(spacing: 16) {
            ForEach(summaries) { summary in
                VStack(spacing: 4) {
                    // Bars
                    HStack(alignment: .bottom, spacing: 4) {
                        // Import bar
                        VStack {
                            Spacer()
                            Rectangle()
                                .fill(Color.blue.opacity(0.7))
                                .frame(width: 20, height: max(4, CGFloat(summary.importKWh / maxEnergy) * 80))
                        }
                        .frame(height: 80)
                        
                        // Export bar
                        VStack {
                            Spacer()
                            Rectangle()
                                .fill(Color.orange.opacity(0.7))
                                .frame(width: 20, height: max(4, CGFloat(summary.exportKWh / maxEnergy) * 80))
                        }
                        .frame(height: 80)
                    }
                    
                    // Label
                    Text(summary.period.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    // Create mock actions for preview
    let mockActions: [InverterAction] = []
    
    ScrollView {
        VStack(spacing: 20) {
            TariffAnalysisSection(
                actions: mockActions,
                peakStartHour: 16.0
            )
            .padding()
        }
    }
}
