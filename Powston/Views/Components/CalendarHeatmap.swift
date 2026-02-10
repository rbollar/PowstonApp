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
    case outstanding // Spike day - >$50 or >10x avg
    case excellent   // Great day - >$20 or >3x avg
    case good        // Above average - >1.5x avg
    case average     // Normal - 0.5x to 1.5x avg
    case poor        // Below average - 0 to 0.5x avg
    case bad         // Loss day - negative
    case noData      // no data available
    case future      // future date
    
    var color: Color {
        switch self {
        case .outstanding: return Color(red: 0, green: 0.8, blue: 0.7) // Bright teal
        case .excellent: return .green
        case .good: return Color.green.opacity(0.6)
        case .average: return .yellow
        case .poor: return Color.orange
        case .bad: return Color.red.opacity(0.7)
        case .noData: return Color.gray.opacity(0.3)
        case .future: return Color.gray.opacity(0.1)
        }
    }
    
    /// Text color for contrast on colored backgrounds
    var textColor: Color {
        switch self {
        case .outstanding, .excellent, .good: return .white
        case .average: return .black
        case .poor: return .white
        case .bad: return .white
        case .noData, .future: return .secondary
        }
    }
    
    var icon: String? {
        switch self {
        case .outstanding: return "star.fill"
        case .bad: return "exclamationmark.triangle.fill"
        default: return nil
        }
    }
    
    /// Label for legend
    var label: String {
        switch self {
        case .outstanding: return "Spike"
        case .excellent: return "Great"
        case .good: return "Good"
        case .average: return "Avg"
        case .poor: return "Low"
        case .bad: return "Loss"
        case .noData: return "N/A"
        case .future: return ""
        }
    }
    
    static func from(netProfit: Double?, rollingAverage: Double) -> HeatmapPerformance {
        guard let net = netProfit else { return .noData }
        
        // Absolute thresholds for spike days (always highlight big wins)
        if net > 50 { return .outstanding }
        if net > 20 { return .excellent }
        
        // Loss days are always bad
        if net < 0 { return .bad }
        
        // If average is near zero or negative, use absolute thresholds
        if rollingAverage < 1.0 {
            if net > 10 { return .excellent }
            if net > 5 { return .good }
            if net > 2 { return .average }
            return .poor
        }
        
        // Ratio-based for normal variation
        let ratio = net / rollingAverage
        
        if ratio > 10 { return .outstanding }  // 10x+ average
        if ratio > 3 { return .excellent }      // 3x+ average
        if ratio > 1.5 { return .good }         // 1.5x+ average
        if ratio > 0.5 { return .average }      // 0.5x to 1.5x average
        return .poor                            // Below 0.5x average
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
        if abs(net) >= 100 {
            return String(format: "$%.0f", abs(net))
        } else if abs(net) >= 10 {
            return String(format: "$%.0f", abs(net))
        }
        return String(format: "$%.0f", abs(net))
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 1) {
                // Day of week letter
                Text(dayOfWeek)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                
                // Day number
                Text("\(dayNumber)")
                    .font(.system(size: 14, weight: isSelected ? .bold : .semibold))
                    .foregroundColor(performance.textColor)
                
                // P&L value
                Text(formattedProfit)
                    .font(.system(size: 9).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(performance.textColor.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(performance.color.opacity(isSelected ? 1.0 : 0.7))
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
    var overrideTotal: Double? = nil  // Use this instead of summing dailySummaries
    
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
        // Use override if provided (from accurate bulk API), otherwise sum dailies
        if let override = overrideTotal {
            return override
        }
        return dailySummaries.reduce(0) { $0 + $1.netProfit }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Header with week total
            HStack {
                Text("Week Overview")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "Total: %@$%.2f", weekTotal >= 0 ? "+" : "", weekTotal))
                    .font(.caption.monospacedDigit())
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
    var overrideTotal: Double? = nil  // Use this instead of summing dailySummaries
    
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = powstonTimezone()
        return cal
    }
    
    private var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: monthStart)
    }
    
    /// Generate week rows for the month grid
    private var weeks: [[Date?]] {
        // Get the first day of the month
        guard let firstDayOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthStart)),
              let range = calendar.range(of: .day, in: .month, for: monthStart) else {
            return []
        }
        
        // Get weekday of first day (1 = Sunday, 2 = Monday, etc.)
        let firstWeekday = calendar.component(.weekday, from: firstDayOfMonth)
        
        // Calculate offset for Monday start (Mon=0, Tue=1, ... Sun=6)
        // weekday: Sun=1, Mon=2, Tue=3, Wed=4, Thu=5, Fri=6, Sat=7
        let offset = (firstWeekday + 5) % 7
        
        var result: [[Date?]] = []
        var currentWeek: [Date?] = []
        
        // Add leading nils for offset
        for _ in 0..<offset {
            currentWeek.append(nil)
        }
        
        // Add all days of the month
        for day in 1...range.count {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDayOfMonth) {
                currentWeek.append(date)
                
                if currentWeek.count == 7 {
                    result.append(currentWeek)
                    currentWeek = []
                }
            }
        }
        
        // Pad last week with nils if needed
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
        // Use override if provided (from accurate bulk API), otherwise sum dailies
        if let override = overrideTotal {
            return override
        }
        return dailySummaries.reduce(0) { $0 + $1.netProfit }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Header with month total
            HStack {
                Text(monthName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "Total: %@$%.2f", monthTotal >= 0 ? "+" : "", monthTotal))
                    .font(.caption.monospacedDigit())
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
            ForEach(Array(weeks.enumerated()), id: \.offset) { weekIndex, week in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { dayIndex in
                        if let date = week[dayIndex] {
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
            Text("\(dayNumber)")
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .foregroundColor(performance.textColor)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(performance.color.opacity(isSelected ? 1.0 : 0.7))
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
    var compact: Bool = false
    
    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Spacer()
            legendItem(performance: .outstanding)
            legendItem(performance: .excellent)
            legendItem(performance: .good)
            legendItem(performance: .average)
            legendItem(performance: .poor)
            legendItem(performance: .bad)
            Spacer()
        }
        .font(.system(size: compact ? 9 : 10))
        .foregroundColor(.secondary)
        .padding(.top, 4)
    }
    
    private func legendItem(performance: HeatmapPerformance) -> some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2)
                .fill(performance.color.opacity(0.8))
                .frame(width: compact ? 8 : 10, height: compact ? 8 : 10)
            Text(performance.label)
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

