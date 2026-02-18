//
//  PricesView.swift
//  Powston
//

import SwiftUI

// MARK: - Price Formatting Helpers
struct PriceFormatter {
    /// Format price in cents - shows dollars if >= 100¢
    static func format(_ cents: Double) -> String {
        if abs(cents) >= 100 {
            return String(format: "$%.2f", cents / 100)
        } else {
            return String(format: "%.1f¢", cents)
        }
    }
    
    /// Color for price based on magnitude
    static func color(_ cents: Double, isBuy: Bool = true) -> Color {
        if cents < 0 { return .green }        // Negative = they pay you
        if cents >= 500 { return .red }       // ≥$5 = extreme
        if cents >= 100 { return .orange }    // ≥$1 = elevated
        if isBuy && cents > 30 { return .red }  // Buy > 30¢ = expensive
        if !isBuy && cents > 30 { return .green } // Sell > 30¢ = good
        return isBuy ? .blue : .green
    }
    
    /// Whether price is extreme enough to highlight background
    static func isExtreme(_ cents: Double) -> Bool {
        abs(cents) >= 100
    }
}

struct PricesView: View {
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @State private var showBuyForecast = false
    @StateObject private var orientationManager = OrientationManager.shared
    
    // Track if user has dismissed rotate hint
    @AppStorage("hidePricesRotateHint") private var hidePricesRotateHint = false
    @State private var rotateHintDismissedThisSession = false
    
    var showRotateHint: Bool {
        !hidePricesRotateHint && !rotateHintDismissedThisSession
    }
    
    func dismissRotateHint() {
        rotateHintDismissedThisSession = true
        // After 3 dismissals in different sessions, hide permanently
        let dismissCount = UserDefaults.standard.integer(forKey: "pricesRotateHintDismissCount") + 1
        UserDefaults.standard.set(dismissCount, forKey: "pricesRotateHintDismissCount")
        if dismissCount >= 3 {
            hidePricesRotateHint = true
        }
    }
    
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
                                    Text(PriceFormatter.format(d.buyPrice ?? 0) + "/kWh")
                                        .foregroundColor(PriceFormatter.color(d.buyPrice ?? 0, isBuy: true))
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Buy Price: \(PriceFormatter.format(d.buyPrice ?? 0)) per kilowatt hour")
                                HStack {
                                    Text("Sell Price")
                                    Spacer()
                                    Text(PriceFormatter.format(d.sellPrice ?? 0) + "/kWh")
                                        .foregroundColor(PriceFormatter.color(d.sellPrice ?? 0, isBuy: false))
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Sell Price: \(PriceFormatter.format(d.sellPrice ?? 0)) per kilowatt hour")
                                HStack {
                                    Text("Wholesale RRP")
                                    Spacer()
                                    Text(String(format: "$%.2f/MWh", d.rrp ?? 0))
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Wholesale RRP: \(String(format: "%.2f", d.rrp ?? 0)) dollars per megawatt hour")
                                HStack {
                                    Text("Spread")
                                    Spacer()
                                    Text(PriceFormatter.format((d.buyPrice ?? 0) - (d.sellPrice ?? 0)))
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Spread: \(PriceFormatter.format((d.buyPrice ?? 0) - (d.sellPrice ?? 0)))")
                            }
                            
                            // Combined Price Forecast
                            if let buyForecast = d.buyForecast, let sellForecast = d.sellForecast,
                               !buyForecast.isEmpty || !sellForecast.isEmpty {
                                Section("Price Forecast") {
                                    // AI Price Outlook
                                    PriceForecastCard(data: d)
                                    
                                    DisclosureGroup(isExpanded: $showBuyForecast) {
                                        ForEach(0..<max(buyForecast.count, sellForecast.count), id: \.self) { i in
                                            CombinedForecastRow(
                                                period: i,
                                                buyPrice: i < buyForecast.count ? buyForecast[i] : nil,
                                                sellPrice: i < sellForecast.count ? sellForecast[i] : nil,
                                                data: d
                                            )
                                        }
                                    } label: {
                                        HStack {
                                            Text("Show \(buyForecast.count) periods")
                                            Spacer()
                                            // Mini sparkline hint
                                            HStack(spacing: 2) {
                                                Text("Buy")
                                                    .font(.caption2)
                                                    .foregroundColor(.blue)
                                                Text("/")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                Text("Sell")
                                                    .font(.caption2)
                                                    .foregroundColor(.green)
                                            }
                                        }
                                    }
                                }
                            }
                            
                            // Rotate hint (dismissible, so after forecast)
                            if showRotateHint {
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
                                        Spacer()
                                        Button(action: { dismissRotateHint() }) {
                                            Image(systemName: "xmark")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            
                            // Forecast info
                            Section {
                                HStack {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.blue)
                                        .accessibilityHidden(true)
                                    Text("Forecast: \((d.buyForecast ?? []).count) periods (\((d.buyForecast ?? []).count * 30 / 60)h \((d.buyForecast ?? []).count * 30 % 60)m)")
                                        .font(.caption)
                                }
                            }
                            
                            // Time Markers
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
                        }
                        .refreshable {
                            await api.fetchData()
                        }
                        .navigationTitle(api.isDemoMode ? "Prices (Demo)" : "Prices")
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                SiteIndicatorPill()
                            }
                        }
                    }
                }
                .toolbar(isLandscape ? .hidden : .visible, for: .tabBar)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "chart.line.downtrend.xyaxis")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    if let site = api.selectedSite, api.selectedInverterId == 0 {
                        Text("Price forecasts require inverter data")
                            .foregroundColor(.secondary)
                        Text("\(site.generationTypeLabel) — no inverter connected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("No data")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 100)
                .navigationTitle(api.isDemoMode ? "Prices (Demo)" : "Prices")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        SiteIndicatorPill()
                    }
                }
            }
        }
        .onAppear {
            orientationManager.allowLandscape()
        }
        .onDisappear {
            orientationManager.lockToPortrait()
        }
    }
}

