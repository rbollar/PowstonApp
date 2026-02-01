//
//  CalendarHeatmap.swift
//  Powston
//
//  Calendar heatmap components for visualizing daily P&L performance
//  Color-coded based on 30-day rolling average comparison
//

import SwiftUI

// MARK: - Heatmap Color Logic

enum HeatmapPerformance {
    case excellent  // > +50% of avg
    case good       // +25% to +50% of avg
    case average    // within ±25% of avg
    case poor       // -25% to -50% of avg
    case bad        // < -50% of avg or negative when avg positive
    case noData     // no data available
    case future     // future date
    
    var color: Color {
        switch self {
        case .excellent: return .green
        case .good: return Color.green.opacity(0.6)
        case .average: return .yellow
        case .poor: return Color.red.opacity(0.6)
        case .bad: return .red
        case .noData: return Color.gray.opacity(0.3)
        case .future: return Color.gray.opacity(0.1)
        }
    }
    
    var icon: String? {
        switch self {
        case .excellent: return "star.fill"
        case .bad: return "exclamationmark.triangle.fill"
        default: return nil
        }
    }
    
    static func from(netProfit: Double?, rollingAverage: Double) -> HeatmapPerformance {
        guard let net = netProfit else { return .noData }
        
        // If average is near zero, use absolute thresholds
        if abs(rollingAverage) < 1.0 {
            if net > 5 { return .excellent }
            if net > 2 { return .good }
            if net > -2 { return .average }
            if net > -5 { return .poor }
            return .bad
        }
        
        let ratio = net / rollingAverage
        
        // Positive average (normal operation)
        if rollingAverage > 0 {
            if ratio > 1.5 { return .excellent }
            if ratio > 1.25 { return .good }
            if ratio > 0.75 { return .average }
            if ratio > 0.5 { return .poor }
            return .bad
        }
        
        // Negative average (unusual but possible)
        // In this case, less negative is better
        if ratio < 0.5 { return .excellent }  // Much less loss
        if ratio < 0.75 { return .good }
        if ratio < 1.25 { return .average }
        if ratio < 1.5 { return .poor }
        return .bad  // Even more loss than average
    }
}

// MARK: - Single Day Cell

struct HeatmapDayCell: View {
    let date: Date
    let netProfit: Double?
    let rollingAverage: Double
    let isSelected: Bool
    let isFuture: Bool
    let onTap: () -> Void
    
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = powstonTimezone()
        return cal
    }
    
    private var dayNumber: Int {
        calendar.component(.day, from: date)
    }
    
    private var dayOfWeek: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        formatter.timeZone = powstonTimezone()
        return String(formatter.string(from: date).prefix(1))
    }
    
    private var performance: HeatmapPerformance {
        if isFuture { return .future }
        return HeatmapPerformance.from(netProfit: netProfit, rollingAverage: rollingAverage)
    }
    
    private var formattedProfit: String {
        guard let net = netProfit else { return "—" }
        if abs(net) >= 10 {
            return String(format: "%@$%.0f", net >= 0 ? "+" : "", net)
        }
        return String(format: "%@$%.1f", net >= 0 ? "+" : "", net)
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                // Day of week letter
                Text(dayOfWeek)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                // Day number
                Text("\(dayNumber)")
                    .font(.subheadline)
                    .fontWeight(isSelected ? .bold : .medium)
                
                // P&L value
                Text(formattedProfit)
                    .font(.caption.monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(netProfit ?? 0 >= 0 ? .primary : .red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(performance.color.opacity(isSelected ? 1.0 : 0.6))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.primary : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }
}

// MARK: - Week Calendar Heatmap

struct WeekCalendarHeatmap: View {
    let weekStart: Date
    let dailySummaries: [DailySummary]
    let rollingAverage: Double
    let selectedDate: Date?
    let onSelectDate: (Date) -> Void
    
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = powstonTimezone()
        return cal
    }
    
    private var weekDates: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }
    
    private func summary(for date: Date) -> DailySummary? {
        dailySummaries.first { calendar.isDate($0.date, inSameDayAs: date) }
    }
    
    private func isFuture(_ date: Date) -> Bool {
        date > Date()
    }
    
    private func isSelected(_ date: Date) -> Bool {
        guard let selected = selectedDate else { return false }
        return calendar.isDate(date, inSameDayAs: selected)
    }
    
    var weekTotal: Double {
        dailySummaries.reduce(0) { $0 + $1.netProfit }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Header with week total
            HStack {
                Text("Week Overview")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "Total: %@$%.2f", weekTotal >= 0 ? "+" : "", weekTotal))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(weekTotal >= 0 ? .green : .red)
            }
            
            // Day cells
            HStack(spacing: 4) {
                ForEach(weekDates, id: \.self) { date in
                    HeatmapDayCell(
                        date: date,
                        netProfit: summary(for: date)?.netProfit,
                        rollingAverage: rollingAverage,
                        isSelected: isSelected(date),
                        isFuture: isFuture(date),
                        onTap: { onSelectDate(date) }
                    )
                }
            }
            
            // Legend
            HeatmapLegend()
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Month Calendar Heatmap

