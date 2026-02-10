//
//  TVContentView.swift
//  PowstonTV
//
//  Main content view for Apple TV - premium energy flow visualization
//

import SwiftUI
import Combine

struct TVContentView: View {
    @EnvironmentObject var api: TVAPI
    
    var body: some View {
        Group {
            switch api.authState {
            case .checking:
                checkingView
            case .notAuthenticated:
                SetupPromptView()
            case .authenticated:
                if api.isLoading && api.data == nil {
                    loadingView
                } else if let data = api.data {
                    TVDashboardView(data: data)
                } else if let error = api.errorMessage {
                    errorView(error)
                } else {
                    loadingView
                }
            }
        }
    }
    
    var checkingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Checking iCloud...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
    
    var loadingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
    
    func errorView(_ message: String) -> some View {
        VStack(spacing: 32) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            
            Text("Error")
                .font(.title)
            
            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Button("Retry") {
                Task { await api.fetchData() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Setup Prompt View

struct SetupPromptView: View {
    @EnvironmentObject var api: TVAPI
    @State private var isRefreshing = false
    @State private var showManualEntry = false
    
    var body: some View {
        VStack(spacing: 48) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 100))
                .foregroundStyle(.tint)
            
            VStack(spacing: 16) {
                Text("Open Energy Controller for Powston on your iPhone")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Sign in on your iPhone and your credentials will sync automatically via iCloud.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)
            }
            
            VStack(spacing: 12) {
                requirementRow(icon: "icloud.fill", text: "Same iCloud account on both devices")
                requirementRow(icon: "wifi", text: "Connected to the internet")
            }
            .padding(.top, 16)
            
            HStack(spacing: 32) {
                Button {
                    isRefreshing = true
                    Task {
                        await api.loadCredentialsAndFetch()
                        isRefreshing = false
                    }
                } label: {
                    HStack(spacing: 12) {
                        if isRefreshing {
                            ProgressView()
                        }
                        Text(isRefreshing ? "Checking..." : "Check Again")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
                
                Button("Enter API Key Manually") {
                    showManualEntry = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(64)
        .fullScreenCover(isPresented: $showManualEntry) {
            ManualEntryView(isPresented: $showManualEntry)
                .environmentObject(api)
        }
    }
    
    func requirementRow(icon: String, text: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Manual Entry View

struct ManualEntryView: View {
    @EnvironmentObject var api: TVAPI
    @Binding var isPresented: Bool
    
    @State private var apiKey = ""
    @State private var isValidating = false
    @State private var errorMessage: String?
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 48) {
            VStack(spacing: 16) {
                Image(systemName: "key.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                
                Text("Enter API Key")
                    .font(.title)
                    .fontWeight(.semibold)
                
                Text("Enter your Powston API key to connect this Apple TV.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)
            }
            
            VStack(spacing: 16) {
                TextField("API Key", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(.system(.title3, design: .monospaced))
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(12)
                    .frame(maxWidth: 600)
                    .focused($isTextFieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                
                Text("Find your API key in the Powston app under Settings → API Key")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                
                if let error = errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(error)
                    }
                    .font(.callout)
                    .foregroundStyle(.red)
                }
            }
            
            HStack(spacing: 32) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                
                Button {
                    validateAndSave()
                } label: {
                    HStack(spacing: 12) {
                        if isValidating {
                            ProgressView()
                        }
                        Text(isValidating ? "Validating..." : "Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
            }
        }
        .padding(64)
        .onAppear {
            isTextFieldFocused = true
        }
    }
    
    private func validateAndSave() {
        isValidating = true
        errorMessage = nil
        
        Task {
            if let error = await api.setManualCredentials(apiKey: apiKey) {
                errorMessage = error
            } else {
                isPresented = false
            }
            isValidating = false
        }
    }
}

// MARK: - Dashboard View

struct TVDashboardView: View {
    let data: TVData
    @EnvironmentObject var api: TVAPI
    @StateObject private var weatherService = WeatherService.shared
    @ObservedObject private var refreshManager = SmartRefreshManager.shared
    @State private var showPriceForecast = false
    @State private var showScorecardDetail = false
    @State private var isLoadingScorecard = false
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.08), Color(white: 0.04), Color(white: 0.02)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Spacer()
                    ZStack {
                        Circle()
                            .stroke(socColor.opacity(0.3), lineWidth: 40)
                            .blur(radius: 20)
                            .frame(width: 320, height: 320)
                        Circle()
                            .stroke(Color.white.opacity(0.1), lineWidth: 28)
                            .frame(width: 320, height: 320)
                        Circle()
                            .trim(from: 0, to: data.soc / 100)
                            .stroke(
                                AngularGradient(
                                    colors: [socColor.opacity(0.7), socColor, socColor.opacity(0.9)],
                                    center: .center,
                                    startAngle: .degrees(-90),
                                    endAngle: .degrees(270)
                                ),
                                style: StrokeStyle(lineWidth: 28, lineCap: .round)
                            )
                            .frame(width: 320, height: 320)
                            .rotationEffect(.degrees(-90))
                        Circle()
                            .stroke(Color.black.opacity(0.3), lineWidth: 2)
                            .frame(width: 290, height: 290)
                        VStack(spacing: 4) {
                            Text("\(Int(data.soc))")
                                .font(.system(size: 130, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("% SOC")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Spacer().frame(height: 50)
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(statusColor.opacity(0.4))
                            .blur(radius: 15)
                            .frame(width: 220, height: 70)
                        HStack(spacing: 14) {
                            Image(systemName: statusIcon)
                                .font(.system(size: 28, weight: .semibold))
                            Text(statusText)
                                .font(.system(size: 32, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(statusColor.opacity(0.25))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(statusColor.opacity(0.5), lineWidth: 2)
                                )
                        )
                    }
                    Spacer()
                }
                .frame(width: 460)
                .padding(.leading, 50)
                
                TimelineView(.animation(minimumInterval: 0.03)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.5) / 2.5
                    TVEnergyFlowView(data: data, flowPhase: phase)
                }
                .frame(maxWidth: .infinity)
                
                VStack(spacing: 24) {
                    Spacer()
                    Button { showPriceForecast = true } label: {
                        TVPriceCard(label: "BUY", price: data.buyPrice, color: .blue)
                    }
                    .buttonStyle(TVPriceButtonStyle(accentColor: .blue))
                    
                    Button { showPriceForecast = true } label: {
                        TVPriceCard(label: "SELL", price: data.sellPrice, color: .green)
                    }
                    .buttonStyle(TVPriceButtonStyle(accentColor: .green))
                    
                    Button { showScorecardDetail = true } label: {
                        TVScorecardButton(scorecard: data.scorecard, isLoading: isLoadingScorecard)
                    }
                    .buttonStyle(TVPriceButtonStyle(accentColor: gradeColor(data.scorecard?.grade ?? "—")))
                    Spacer()
                }
                .frame(width: 320)
                .padding(.trailing, 50)
            }
            
            VStack {
                HStack {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(.green.opacity(0.3)).frame(width: 28, height: 28)
                            Circle().fill(.green).frame(width: 16, height: 16)
                        }
                        Text(api.siteName)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                        if api.credentialSource == .manual {
                            Text("Manual")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.orange.opacity(0.2))
                                        .overlay(Capsule().stroke(Color.orange.opacity(0.4), lineWidth: 1))
                                )
                        }
                    }
                    Spacer()
                    Text(Date(), style: .time)
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 50)
                .padding(.top, 35)
                Spacer()
                HStack {
                    // AEMO interval time (stable, put first)
                    if let intervalTime = data.forecastStart {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 16))
                            Text("AEMO \(formatIntervalTime(intervalTime))")
                                .font(.system(size: 20))
                        }
                        .foregroundStyle(.white.opacity(0.5))
                        
                        Text("•")
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    
                    // Countdown to next update
                    HStack(spacing: 6) {
                        if refreshManager.isPolling {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Updating...")
                                .font(.system(size: 20))
                                .foregroundStyle(.white.opacity(0.5))
                        } else {
                            Circle()
                                .fill(refreshManager.secondsUntilNextPoll < 30 ? Color.yellow : Color.green)
                                .frame(width: 8, height: 8)
                            Text("Next update in \(refreshManager.countdownText)")
                                .font(.system(size: 20))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill").font(.system(size: 18))
                        Text("\(data.inverterCount) Inverter\(data.inverterCount == 1 ? "" : "s")")
                            .font(.system(size: 20))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 50)
                .padding(.bottom, 35)
            }
        }
        .fullScreenCover(isPresented: $showPriceForecast) {
            TVPriceForecastView(data: data, weatherService: weatherService)
        }
        .sheet(isPresented: $showScorecardDetail) {
            TVScorecardDetailView(scorecard: data.scorecard)
        }
        .onAppear {
            refreshManager.start(api: api)
            
            if data.scorecard == nil {
                isLoadingScorecard = true
                Task {
                    _ = await api.computeScorecard()
                    isLoadingScorecard = false
                }
            }
            Task {
                await weatherService.fetchWeather(latitude: api.siteLatitude, longitude: api.siteLongitude)
            }
        }
        .onDisappear {
            refreshManager.stop()
        }
    }
    
    var socColor: Color {
        if data.soc >= 80 { return .green }
        if data.soc >= 50 { return .yellow }
        if data.soc >= 20 { return .orange }
        return .red
    }
    
    var statusText: String {
        switch data.action.lowercased() {
        case "charge", "charging": return "CHARGING"
        case "discharge", "discharging", "export": return "EXPORTING"
        case "auto": return "AUTO"
        case "import": return "IMPORTING"
        default: return data.action.uppercased()
        }
    }
    
    var statusIcon: String {
        switch data.action.lowercased() {
        case "charge", "charging": return "arrow.down.circle.fill"
        case "discharge", "discharging", "export": return "arrow.up.circle.fill"
        case "import": return "bolt.circle.fill"
        default: return "bolt.circle.fill"
        }
    }
    
    var statusColor: Color {
        switch data.action.lowercased() {
        case "charge", "charging": return .green
        case "discharge", "discharging", "export": return .orange
        case "auto": return .blue
        case "import": return .cyan
        default: return .gray
        }
    }
    
    func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "A", "A+": return .green
        case "B+", "B": return .blue
        case "C+", "C": return .orange
        case "D", "D+", "F": return .red
        default: return .gray
        }
    }
    
    func formatIntervalTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        // Use site timezone from API if available, otherwise Brisbane
        formatter.timeZone = tvTimezone()
        return formatter.string(from: date)
    }

