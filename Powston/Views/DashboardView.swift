//
//  DashboardView.swift
//  Powston
//

import SwiftUI
import Combine

struct DashboardView: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var currentTime = Date()
    @State private var timer: Timer?
    @AppStorage("dashboard_style") private var dashboardStyle: DashboardStyle = .sections
    
    var body: some View {
        NavigationStack {
            ScrollView {
                if let d = api.data {
                    VStack(spacing: 24) {
                        // Demo mode banner
                        if api.isDemoMode {
                            HStack {
                                Image(systemName: "theatermasks.fill")
                                    .foregroundColor(.orange)
                                Text("Demo Mode Active")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("Using sample data")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(12)
                            .padding(.horizontal)
                        }
                        
                        PriceAlertBanner()
                            .padding(.horizontal)
                        
                        // Switch between dashboard styles
                        switch dashboardStyle {
                        case .sections:
                            SectionsDashboard(data: d)
                                .id("sections-dashboard")  // Stable identity to prevent recreation
                            
                            // Still show weather widget in sections mode
                            if let site = api.selectedSite,
                               let lat = site.latitude,
                               let lon = site.longitude {
                                WeatherWidget(latitude: lat, longitude: lon)
                                    .padding(.horizontal)
                            }
                            
                            // Leaderboard card
                            LeaderboardCard()
                                .padding(.horizontal)

                            // Action Items card
                            ActionItemsDashboardCard()
                                .padding(.horizontal)

                        case .classic:
                            // NOW-style card
                            VStack(spacing: 16) {
                                // Row 1: Solar, Home, Export/Import, Battery
                                HStack(spacing: 0) {
                                    ClassicStatItem(
                                        icon: "sun.max.fill",
                                        value: String(format: "%.1f", d.solarKw),
                                        label: "Solar",
                                        color: .yellow,
                                        onTap: { TabSelection.shared.selectedTab = .decisions }
                                    )
                                    .frame(maxWidth: .infinity)
                                    
                                    ClassicStatItem(
                                        icon: "house.fill",
                                        value: String(format: "%.1f", d.displayHouseKw),
                                        label: "Home",
                                        color: .purple,
                                        showBadge: d.hasSignificantImbalance,
                                        onTap: { TabSelection.shared.selectedTab = .decisions }
                                    )
                                    .frame(maxWidth: .infinity)
                                    
                                    ClassicStatItem(
                                        icon: "bolt.fill",
                                        value: String(format: "%.1f", abs(d.gridKw)),
                                        label: d.isGridExporting ? "Export" : "Import",
                                        color: d.isGridExporting ? .green : .blue,
                                        onTap: { TabSelection.shared.selectedTab = .decisions }
                                    )
                                    .frame(maxWidth: .infinity)
                                    
                                    ClassicStatItem(
                                        icon: d.isCharging ? "battery.100.bolt" : "battery.75",
                                        value: String(format: "%.1f", abs(d.batteryKw)),
                                        label: d.isCharging ? "Charge" : "Dchg",
                                        color: d.isCharging ? .green : .orange,
                                        onTap: { TabSelection.shared.selectedTab = .decisions }
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                
                                Divider()
                                    .padding(.horizontal)
                                
                                // Row 2: Action and SOC
                                HStack(spacing: 24) {
                                    // Action badge - tappable
                                    ActionBadgeView(api: api, realtimeAction: d.action, flowAction: d.lastAction)
                                    
                                    Spacer()
                                    
                                    // SOC ring
                                    VStack(spacing: 4) {
                                        ZStack {
                                            Circle()
                                                .stroke(Color.gray.opacity(0.3), lineWidth: 6)
                                                .frame(width: 56, height: 56)
                                            Circle()
                                                .trim(from: 0, to: (d.batterySoc ?? 0) / 100)
                                                .stroke(socColor(d.batterySoc ?? 0), lineWidth: 6)
                                                .frame(width: 56, height: 56)
                                                .rotationEffect(.degrees(-90))
                                            Text("\(Int(d.batterySoc ?? 0))")
                                                .font(.title3.weight(.bold))
                                        }
                                        Text("SOC")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Battery state of charge: \(Int(d.batterySoc ?? 0)) percent")
                                }
                                .padding(.horizontal, 28)
                                
                                // Prices row
                                HStack(spacing: 20) {
                                    HStack(spacing: 4) {
                                        Text("Buy")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        InlinePriceText(cents: d.buyPrice ?? 0, isBuy: true)
                                    }
                                    HStack(spacing: 4) {
                                        Text("Sell")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        InlinePriceText(cents: d.sellPrice ?? 0, isBuy: false)
                                    }
                                    Spacer()
                                    TodayPLCard()
                                        .frame(width: 100)
                                }
                                .padding(.horizontal)
                            }
                            .padding(.vertical, 16)
                            .background(Color.blue.opacity(0.05))
                            .cornerRadius(16)
                            .padding(.horizontal)
                            
                            // Weather / Solar Forecast
                            if let site = api.selectedSite,
                               let lat = site.latitude,
                               let lon = site.longitude {
                                WeatherWidget(latitude: lat, longitude: lon)
                                    .padding(.horizontal)
                            }
                            
                            // Leaderboard card
                            LeaderboardCard()
                                .padding(.horizontal)

                            // Action Items card
                            ActionItemsDashboardCard()
                                .padding(.horizontal)

                        case .ems:
                            EMSDashboard(data: d)

                            // Weather widget
                            if let site = api.selectedSite,
                               let lat = site.latitude,
                               let lon = site.longitude {
                                WeatherWidget(latitude: lat, longitude: lon)
                                    .padding(.horizontal)
                            }

                            // Leaderboard card
                            LeaderboardCard()
                                .padding(.horizontal)

                            // Action Items card
                            ActionItemsDashboardCard()
                                .padding(.horizontal)

                        case .snapshot:
                            DecisionSnapshotDashboard(data: d)

                            // Weather widget
                            if let site = api.selectedSite,
                               let lat = site.latitude,
                               let lon = site.longitude {
                                WeatherWidget(latitude: lat, longitude: lon)
                                    .padding(.horizontal)
                            }

                            // Leaderboard card
                            LeaderboardCard()
                                .padding(.horizontal)

                            // Action Items card
                            ActionItemsDashboardCard()
                                .padding(.horizontal)
                        }
                    }
                    .padding(.bottom, 20)  // Space above tab bar
                } else if api.isLoading {
                    ProgressView("Loading...")
                        .padding(.top, 100)
                } else if api.selectedInverterId == 0 && api.selectedSite != nil && !api.apiKey.isEmpty {
                    // Zero-inverter site (e.g. hydro) — show reduced dashboard
                    VStack(spacing: 24) {
                        // Info banner with generation-aware messaging
                        HStack {
                            if let site = api.selectedSite {
                                Image(systemName: site.generationIcon)
                                    .foregroundColor(site.generationColor)
                                Text("\(site.generationTypeLabel) — live data not available")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            } else {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.blue)
                                Text("Live data not available")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .background((api.selectedSite?.generationColor ?? .blue).opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal)

                        // P&L card
                        TodayPLCard()
                            .padding(.horizontal)

                        // Weather widget
                        if let site = api.selectedSite,
                           let lat = site.latitude,
                           let lon = site.longitude {
                            WeatherWidget(latitude: lat, longitude: lon)
                                .padding(.horizontal)
                        }

                        // Leaderboard card
                        LeaderboardCard()
                            .padding(.horizontal)
                    }
                    .padding(.bottom, 20)
                } else if api.selectedInverterId == 0 {
                    WelcomeView()
                } else if let err = api.error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(err)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            Task { await api.fetchData() }
                        }
                    }
                    .padding(.top, 100)
                }
            }
            .refreshable {
                await api.fetchData()
                if let site = api.selectedSite,
                   let lat = site.latitude,
                   let lon = site.longitude {
                    await WeatherService.shared.fetchWeather(latitude: lat, longitude: lon)
                }
            }
            .background(Color.gray.opacity(0.05))
            .navigationTitle(dashboardTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        SiteIndicatorPill()
                        StatusIndicator(api: api)
                    }
                }
            }
            .onAppear {
                startTimer()
            }
            .onDisappear {
                stopTimer()
            }
        }
    }
    
    private func startTimer() {
        // Only update time if timer isn't already running (avoid redraw on tab switch)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            currentTime = Date()
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private var dashboardTitle: String {
        if api.isDemoMode {
            return "Demo Mode"
        }
        if let site = api.selectedSite {
            return site.displayName ?? site.name
        }
        return "Dashboard"
    }
    
    func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
    
    func timeAgo(_ date: Date) -> String {
        let seconds = Int(currentTime.timeIntervalSince(date))
        
        if seconds < 60 {
            return "just now"
        } else if seconds < 120 {
            return "1 minute ago"
        } else if seconds < 3600 {
            return "\(seconds / 60) minutes ago"
        } else if seconds < 7200 {
            return "1 hour ago"
        } else {
            return "\(seconds / 3600) hours ago"
        }
    }
    
    func dataAgeColor(_ date: Date) -> Color {
        let seconds = currentTime.timeIntervalSince(date)
        
        if seconds < 300 { return .green }
        else if seconds < 600 { return .yellow }
        else if seconds < 1800 { return .orange }
        else { return .red }
    }
    
    func socColor(_ soc: Double) -> Color {
        if soc >= 80 { return .green }
        if soc >= 40 { return .yellow }
        if soc >= 20 { return .orange }
        return .red
    }
    
    /// Normalized action category for color/icon matching
    private func actionCategory(_ action: String) -> String {
        let lower = action.lowercased()
        if lower.contains("curtail") { return "curtail" }
        if lower.contains("export") || lower.contains("trickle") || lower == "p2p exp" { return "export" }
        if lower.contains("import") || lower == "p2p imp" { return "import" }
        if lower.contains("charge") { return "charge" }
        if lower.contains("discharge") { return "discharge" }
        if lower.contains("auto") || lower.contains("hold") { return "auto" }
        return lower
    }

    func actionIcon(_ action: String) -> String {
        switch actionCategory(action) {
        case "import": return "arrow.down.circle.fill"
        case "export": return "arrow.up.circle.fill"
        case "charge": return "battery.100.bolt"
        case "curtail": return "sun.max.trianglebadge.exclamationmark"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    func actionColor(_ action: String) -> Color {
        switch actionCategory(action) {
        case "import": return .blue
        case "export": return .green
        case "charge": return .yellow
        case "curtail": return .orange
        default: return .gray
        }
    }

    func badgeColor(for action: String) -> Color {
        if api.hasActiveOverride {
            return .orange
        } else if api.hasPendingOverride {
            return .blue
        } else {
            return actionColor(action)
        }
    }

    func displayAction(_ action: String, gridKw: Double? = nil) -> String {
        let lower = action.lowercased()
        if lower.contains("curtail") {
            return "Curtail"
        } else if lower.contains("export") {
            // Without optimal_discharging, just show "Export" for historical chart overlays
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
}

// MARK: - Classic Stat Item (larger version for classic dashboard)
struct ClassicStatItem: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    var showBadge: Bool = false
    var onTap: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundColor(color)
                    .frame(height: 32)
                
                if showBadge {
                    Image(systemName: "plusminus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .offset(x: 8, y: -4)
                }
            }
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
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

// MARK: - Welcome View
struct WelcomeView: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var showDashboardPicker = false
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.slash.circle")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("Welcome to Powston")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Monitor your solar, battery, and energy optimization")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 16) {
                Button(action: {
                    showDashboardPicker = true
                }) {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "theatermasks.fill")
                                .font(.title3)
                            Text("Try Demo Mode")
                                .font(.headline)
                        }
                        Text("Explore the app with sample data")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange.opacity(0.15))
                    .foregroundColor(.orange)
                    .cornerRadius(12)
                }
                
                NavigationLink(destination: SettingsView()) {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "key.fill")
                                .font(.title3)
                            Text("Connect Your Account")
                                .font(.headline)
                        }
                        Text("Enter your API key to get started")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green.opacity(0.15))
                    .foregroundColor(.green)
                    .cornerRadius(12)
                }
            }
            .padding(.horizontal, 30)
            
            VStack(spacing: 4) {
                Text("Not a Powston customer?")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Link("Learn more about Powston", destination: URL(string: "https://powston.com.au")!)
                    .font(.caption)
            }
            .padding(.top, 8)
        }
        .padding(.top, 60)
        .padding(.horizontal, 20)
        .sheet(isPresented: $showDashboardPicker) {
            DashboardPickerSheet(isDemo: true) {
                api.demoModeEnabled = true
                api.loadDemoData()
            }
        }
    }
}