struct MonthCalendarHeatmap: View {
    let monthStart: Date
    let dailySummaries: [DailySummary]
    let rollingAverage: Double
    let selectedDate: Date?
    let onSelectDate: (Date) -> Void
    
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = powstonTimezone()
        cal.firstWeekday = 2 // Monday
        return cal
    }
    
    private var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: monthStart)
    }
    
    private var weeks: [[Date?]] {
        var result: [[Date?]] = []
        
        // Get first day of month and number of days
        let range = calendar.range(of: .day, in: .month, for: monthStart)!
        let firstDayOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthStart))!
        let firstWeekday = calendar.component(.weekday, from: firstDayOfMonth)
        
        // Adjust for Monday start (weekday 1 = Sunday, we want Monday = 1)
        let offset = (firstWeekday + 5) % 7  // Convert to Monday-based
        
        var currentWeek: [Date?] = Array(repeating: nil, count: offset)
        
        for day in 1...range.count {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDayOfMonth) {
                currentWeek.append(date)
                
                if currentWeek.count == 7 {
                    result.append(currentWeek)
                    currentWeek = []
                }
            }
        }
        
        // Pad last week if needed
        if !currentWeek.isEmpty {
            while currentWeek.count < 7 {
                currentWeek.append(nil)
            }
            result.append(currentWeek)
        }
        
        return result
    }
    
    private let dayHeaders = ["M", "T", "W", "T", "F", "S", "S"]
    
    private func summary(for date: Date) -> DailySummary? {
        dailySummaries.first { calendar.isDate($0.date, inSameDayAs: date) }
    }
    
    private func isFuture(_ date: Date) -> Bool {
        date > Date()
    }
    
    private func isSelected(_ date: Date) -> Bool {
        guard let selected = selectedDate else { return false }
        return calendar.isDate(date, inSameDayAs: selected)
    }
    
    var monthTotal: Double {
        dailySummaries.reduce(0) { $0 + $1.netProfit }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Header with month total
            HStack {
                Text(monthName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "Total: %@$%.2f", monthTotal >= 0 ? "+" : "", monthTotal))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(monthTotal >= 0 ? .green : .red)
            }
            
            // Day of week headers
            HStack(spacing: 4) {
                ForEach(dayHeaders, id: \.self) { day in
                    Text(day)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            
            // Week rows
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 4) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, date in
                        if let date = date {
                            MonthHeatmapDayCell(
                                date: date,
                                netProfit: summary(for: date)?.netProfit,
                                rollingAverage: rollingAverage,
                                isSelected: isSelected(date),
                                isFuture: isFuture(date),
                                onTap: { onSelectDate(date) }
                            )
                        } else {
                            // Empty cell for padding
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
            
            // Legend
            HeatmapLegend()
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Compact Month Day Cell

struct MonthHeatmapDayCell: View {
    let date: Date
    let netProfit: Double?
    let rollingAverage: Double
    let isSelected: Bool
    let isFuture: Bool
    let onTap: () -> Void
    
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = powstonTimezone()
        return cal
    }
    
    private var dayNumber: Int {
        calendar.component(.day, from: date)
    }
    
    private var performance: HeatmapPerformance {
        if isFuture { return .future }
        return HeatmapPerformance.from(netProfit: netProfit, rollingAverage: rollingAverage)
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 1) {
                Text("\(dayNumber)")
                    .font(.caption2)
                    .fontWeight(isSelected ? .bold : .medium)
                
                if let net = netProfit {
                    Text(net >= 0 ? "+" : "−")
                        .font(.system(size: 8))
                        .foregroundColor(net >= 0 ? .green : .red)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(performance.color.opacity(isSelected ? 1.0 : 0.6))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.primary : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }
}

// MARK: - Legend

struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            legendItem(color: .green, label: "Great")
            legendItem(color: .yellow, label: "Avg")
            legendItem(color: .red, label: "Poor")
            Spacer()
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.top, 4)
    }
    
    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.6))
                .frame(width: 12, height: 12)
            Text(label)
        }
    }
}

// MARK: - Rolling Average Card

struct RollingAverageCard: View {
    let currentNet: Double
    let rollingAverage: Double
    let days: Int
    
    var percentChange: Double {
        guard abs(rollingAverage) > 0.01 else { return 0 }
        return ((currentNet - rollingAverage) / abs(rollingAverage)) * 100
    }
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(days)-day avg")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "$%.2f/day", rollingAverage))
                    .font(.subheadline.monospacedDigit().weight(.medium))
            }
            
            Spacer()
            
            if abs(percentChange) > 1 {
                HStack(spacing: 4) {
                    Image(systemName: percentChange > 0 ? "arrow.up.right" : "arrow.down.right")
                    Text(String(format: "%.0f%%", abs(percentChange)))
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(percentChange > 0 ? .green : .red)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }
}