    // Add helper function
    func tvTimezone() -> TimeZone {
        // If TVAPI has site state, use it
        // For now, check UserDefaults (shared via iCloud)
        if let state = UserDefaults.standard.string(forKey: "selected_site_state") {
            switch state.uppercased() {
            case "NSW", "ACT":
                return TimeZone(identifier: "Australia/Sydney") ?? .current
            case "VIC":
                return TimeZone(identifier: "Australia/Melbourne") ?? .current
            case "QLD":
                return TimeZone(identifier: "Australia/Brisbane") ?? .current
            case "SA":
                return TimeZone(identifier: "Australia/Adelaide") ?? .current
            case "WA":
                return TimeZone(identifier: "Australia/Perth") ?? .current
            case "TAS":
                return TimeZone(identifier: "Australia/Hobart") ?? .current
            case "NT":
                return TimeZone(identifier: "Australia/Darwin") ?? .current
            default:
                break
            }
        }
        return TimeZone(identifier: "Australia/Brisbane") ?? .current
    }
}

// MARK: - Scorecard Button

struct TVScorecardButton: View {
    let scorecard: TVScorecardSummary?
    let isLoading: Bool
    
    var gradeColor: Color {
        guard let grade = scorecard?.grade else { return .gray }
        switch grade {
        case "A", "A+": return .green
        case "B+", "B": return .blue
        case "C+", "C": return .orange
        case "D", "D+", "F": return .red
        default: return .gray
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            if isLoading {
                ProgressView().scaleEffect(1.5).frame(height: 60)
                Text("Loading...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            } else if let scorecard = scorecard {
                Text(scorecard.grade)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(scorecard.periodLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(formatCurrency(scorecard.netPosition))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(scorecard.netPosition <= 0 ? .green : .white.opacity(0.8))
            } else {
                Text("—")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                Text("Scorecard")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 260, height: 140)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(LinearGradient(colors: [gradeColor.opacity(0.8), gradeColor.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            }
        )
        .shadow(color: gradeColor.opacity(0.4), radius: 15, y: 8)
    }
    
    func formatCurrency(_ value: Double) -> String {
        value <= 0 ? String(format: "+$%.2f", abs(value)) : String(format: "-$%.2f", value)
    }
}

// MARK: - Plain No Highlight Button Style

struct PlainNoHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

// MARK: - Full Screen Price Forecast View

struct TVPriceForecastView: View {
    let data: TVData
    @ObservedObject var weatherService: WeatherService
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedPeriod: Int? = nil
    
    var solarForecast: [Double] {
        guard let forecastStart = data.forecastStart,
              let buyForecast = data.buyForecast else { return [] }
        return weatherService.solarForecastForPricePeriods(
            startDate: forecastStart,
            periodCount: buyForecast.count
        )
    }
    
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.06), Color(white: 0.02)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Price Forecast")
                            .font(.system(size: 56, weight: .bold))
                            .foregroundStyle(.white)
                        if let selectedPeriod = selectedPeriod, let forecastStart = data.forecastStart {
                            let periodTime = Calendar.current.date(byAdding: .minute, value: selectedPeriod * 30, to: forecastStart)
                            Text(periodTime ?? Date(), style: .time)
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.6))
                        } else {
                            Text("Next 12 hours")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Spacer()
                    HStack(spacing: 48) {
                        VStack(spacing: 8) {
                            Text("BUY").font(.system(size: 20, weight: .bold)).foregroundStyle(.blue.opacity(0.8)).tracking(2)
                            Text(formatPrice(selectedBuyPrice)).font(.system(size: 52, weight: .bold, design: .rounded)).foregroundStyle(.blue)
                        }
                        VStack(spacing: 8) {
                            Text("SELL").font(.system(size: 20, weight: .bold)).foregroundStyle(.green.opacity(0.8)).tracking(2)
                            Text(formatPrice(selectedSellPrice)).font(.system(size: 52, weight: .bold, design: .rounded)).foregroundStyle(.green)
                        }
                        VStack(spacing: 8) {
                            Text("SPREAD").font(.system(size: 20, weight: .bold)).foregroundStyle(.orange.opacity(0.8)).tracking(2)
                            Text(formatPrice(selectedBuyPrice - selectedSellPrice)).font(.system(size: 52, weight: .bold, design: .rounded)).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 50)
                
                Spacer().frame(height: 40)
                
                if let buyForecast = data.buyForecast, !buyForecast.isEmpty {
                    Button {
                        dismiss()
                    } label: {
                        TVFullScreenForecastChart(
                            buyForecast: buyForecast,
                            sellForecast: data.sellForecast ?? [],
                            solarForecast: solarForecast,
                            forecastStart: data.forecastStart,
                            selectedPeriod: $selectedPeriod
                        )
                    }
                    .buttonStyle(PlainNoHighlightButtonStyle())
                    .padding(.horizontal, 60)
                    .onMoveCommand { direction in
                        handleSwipe(direction: direction, periodCount: buyForecast.count)
                    }
                    .onExitCommand { dismiss() }
                } else {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 80)).foregroundStyle(.white.opacity(0.3))
                        Text("No forecast data available").font(.title).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                }
                
                Spacer().frame(height: 30)
                
                HStack {
                    HStack(spacing: 40) {
                        LegendItem(color: .yellow.opacity(0.3), label: "Solar Radiation", isDashed: false, isFilled: true)
                        LegendItem(color: .blue, label: "Buy Price", isDashed: false, isFilled: false)
                        LegendItem(color: .green, label: "Sell Price", isDashed: false, isFilled: false)
                    }
                    Spacer()
                    Text("Swipe left/right • Press to close")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 80)
                
                Spacer().frame(height: 50)
            }
        }
    }
    
    var selectedBuyPrice: Double {
        if let period = selectedPeriod, let forecast = data.buyForecast, period < forecast.count { return forecast[period] }
        return data.buyPrice
    }
    
    var selectedSellPrice: Double {
        if let period = selectedPeriod, let forecast = data.sellForecast, period < forecast.count { return forecast[period] }
        return data.sellPrice
    }
    
    func handleSwipe(direction: MoveCommandDirection, periodCount: Int) {
        switch direction {
        case .left: selectedPeriod = selectedPeriod.map { max(0, $0 - 1) } ?? 0
        case .right: selectedPeriod = selectedPeriod.map { min(periodCount - 1, $0 + 1) } ?? 1
        default: break
        }
    }
    
    func formatPrice(_ price: Double) -> String {
        let absPrice = abs(price)
        let sign = price < 0 ? "-" : ""
        return absPrice >= 100 ? String(format: "%@$%.2f", sign, absPrice / 100) : String(format: "%@%.1f¢", sign, absPrice)
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    let isDashed: Bool
    let isFilled: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            if isFilled {
                RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 24, height: 16)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 24, height: 4)
            }
            Text(label).font(.system(size: 18)).foregroundStyle(.white.opacity(0.7))
        }
    }
}

