//
//  SectionsDashboard.swift
//  Powston
//
//  Three-section dashboard: NOW / NEXT / OPPORTUNITY
//

import SwiftUI

struct SectionsDashboard: View {
    let data: InverterResponse
    let sites: [Site]
    @StateObject private var weather = WeatherService.shared
    
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
    
    // Solar forecast for next 6 hours
    var solarForecast: [(hour: Int, kw: Double)] {
        guard let startDate = data.forecastStartDate else { return [] }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        // Get hourly solar forecast
        var forecast: [(hour: Int, kw: Double)] = []
        let currentHour = calendar.component(.hour, from: startDate)
        
        for i in 0..<6 {
            let hour = (currentHour + i) % 24
            let forecastDate = calendar.date(byAdding: .hour, value: i, to: startDate) ?? startDate
            let solarWm2 = weather.solarForecastForHour(forecastDate)
            // Rough conversion: W/m² to kW for a typical system
            // Assume ~6kW system, ~20% efficiency at 1000 W/m²
            let kw = (solarWm2 / 1000.0) * 6.0 * 0.8
            forecast.append((hour: hour, kw: kw))
        }
        
        return forecast
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // SECTION 1: NOW
            nowSection
            
            // SECTION 2: NEXT (Solar Forecast)
            nextSection
            
            // SECTION 3: OPPORTUNITY
            opportunitySection
        }
        .padding(.horizontal)
    }
    
    // MARK: - NOW Section
    var nowSection: View {
        VStack(alignment: .leading, spacing: 10) {
            Label("NOW", systemImage: "clock.fill")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.blue)
            
            HStack(spacing: 16) {
                // Action badge with link to control
                NavigationLink(destination: ManualOverrideView()) {
                    VStack(spacing: 4) {
                        Text((data.action ?? "auto").uppercased())
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(actionColor(data.action ?? "auto"))
                        Text("Tap to control")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 90)
                }
                .buttonStyle(.plain)
                
                Divider()
                    .frame(height: 50)
                
                // Current stats
                HStack(spacing: 14) {
                    StatItem(icon: "sun.max.fill", value: String(format: "%.1f", data.solarKw), unit: "kW", color: .yellow)
                    StatItem(icon: "house.fill", value: String(format: "%.1f", data.houseKw), unit: "kW", color: .purple)
                    StatItem(icon: "bolt.fill", value: String(format: "%.1f", abs(data.gridKw)), unit: "kW", color: data.gridKw > 0 ? .blue : .green)
                    
                    // Battery SOC ring
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
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        Text("SOC")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Prices row
            HStack(spacing: 20) {
                HStack(spacing: 4) {
                    Text("Buy")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f¢", data.buyPrice ?? 0))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }
                HStack(spacing: 4) {
                    Text("Sell")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f¢", data.sellPrice ?? 0))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                }
                Spacer()
                if let reason = data.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .cornerRadius(12)
    }
    
    // MARK: - NEXT Section
    var nextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("NEXT", systemImage: "sun.horizon.fill")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.orange)
            
            if solarForecast.isEmpty || solarForecast.allSatisfy({ $0.kw < 0.1 }) {
                HStack {
                    Image(systemName: "moon.stars.fill")
                        .foregroundColor(.secondary)
                    Text("No significant solar expected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(solarForecast, id: \.hour) { forecast in
                        VStack(spacing: 4) {
                            Text(String(format: "%d:00", forecast.hour))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            
                            // Bar
                            let maxKw = max(solarForecast.map(\.kw).max() ?? 1, 1)
                            let height = CGFloat(forecast.kw / maxKw) * 40
                            
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.yellow.opacity(forecast.kw > 0.1 ? 0.8 : 0.2))
                                .frame(width: 28, height: max(height, 4))
                            
                            Text(String(format: "%.1f", forecast.kw))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                
                Text("kW solar generation forecast")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.05))
        .cornerRadius(12)
    }
    
    // MARK: - OPPORTUNITY Section
    var opportunitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("OPPORTUNITY", systemImage: "dollarsign.circle.fill")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.green)
            
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
                    }
                    
                    NavigationLink(destination: ManualOverrideView()) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title)
                            .foregroundColor(.green)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("No significant price spikes in the next 12 hours")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.green.opacity(0.05))
        .cornerRadius(12)
    }
    
    // MARK: - Helpers
    
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
    
    func actionColor(_ action: String) -> Color {
        switch action.lowercased() {
        case "import": return .blue
        case "export": return .green
        case "auto": return .purple
        case "charge": return .blue
        case "discharge": return .orange
        default: return .gray
        }
    }
    
    func socColor(_ soc: Double) -> Color {
        if soc >= 80 { return .green }
        else if soc >= 40 { return .yellow }
        else if soc >= 20 { return .orange }
        else { return .red }
    }
}

// MARK: - Stat Item
struct StatItem: View {
    let icon: String
    let value: String
    let unit: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
            Text(unit)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Dashboard Style Enum
enum DashboardStyle: String, CaseIterable {
    case classic = "classic"
    case sections = "sections"
    
    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .sections: return "Sections"
        }
    }
    
    var icon: String {
        switch self {
        case .classic: return "square.grid.2x2"
        case .sections: return "rectangle.split.3x1"
        }
    }
}
