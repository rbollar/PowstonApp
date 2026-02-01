//
//  PricesView.swift
//  Powston
//

import SwiftUI

struct PricesView: View {
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @State private var showBuyForecast = false
    @State private var showSellForecast = false
    
    var isLandscape: Bool {
        verticalSizeClass == .compact
    }
    
    var body: some View {
        NavigationStack {
            if let d = api.data {
                Group {
                    if isLandscape {
                        PriceForecastGraphView(data: d)
                            .navigationTitle("Price Forecast")
                            .navigationBarTitleDisplayMode(.inline)
                    } else {
                        List {
                            Section("Current") {
                                HStack {
                                    Text("Buy Price")
                                    Spacer()
                                    Text(String(format: "%.2f¢/kWh", d.buyPrice))
                                }
                                HStack {
                                    Text("Sell Price")
                                    Spacer()
                                    Text(String(format: "%.2f¢/kWh", d.sellPrice))
                                }
                                HStack {
                                    Text("Wholesale RRP")
                                    Spacer()
                                    Text(String(format: "$%.2f/MWh", d.rrp))
                                }
                                HStack {
                                    Text("Spread")
                                    Spacer()
                                    Text(String(format: "%.2f¢", d.buyPrice - d.sellPrice))
                                }
                            }
                            
                            Section {
                                HStack {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.blue)
                                    Text("Forecast has \(d.buyForecast.count) periods (\(d.buyForecast.count * 30) minutes)")
                                        .font(.caption)
                                }
                            }
                            
                            if d.sunriseHour != nil || d.peakStartHour != nil {
                                Section("Time Markers") {
                                    if let sunrise = d.sunriseHour {
                                        TimeMarkerRow(icon: "sunrise.fill", color: .orange, label: "Sunrise", hour: sunrise, data: d)
                                    }
                                    if let sunset = d.sunsetHour {
                                        TimeMarkerRow(icon: "sunset.fill", color: .orange, label: "Sunset", hour: sunset, data: d)
                                    }
                                    if let peakStart = d.peakStartHour {
                                        TimeMarkerRow(icon: "bolt.fill", color: .red, label: "Peak Start", hour: peakStart, data: d)
                                    }
                                    if let peakEnd = d.peakEndHour {
                                        TimeMarkerRow(icon: "bolt.fill", color: .red, label: "Peak End", hour: peakEnd, data: d)
                                    }
                                }
                            }
                            
                            Section {
                                HStack(spacing: 12) {
                                    Image(systemName: "rotate.right")
                                        .font(.title2)
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Rotate for Graph View")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Text("Turn your phone to landscape to see the interactive price chart")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            
                            Section("Buy Forecast (30-min periods)") {
                                DisclosureGroup("Show \(d.buyForecast.count) forecast periods", isExpanded: $showBuyForecast) {
                                    ForEach(0..<d.buyForecast.count, id: \.self) { i in
                                        ForecastRow(period: i, price: d.buyForecast[i], data: d)
                                    }
                                }
                            }
                            
                            Section("Sell Forecast (30-min periods)") {
                                DisclosureGroup("Show \(d.sellForecast.count) forecast periods", isExpanded: $showSellForecast) {
                                    ForEach(0..<d.sellForecast.count, id: \.self) { i in
                                        ForecastRow(period: i, price: d.sellForecast[i], data: d)
                                    }
                                }
                            }
                        }
                        .navigationTitle(api.isDemoMode ? "Prices (Demo)" : "Prices")
                    }
                }
                .toolbar(isLandscape ? .hidden : .visible, for: .tabBar)
            } else {
                VStack {
                    Text("No data")
                        .foregroundColor(.secondary)
                }
                .navigationTitle(api.isDemoMode ? "Prices (Demo)" : "Prices")
            }
        }
    }
}

// MARK: - Forecast Row
struct ForecastRow: View {
    let period: Int
    let price: Double
    let data: InverterResponse
    
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                if let absTime = data.absoluteTimeForPeriod(period) {
                    Text(formatAbsoluteTime(absTime))
                        .font(.caption.monospacedDigit())
                } else {
                    Text(formatForecastTime(period: period))
                        .font(.caption.monospacedDigit())
                }
                if isSpecialPeriod {
                    Image(systemName: periodIcon)
                        .font(.caption2)
                        .foregroundColor(periodColor)
                }
            }
            Spacer()
            Text(String(format: "%.1f¢", price))
                .fontWeight(isSpecialPeriod ? .semibold : .regular)
        }
    }
    
    var isSpecialPeriod: Bool {
        let periodHour = Double(period) * 0.5
        
        if let sunrise = data.sunriseHour, abs(periodHour - sunrise) < 0.25 { return true }
        if let sunset = data.sunsetHour, abs(periodHour - sunset) < 0.25 { return true }
        
        if let peakStart = data.peakStartHour, let peakEnd = data.peakEndHour {
            let periodStart = Double(period) * 0.5
            let periodEnd = Double(period + 1) * 0.5
            if periodEnd > peakStart && periodStart < peakEnd { return true }
        }
        
        return false
    }
    
    var periodIcon: String {
        let periodHour = Double(period) * 0.5
        
        if let sunrise = data.sunriseHour, abs(periodHour - sunrise) < 0.25 { return "sunrise.fill" }
        if let sunset = data.sunsetHour, abs(periodHour - sunset) < 0.25 { return "sunset.fill" }
        if let peakStart = data.peakStartHour, let peakEnd = data.peakEndHour {
            if periodHour >= peakStart && periodHour < peakEnd { return "bolt.fill" }
        }
        return ""
    }
    
    var periodColor: Color {
        let periodHour = Double(period) * 0.5
        
        if let sunrise = data.sunriseHour, abs(periodHour - sunrise) < 0.25 { return .orange }
        if let sunset = data.sunsetHour, abs(periodHour - sunset) < 0.25 { return .orange }
        if let peakStart = data.peakStartHour, let peakEnd = data.peakEndHour {
            if periodHour >= peakStart && periodHour < peakEnd { return .red }
        }
        return .secondary
    }
    
    func formatForecastTime(period: Int) -> String {
        let totalMinutes = period * 30
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "+\(hours)h" : "+\(hours)h \(minutes)m"
    }
    
    func formatAbsoluteTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
}