// MARK: - Full Screen Forecast Chart

struct TVFullScreenForecastChart: View {
    let buyForecast: [Double]
    let sellForecast: [Double]
    let solarForecast: [Double]
    let forecastStart: Date?
    @Binding var selectedPeriod: Int?
    
    var maxPrice: Double { max((buyForecast + sellForecast).max() ?? 50, 50) }
    var minPrice: Double { min((buyForecast + sellForecast).min() ?? 0, 0) }
    var priceRange: Double { max(maxPrice - minPrice, 1) }
    var maxSolar: Double { max(solarForecast.max() ?? 1000, 1000) }
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let leftMargin: CGFloat = 70
            let rightMargin: CGFloat = 70
            let bottomMargin: CGFloat = 50
            let chartWidth = width - leftMargin - rightMargin
            let chartHeight = height - bottomMargin
            
            ZStack(alignment: .topLeading) {
                // Solar radiation bars (background) - one bar per hour, skip first partial hour
                if !solarForecast.isEmpty {
                    let hourlyCount = (solarForecast.count + 1) / 2
                    
                    ForEach(0..<hourlyCount, id: \.self) { hourIndex in
                        let periodIndex = hourIndex * 2
                        let solarDataIndex = periodIndex + 2  // Skip first hour of data
                        let solarValue = solarDataIndex < solarForecast.count ? solarForecast[solarDataIndex] : 0
                        
                        let startX = leftMargin + chartWidth * CGFloat(periodIndex) / CGFloat(max(buyForecast.count - 1, 1))
                        let endPeriod = min(periodIndex + 2, buyForecast.count - 1)
                        let endX = leftMargin + chartWidth * CGFloat(endPeriod) / CGFloat(max(buyForecast.count - 1, 1))
                        let barCenterX = (startX + endX) / 2
                        
                        let barHeight = solarValue > 0 && maxSolar > 0 ? chartHeight * CGFloat(solarValue / maxSolar) : 0
                        let barWidth = max(endX - startX - 4, 8)
                        
                        if barHeight > 0 && barHeight.isFinite {
                            Rectangle()
                                .fill(LinearGradient(colors: [.yellow.opacity(0.4), .yellow.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                                .frame(width: barWidth, height: barHeight)
                                .position(x: barCenterX, y: chartHeight - barHeight / 2)
                        }
                    }
                }
                
                // Grid lines
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                    let y = chartHeight * (1 - fraction)
                    Path { path in
                        path.move(to: CGPoint(x: leftMargin, y: y))
                        path.addLine(to: CGPoint(x: width - rightMargin, y: y))
                    }
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    
                    let price = minPrice + priceRange * fraction
                    Text(formatAxisPrice(price))
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.5))
                        .position(x: 35, y: y)
                }
                
                // Zero line if range includes negative
                if minPrice < 0 && maxPrice > 0 {
                    let zeroY = chartHeight * (maxPrice / priceRange)
                    Path { path in
                        path.move(to: CGPoint(x: leftMargin, y: zeroY))
                        path.addLine(to: CGPoint(x: width - rightMargin, y: zeroY))
                    }
                    .stroke(Color.white.opacity(0.4), lineWidth: 2)
                    Text("0¢").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.6)).position(x: 35, y: zeroY)
                }
                
                // Sell forecast line
                if !sellForecast.isEmpty {
                    Path { path in
                        for (index, price) in sellForecast.enumerated() {
                            let x = leftMargin + chartWidth * CGFloat(index) / CGFloat(max(sellForecast.count - 1, 1))
                            let normalizedPrice = (price - minPrice) / priceRange
                            let y = chartHeight * (1 - normalizedPrice)
                            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .shadow(color: .green.opacity(0.5), radius: 8)
                }
                
                // Buy forecast line
                Path { path in
                    for (index, price) in buyForecast.enumerated() {
                        let x = leftMargin + chartWidth * CGFloat(index) / CGFloat(max(buyForecast.count - 1, 1))
                        let normalizedPrice = (price - minPrice) / priceRange
                        let y = chartHeight * (1 - normalizedPrice)
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .shadow(color: .blue.opacity(0.5), radius: 8)
                
                // Selected period indicator
                if let period = selectedPeriod, period < buyForecast.count {
                    let x = leftMargin + chartWidth * CGFloat(period) / CGFloat(max(buyForecast.count - 1, 1))
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: chartHeight))
                    }
                    .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    
                    let buyY = chartHeight * (1 - (buyForecast[period] - minPrice) / priceRange)
                    Circle().fill(Color.blue).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .position(x: x, y: buyY)
                    
                    if period < sellForecast.count {
                        let sellY = chartHeight * (1 - (sellForecast[period] - minPrice) / priceRange)
                        Circle().fill(Color.green).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .position(x: x, y: sellY)
                    }
                }
                
                // Time labels
                HStack {
                    Text("Now"); Spacer(); Text("+3h"); Spacer(); Text("+6h"); Spacer(); Text("+9h"); Spacer(); Text("+12h")
                }
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, leftMargin)
                .offset(y: chartHeight + 15)
            }
        }
    }
    
    func formatAxisPrice(_ price: Double) -> String {
        abs(price) >= 100 ? String(format: "$%.0f", price / 100) : String(format: "%.0f¢", price)
    }
}