// MARK: - Dashboard Picker Sheet
struct DashboardPickerSheet: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("dashboard_style") private var dashboardStyle: DashboardStyle = .sections
    
    let isDemo: Bool
    let onComplete: () -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                    
                    Text("Choose Your Dashboard")
                        .font(.title)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text("Pick a layout that fits how you like to monitor your system")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                }
                .padding(.top, 20)
                
                // Dashboard options
                VStack(spacing: 12) {
                    ForEach(DashboardStyle.allCases, id: \.self) { style in
                        DashboardOptionCard(
                            style: style,
                            title: style.displayName,
                            description: style.description,
                            icon: style.icon,
                            isSelected: dashboardStyle == style
                        ) {
                            dashboardStyle = style
                        }
                    }
                }
                .padding(.horizontal)
                
                Spacer()
                
                // Footer
                VStack(spacing: 12) {
                    Button(action: {
                        onComplete()
                        dismiss()
                    }) {
                        Text("Get Started")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)
                    
                    Text("You can change this anytime in Settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 30)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") {
                        onComplete()
                        dismiss()
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Dashboard Option Card
struct DashboardOptionCard: View {
    let style: DashboardStyle
    let title: String
    let description: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundColor(isSelected ? .white : .green)
                    .frame(width: 50, height: 50)
                    .background(isSelected ? Color.green : Color.green.opacity(0.15))
                    .cornerRadius(12)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.green : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Today's P&L Card
struct TodayPLCard: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var todayNet: Double?
    @State private var dataDate: Date?
    @State private var isLoading = false
    
    var dateLabel: String {
        guard let date = dataDate else { return "–" }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            formatter.timeZone = powstonTimezone()
            return formatter.string(from: date)
        }
    }
    
    var accessibilityDescription: String {
        if isLoading {
            return "Loading profit and loss"
        } else if let net = todayNet {
            let sign = net >= 0 ? "profit" : "loss"
            return "\(dateLabel) net \(sign): \(formatCurrency(abs(net)))"
        } else {
            return "Profit and loss unavailable"
        }
    }
    
    var body: some View {
        Button(action: {
            TabSelection.shared.selectedTab = .history
        }) {
            VStack(spacing: 6) {
                Text(dateLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if let net = todayNet {
                    Text(formatCurrency(net))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(net >= 0 ? .green : .red)
                } else {
                    Text("–")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                }
                
                Text("Net P&L")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double tap to view history")
        .task {
            await loadTodayPL()
        }
    }
    
    func loadTodayPL() async {
        guard !api.isDemoMode else {
            // Demo data
            todayNet = -8.61
            dataDate = Date()
            return
        }
        
        isLoading = true
        
        // Use yesterday (last complete day) to match History view
        // Today's data is incomplete until end of day
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        
        // Fetch yesterday's records
        let records = await api.fetchMeterRecords(fromDate: yesterday, toDate: yesterday)
        
        dataDate = yesterday

        if !records.isEmpty {
            let earnings = records.compactMap { $0.earnings }.reduce(0, +) / 100.0
            let costs = records.compactMap { $0.costs }.reduce(0, +) / 100.0
            todayNet = earnings - costs
        } else {
            todayNet = nil
        }
        isLoading = false
    }

    func formatCurrency(_ value: Double) -> String {
        let absValue = abs(value)
        let prefix = value >= 0 ? "+$" : "-$"
        return prefix + String(format: "%.2f", absValue)
    }
}

// MARK: - Detailed P&L Card (for Decisions page)
struct DetailedPLCard: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var todayNet: Double?
    @State private var dataDate: Date?
    @State private var isLoading = false
    
    var buyPrice: Double {
        api.data?.buyPrice ?? 0
    }
    
    var sellPrice: Double {
        api.data?.sellPrice ?? 0
    }
    
    var body: some View {
        VStack(spacing: 8) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 4) {
                        Text("Buy")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.2f", buyPrice))
                            .font(.headline.monospacedDigit())
                            .foregroundColor(.blue)
                        Text("¢/kWh")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(spacing: 4) {
                        Text("Sell")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.2f", sellPrice))
                            .font(.headline.monospacedDigit())
                            .foregroundColor(.green)
                        Text("¢/kWh")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(spacing: 4) {
                        Text("Yesterday")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let net = todayNet {
                            Text(formatCurrency(net))
                                .font(.headline.monospacedDigit())
                                .foregroundColor(net >= 0 ? .green : .red)
                        } else {
                            Text("–")
                                .font(.headline.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Text("Net P&L")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
        .task {
            await loadTodayPL()
        }
    }
    
    func loadTodayPL() async {
        guard !api.isDemoMode else {
            todayNet = 4.75
            dataDate = Date()
            return
        }
        
        isLoading = true
        
        // Use yesterday (last complete day) to match History view
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        
        // Fetch yesterday's records
        let records = await api.fetchMeterRecords(fromDate: yesterday, toDate: yesterday)
        
        dataDate = yesterday

        if !records.isEmpty {
            let earnings = records.compactMap { $0.earnings }.reduce(0, +) / 100.0
            let costs = records.compactMap { $0.costs }.reduce(0, +) / 100.0
            todayNet = earnings - costs
        } else {
            todayNet = nil
        }
        isLoading = false
    }

    func formatCurrency(_ value: Double) -> String {
        let absValue = abs(value)
        let prefix = value >= 0 ? "+$" : "-$"
        return prefix + String(format: "%.2f", absValue)
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    @ObservedObject var api: PowstonAPI
    @ObservedObject var refreshManager = SmartRefreshManager.shared
    @State private var showingDetails = false
    
    var isStale: Bool {
        guard let lastUpdate = refreshManager.lastUpdateTime else {
            // Fall back to api.lastFetchTime if no update yet
            guard let lastFetch = api.lastFetchTime else { return true }
            return Date().timeIntervalSince(lastFetch) > 360
        }
        return Date().timeIntervalSince(lastUpdate) > 360 // 6 minutes
    }
    
    var statusColor: Color {
            // Blue while polling
            if refreshManager.isPolling { return .blue }
            
            // Powston service down = red, highest priority
            if !api.powstonServiceOnline { return .red }
            
            // Controller health takes priority over staleness
            switch api.controllerHealthStatus {
            case .offline:
                return .red
            case .degraded:
                return .orange
            case .healthy, .unknown:
                return isStale ? .red : .green
            }
        }
    
    var statusDescription: String {
            if refreshManager.isPolling {
                return "Updating..."
            }
            if !api.powstonServiceOnline {
                return "Powston service offline"
            }
            switch api.controllerHealthStatus {
            case .offline:
                return "All controllers offline"
            case .degraded(let count):
                return "\(count) controller\(count == 1 ? "" : "s") offline"
            case .healthy:
                return isStale ? "Data is stale" : "All systems operational"
            case .unknown:
                return isStale ? "Data is stale" : "Connected"
            }
        }
    
    var body: some View {
        Button(action: { showingDetails.toggle() }) {
            HStack(spacing: 4) {
                if refreshManager.isPolling {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                }
                
                // Show countdown when not polling and under 60s
                if !refreshManager.isPolling && refreshManager.secondsUntilNextPoll <= 60 {
                    Text(refreshManager.countdownText)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
        .popover(isPresented: $showingDetails) {
            StatusDetailView(api: api)
        }
        .accessibilityLabel("System status: \(statusDescription)")
    }
}


// MARK: - Compact P&L Indicator
struct CompactPLIndicator: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var todayNet: Double?
    @State private var isLoading = false
    
    var body: some View {
        Button(action: {
            TabSelection.shared.selectedTab = .decisions
        }) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else if let net = todayNet {
                Text(formatCurrency(net))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundColor(net >= 0 ? .green : .red)
            } else {
                Text("–")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .task {
            await loadTodayPL()
        }
    }
    
    func loadTodayPL() async {
        guard !api.isDemoMode else {
            todayNet = 4.75
            return
        }

        isLoading = true

        // Use latestCompleteDataDate (most recent finalized day) instead of hardcoded yesterday
        await api.refreshLatestCompleteDataDate()

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let targetDate = api.latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()

        let records = await api.fetchMeterRecords(fromDate: targetDate, toDate: targetDate)

        await MainActor.run {
            if !records.isEmpty {
                // Values are in cents, divide by 100 for dollars
                let earnings = records.compactMap { $0.earnings }.reduce(0, +) / 100.0
                let costs = records.compactMap { $0.costs }.reduce(0, +) / 100.0
                todayNet = earnings - costs
            } else {
                todayNet = nil
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

// MARK: - Status Detail View

struct StatusDetailView: View {
    @ObservedObject var api: PowstonAPI
    @ObservedObject var refreshManager = SmartRefreshManager.shared
    @Environment(\.dismiss) var dismiss
    
    var controllerIcon: String {
        switch api.controllerHealthStatus {
        case .healthy: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .offline: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    
    var controllerStatusText: String {
        switch api.controllerHealthStatus {
        case .healthy: return "All Online"
        case .degraded(let count): return "\(count) Offline"
        case .offline: return "All Offline"
        case .unknown: return "Unknown"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Status")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Next Update Countdown
                        HStack {
                            Image(systemName: refreshManager.isPolling ? "arrow.triangle.2.circlepath" : "timer")
                                .foregroundColor(refreshManager.isPolling ? .blue : .green)
                            Text("Next Update:")
                            Spacer()
                            if refreshManager.isPolling {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Updating...")
                                        .foregroundColor(.blue)
                                }
                            } else {
                                Text(refreshManager.countdownText)
                                    .foregroundColor(.green)
                                    .fontWeight(.medium)
                                    .monospacedDigit()
                            }
                        }
                        .font(.subheadline)
                        
                        // Powston Service Status
                        HStack {
                            Image(systemName: api.powstonServiceOnline ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(api.powstonServiceOnline ? .green : .red)
                            Text("Powston:")
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(api.powstonServiceOnline ? "Online" : "Offline")
                                    .foregroundColor(api.powstonServiceOnline ? .green : .red)
                                if let lastCheck = api.powstonServiceLastCheck {
                                    Text(timeAgo(lastCheck))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .font(.subheadline)
                        
                        // Controller Health Status
            HStack {
                Image(systemName: controllerIcon)
                    .foregroundColor(api.controllerHealthStatus.color)
                Text("Controllers:")
                Spacer()
                Text(controllerStatusText)
                    .foregroundColor(api.controllerHealthStatus.color)
            }
            .font(.subheadline)
            
            if let intervalTime = api.data?.forecastStartDate {
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                    Text("AEMO Interval:")
                    Spacer()
                    Text(formatDateTime(intervalTime))
                        .foregroundColor(.secondary)
                }
                .font(.subheadline)
            }
            
            if let lastFetch = api.lastFetchTime {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                    Text("Last Updated:")
                    Spacer()
                    Text(timeAgo(lastFetch))
                        .foregroundColor(.secondary)
                }
                .font(.subheadline)
            }
            
            if let healthCheck = api.lastControllerHealthCheck {
                HStack {
                    Image(systemName: "heart.text.square")
                        .foregroundColor(.secondary)
                    Text("Health Check:")
                    Spacer()
                    Text(timeAgo(healthCheck))
                        .foregroundColor(.secondary)
                }
                .font(.subheadline)
            }

            // Historical data availability
            HStack {
                Image(systemName: "chart.bar.doc.horizontal")
                    .foregroundColor(historyDataColor)
                Text("History Data:")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let latestDate = api.latestCompleteDataDate {
                        Text(formatHistoryDate(latestDate))
                            .foregroundColor(historyDataColor)
                        if dataLagDays > 1 && isPastDataExpectedTime {
                            Text("\(dataLagDays) days behind")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    } else {
                        Text("Checking...")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .font(.subheadline)
            .task {
                await api.refreshLatestCompleteDataDate()
            }

            Divider()
            
            Button(action: {
                Task {
                    await SmartRefreshManager.shared.forceRefresh()
                }
                dismiss()
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh Now")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 300)
    }
    
    func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
    
    func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins) min\(mins == 1 ? "" : "s") ago"
        } else {
            let hours = Int(interval / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
    }

    /// Days between latest complete data and today
    var dataLagDays: Int {
        guard let latestDate = api.latestCompleteDataDate else { return 0 }
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let today = calendar.startOfDay(for: Date())
        let dataDay = calendar.startOfDay(for: latestDate)
        return calendar.dateComponents([.day], from: dataDay, to: today).day ?? 0
    }

    /// Whether it's late enough to expect yesterday's data (after 10am)
    var isPastDataExpectedTime: Bool {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let hour = calendar.component(.hour, from: Date())
        return hour >= 10
    }

    /// Color for history data indicator
    /// Only shows warning colors after 10am when data should be available
    var historyDataColor: Color {
        guard api.latestCompleteDataDate != nil else { return .secondary }

        // Before 10am, don't warn about lag - data may not be ready yet
        guard isPastDataExpectedTime else { return .green }

        if dataLagDays > 2 {
            return .orange
        } else if dataLagDays > 1 {
            return .yellow
        }
        return .green
    }

    /// Format date for history display (e.g., "Feb 2")
    func formatHistoryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
}

// MARK: - Action Badge View (extracted to help type checker)
struct ActionBadgeView: View {
    @ObservedObject var api: PowstonAPI
    let realtimeAction: String?  // Current decision (real-time)
    let flowAction: String?       // Action from flows (5 min ago)
    
    /// The action to display for color/icon (prefer realtime)
    private var displayedAction: String {
        realtimeAction?.lowercased() ?? flowAction?.lowercased() ?? "auto"
    }
    
    /// Whether there's a transition between flow and realtime action
    private var isTransitioning: Bool {
        guard let realtime = realtimeAction?.lowercased(),
              let flow = flowAction?.lowercased() else { return false }
        return normalizeAction(realtime) != normalizeAction(flow)
    }
    
    /// Normalize action names for comparison
    private func normalizeAction(_ action: String) -> String {
        switch action.lowercased() {
        case "charge", "import": return "import"
        case "discharge", "export": return "export"
        case "auto": return "auto"
        default: return action.lowercased()
        }
    }

    /// Short action name for transition display
    private func shortAction(_ action: String?) -> String {
        guard let action = action?.lowercased() else { return "?" }
        switch action {
        case "charge", "import": return "Import"
        case "discharge", "export": return "Export"
        case "auto": return "Auto"
        default: return action.capitalized
        }
    }

    var badgeColor: Color {
        if api.hasActiveOverride { return .orange }
        if api.hasPendingOverride || api.hasScheduledOverride { return .blue }

        switch displayedAction {
        case "charge", "import": return .green
        case "discharge", "export": return .orange
        case "auto": return .blue
        default: return .secondary
        }
    }

    var iconName: String {
        if api.hasPendingOverride { return "hourglass" }
        if api.hasActiveOverride { return "exclamationmark.triangle.fill" }
        if api.hasScheduledOverride { return "clock.fill" }

        switch displayedAction {
        case "charge": return "battery.100.bolt"
        case "discharge": return "battery.50"
        case "export": return "arrow.up.circle.fill"
        case "import": return "arrow.down.circle.fill"
        case "auto": return "arrow.triangle.2.circlepath"
        default: return "bolt.fill"
        }
    }

    func displayAction(_ action: String?) -> String {
        guard let action = action else { return "Unknown" }
        switch action.lowercased() {
        case "charge": return "Charge"
        case "discharge", "export": return exportLabel
        case "import": return "Import"
        case "auto": return "Auto"
        default: return action.capitalized
        }
    }

    /// Use real-time grid power vs inverter rated power to distinguish export types
    /// No optimal_discharging in real-time data, so grid power is the best proxy
    private var exportLabel: String {
        let gk = api.data?.gridKw ?? 0  // positive = exporting
        guard gk > 0 else { return "Export" }

        // Sum rated power across all site inverters (kW)
        let siteInverters = api.inverters.filter { $0.siteId == api.selectedSiteId }
        let totalRatedKw = siteInverters.isEmpty ? 0 :
            Double(siteInverters.map { $0.dischargeCapacityWatts }.reduce(0, +)) / 1000.0

        // If exporting well below rated capacity, it's throttled for P2P
        if totalRatedKw > 0 && gk < totalRatedKw * 0.8 {
            return gk <= 1.0 ? "Trickle" : "P2P Exp"
        }
        return "Export"
    }
    
    /// The text to show for the action state
    private var actionText: String {
        if isTransitioning {
            // Show transition: "Export → Auto"
            return "\(shortAction(flowAction)) → \(shortAction(realtimeAction))"
        } else {
            // Stable state
            return displayAction(realtimeAction ?? flowAction).uppercased()
        }
    }
    
    var body: some View {
        NavigationLink(destination: ManualOverrideView()) {
            HStack(spacing: 8) {
                // Icon
                if api.hasPendingOverride {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: iconName)
                        .font(.title2)
                }
                
                // Text
                VStack(alignment: .leading, spacing: 2) {
                    if api.hasPendingOverride {
                        Text("PENDING")
                            .font(.headline)
                            .fontWeight(.bold)
                    } else if api.hasActiveOverride, let firstActive = api.currentOverrides.first {
                        Text("MANUAL: \(firstActive.action.uppercased())")
                            .font(.headline)
                            .fontWeight(.bold)
                    } else if api.hasScheduledOverride, let firstScheduled = api.scheduledOverrides.first {
                        Text("SCHED: \(firstScheduled.action.uppercased())")
                            .font(.headline)
                            .fontWeight(.bold)
                        Text(firstScheduled.formattedStartsIn)
                            .font(.caption2)
                            .foregroundColor(.blue)
                    } else {
                        Text(actionText)
                            .font(.headline)
                            .fontWeight(.bold)
                        
                        // Show "transitioning" hint if applicable
                        if isTransitioning {
                            Text("Transitioning")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if !api.hasScheduledOverride && !isTransitioning {
                        Text("Tap to control")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .foregroundColor(badgeColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(badgeColor.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Current action: \(actionText)")
        .accessibilityHint("Double tap to open manual controls")
    }
}
