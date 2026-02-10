//
//  SectionsDashboard.swift
//  Powston
//
//  Three-section dashboard: NOW / NEXT / OPPORTUNITY
//

import SwiftUI

struct SectionsDashboard: View {
    @EnvironmentObject var api: PowstonAPI
    let data: InverterResponse
    @State private var selectedPricePeriod: Int?
    
    // Find next price spike in forecast
    var nextPriceSpike: (period: Int, price: Double, time: Date)? {
        guard let sellForecast = data.sellForecast,
              let startDate = data.forecastStartDate else { return nil }
        
        // Look for sell prices above 40¢ in the next 12 hours (24 periods)
        let threshold: Double = 40
        let lookAhead = min(24, sellForecast.count)
        
        for i in 0..<lookAhead {
            if sellForecast[i] >= threshold {
                let time = Calendar.current.date(byAdding: .minute, value: i * 30, to: startDate) ?? startDate
                return (period: i, price: sellForecast[i], time: time)
            }
        }
        return nil
    }
    
    // Calculate potential earnings from exporting at spike price
    var potentialEarnings: Double? {
        guard let spike = nextPriceSpike else { return nil }
        
        // Assume we can export ~10kWh at the spike price (rough estimate)
        // Price is in cents, so divide by 100 for dollars
        let exportableKwh: Double = 10
        return (spike.price * exportableKwh) / 100
    }
    