// MARK: - Scorecard Detail View

struct TVScorecardDetailView: View {
    let scorecard: TVScorecardSummary?
    @Environment(\.dismiss) var dismiss
    
    let componentOrder = ["Timing Efficiency", "Peak Avoidance", "Overnight Efficiency", "Morning Survival", "Opportunity Capture"]
    
    var gradeColor: Color {
        guard let grade = scorecard?.grade else { return .gray }
        switch grade {
        case "A", "A+": return .green
        case "B+", "B": return .blue
        case "C+", "C": return .orange
        case "D", "D+", "F": return .red
        default: return .gray
        }
    }
    
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.08), Color(white: 0.02)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            
            if let scorecard = scorecard {
                VStack(spacing: 40) {
                    Spacer()
                    VStack(spacing: 16) {
                        Text(scorecard.periodLabel).font(.system(size: 32, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        ZStack {
                            Circle().fill(gradeColor.opacity(0.3)).frame(width: 220, height: 220).blur(radius: 30)
                            Circle().fill(RadialGradient(colors: [gradeColor.opacity(0.4), gradeColor.opacity(0.1)], center: .center, startRadius: 0, endRadius: 100)).frame(width: 200, height: 200)
                            Circle().stroke(gradeColor, lineWidth: 4).frame(width: 200, height: 200)
                            Text(scorecard.grade).font(.system(size: 100, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        }
                        Text("Score: \(Int(scorecard.score))/100").font(.system(size: 28)).foregroundStyle(.white.opacity(0.7))
                    }
                    VStack(spacing: 8) {
                        Text("Net Position").font(.system(size: 24)).foregroundStyle(.white.opacity(0.6))
                        Text(formatCurrency(scorecard.netPosition))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundStyle(scorecard.netPosition <= 0 ? .green : .red)
                    }
                    if !scorecard.componentGrades.isEmpty {
                        VStack(spacing: 16) {
                            Text("Components").font(.system(size: 24)).foregroundStyle(.white.opacity(0.6))
                            HStack(spacing: 20) {
                                ForEach(componentOrder, id: \.self) { name in
                                    if let grade = scorecard.componentGrades[name] {
                                        ComponentGradeChip(name: shortName(name), grade: grade)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 60)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "iphone").font(.system(size: 18))
                        Text("See iPhone app for detailed breakdown").font(.system(size: 18))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 8)
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).font(.title2).padding(.bottom, 50)
                }
            } else {
                VStack(spacing: 24) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 64)).foregroundStyle(.white.opacity(0.3))
                    Text("No scorecard data").font(.title).foregroundStyle(.white.opacity(0.5))
                    Text("Performance data is still loading").font(.title3).foregroundStyle(.white.opacity(0.4))
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).font(.title2).padding(.top, 32)
                }
            }
        }
    }
    
    func formatCurrency(_ value: Double) -> String {
        value <= 0 ? String(format: "+$%.2f", abs(value)) : String(format: "-$%.2f", value)
    }
    
    func shortName(_ name: String) -> String {
        switch name {
        case "Timing Efficiency": return "Timing"
        case "Peak Avoidance": return "Peak"
        case "Overnight Efficiency": return "Night"
        case "Morning Survival": return "Morning"
        case "Opportunity Capture": return "Opportunity"
        default: return String(name.prefix(8))
        }
    }
}

