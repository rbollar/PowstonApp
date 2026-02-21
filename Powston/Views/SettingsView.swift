//
//  SettingsView.swift
//  Powston
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var api: PowstonAPI
    @AppStorage("api_key") private var apiKey = ""
    @AppStorage("appearance_mode") private var appearanceMode: AppearanceMode = .system
    @AppStorage("dashboard_style") private var dashboardStyle: DashboardStyle = .sections
    @AppStorage("use_system_timezone") private var useSystemTimezone: Bool = true
    @AppStorage("use_dev_server") private var useDevServer: Bool = false
    @AppStorage("show_experimental_features") private var showExperimentalFeatures: Bool = false
    @AppStorage("single_site_mode") private var singleSiteMode: Bool = false
    
    // Price alerts (for summary badge)
    @AppStorage("price_alerts_enabled") private var priceAlertsEnabled: Bool = false
    @AppStorage("sell_above_enabled") private var sellAboveEnabled: Bool = false
    @AppStorage("sell_below_enabled") private var sellBelowEnabled: Bool = false
    @AppStorage("buy_above_enabled") private var buyAboveEnabled: Bool = false
    @AppStorage("buy_below_enabled") private var buyBelowEnabled: Bool = false
    
    // Peak hours (for summary badge)
    @AppStorage("peak_enabled") private var peakEnabled: Bool = false
    @AppStorage("peak_start_hour") private var peakStartHour: Double = 16.0
    @AppStorage("peak_end_hour") private var peakEndHour: Double = 21.0
    
    // Leaderboard (for summary badge)
    @AppStorage("leaderboard_enabled") private var leaderboardEnabled: Bool = true
    @AppStorage("leaderboard_default_sort") private var leaderboardDefaultSort: String = "efficiency"
    @AppStorage("comparison_buy_rate") private var comparisonBuyRate: Double = 33.0
    @AppStorage("comparison_sell_rate") private var comparisonSellRate: Double = 5.0
    
    // Scorecard
    @AppStorage("scorecard_enabled") private var scorecardEnabled: Bool = true

    // Optimization Goal
    @AppStorage("optimization_goal") private var optimizationGoal: String = "balanced"

    // Apple Intelligence
    @AppStorage("enableAppleIntelligence") private var enableAppleIntelligence: Bool = true

    @State private var showingApiSetup = false
    @State private var userCoupons: [UserCoupon] = []
    @State private var showDevOptions = false
    @State private var isRefetchingTrades = false
    @State private var refetchTradeResult: String? = nil
    @StateObject private var notificationManager = NotificationManager.shared

    var aboutURL: URL {
        if api.isDemoMode {
            return URL(string: "https://powston.com.au")!
        } else if let site = api.selectedSite {
            return URL(string: "https://app.powston.com/summary/\(site.id)")!
        } else {
            return URL(string: "https://app.powston.com")!
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Connection
                Section("Connection") {
                    if api.isDemoMode {
                        HStack {
                            Image(systemName: "theatermasks.fill").foregroundColor(.orange)
                            Text("Demo Mode").fontWeight(.medium)
                            Spacer()
                            Button("Configure API") { showingApiSetup = true }.font(.subheadline)
                        }
                    } else if api.data != nil || (api.selectedSite != nil && !api.apiKey.isEmpty) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connected").fontWeight(.medium)
                                if let site = api.selectedSite {
                                    Text(site.displayName ?? site.name)
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button("Change") { showingApiSetup = true }.font(.subheadline)
                        }
                    } else if api.isLoading {
                        HStack { ProgressView(); Text("Connecting...").foregroundColor(.secondary) }
                    } else {
                        HStack {
                            Image(systemName: "bolt.slash.circle").foregroundColor(.secondary)
                            Text("Not connected").foregroundColor(.secondary)
                            Spacer()
                            Button("Set Up") { showingApiSetup = true }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                    if let error = api.error, !api.isDemoMode {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(error).font(.caption).foregroundColor(.orange)
                        }
                    }
                    
                    if api.sites.count > 1 {
                        Toggle(isOn: $singleSiteMode) {
                            VStack(alignment: .leading) {
                                Text("Single Site Mode")
                                Text("Show only the currently selected site")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // MARK: - Appearance
                Section("Appearance") {
                    Picker("Theme", selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            HStack { Image(systemName: mode.icon); Text(mode.displayName) }.tag(mode)
                        }
                    }.pickerStyle(.menu)
                    
                    Picker("Dashboard Style", selection: $dashboardStyle) {
                        ForEach(DashboardStyle.allCases, id: \.self) { style in
                            HStack {
                                Image(systemName: style.icon)
                                Text(style.displayName)
                            }.tag(style)
                        }
                    }.pickerStyle(.menu)
                    
                    Toggle(isOn: $useSystemTimezone) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use Site Timezone")
                            Text(useSystemTimezone ? "Based on site location" : "Phone local time")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // MARK: - Features (Nested)
                Section("Features") {
                    NavigationLink {
                        LeaderboardSettingsView()
                    } label: {
                        SettingsRowWithBadge(
                            icon: "chart.bar.fill",
                            iconColor: .purple,
                            title: "Leaderboard",
                            badge: LeaderboardSettingsView.summary(
                                enabled: leaderboardEnabled,
                                buyRate: comparisonBuyRate,
                                sellRate: comparisonSellRate,
                                defaultSort: leaderboardDefaultSort
                            )
                        )
                    }
                    
                    NavigationLink {
                        PriceAlertsSettingsView()
                    } label: {
                        SettingsRowWithBadge(
                            icon: "bell.badge.fill",
                            iconColor: .blue,
                            title: "Price & Spike Alerts",
                            badge: PriceAlertsSettingsView.summary(
                                enabled: priceAlertsEnabled,
                                sellAbove: sellAboveEnabled,
                                sellBelow: sellBelowEnabled,
                                buyAbove: buyAboveEnabled,
                                buyBelow: buyBelowEnabled
                            )
                        )
                    }
                    
                    NavigationLink {
                        PeakHoursSettingsView()
                    } label: {
                        SettingsRowWithBadge(
                            icon: "clock.badge.exclamationmark.fill",
                            iconColor: .orange,
                            title: "Peak Hours",
                            badge: PeakHoursSettingsView.summary(
                                enabled: peakEnabled,
                                startHour: peakStartHour,
                                endHour: peakEndHour
                            )
                        )
                    }

                    NavigationLink {
                        LocalVoltsSetupView()
                    } label: {
                        SettingsRowWithBadge(
                            icon: "bolt.circle.fill",
                            iconColor: .orange,
                            title: "LocalVolts Sync",
                            badge: LocalVoltsSetupView.summary()
                        )
                    }

                    Toggle(isOn: $scorecardEnabled) {
                        HStack {
                            Image(systemName: "gauge.with.dots.needle.33percent")
                                .foregroundColor(.cyan)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Performance Scorecard")
                                Text("Analyze battery performance over time")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // MARK: - Strategy
                Section {
                    Picker(selection: $optimizationGoal) {
                        ForEach(UserGoal.allCases) { goal in
                            HStack {
                                Image(systemName: goal.icon)
                                Text(goal.displayName)
                            }
                            .tag(goal.rawValue)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "target")
                                .foregroundColor(.green)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Optimization Goal")
                                Text(UserGoal(from: optimizationGoal).description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Strategy")
                } footer: {
                    Text("Your optimization goal affects how Action Items (on Decisions tab) prioritizes recommendations.")
                }

                // MARK: - Apple Intelligence
                if #available(iOS 26.0, *) {
                    Section {
                        Toggle(isOn: $enableAppleIntelligence) {
                            HStack {
                                Image(systemName: "apple.intelligence")
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.purple, .blue, .cyan],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Apple Intelligence")
                                    Text("AI-powered summaries and insights")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Apple Intelligence")
                    } footer: {
                        Text("Uses on-device AI to explain controller decisions, generate performance summaries, and forecast prices. All processing happens privately on your device.")
                    }
                }
                
                // MARK: - Sites & Inverters
                if !api.effectiveSites.isEmpty {
                    Section("Sites & Inverters") {
                        ForEach(api.effectiveSites, id: \.id) { site in
                            SiteRow(site: site, api: api, totalBatteryCapacity: totalBatteryCapacity)
                                .id(site.id)
                        }
                        
                        if !singleSiteMode && api.sites.count > 1 {
                            NavigationLink(destination: AllSitesMapView(sites: api.effectiveSites)) {
                                HStack {
                                    Image(systemName: "map.fill")
                                        .foregroundColor(.green)
                                        .frame(width: 24)
                                    Text("View All Sites on Map")
                                    Spacer()
                                    Text("\(api.effectiveSites.count)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.gray.opacity(0.2))
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                    
                    // MARK: - Referral Coupons
                    if !userCoupons.isEmpty {
                        Section {
                            ForEach(userCoupons) { coupon in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(coupon.code)
                                            .font(.system(.body, design: .monospaced))
                                            .fontWeight(.semibold)
                                        Spacer()
                                        Button {
                                            UIPasteboard.general.string = coupon.code
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    Text("Share this code with a friend to give them $150 off the Powston controller!")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        } header: {
                            Text("Your Referral Code")
                        } footer: {
                            Text("Help Powston grow by sharing your referral code.")
                        }
                    }
                    
                    // MARK: - About
                    Section("About") {
                        Link(destination: aboutURL) {
                            HStack {
                                Text(api.isDemoMode ? "Powston Website" : "View in Powston Web")
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        
                        Text("This app is an independent client that connects to Powston systems using their publicly available APIs. It is not affiliated with, endorsed by, or operated by Powston.")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .onLongPressGesture {
                                                        let generator = UIImpactFeedbackGenerator(style: .medium)
                                                        generator.impactOccurred()
                                                        showDevOptions.toggle()
                                                    }
                        
                        Text("Powston helps manage battery and energy system behavior using configurable automation and real-time data. Outcomes depend on energy prices, equipment performance, and site conditions. Users are responsible for ensuring compliance with their energy plan and local requirements.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // Hidden dev options - revealed by long-press on disclaimer
                        if showDevOptions {
                            Toggle(isOn: $useDevServer) {
                                VStack(alignment: .leading) {
                                    Text("Use Dev Server")
                                    Text("dev.inverterintelligence.com")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .onChange(of: useDevServer) { _, _ in
                                api.clearMeterRecordsCache()
                            }
                            .listRowBackground(Color.orange.opacity(0.1))

                            Toggle(isOn: $showExperimentalFeatures) {
                                VStack(alignment: .leading) {
                                    Text("Experimental Features")
                                    Text("Show features not yet ready for public release")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .listRowBackground(Color.purple.opacity(0.1))

                            if LocalVoltsService.shared.hasCredentials {
                                Button {
                                    isRefetchingTrades = true
                                    Task {
                                        if let siteId = api.selectedSite?.id {
                                            let count = await LocalVoltsService.shared.refetchAllTrades(siteId: siteId)
                                            refetchTradeResult = "Fetched \(count) trades"
                                        }
                                        isRefetchingTrades = false
                                    }
                                } label: {
                                    HStack {
                                        if isRefetchingTrades {
                                            ProgressView().scaleEffect(0.8)
                                        }
                                        VStack(alignment: .leading) {
                                            Text("Refetch P2P Trades")
                                            Text(refetchTradeResult ?? "Re-download 60 days of P2P trade history")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .disabled(isRefetchingTrades)
                                .listRowBackground(Color.purple.opacity(0.1))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SiteIndicatorPill()
                }
            }
            .onAppear {
                notificationManager.checkAuthorization()
                Task {
                    userCoupons = await api.fetchUserCoupons()
                }
            }
            .sheet(isPresented: $showingApiSetup) { APISetupView() }
        }
    }
    
    func totalBatteryCapacity(for inverters: [Inverter]) -> String? {
        let total = inverters.compactMap { $0.batteryCapacity }.reduce(0, +)
        guard total > 0 else { return nil }
        let kWh = Double(total) / 1000.0
        return String(format: "%.1f kWh", kWh)
    }
}

// MARK: - Settings Row with Badge
struct SettingsRowWithBadge: View {
    let icon: String
    let iconColor: Color
    let title: String
    let badge: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(badge)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
        }
    }
}

// MARK: - Site Row
struct SiteRow: View {
    let site: Site
    let api: PowstonAPI
    let totalBatteryCapacity: ([Inverter]) -> String?
    @State private var isExpanded = false
    @State private var showTuningParameters = false
    @AppStorage("use_dev_server") private var useDevServer: Bool = false
    
    var body: some View {
        let siteInverters = api.inverters.filter { $0.siteId == site.id }
        let isActiveSite = api.selectedSite?.id == site.id
        let leadInv = api.leadInverter(forSiteId: site.id)
        
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(siteInverters) { inverter in
                InverterRow(inverter: inverter, api: api, isLead: leadInv?.id == inverter.id)
            }
            
            NavigationLink(destination: SiteDetailView(site: site)) {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    Text("Site Details")
                        .foregroundColor(.blue)
                }
            }
            .accessibilityLabel("View details for \(site.displayName ?? site.name)")
            
            NavigationLink(destination: ControllerHealthView(site: site)) {
                HStack {
                    Image(systemName: "heart.text.square")
                        .foregroundColor(.green)
                    Text("Controller Health")
                        .foregroundColor(.green)
                }
            }
            .accessibilityLabel("View controller health for \(site.displayName ?? site.name)")
            
            // Tuning Parameters
            NavigationLink(destination: TrainingParametersView(siteId: site.id, siteName: site.displayName ?? site.name)) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.purple)
                    Text("Tuning Parameters")
                        .foregroundColor(.purple)
                }
            }
            .accessibilityLabel("Edit tuning parameters for \(site.displayName ?? site.name)")
            
        } label: {
            HStack(spacing: 12) {
                Button(action: {
                    Task { await api.switchToSite(site) }
                }) {
                    Circle()
                        .fill(isActiveSite ? Color.blue : Color.gray.opacity(0.3))
                        .frame(width: 20, height: 20)
                        .overlay {
                            if isActiveSite {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isActiveSite ? "Selected site" : "Select this site")
                .accessibilityHint(isActiveSite ? "" : "Double tap to switch to \(site.displayName ?? site.name)")
                
                Image(systemName: "building.2.fill")
                    .foregroundColor(.blue)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.displayName ?? site.name)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Text(site.state ?? "")
                        if let network = site.network {
                            Text("•")
                            Text(network.capitalized)
                        }
                        if let capacity = totalBatteryCapacity(siteInverters) {
                            Text("•")
                            Text(capacity)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(siteAccessibilityLabel(siteInverters, isActiveSite))
        }
    }
            
            func siteAccessibilityLabel(_ inverters: [Inverter], _ isActive: Bool) -> String {
        var label = site.displayName ?? site.name
        if isActive { label += ", currently selected" }
        if let state = site.state { label += ", \(state)" }
        if let network = site.network { label += ", \(network)" }
        if let capacity = totalBatteryCapacity(inverters) { label += ", \(capacity)" }
        label += ", \(inverters.count) inverter\(inverters.count == 1 ? "" : "s")"
        return label
    }
}

// MARK: - Inverter Row
struct InverterRow: View {
    let inverter: Inverter
    let api: PowstonAPI
    let isLead: Bool
    
    var body: some View {
        let isSelected = api.selectedInverterId == inverter.id
        
        HStack {
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundColor(isLead ? .yellow : .clear)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(inverter.productName)
                    .font(.subheadline)
                HStack(spacing: 4) {
                    Text(inverter.manufacturer)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(inverter.serialNumber)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if isLead {
                        Text("• Lead")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                }
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundColor(.green)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            api.selectedInverterId = inverter.id
            api.setLeadInverterOverride(siteId: inverter.siteId, inverterId: inverter.id)
            api.clearMeterRecordsCache()
            Task { await api.fetchData() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(inverterAccessibilityLabel(isSelected))
        .accessibilityHint(isSelected ? "Currently selected" : "Double tap to select this inverter as lead")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
    
    func inverterAccessibilityLabel(_ isSelected: Bool) -> String {
        var label = "\(inverter.manufacturer) \(inverter.productName)"
        if isLead { label += ", lead inverter" }
        if isSelected { label += ", selected" }
        return label
    }
}
