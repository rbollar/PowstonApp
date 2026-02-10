//
//  TariffAnalysis.swift
//  Powston
//
//  Tariff period analysis components:
//  - TariffPeriodSection: Uses tariff_rates API data (preferred)
//  - TariffAnalysisSection: Uses MeterRecord data (fallback)
//

import SwiftUI

// MARK: - Tariff Period Section (API-based)

/// Displays tariff period analysis using data from the tariff_rates API endpoint
/// Portrait: Compact pills with period name, time range, and net P&L
/// Landscape: Full breakdown table with import/export/cost/earnings/rates
struct TariffPeriodSection: View {
    let periods: [TariffPeriodPerformance]
    let definitions: [TariffPeriodDefinition]
    let isLandscape: Bool
    
    @State private var isExpanded = false
    
    var totalNet: Double {
        periods.reduce(0) { $0 + $1.netDollars }
    }
    
    var hasData: Bool {
        periods.contains { $0.energyImport > 0 || $0.energyExport > 0 || $0.costs > 0 || $0.earnings > 0 }
    }
    
    /// Get time range string for a period from definitions
    func timeRange(for periodName: String) -> String {
        if let def = definitions.first(where: { $0.periodName.lowercased() == periodName.lowercased() }) {
            return def.timeRange
        }
        return ""
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Tariff Periods")
                    .font(.headline)
                Spacer()
                if hasData {
                    Text(String(format: "Net: %@$%.2f", totalNet >= 0 ? "+" : "", abs(totalNet)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(totalNet >= 0 ? .green : .red)
                }
            }
            
            if hasData {
                if isLandscape {
                    // Full breakdown table in landscape
                    TariffPeriodTable(periods: periods, definitions: definitions)
                } else {
                    // Compact pills in portrait
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(periods, id: \.periodName) { period in
                                TariffPeriodPill(
                                    period: period,
                                    timeRange: timeRange(for: period.periodName)
                                )
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                    
                    // Expandable breakdown
                    DisclosureGroup(isExpanded: $isExpanded) {
                        TariffPeriodTable(periods: periods, definitions: definitions)
                            .padding(.top, 8)
                    } label: {
                        Text("Show breakdown")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("No tariff data for this period")
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

// MARK: - Tariff Period Pill (Compact)

struct TariffPeriodPill: View {
    let period: TariffPeriodPerformance
    let timeRange: String
    
    var netValue: Double {
        period.netDollars
    }
    
    var periodColor: Color {
        switch period.periodName.lowercased() {
        case "peak", "evening": return .red
        case "offpeak", "overnight", "off-peak": return .blue
        case "shoulder", "day": return .green
        default: return .gray
        }
    }
    
    var periodIcon: String {
        switch period.periodName.lowercased() {
        case "peak", "evening": return "sunset.fill"
        case "offpeak", "overnight", "off-peak": return "moon.stars.fill"
        case "shoulder", "day": return "sun.max.fill"
        default: return "clock.fill"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Image(systemName: periodIcon)
                    .foregroundColor(periodColor)
                Text(period.periodName.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            
            // Time range
            if !timeRange.isEmpty {
                Text(timeRange)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Divider()
            
            // Net value (primary display)
            Text(String(format: "%@$%.2f", netValue >= 0 ? "+" : "", abs(netValue)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundColor(netValue >= 0 ? .green : .red)
            
            // Import/Export summary
            HStack(spacing: 8) {
                Text(String(format: "↓%.1f", period.energyImport))
                    .foregroundColor(.blue)
                Text(String(format: "↑%.1f", period.energyExport))
                    .foregroundColor(.orange)
            }
            .font(.caption2.monospacedDigit())
        }
        .padding(12)
        .frame(width: 130)
        .background(periodColor.opacity(0.08))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(periodColor.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Tariff Period Table (Full Breakdown)

struct TariffPeriodTable: View {
    let periods: [TariffPeriodPerformance]
    let definitions: [TariffPeriodDefinition]
    
    func timeRangeFor(_ periodName: String) -> String {
        if let def = definitions.first(where: { $0.periodName.lowercased() == periodName.lowercased() }) {
            return def.timeRange
        }
        return ""
    }
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    Text("Period")
                        .frame(width: 80, alignment: .leading)
                    Text("Time")
                        .frame(width: 80, alignment: .leading)
                    Text("Import")
                        .frame(width: 65, alignment: .trailing)
                    Text("Export")
                        .frame(width: 65, alignment: .trailing)
                    Text("Cost")
                        .frame(width: 65, alignment: .trailing)
                    Text("Earn")
                        .frame(width: 65, alignment: .trailing)
                    Text("Net")
                        .frame(width: 75, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
                
                Divider()
                
                // Data rows
                ForEach(periods, id: \.periodName) { period in
                    let net = period.netDollars
                    let periodColor = colorFor(period.periodName)
                    
                    HStack(spacing: 0) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(periodColor)
                                .frame(width: 8, height: 8)
                            Text(period.periodName.capitalized)
                                .lineLimit(1)
                        }
                        .frame(width: 80, alignment: .leading)
                        
                        Text(timeRangeFor(period.periodName))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(width: 80, alignment: .leading)
                        
                        Text(String(format: "%.1f", period.energyImport))
                            .foregroundColor(.blue)
                            .frame(width: 65, alignment: .trailing)
                        
                        Text(String(format: "%.1f", period.energyExport))
                            .foregroundColor(.orange)
                            .frame(width: 65, alignment: .trailing)
                        
                        Text(String(format: "$%.2f", period.costs / 100.0))
                            .foregroundColor(.red)
                            .frame(width: 65, alignment: .trailing)
                        
                        Text(String(format: "$%.2f", period.earnings / 100.0))
                            .foregroundColor(.green)
                            .frame(width: 65, alignment: .trailing)
                        
                        Text(String(format: "%@$%.2f", net >= 0 ? "+" : "", abs(net)))
                            .foregroundColor(net >= 0 ? .green : .red)
                            .frame(width: 75, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                    .padding(.vertical, 6)
                    
                    Divider()
                }
                
                // Totals row
                let totalImport = periods.reduce(0) { $0 + $1.energyImport }
                let totalExport = periods.reduce(0) { $0 + $1.energyExport }
                let totalCosts = periods.reduce(0) { $0 + $1.costs } / 100.0
                let totalEarnings = periods.reduce(0) { $0 + $1.earnings } / 100.0
                let totalNet = totalEarnings - totalCosts
                
                HStack(spacing: 0) {
                    Text("Total")
                        .fontWeight(.semibold)
                        .frame(width: 80, alignment: .leading)
                    
                    Text("")
                        .frame(width: 80, alignment: .leading)
                    
                    Text(String(format: "%.1f", totalImport))
                        .foregroundColor(.blue)
                        .frame(width: 65, alignment: .trailing)
                    
                    Text(String(format: "%.1f", totalExport))
                        .foregroundColor(.orange)
                        .frame(width: 65, alignment: .trailing)
                    
                    Text(String(format: "$%.2f", totalCosts))
                        .foregroundColor(.red)
                        .frame(width: 65, alignment: .trailing)
                    
                    Text(String(format: "$%.2f", totalEarnings))
                        .foregroundColor(.green)
                        .frame(width: 65, alignment: .trailing)
                    
                    Text(String(format: "%@$%.2f", totalNet >= 0 ? "+" : "", abs(totalNet)))
                        .foregroundColor(totalNet >= 0 ? .green : .red)
                        .fontWeight(.semibold)
                        .frame(width: 75, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .padding(.vertical, 6)
            }
            .frame(minWidth: 495)
        }
    }
    
    func colorFor(_ periodName: String) -> Color {
        switch periodName.lowercased() {
        case "peak", "evening": return .red
        case "offpeak", "overnight", "off-peak": return .blue
        case "shoulder", "day": return .green
        default: return .gray
        }
    }
}

// MARK: - Legacy Tariff Period Definition

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
    
    static func forHour(_ hour: Int, peakStartHour: Double) -> TariffPeriod {
        let peakStart = Int(peakStartHour)
        if hour >= peakStart && hour < 21 { return .evening }
        if hour >= 21 || hour < 11 { return .overnight }
        return .day
    }
    
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

// MARK: - Legacy Tariff Period Summary

struct TariffPeriodSummary: Identifiable {
    let id = UUID()
    let period: TariffPeriod
    let peakStartHour: Double
    
    var importKWh: Double = 0
    var exportKWh: Double = 0
    var costs: Double = 0
    var earnings: Double = 0
    var recordCount: Int = 0
    
    var netValue: Double { earnings - costs }
    var timeRange: String { period.timeRange(peakStartHour: peakStartHour) }
    
    var avgBuyRate: Double {
        guard importKWh > 0 else { return 0 }
        return (costs / importKWh) * 100
    }
    
    var avgSellRate: Double {
        guard exportKWh > 0 else { return 0 }
        return (earnings / exportKWh) * 100
    }
    
    static func fromRecords(_ records: [MeterRecord], peakStartHour: Double) -> [TariffPeriodSummary] {
        var summaries: [TariffPeriod: TariffPeriodSummary] = [:]
        
        for period in TariffPeriod.allCases {
            summaries[period] = TariffPeriodSummary(period: period, peakStartHour: peakStartHour)
        }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        for record in records {
            guard let date = record.date else { continue }
            
            let hour = calendar.component(.hour, from: date)
            let period = TariffPeriod.forHour(hour, peakStartHour: peakStartHour)
            
            summaries[period]?.importKWh += record.effectiveImport
            summaries[period]?.exportKWh += record.effectiveExport
            summaries[period]?.costs += (record.costs ?? 0) / 100.0
            summaries[period]?.earnings += (record.earnings ?? 0) / 100.0
            summaries[period]?.recordCount += 1
        }
        
        return TariffPeriod.allCases.compactMap { summaries[$0] }
    }
}

// MARK: - Legacy Tariff Analysis Section (MeterRecord-based fallback)

struct TariffAnalysisSection: View {
    let records: [MeterRecord]
    let peakStartHour: Double
    @State private var isExpanded = false
    
    var summaries: [TariffPeriodSummary] {
        TariffPeriodSummary.fromRecords(records, peakStartHour: peakStartHour)
    }
    
    var totalEarnings: Double { summaries.reduce(0) { $0 + $1.earnings } }
    var totalCosts: Double { summaries.reduce(0) { $0 + $1.costs } }
    var netValue: Double { totalEarnings - totalCosts }
    
    var hasData: Bool {
        summaries.contains { $0.importKWh > 0 || $0.exportKWh > 0 || $0.costs > 0 || $0.earnings > 0 }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(summaries) { summary in
                            TariffPeriodCard(summary: summary)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                
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
                    Text("No meter data for tariff analysis")
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

// MARK: - Legacy Tariff Period Card

struct TariffPeriodCard: View {
    let summary: TariffPeriodSummary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: summary.period.icon)
                    .foregroundColor(summary.period.color)
                Text(summary.period.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if summary.avgSellRate > 0 {
                    Text(String(format: "%.1f¢", summary.avgSellRate))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            
            Text(summary.timeRange)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            Divider()
            
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import").font(.caption2).foregroundColor(.secondary)
                    Text(formatEnergy(summary.importKWh))
                        .font(.caption.monospacedDigit()).foregroundColor(.blue).lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export").font(.caption2).foregroundColor(.secondary)
                    Text(formatEnergy(summary.exportKWh))
                        .font(.caption.monospacedDigit()).foregroundColor(.green).lineLimit(1)
                }
            }
            
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cost").font(.caption2).foregroundColor(.secondary)
                    Text(formatCurrency(summary.costs))
                        .font(.caption.monospacedDigit()).foregroundColor(.red).lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Earn").font(.caption2).foregroundColor(.secondary)
                    Text(formatCurrency(summary.earnings))
                        .font(.caption.monospacedDigit()).foregroundColor(.green).lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(width: 160)
        .background(summary.period.color.opacity(0.08))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(summary.period.color.opacity(0.3), lineWidth: 1)
        )
    }
    
    func formatEnergy(_ kwh: Double) -> String {
        kwh >= 1000 ? String(format: "%.0f kWh", kwh) : String(format: "%.1f kWh", kwh)
    }
    
    func formatCurrency(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }
}

// MARK: - Legacy Tariff Breakdown Table

struct TariffBreakdownTable: View {
    let summaries: [TariffPeriodSummary]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Period").frame(width: 80, alignment: .leading)
                    Text("Import").frame(width: 70, alignment: .trailing)
                    Text("Export").frame(width: 70, alignment: .trailing)
                    Text("Cost").frame(width: 70, alignment: .trailing)
                    Text("Earn").frame(width: 70, alignment: .trailing)
                    Text("Net").frame(width: 80, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
                
                Divider()
                
                ForEach(summaries) { summary in
                    HStack(spacing: 0) {
                        HStack(spacing: 4) {
                            Circle().fill(summary.period.color).frame(width: 8, height: 8)
                            Text(summary.period.rawValue).lineLimit(1)
                        }
                        .frame(width: 80, alignment: .leading)
                        
                        Text(String(format: "%.1f", summary.importKWh))
                            .foregroundColor(.blue).frame(width: 70, alignment: .trailing)
                        Text(String(format: "%.1f", summary.exportKWh))
                            .foregroundColor(.green).frame(width: 70, alignment: .trailing)
                        Text(String(format: "$%.2f", summary.costs))
                            .foregroundColor(.red).frame(width: 70, alignment: .trailing)
                        Text(String(format: "$%.2f", summary.earnings))
                            .foregroundColor(.green).frame(width: 70, alignment: .trailing)
                        Text(String(format: "%@$%.2f", summary.netValue >= 0 ? "+" : "-", abs(summary.netValue)))
                            .foregroundColor(summary.netValue >= 0 ? .green : .red).frame(width: 80, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                    .padding(.vertical, 6)
                    
                    Divider()
                }
                
                HStack(spacing: 0) {
                    Text("Total").fontWeight(.semibold).frame(width: 80, alignment: .leading)
                    Text(String(format: "%.1f", summaries.reduce(0) { $0 + $1.importKWh }))
                        .foregroundColor(.blue).frame(width: 70, alignment: .trailing)
                    Text(String(format: "%.1f", summaries.reduce(0) { $0 + $1.exportKWh }))
                        .foregroundColor(.green).frame(width: 70, alignment: .trailing)
                    let totalCosts = summaries.reduce(0) { $0 + $1.costs }
                    Text(String(format: "$%.2f", totalCosts))
                        .foregroundColor(.red).frame(width: 70, alignment: .trailing)
                    let totalEarnings = summaries.reduce(0) { $0 + $1.earnings }
                    Text(String(format: "$%.2f", totalEarnings))
                        .foregroundColor(.green).frame(width: 70, alignment: .trailing)
                    let totalNet = totalEarnings - totalCosts
                    Text(String(format: "%@$%.2f", totalNet >= 0 ? "+" : "-", abs(totalNet)))
                        .foregroundColor(totalNet >= 0 ? .green : .red).fontWeight(.semibold).frame(width: 80, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .padding(.vertical, 6)
            }
            .frame(minWidth: 440)
        }
    }
}