struct ComponentGradeChip: View {
    let name: String
    let grade: String
    
    var gradeColor: Color {
        switch grade {
        case "A", "A+": return .green
        case "B+", "B": return .blue
        case "C+", "C": return .orange
        default: return .red
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            Text(grade).font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(gradeColor)
            Text(name).font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(width: 100)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(gradeColor.opacity(0.3), lineWidth: 1))
        )
    }
}

// MARK: - Premium Energy Flow Visualization

struct TVEnergyFlowView: View {
    let data: TVData
    let flowPhase: CGFloat
    
    var isGridExporting: Bool {
        let expectedGrid = data.solarKw + (data.isCharging ? 0 : data.batteryKw) - data.loadKw - (data.isCharging ? data.batteryKw : 0)
        return expectedGrid > 0.1
    }
    
    var body: some View {
        GeometryReader { geo in
            let centerX = geo.size.width / 2
            let centerY = geo.size.height / 2
            let solarPos = CGPoint(x: centerX, y: centerY - 200)
            let inverterPos = CGPoint(x: centerX, y: centerY)
            let gridPos = CGPoint(x: centerX - 240, y: centerY)
            let homePos = CGPoint(x: centerX + 240, y: centerY)
            let batteryPos = CGPoint(x: centerX, y: centerY + 200)
            
            ZStack {
                RadialGradient(colors: [Color.white.opacity(0.03), Color.clear], center: .center, startRadius: 50, endRadius: 350)
                
                TVCurvedFlowLine(from: CGPoint(x: solarPos.x, y: solarPos.y + 55), to: CGPoint(x: inverterPos.x, y: inverterPos.y - 55), curveDirection: .none, isActive: data.solarKw > 0.05, flowPhase: flowPhase, color: .yellow, intensity: min(data.solarKw / 10, 1.0))
                
                if isGridExporting {
                    TVCurvedFlowLine(from: CGPoint(x: inverterPos.x - 55, y: inverterPos.y), to: CGPoint(x: gridPos.x + 55, y: gridPos.y), curveDirection: .up, isActive: abs(data.gridKw) > 0.05, flowPhase: flowPhase, color: .green, intensity: min(abs(data.gridKw) / 10, 1.0))
                } else {
                    TVCurvedFlowLine(from: CGPoint(x: gridPos.x + 55, y: gridPos.y), to: CGPoint(x: inverterPos.x - 55, y: inverterPos.y), curveDirection: .down, isActive: abs(data.gridKw) > 0.05, flowPhase: flowPhase, color: .cyan, intensity: min(abs(data.gridKw) / 10, 1.0))
                }
                
                TVCurvedFlowLine(from: CGPoint(x: inverterPos.x + 55, y: inverterPos.y), to: CGPoint(x: homePos.x - 55, y: homePos.y), curveDirection: .up, isActive: data.loadKw > 0.05, flowPhase: flowPhase, color: .purple, intensity: min(data.loadKw / 10, 1.0))
                
                if data.isCharging {
                    TVCurvedFlowLine(from: CGPoint(x: inverterPos.x, y: inverterPos.y + 55), to: CGPoint(x: batteryPos.x, y: batteryPos.y - 55), curveDirection: .none, isActive: data.batteryKw > 0.05, flowPhase: flowPhase, color: .cyan, intensity: min(data.batteryKw / 15, 1.0))
                } else {
                    TVCurvedFlowLine(from: CGPoint(x: batteryPos.x, y: batteryPos.y - 55), to: CGPoint(x: inverterPos.x, y: inverterPos.y + 55), curveDirection: .none, isActive: data.batteryKw > 0.05, flowPhase: flowPhase, color: .orange, intensity: min(data.batteryKw / 15, 1.0))
                }
                
                TVPremiumNode(icon: "sun.max.fill", label: "SOLAR", value: formatPower(data.solarKw), color: .yellow, isActive: data.solarKw > 0.05).position(solarPos)
                TVPremiumNode(icon: isGridExporting ? "arrow.up.forward.circle.fill" : "arrow.down.backward.circle.fill", label: isGridExporting ? "EXPORT" : "IMPORT", value: formatPower(abs(data.gridKw)), color: isGridExporting ? .green : .cyan, isActive: abs(data.gridKw) > 0.05).position(gridPos)
                TVInverterHub(isActive: true).position(inverterPos)
                TVPremiumNode(icon: "house.fill", label: "HOME", value: formatPower(data.loadKw), color: .purple, isActive: data.loadKw > 0.05).position(homePos)
                TVPremiumBatteryNode(soc: data.soc, power: data.batteryKw, isCharging: data.isCharging).position(batteryPos)
            }
        }
    }
    