// MARK: - Year Calendar Heatmap

struct YearCalendarHeatmap: View {
    let year: Int
    let monthlySummaries: [DailySummary]  // One per month
    let yearlyAverage: Double  // Average monthly net for color calibration
    let onSelectMonth: (Int) -> Void  // month number (1-12)
    var overrideTotal: Double? = nil  // Use this instead of summing monthlySummaries
    
    private let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = powstonTimezone()
        return cal
    }
    
    private func summary(for month: Int) -> DailySummary? {
        monthlySummaries.first { calendar.component(.month, from: $0.date) == month }
    }
    
    private func isFuture(_ month: Int) -> Bool {
        let now = Date()
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)
        
        if year > currentYear { return true }
        if year == currentYear && month > currentMonth { return true }
        return false
    }
    
    var yearTotal: Double {
        // Use override if provided (from accurate bulk API), otherwise sum monthlies
        if let override = overrideTotal {
            return override
        }
        return monthlySummaries.reduce(0) { $0 + $1.netProfit }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Header with year total
            HStack {
                Text("\(String(year)) Overview")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "Total: %@$%.2f", yearTotal >= 0 ? "+" : "", yearTotal))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(yearTotal >= 0 ? .green : .red)
            }
            
            // Month grid - 3 columns x 4 rows
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(1...12, id: \.self) { month in
                    YearMonthCell(
                        month: month,
                        monthName: monthNames[month - 1],
                        netProfit: summary(for: month)?.netProfit,
                        yearlyAverage: yearlyAverage,
                        isFuture: isFuture(month),
                        onTap: { onSelectMonth(month) }
                    )
                }
            }
            
            // Legend
            HeatmapLegend(compact: true)
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Year Month Cell

struct YearMonthCell: View {
    let month: Int
    let monthName: String
    let netProfit: Double?
    let yearlyAverage: Double
    let isFuture: Bool
    let onTap: () -> Void
    
    private var performance: HeatmapPerformance {
        if isFuture { return .future }
        // For monthly view, scale thresholds by ~30 (days in month)
        return HeatmapPerformance.fromMonthly(netProfit: netProfit, monthlyAverage: yearlyAverage)
    }
    
    private var formattedProfit: String {
        guard let net = netProfit else { return "—" }
        return String(format: "$%.0f", abs(net))
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text(monthName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(performance.textColor)
                
                Text(formattedProfit)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(performance.textColor.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(performance.color.opacity(isFuture ? 0.3 : 0.7))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }
}

// MARK: - Monthly Performance Extension

extension HeatmapPerformance {
    /// Calculate performance for monthly totals (scaled thresholds)
    static func fromMonthly(netProfit: Double?, monthlyAverage: Double) -> HeatmapPerformance {
        guard let net = netProfit else { return .noData }
        
        // Absolute thresholds scaled for monthly (roughly 30x daily)
        if net > 500 { return .outstanding }  // Great month
        if net > 200 { return .excellent }
        
        // Loss months
        if net < 0 { return .bad }
        
        // If average is low, use absolute thresholds
        if monthlyAverage < 30 {
            if net > 100 { return .excellent }
            if net > 50 { return .good }
            if net > 20 { return .average }
            return .poor
        }
        
        // Ratio-based
        let ratio = net / monthlyAverage
        
        if ratio > 5 { return .outstanding }
        if ratio > 2 { return .excellent }
        if ratio > 1.3 { return .good }
        if ratio > 0.7 { return .average }
        return .poor
    }
}