// MARK: - AI Price Forecast Card (Performance card style)
struct PriceForecastCard: View {
    let data: InverterResponse
    @StateObject private var forecastService = PriceForecastService.shared
    @State private var forecast: PriceForecastSummary?
    @State private var hasLoaded = false
    
    var body: some View {
        Group {
            if let forecast = forecast {
                VStack(alignment: .leading, spacing: 10) {
                    // Headline row
                    HStack {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(.yellow)
                        Text(forecast.headline)
                            .font(.subheadline.bold())
                    }
                    
                    // Outlook paragraph
                    Text(forecast.outlook)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    // Best Buy / Best Peak Price row (deterministic values)
                    if forecast.bestBuyTime != nil || forecast.bestPeakPrice != nil {
                        HStack(spacing: 16) {
                            if let buyTime = forecast.bestBuyTime, let buyPrice = forecast.bestBuyPrice {
                                Label {
                                    Text("Buy: \(buyTime) (\(PriceFormatter.format(buyPrice)))")
                                        .font(.caption)
                                } icon: {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                }
                            }
                            
                            if let peakTime = forecast.bestPeakTime, let peakPrice = forecast.bestPeakPrice {
                                Label {
                                    Text("Sell: \(peakTime) (\(PriceFormatter.format(peakPrice)))")
                                        .font(.caption)
                                } icon: {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                }
                            } else if let peakPrice = forecast.bestPeakPrice {
                                // Fallback if no time but we have price
                                Label {
                                    Text("Sell: \(PriceFormatter.format(peakPrice))")
                                        .font(.caption)
                                } icon: {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    
                    // Conditional alerts section (color-coded bullets)
                    VStack(alignment: .leading, spacing: 6) {
                        // Spike alert (highest priority - red)
                        if let spikeAlert = forecast.spikeAlert {
                            ForecastAlertRow(
                                icon: "bell.fill",
                                color: .red,
                                text: spikeAlert
                            )
                        }
                        
                        // SOC advisory (yellow)
                        if let socAdvisory = forecast.socAdvisory {
                            ForecastAlertRow(
                                icon: "battery.25",
                                color: .yellow,
                                text: socAdvisory
                            )
                        }
                        
                        // Peak warning (yellow background pill)
                        if let peakWarning = forecast.peakWarning {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                                Text(peakWarning)
                                    .font(.caption.bold())
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.yellow.opacity(0.15))
                            .cornerRadius(6)
                        }
                        
                        // Least bad option (orange - shown when no good buy window)
                        if let leastBad = forecast.leastBadOption {
                            ForecastAlertRow(
                                icon: "exclamationmark.circle",
                                color: .orange,
                                text: leastBad
                            )
                        }
                        
                        // Weather impact (blue - lowest priority)
                        if let weather = forecast.weatherImpact {
                            ForecastAlertRow(
                                icon: "cloud.fill",
                                color: .blue,
                                text: weather
                            )
                        }
                    }
                    
                    // AI indicator
                    if forecast.usedAI {
                        AppleIntelligenceIndicator()
                    }
                }
                .padding(.vertical, 4)
            } else if !hasLoaded {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Analyzing prices...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .task {
            await generateForecast()
        }
        .onAppear {
            // Check if we should regenerate with AI
            if forecastService.shouldUseAI && !(forecast?.usedAI ?? false) && hasLoaded {
                Task {
                    await generateForecast()
                }
            }
        }
        .onChange(of: forecastService.isAvailable) { _, isAvailable in
            // Regenerate with AI when FM becomes available
            if isAvailable && !(forecast?.usedAI ?? false) {
                Task {
                    await generateForecast()
                }
            }
        }
    }
    
    private func generateForecast() async {
        let result = await forecastService.forecast(from: data)
        await MainActor.run {
            forecast = result
            hasLoaded = true
        }
    }
}

// MARK: - Forecast Alert Row
struct ForecastAlertRow: View {
    let icon: String
    let color: Color
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Combined Forecast Row (Buy & Sell side by side)
struct CombinedForecastRow: View {
    let period: Int
    let buyPrice: Double?
    let sellPrice: Double?
    let data: InverterResponse
    
    var isExtremePrice: Bool {
        if let buy = buyPrice, PriceFormatter.isExtreme(buy) { return true }
        if let sell = sellPrice, PriceFormatter.isExtreme(sell) { return true }
        return false
    }
    
    var body: some View {
        HStack {
            // Time column
            HStack(spacing: 4) {
                if let absTime = data.absoluteTimeForPeriod(period) {
                    Text(formatAbsoluteTime(absTime))
                        .font(.caption.monospacedDigit())
                        .frame(width: 70, alignment: .leading)
                } else {
                    Text(formatForecastTime(period: period))
                        .font(.caption.monospacedDigit())
                        .frame(width: 70, alignment: .leading)
                }
                if isSpecialPeriod {
                    Image(systemName: periodIcon)
                        .font(.caption2)
                        .foregroundColor(periodColor)
                }
            }
            
            Spacer()
            
            // Buy price
            if let buy = buyPrice {
                Text(PriceFormatter.format(buy))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(PriceFormatter.color(buy, isBuy: true))
                    .frame(width: 65, alignment: .trailing)
            } else {
                Text("—")
                    .foregroundColor(.secondary)
                    .frame(width: 65, alignment: .trailing)
            }
            
            // Sell price
            if let sell = sellPrice {
                Text(PriceFormatter.format(sell))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(PriceFormatter.color(sell, isBuy: false))
                    .frame(width: 65, alignment: .trailing)
            } else {
                Text("—")
                    .foregroundColor(.secondary)
                    .frame(width: 65, alignment: .trailing)
            }
            
            // Spread indicator
            if let buy = buyPrice, let sell = sellPrice {
                let spread = buy - sell
                Image(systemName: spread > 10 ? "arrow.up.circle.fill" : spread < 5 ? "arrow.down.circle.fill" : "circle.fill")
                    .font(.caption2)
                    .foregroundColor(spread > 10 ? .red : spread < 5 ? .green : .secondary)
                    .frame(width: 20)
            } else {
                Color.clear.frame(width: 20)
            }
        }
        .padding(.vertical, isExtremePrice ? 4 : 0)
        .padding(.horizontal, isExtremePrice ? 8 : 0)
        .background(isExtremePrice ? Color.red.opacity(0.15) : Color.clear)
        .cornerRadius(6)
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

// MARK: - Single Forecast Row (legacy)
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
            Text(PriceFormatter.format(price))
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
    @StateObject private var weather = WeatherService.shared
    
    var solarValues: [Double] {
        guard let startDate = data.forecastStartDate else { return [] }
        return weather.solarForecastForPricePeriods(startDate: startDate, periodCount: (data.buyForecast ?? []).count)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Price & Solar Forecast")
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
                            HStack(spacing: 4) {
                                Circle().fill(Color.yellow).frame(width: 8, height: 8)
                                Text("Solar").font(.caption2)
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    CombinedForecastChart(
                        buyValues: data.buyForecast ?? [],
                        sellValues: data.sellForecast ?? [],
                        solarValues: solarValues,
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
                        MiniStat(label: "Buy", value: formatRange(data.buyForecast ?? []), color: .blue)
                        MiniStat(label: "Sell", value: formatRange(data.sellForecast ?? []), color: .green)
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
                
                if let period = selectedPeriod, let buyForecast = data.buyForecast, let sellForecast = data.sellForecast, period < buyForecast.count {
                    HStack(spacing: 12) {
                        if let absTime = data.absoluteTimeForPeriod(period) {
                            Text(formatTime(absTime))
                                .font(.subheadline.monospacedDigit())
                                .fontWeight(.semibold)
                        }
                        
                        HStack(spacing: 4) {
                            Circle().fill(Color.blue).frame(width: 6, height: 6)
                            Text(PriceFormatter.format(buyForecast[period]))
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(PriceFormatter.color(buyForecast[period], isBuy: true))
                        }
                        
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text(PriceFormatter.format(sellForecast[period]))
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(PriceFormatter.color(sellForecast[period], isBuy: false))
                        }
                        
                        if period < solarValues.count && solarValues[period] > 0 {
                            HStack(spacing: 4) {
                                Circle().fill(Color.yellow).frame(width: 6, height: 6)
                                Text(String(format: "%.0fW", solarValues[period]))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(.yellow)
                            }
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
        // Use smart formatting for range
        if max >= 100 {
            return "\(PriceFormatter.format(min))-\(PriceFormatter.format(max))"
        }
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