    func formatPower(_ kw: Double) -> String {
        if kw < 0.1 { return "0 W" }
        else if kw < 1 { return String(format: "%.0f W", kw * 1000) }
        else { return String(format: "%.1f kW", kw) }
    }
}

enum CurveDirection { case up, down, none }

struct TVCurvedFlowLine: View {
    let from: CGPoint
    let to: CGPoint
    let curveDirection: CurveDirection
    let isActive: Bool
    let flowPhase: CGFloat
    let color: Color
    let intensity: CGFloat
    
    var controlPoint: CGPoint {
        let midX = (from.x + to.x) / 2
        let midY = (from.y + to.y) / 2
        let offset: CGFloat = 40
        switch curveDirection {
        case .up: return CGPoint(x: midX, y: midY - offset)
        case .down: return CGPoint(x: midX, y: midY + offset)
        case .none: return CGPoint(x: midX, y: midY)
        }
    }
    
    var body: some View {
        ZStack {
            if isActive {
                Path { path in path.move(to: from); path.addQuadCurve(to: to, control: controlPoint) }
                    .stroke(color.opacity(0.4 * intensity), lineWidth: 12).blur(radius: 8)
            }
            Path { path in path.move(to: from); path.addQuadCurve(to: to, control: controlPoint) }
                .stroke(isActive ? color.opacity(0.6) : Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            if isActive { TVEnergyParticles(from: from, to: to, control: controlPoint, phase: flowPhase, color: color, intensity: intensity) }
        }
    }
}

struct TVEnergyParticles: View {
    let from: CGPoint
    let to: CGPoint
    let control: CGPoint
    let phase: CGFloat
    let color: Color
    let intensity: CGFloat
    let particleCount = 5
    