    // Price forecast for next 6 hours (12 x 30-min periods)
    var priceForecast: [(period: Int, time: Date, buy: Double, sell: Double)] {
        guard let buyForecast = data.buyForecast,
              let sellForecast = data.sellForecast,
              let startDate = data.forecastStartDate else { return [] }
        
        var forecast: [(period: Int, time: Date, buy: Double, sell: Double)] = []
        let periodsToShow = min(12, buyForecast.count, sellForecast.count)
        
        for i in 0..<periodsToShow {
            let time = Calendar.current.date(byAdding: .minute, value: i * 30, to: startDate) ?? startDate
            forecast.append((period: i, time: time, buy: buyForecast[i], sell: sellForecast[i]))
        }
        
        return forecast
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // SECTION 1: NOW
            nowSection
            
            // SECTION 2: NEXT (Price Forecast)
            nextSection
            
            // SECTION 3: OPPORTUNITY
            opportunitySection
        }
        .padding(.horizontal)
    }
    
    // MARK: - NOW Section
    @ViewBuilder
    var nowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("NOW", systemImage: "clock.fill")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                    .accessibilityAddTraits(.isHeader)
                
                if let intervalTime = data.intervalTime {
                    Text("• \(formatIntervalTime(intervalTime))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            HStack(spacing: 16) {
                // Action badge with link to control
                NavigationLink(destination: ManualOverrideView()) {
                    VStack(spacing: 4) {
                        if api.hasPendingOverride {
                            ProgressView()
                                .controlSize(.small)
                            Text("PENDING")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                        } else if api.hasActiveOverride, let firstActive = api.currentOverrides.first {
                            Text("MANUAL")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.orange)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            Text(firstActive.action.uppercased())
                                .font(.caption)
                                .foregroundColor(.orange)
                                .lineLimit(1)
                        } else if api.hasScheduledOverride, let firstScheduled = api.scheduledOverrides.first {
                            Text("SCHEDULED")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            Text(firstScheduled.action.uppercased())
                                .font(.caption2)
                                .foregroundColor(.blue)
                                .lineLimit(1)
                            Text(firstScheduled.formattedStartsIn)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(displayAction(data.currentAction).uppercased())
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(actionColor(data.currentAction))
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            Text("Tap to control")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 90)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Current action: \(displayAction(data.currentAction))")
                .accessibilityHint("Double tap to open manual controls")
                
                Divider()
                    .frame(height: 50)
                    .accessibilityHidden(true)
                
                // Current stats - cap dynamic type to prevent overflow
                HStack(alignment: .bottom, spacing: 0) {
                    StatItemLarge(icon: "sun.max.fill", value: String(format: "%.1f", data.solarKw), color: .yellow, label: "Solar", onTap: { TabSelection.shared.selectedTab = .decisions })
                        .frame(maxWidth: .infinity)
                    StatItemLarge(icon: "house.fill", value: String(format: "%.1f", data.displayHouseKw), color: .purple, label: "Home", showBadge: data.hasSignificantImbalance, onTap: { TabSelection.shared.selectedTab = .decisions })
                        .frame(maxWidth: .infinity)
                    StatItemLarge(icon: "bolt.fill", value: String(format: "%.1f", abs(data.gridKw)), color: data.isGridExporting ? .green : .blue, label: data.isGridExporting ? "Export" : "Import", onTap: { TabSelection.shared.selectedTab = .decisions })
                        .frame(maxWidth: .infinity)
                    
                    // Battery with integrated SOC ring
                    VStack(spacing: 2) {
                        ZStack {
                            Circle()
                                .stroke(Color.gray.opacity(0.3), lineWidth: 4)
                                .frame(width: 38, height: 38)
                            Circle()
                                .trim(from: 0, to: (data.batterySoc ?? 0) / 100)
                                .stroke(socColor(data.batterySoc ?? 0), lineWidth: 4)
                                .frame(width: 38, height: 38)
                                .rotationEffect(.degrees(-90))
                            Text("\(Int(data.batterySoc ?? 0))")
                                .font(.caption.weight(.bold))
                        }
                        Text(String(format: "%.1f", abs(data.batteryKw)))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Text(data.isCharging ? "Chg" : "Dchg")
                            .font(.caption2)
                            .foregroundColor(data.isCharging ? .green : .orange)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { TabSelection.shared.selectedTab = .decisions }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Battery \(data.isCharging ? "charging" : "discharging") at \(String(format: "%.1f", abs(data.batteryKw))) kilowatts, \(Int(data.batterySoc ?? 0)) percent")
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)  // Cap at xxxLarge
            }
            
            // Prices row - also cap here
            HStack(spacing: 20) {
                HStack(spacing: 4) {
                    Text("Buy")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    InlinePriceText(cents: data.buyPrice ?? 0, isBuy: true, font: .subheadline)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Buy price: \(PriceFormat.format(data.buyPrice ?? 0)) per kilowatt hour")
                HStack(spacing: 4) {
                    Text("Sell")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    InlinePriceText(cents: data.sellPrice ?? 0, isBuy: false, font: .subheadline)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sell price: \(PriceFormat.format(data.sellPrice ?? 0)) per kilowatt hour")
                Spacer()
                if let reason = data.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityLabel("Decision reason: \(reason)")
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .cornerRadius(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current status")
    }
    
    // MARK: - NEXT Section (Price Forecast)
    @ViewBuilder
    var nextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("NEXT", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.orange)
                .accessibilityAddTraits(.isHeader)
            
            if priceForecast.isEmpty {
                HStack {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text("No price forecast available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                // Selected period detail
                if let selected = selectedPricePeriod, selected < priceForecast.count {
                    let period = priceForecast[selected]
                    HStack(spacing: 12) {
                        Text(formatPeriodTime(period.time))
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle().fill(PriceColors.buyColor(period.buy)).frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            Text(PriceFormat.format(period.buy))
                                .font(.caption)
                                .foregroundColor(PriceColors.buyColor(period.buy))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Buy: \(PriceFormat.format(period.buy))")
                        HStack(spacing: 4) {
                            Circle().fill(PriceColors.sellColor(period.sell)).frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            Text(PriceFormat.format(period.sell))
                                .font(.caption)
                                .foregroundColor(PriceColors.sellColor(period.sell))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Sell: \(PriceFormat.format(period.sell))")
                        Button(action: { selectedPricePeriod = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .accessibilityLabel("Dismiss")
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(6)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Selected period: \(formatPeriodTime(period.time))")
                }
                
                // Price chart - show buy and sell lines
                PriceForecastMiniChart(forecast: priceForecast, selectedPeriod: $selectedPricePeriod)
                    .frame(height: 60)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Price forecast chart for next 6 hours. Tap to select a time period.")
                    .accessibilityAddTraits(.allowsDirectInteraction)
                
                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.blue).frame(width: 6, height: 6)
                        Text("Buy")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Sell")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("Tap chart for details")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .accessibilityHidden(true)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.05))
        .cornerRadius(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Price forecast")
    }
    
    func formatPeriodTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "E j:mm", options: 0, locale: Locale.current)
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
    
    // MARK: - OPPORTUNITY Section
    @ViewBuilder
    var opportunitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("OPPORTUNITY", systemImage: "dollarsign.circle.fill")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.green)
                .accessibilityAddTraits(.isHeader)
            
            if let spike = nextPriceSpike {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next price spike")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(formatTime(spike.time))
                                .font(.title2)
                                .fontWeight(.bold)
                            Text(String(format: "%.0f¢/kWh", spike.price))
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Next price spike at \(formatTime(spike.time)), \(String(format: "%.0f", spike.price)) cents per kilowatt hour")
                    
                    Spacer()
                    
                    if let earnings = potentialEarnings {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Potential")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(String(format: "+$%.2f", earnings))
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.green)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Potential earnings: \(String(format: "%.2f", earnings)) dollars")
                    }
                    
                    Button(action: {
                        TabSelection.shared.selectedTab = .prices
                    }) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title)
                            .foregroundColor(.green)
                    }
                    .accessibilityLabel("View price forecast")
                    .accessibilityHint("Double tap to see full price details")
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .accessibilityHidden(true)
                    Text("No significant price spikes in the next 12 hours")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.green.opacity(0.05))
        .cornerRadius(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Opportunity")
    }
    
    // MARK: - Helpers
    
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
    
    func actionColor(_ action: String) -> Color {
        let simplified = displayAction(action).lowercased()
        switch simplified {
        case "import": return .blue
        case "export": return .green
        case "auto": return .purple
        case "charge": return .blue
        case "discharge": return .orange
        case "curtail": return .orange
        default: return .gray
        }
    }
    
    func displayAction(_ action: String) -> String {
        let lower = action.lowercased()
        if lower.contains("curtail") {
            return "Curtail"
        } else if lower.contains("export") {
            return "Export"
        } else if lower.contains("import") {
            return "Import"
        } else if lower.contains("discharge") {
            return "Discharge"
        } else if lower.contains("charge") {
            return "Charge"
        } else if lower.contains("auto") || lower.contains("hold") {
            return "Auto"
        }
        return action
    }
    
    func socColor(_ soc: Double) -> Color {
        if soc >= 80 { return .green }
        else if soc >= 40 { return .yellow }
        else if soc >= 20 { return .orange }
        else { return .red }
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

// MARK: - Stat Item
struct StatItem: View {
    let icon: String
    let value: String
    let unit: String
    let color: Color
    var label: String = ""
    
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundColor(color)
            Text(value)
                .font(.footnote.weight(.semibold).monospacedDigit())
            Text(unit)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.isEmpty ? icon : label): \(value) \(unit)")
    }
}

struct StatItemLarge: View {
    let icon: String
    let value: String
    let color: Color
    var label: String = ""
    var showBadge: Bool = false
    var onTap: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                    .frame(height: 28)
                
                if showBadge {
                    Image(systemName: "plusminus.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .offset(x: 6, y: -2)
                }
            }
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value) kilowatts\(showBadge ? ", includes unmetered load" : "")")
    }
}

// MARK: - Price Forecast Mini Chart
struct PriceForecastMiniChart: View {
    let forecast: [(period: Int, time: Date, buy: Double, sell: Double)]
    @Binding var selectedPeriod: Int?
    
    var body: some View {
        GeometryReader { geometry in
            let allPrices = forecast.flatMap { [$0.buy, $0.sell] }
            let maxPrice = allPrices.max() ?? 1
            let minPrice = min(allPrices.min() ?? 0, 0) // Include negative prices
            let priceRange = maxPrice - minPrice
            
            let leftPadding: CGFloat = 35  // Space for price labels
            let bottomPadding: CGFloat = 16 // Space for time labels
            let width = geometry.size.width - leftPadding
            let height = geometry.size.height - bottomPadding
            let stepX = width / CGFloat(max(forecast.count - 1, 1))
            
            ZStack(alignment: .topLeading) {
                // Chart area (offset for labels)
                ZStack {
                    // Zero line if we have negative prices
                    if minPrice < 0 {
                        let zeroY = height * (1 - CGFloat((0 - minPrice) / priceRange))
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: zeroY))
                            path.addLine(to: CGPoint(x: width, y: zeroY))
                        }
                        .stroke(Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    
                    // Buy price line (blue)
                    Path { path in
                        for (index, item) in forecast.enumerated() {
                            let x = CGFloat(index) * stepX
                            let y = height * (1 - CGFloat((item.buy - minPrice) / priceRange))
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.blue, lineWidth: 2)
                    
                    // Sell price line (green)
                    Path { path in
                        for (index, item) in forecast.enumerated() {
                            let x = CGFloat(index) * stepX
                            let y = height * (1 - CGFloat((item.sell - minPrice) / priceRange))
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.green, lineWidth: 2)
                    
                    // Selection indicator
                    if let selected = selectedPeriod, selected < forecast.count {
                        let x = CGFloat(selected) * stepX
                        Rectangle()
                            .fill(Color.orange.opacity(0.3))
                            .frame(width: stepX, height: height)
                            .position(x: x + stepX/2, y: height/2)
                    }
                    
                    // Time labels at bottom
                    if let first = forecast.first, let last = forecast.last {
                        VStack {
                            Spacer()
                            HStack {
                                Text(formatTimeShort(first.time))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(formatTimeShort(last.time))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .frame(width: width, height: geometry.size.height)
                .offset(x: leftPadding)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            // Only respond to horizontal drags - let vertical pass through for scrolling
                            let horizontalDistance = abs(value.translation.width)
                            let verticalDistance = abs(value.translation.height)
                            guard horizontalDistance > verticalDistance * 1.5 else { return }
                            
                            let x = value.location.x
                            let index = Int((x / stepX).rounded())
                            let clampedIndex = max(0, min(index, forecast.count - 1))
                            if selectedPeriod != clampedIndex {
                                selectedPeriod = clampedIndex
                            }
                        }
                )
                
                // Price labels on left
                VStack {
                    Text(String(format: "%.0f¢", maxPrice))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    if minPrice < 0 {
                        Text(String(format: "%.0f¢", minPrice))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: leftPadding - 4, height: height, alignment: .trailing)
            }
        }
    }
    
    func formatTimeShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: Locale.current)
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
}

// MARK: - Dashboard Style Enum
enum DashboardStyle: String, CaseIterable {
    case classic = "classic"
    case sections = "sections"
    case ems = "ems"
    case snapshot = "snapshot"
    
    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .sections: return "Now → Next"
        case .ems: return "Power Flows"
        case .snapshot: return "Snapshot"
        }
    }
    
    var icon: String {
        switch self {
        case .classic: return "gauge.with.dots.needle.50percent"
        case .sections: return "clock.arrow.circlepath"
        case .ems: return "arrow.triangle.swap"
        case .snapshot: return "camera.viewfinder"
        }
    }
    
    var description: String {
        switch self {
        case .classic:
            return "Clean overview with battery, solar, and price essentials. Great for a quick status check."
        case .sections:
            return "Current status with upcoming price windows. Perfect for planning when to charge or export."
        case .ems:
            return "Visual energy flow diagram showing how power moves between solar, battery, grid, and home."
        case .snapshot:
            return "5-minute decision snapshot with animated energy flows and detailed decision reasoning."
        }
    }
}