// MARK: - Time Marker Row
struct TimeMarkerRow: View {
    let icon: String
    let color: Color
    let label: String
    let hour: Double
    let data: InverterResponse
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(formatAbsoluteTime(hour))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    func formatAbsoluteTime(_ offset: Double) -> String {
        guard let startDate = data.forecastStartDate else {
            let h = Int(offset)
            let m = Int((offset - Double(h)) * 60)
            return String(format: "%02d:%02d", h, m)
        }
        
        let offsetSeconds = offset * 3600
        guard let absoluteDate = Calendar.current.date(byAdding: .second, value: Int(offsetSeconds), to: startDate) else {
            let h = Int(offset)
            let m = Int((offset - Double(h)) * 60)
            return String(format: "%02d:%02d", h, m)
        }
        
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: absoluteDate)
    }
}

// MARK: - Price Forecast Graph View
struct PriceForecastGraphView: View {
    let data: InverterResponse
    @State private var selectedPeriod: Int? = nil
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Buy & Sell Forecast")
                            .font(.headline)
                        Spacer()
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Circle().fill(Color.blue).frame(width: 8, height: 8)
                                Text("Buy").font(.caption2)
                            }
                            HStack(spacing: 4) {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                Text("Sell").font(.caption2)
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    CombinedForecastChart(
                        buyValues: data.buyForecast,
                        sellValues: data.sellForecast,
                        sunriseHour: data.sunriseHour,
                        sunsetHour: data.sunsetHour,
                        peakStartHour: data.peakStartHour,
                        peakEndHour: data.peakEndHour,
                        data: data,
                        selectedPeriod: $selectedPeriod
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    
                    HStack(spacing: 16) {
                        MiniStat(label: "Buy", value: formatRange(data.buyForecast), color: .blue)
                        MiniStat(label: "Sell", value: formatRange(data.sellForecast), color: .green)
                        if let sunrise = data.sunriseHour {
                            MiniStat(label: "☀️", value: formatHourShort(sunrise), color: .orange)
                        }
                        if let sunset = data.sunsetHour {
                            MiniStat(label: "🌙", value: formatHourShort(sunset), color: .orange)
                        }
                        if let peakStart = data.peakStartHour, let peakEnd = data.peakEndHour {
                            MiniStat(label: "⚡", value: "\(formatHourShort(peakStart))-\(formatHourShort(peakEnd))", color: .red)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                
                if let period = selectedPeriod {
                    HStack(spacing: 16) {
                        if let absTime = data.absoluteTimeForPeriod(period) {
                            Text(formatTime(absTime))
                                .font(.subheadline.monospacedDigit())
                                .fontWeight(.semibold)
                        }
                        
                        HStack(spacing: 4) {
                            Circle().fill(Color.blue).frame(width: 6, height: 6)
                            Text(String(format: "%.1f¢", data.buyForecast[period]))
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.blue)
                        }
                        
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text(String(format: "%.1f¢", data.sellForecast[period]))
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.green)
                        }
                        
                        Spacer()
                        
                        Button(action: { selectedPeriod = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.1), radius: 4)
                    .padding(.horizontal)
                    .padding(.top, 44)
                }
            }
        }
    }
    
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
    
    func formatRange(_ values: [Double]) -> String {
        guard let min = values.min(), let max = values.max() else { return "—" }
        return String(format: "%.0f-%.0f¢", min, max)
    }
    
    func formatHourShort(_ hour: Double) -> String {
        guard let startDate = data.forecastStartDate else {
            return String(format: "%d:00", Int(hour))
        }
        let offsetSeconds = hour * 3600
        guard let date = Calendar.current.date(byAdding: .second, value: Int(offsetSeconds), to: startDate) else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
}