    var body: some View {
        ForEach(0..<particleCount, id: \.self) { i in
            let progress = (phase + CGFloat(i) / CGFloat(particleCount)).truncatingRemainder(dividingBy: 1)
            let pos = quadBezierPoint(from: from, to: to, control: control, t: progress)
            let size: CGFloat = 14 + (intensity * 6)
            ZStack {
                Circle().fill(color.opacity(0.3)).frame(width: size * 2.5, height: size * 2.5).blur(radius: 8)
                Circle().fill(RadialGradient(colors: [.white, color], center: .center, startRadius: 0, endRadius: size / 2)).frame(width: size, height: size)
            }
            .position(pos)
            .opacity(particleOpacity(progress: progress))
        }
    }
    
    func quadBezierPoint(from: CGPoint, to: CGPoint, control: CGPoint, t: CGFloat) -> CGPoint {
        let x = pow(1 - t, 2) * from.x + 2 * (1 - t) * t * control.x + pow(t, 2) * to.x
        let y = pow(1 - t, 2) * from.y + 2 * (1 - t) * t * control.y + pow(t, 2) * to.y
        return CGPoint(x: x, y: y)
    }
    
    func particleOpacity(progress: CGFloat) -> Double {
        if progress < 0.1 { return Double(progress / 0.1) }
        else if progress > 0.9 { return Double((1 - progress) / 0.1) }
        return 1.0
    }
}

// MARK: - Premium Node

struct TVPremiumNode: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    let isActive: Bool
    
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                if isActive { Circle().fill(color.opacity(0.3)).frame(width: 110, height: 110).blur(radius: 15) }
                Circle().fill(RadialGradient(colors: [isActive ? color.opacity(0.3) : Color.white.opacity(0.1), isActive ? color.opacity(0.1) : Color.white.opacity(0.05)], center: .center, startRadius: 0, endRadius: 50)).frame(width: 100, height: 100)
                Circle().stroke(isActive ? color.opacity(0.8) : Color.white.opacity(0.2), lineWidth: isActive ? 3 : 1).frame(width: 100, height: 100)
                Image(systemName: icon).font(.system(size: 44, weight: .medium)).foregroundStyle(isActive ? color : Color.white.opacity(0.4)).shadow(color: isActive ? color.opacity(0.5) : .clear, radius: 10)
            }
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(isActive ? .white : .white.opacity(0.5))
            Text(label).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).tracking(1)
        }
    }
}

struct TVInverterHub: View {
    let isActive: Bool
    @State private var rotation: Double = 0
    
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.1)).frame(width: 120, height: 120).blur(radius: 20)
            Circle().stroke(AngularGradient(colors: [.blue.opacity(0.5), .green.opacity(0.5), .orange.opacity(0.5), .blue.opacity(0.5)], center: .center), lineWidth: 3).frame(width: 100, height: 100).rotationEffect(.degrees(rotation))
            Circle().fill(RadialGradient(colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)], center: .center, startRadius: 0, endRadius: 45)).frame(width: 90, height: 90)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)).frame(width: 50, height: 50).offset(x: 4, y: 4)
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.15)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.3), lineWidth: 1)).frame(width: 50, height: 50)
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 24, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .onAppear { withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { rotation = 360 } }
    }
}

struct TVPremiumBatteryNode: View {
    let soc: Double
    let power: Double
    let isCharging: Bool
    
    var socColor: Color {
        if soc >= 80 { return .green }
        if soc >= 50 { return .yellow }
        if soc >= 20 { return .orange }
        return .red
    }
    
    var activeColor: Color { isCharging ? .cyan : .orange }
    
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                if power > 0.1 { Circle().fill(activeColor.opacity(0.3)).frame(width: 110, height: 110).blur(radius: 15) }
                Circle().fill(RadialGradient(colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)], center: .center, startRadius: 0, endRadius: 50)).frame(width: 100, height: 100)
                Circle().trim(from: 0, to: soc / 100).stroke(socColor, style: StrokeStyle(lineWidth: 4, lineCap: .round)).frame(width: 100, height: 100).rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.5)).frame(width: 16, height: 6)
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 2).frame(width: 40, height: 52)
                        RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [socColor, socColor.opacity(0.7)], startPoint: .top, endPoint: .bottom)).frame(width: 34, height: max(4, 46 * soc / 100)).padding(.bottom, 3)
                    }
                }
            }
            Text(formatPower(power)).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(power > 0.1 ? .white : .white.opacity(0.5))
            Text(isCharging ? "CHARGING" : "DISCHARGE").font(.system(size: 16, weight: .semibold)).foregroundStyle(activeColor.opacity(power > 0.1 ? 0.8 : 0.4)).tracking(1)
        }
    }
    
    func formatPower(_ kw: Double) -> String {
        if kw < 0.1 { return "0 W" }
        else if kw < 1 { return String(format: "%.0f W", kw * 1000) }
        else { return String(format: "%.1f kW", kw) }
    }
}

struct TVPriceCard: View {
    let label: String
    let price: Double
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            Text(label).font(.system(size: 20, weight: .bold)).foregroundStyle(.white.opacity(0.7)).tracking(2)
            Text(formatPrice(price)).font(.system(size: 64, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(width: 260, height: 140)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.2), lineWidth: 1)
            }
        )
        .shadow(color: color.opacity(0.4), radius: 15, y: 8)
    }
    
    func formatPrice(_ price: Double) -> String {
        let absPrice = abs(price)
        let sign = price < 0 ? "-" : ""
        return absPrice >= 100 ? String(format: "%@$%.0f", sign, absPrice / 100) : String(format: "%@%.1f¢", sign, absPrice)
    }
}

struct TVPriceButtonStyle: ButtonStyle {
    let accentColor: Color
    @Environment(\.isFocused) var envFocused
    @FocusState private var isFocused: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        let focused = envFocused || isFocused
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white, lineWidth: focused ? 4 : 0))
            .scaleEffect(configuration.isPressed ? 0.95 : (focused ? 1.08 : 1.0))
            .shadow(color: focused ? accentColor.opacity(0.6) : accentColor.opacity(0.3), radius: focused ? 30 : 15, y: focused ? 15 : 8)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.2), value: focused)
            .focusable()
            .focused($isFocused)
    }
}
